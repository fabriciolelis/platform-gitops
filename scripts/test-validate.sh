#!/usr/bin/env bash
# Checks that validate.sh accepts valid desired state and rejects each rule,
# for the right reason, using the cases in scripts/testdata.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
status=0

# expect <case> <expected message, or "valid">
expect() {
  output="$("$here/validate.sh" "$here/testdata/$1" 2>&1)"
  result=$?
  if [ "$2" = valid ] && [ "$result" -eq 0 ]; then
    echo "ok   $1"
  elif [ "$2" != valid ] && [ "$result" -ne 0 ] && grep -qF "$2" <<< "$output"; then
    echo "ok   $1"
  else
    echo "FAIL $1: expected \"$2\""
    echo "$output" | sed 's/^/     /'
    status=1
  fi
}

expect valid valid
expect no-containers valid
expect unencrypted-secret "Secret demo is committed unencrypted"
expect plaintext-enc-file "secret.enc.yaml is not encrypted with SOPS"
expect untagged-image "not pinned to a tag or digest"
expect latest-image "not pinned to a tag or digest"
expect missing-limits "needs CPU and memory requests and limits"
expect invalid-prometheus-config "has an invalid Prometheus configuration"
expect invalid-prometheus-rule "has an invalid Prometheus configuration"
expect failing-rule-test "has failing Prometheus rule tests"

exit "$status"
