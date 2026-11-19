#!/usr/bin/env bash
# Installs the pinned tools that validate.sh needs (kustomize, kubeconform, yq,
# promtool) into one directory, checking each download against its upstream
# SHA-256. CI and local runs use the same versions from this one place.
#
# Usage: scripts/install-tools.sh <directory>
# Then put <directory> on PATH. Supports Linux and Windows (Git Bash), amd64.
set -euo pipefail

dir="${1:?usage: scripts/install-tools.sh <directory>}"
mkdir -p "$dir"
dir="$(cd "$dir" && pwd)"
case "$(uname -s)" in
  Linux) os=linux; exe= ;;
  MINGW* | MSYS*) os=windows; exe=.exe ;;
  *) echo "unsupported system: $(uname -s)" >&2; exit 1 ;;
esac

# kustomize matches the version built into the pinned Argo CD; promtool comes
# from the Prometheus release that runs in the cluster (ADR-009).
kustomize_version=5.8.1
kubeconform_version=0.8.0
yq_version=4.54.1
prometheus_version=3.15.1

declare -A sha256=(
  [kustomize-linux]=029a7f0f4e1932c52a0476cf02a0fd855c0bb85694b82c338fc648dcb53a819d
  [kustomize-windows]=8ec7f5e815e526d4622c06df0a7793d8cfb6eb1c74f816b46166097fef8b26c6
  [kubeconform-linux]=9bc2bffbf71f261128533edaf912153948b7ff238f9a531ae6d34466ec287883
  [kubeconform-windows]=e3f56102bcf4f50b034a567e2482a1c5330799983ddd655952310211aef73d93
  [yq-linux]=8e34fc298390875de416e6a4afcb8cabeceb25d9aa8506c1a2f9353cf702ea5f
  [yq-windows]=b645f47ebb3a0d2fbab52998550bbd0a1706f23b5ca5f5b48e638c580bb70928
  [prometheus-linux]=6a726885328ad9efebbf36e876ce2fb6225468a71fd1e7ce3ba666d5f4d97a84
  [prometheus-windows]=24349b9121f9a13a0187784aa861060c2c55f5b384954a5961d7ae3620b5d43c
)

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# fetch <tool> <url> <file>: downloads into the work directory and verifies it.
fetch() {
  curl -fsSLo "$work/$3" "$2"
  echo "${sha256[$1-$os]}  $work/$3" | sha256sum -c --quiet -
}

if [ "$os" = linux ]; then archive=tar.gz; else archive=zip; fi
unpack() {
  if [ "$archive" = zip ]; then unzip -qo "$work/$1" "$2" -d "$dir"; else tar -xzf "$work/$1" -C "$dir" "$2"; fi
}

fetch kustomize "https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2Fv${kustomize_version}/kustomize_v${kustomize_version}_${os}_amd64.${archive}" "kustomize.${archive}"
unpack "kustomize.${archive}" "kustomize${exe}"

fetch kubeconform "https://github.com/yannh/kubeconform/releases/download/v${kubeconform_version}/kubeconform-${os}-amd64.${archive}" "kubeconform.${archive}"
unpack "kubeconform.${archive}" "kubeconform${exe}"

fetch yq "https://github.com/mikefarah/yq/releases/download/v${yq_version}/yq_${os}_amd64${exe}" "yq${exe}"
install -m 0755 "$work/yq${exe}" "$dir/yq${exe}"

prometheus="prometheus-${prometheus_version}.${os}-amd64"
fetch prometheus "https://github.com/prometheus/prometheus/releases/download/v${prometheus_version}/${prometheus}.tar.gz" prometheus.tar.gz
tar -xzf "$work/prometheus.tar.gz" -C "$dir" --strip-components=1 "${prometheus}/promtool${exe}"

echo "Installed kustomize, kubeconform, yq, and promtool in $dir"
