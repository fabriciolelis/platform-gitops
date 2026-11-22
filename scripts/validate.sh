#!/usr/bin/env bash
# Validates the desired state without a cluster or the age key (ADR-008): renders
# every Kustomize entry point, checks the result against the Kubernetes schemas,
# and enforces what may be committed (SPEC.md, Testing strategy).
#
# Usage: scripts/validate.sh [repository root]
# Needs kustomize, kubeconform, yq, and promtool on PATH (pinned versions in
# validate.yml).
set -euo pipefail

root="$(cd "${1:-.}" && pwd)"
kubernetes_version=1.35.9
# Schemas for Argo CD's Application and AppProject, pinned to one commit.
crd_schemas='https://raw.githubusercontent.com/datreeio/CRDs-catalog/3eb90d47aba8d61919d4419dd38301536e32a94b/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cp -R "$root/." "$work/"
rm -rf "$work/.git" "$work/scripts/testdata"

failures=0
fail() {
  echo "FAIL: $*" >&2
  failures=$((failures + 1))
}

# Committed secrets must be SOPS-encrypted.
while IFS= read -r file; do
  yq -e '.sops.mac' "$file" > /dev/null 2>&1 || fail "${file#"$work"/} is not encrypted with SOPS"
done < <(find "$work" -name '*.enc.yaml')

# CI has no age key, so the KSOPS generators (the only `generators:` used here)
# are dropped and everything else still renders.
while IFS= read -r file; do
  yq -i 'del(.generators)' "$file"
done < <(find "$work" -name kustomization.yaml)

# Bases are rendered through their overlays.
entry_points=()
while IFS= read -r file; do
  entry_points+=("$(dirname "$file")")
done < <(find "$work" -name kustomization.yaml -not -path '*/base/*' | sort)

for dir in "${entry_points[@]}"; do
  name="${dir#"$work"/}"
  [ "$dir" = "$work" ] && name="."
  rendered="$work/.rendered.yaml"
  if ! kustomize build "$dir" > "$rendered"; then
    fail "$name does not render"
    continue
  fi
  # The Kubernetes schema catalog has no schema for CustomResourceDefinition
  # itself (it is recursive); the only CRDs here come with the upstream Argo CD.
  kubeconform -strict -summary -kubernetes-version "$kubernetes_version" \
    -skip CustomResourceDefinition \
    -schema-location default -schema-location "$crd_schemas" "$rendered" \
    || fail "$name has resources that do not match their schema"

  # The upstream Argo CD install is not ours to change.
  case "$name" in bootstrap/*) continue ;; esac

  # Secrets only come from the dropped KSOPS generators, so any Secret left
  # in the output was committed unencrypted.
  while IFS= read -r secret; do
    fail "$name: Secret $secret is committed unencrypted"
  done < <(yq -N 'select(.kind == "Secret") | .metadata.name' "$rendered")

  while IFS='|' read -r container image req_cpu req_mem lim_cpu lim_mem; do
    # yq prints an empty line for each document without containers.
    [ -z "$container$image" ] && continue
    tag="${image##*/}"
    if [[ "$tag" != *@sha256:* && ( "$tag" != *:* || "$tag" == *:latest ) ]]; then
      fail "$name: container $container uses $image, which is not pinned to a tag or digest"
    fi
    if [[ -z "$req_cpu" || -z "$req_mem" || -z "$lim_cpu" || -z "$lim_mem" ]]; then
      fail "$name: container $container needs CPU and memory requests and limits"
    fi
  done < <(yq -N '.. | select(tag == "!!map" and has("containers"))
    | (.containers + (.initContainers // []))[]
    | [.name, .image,
       .resources.requests.cpu // "", .resources.requests.memory // "",
       .resources.limits.cpu // "", .resources.limits.memory // ""]
    | join("|")' "$rendered")

  # Prometheus configuration and the rule files next to it are checked by
  # promtool, as Prometheus would load them from the mounted ConfigMap.
  while IFS= read -r configmap; do
    [ -z "$configmap" ] && continue
    config_dir="$work/.prometheus/$configmap"
    mkdir -p "$config_dir"
    while IFS= read -r key; do
      yq -N "select(.kind == \"ConfigMap\" and .metadata.name == \"$configmap\") | .data[\"$key\"]" \
        "$rendered" > "$config_dir/$key"
    done < <(yq -N "select(.kind == \"ConfigMap\" and .metadata.name == \"$configmap\") | .data | keys | .[]" "$rendered")
    if ! output="$(promtool check config "$config_dir/prometheus.yml" 2>&1)"; then
      echo "$output" >&2
      fail "$name: ConfigMap $configmap has an invalid Prometheus configuration"
    fi
  done < <(yq -N 'select(.kind == "ConfigMap" and .data["prometheus.yml"] != null) | .metadata.name' "$rendered")
done

# Unit tests for Prometheus rules, on synthetic series.
while IFS= read -r file; do
  if ! output="$(cd "$(dirname "$file")" && promtool test rules "$(basename "$file")" 2>&1)"; then
    echo "$output" >&2
    fail "${file#"$work"/} has failing Prometheus rule tests"
  fi
done < <(find "$work" -name '*.test.yml' | sort)

if [ "$failures" -gt 0 ]; then
  echo "$failures problem(s) found" >&2
  exit 1
fi
echo "Desired state is valid (${#entry_points[@]} entry point(s))"
