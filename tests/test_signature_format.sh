#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation

# Regression test for the release lane's signature_format input (#114).
# A real signature needs pushed images and Sigstore, which no self-test
# reaches, so this tests what decides the stored format: the cosign
# release the sign job installs, and the arguments it passes to
# 'cosign sign'.
#
# The test reads the wiring from the workflow, then extracts two step
# scripts and runs each as GitHub runs a 'shell: bash' step:
#
# - the gerrit-validate job's 'signature-format' step, which must
#   accept bundle and legacy and reject anything else up front
# - the sign job's signing step, against a fake cosign on PATH that
#   records its arguments, which must pass the flags each format needs
#
# Usage: tests/test_signature_format.sh [workflow-file]
# Needs bash and yq (either the Go or the Python implementation).

set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
workflow="${1:-${root}/.github/workflows/build-test-release.yaml}"

work=$(mktemp -d)
trap 'rm -rf "${work}"' EXIT

failures=0

fail() {
  echo "FAIL: $1"
  failures=$((failures + 1))
}

# query EXPRESSION: a yq query against the workflow, 'null' when absent
query() {
  yq -r "$1" "${workflow}"
}

# expect DESCRIPTION ACTUAL EXPECTED
expect() {
  if [ "$2" = "$3" ]; then
    echo "ok: $1"
  else
    fail "$1: got '$2', expected '$3'"
  fi
}

# --- Wiring --------------------------------------------------------------

# The Python yq reads the 'on' key as YAML 1.1's boolean true
expect 'signature_format defaults to bundle' \
  "$(query '(.on // .["true"]).workflow_call.inputs.signature_format.default')" \
  bundle

install='.jobs.sign.steps[] | select(.uses // "" | test("^sigstore/cosign-installer@"))'
uses=$(query "${install} | .uses")
if [[ "${uses}" =~ ^sigstore/cosign-installer@[0-9a-f]{40}$ ]]; then
  echo 'ok: cosign-installer is pinned to a commit SHA'
else
  fail "cosign-installer is not pinned to a commit SHA (got '${uses}')"
fi
expect 'the installed cosign release is pinned' \
  "$(query "${install} | .with.\"cosign-release\"")" v3.0.6

sign='.jobs.sign.steps[] | select(.run // "" | test("cosign sign"))'
# shellcheck disable=SC2016  # literal workflow expressions
expect 'the sign step reads signature_format' \
  "$(query "${sign} | .env.SIGNATURE_FORMAT")" \
  '${{ inputs.signature_format }}'

validate='.jobs."gerrit-validate".steps[] | select(.id == "signature-format")'
# shellcheck disable=SC2016
expect 'the validation step reads signature_format' \
  "$(query "${validate} | .env.SIGNATURE_FORMAT")" \
  '${{ inputs.signature_format }}'

# --- Up-front validation ---------------------------------------------------

query "${validate} | .run" > "${work}/validate.sh"
if [ ! -s "${work}/validate.sh" ] || [ "$(cat "${work}/validate.sh")" = null ]
then
  echo "FAIL: no 'signature-format' step in the gerrit-validate job"
  exit 1
fi

# validate_case DESCRIPTION FORMAT EXPECTED ('ok' or 'error')
validate_case() {
  local status=0
  env -i PATH="${PATH}" HOME="${work}" SIGNATURE_FORMAT="$2" \
    bash --noprofile --norc -eo pipefail "${work}/validate.sh" \
    > "${work}/log" 2>&1 || status=$?
  if [ "$3" = 'error' ] && [ "${status}" -ne 0 ] &&
    grep -q '^::error::Invalid signature_format' "${work}/log"; then
    echo "ok: $1"
  elif [ "$3" = 'ok' ] && [ "${status}" -eq 0 ]; then
    echo "ok: $1"
  else
    fail "$1: expected $3 (exit ${status})"
    sed 's/^/  | /' "${work}/log"
  fi
}

validate_case 'bundle validates' bundle ok
validate_case 'legacy validates' legacy ok
validate_case 'an empty format fails' '' error
validate_case 'the format is case-sensitive' Legacy error
validate_case 'an unknown format fails' oci-1-1 error

# --- Signing arguments -----------------------------------------------------

query "${sign} | .run" > "${work}/sign.sh"
if [ ! -s "${work}/sign.sh" ] || [ "$(cat "${work}/sign.sh")" = null ]; then
  echo 'FAIL: no cosign sign step in the sign job'
  exit 1
fi

mkdir -p "${work}/bin"
# Records one argument per line and succeeds, as a signature push would
cat > "${work}/bin/cosign" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "${COSIGN_ARGS}"
EOF
chmod +x "${work}/bin/cosign"

image='ghcr.io/probeorg/probe'
digest="sha256:$(printf 'a%.0s' {1..64})"

# sign_case DESCRIPTION FORMAT EXPECTED
# EXPECTED is the cosign argument list, space separated, or 'error'
# when the step must fail without running cosign
sign_case() {
  local status=0 actual
  rm -f "${work}/args"
  : > "${work}/summary"
  env -i PATH="${work}/bin:${PATH}" HOME="${work}" \
    COSIGN_ARGS="${work}/args" GITHUB_STEP_SUMMARY="${work}/summary" \
    IMAGE="${image}" DIGEST="${digest}" REQUIRED_REGISTRIES='ghcr.io' \
    SIGNATURE_FORMAT="$2" \
    bash --noprofile --norc -eo pipefail "${work}/sign.sh" \
    > "${work}/log" 2>&1 || status=$?
  if [ "$3" = 'error' ]; then
    if [ "${status}" -ne 0 ] && [ ! -e "${work}/args" ] &&
      grep -q '^::error::Invalid signature_format' "${work}/log"; then
      echo "ok: $1"
      return
    fi
    actual="exit ${status}"
  else
    actual=$(paste -sd ' ' "${work}/args" 2> /dev/null || true)
    if [ "${status}" -eq 0 ] && [ "${actual}" = "$3" ]; then
      echo "ok: $1"
      return
    fi
  fi
  fail "$1"
  echo "  expected: $3"
  echo "  actual:   ${actual:-<none>} (exit ${status})"
  sed 's/^/  | /' "${work}/log"
}

sign_case 'bundle signs with cosign defaults' bundle \
  "sign --yes ${image}@${digest}"
legacy='--new-bundle-format=false --use-signing-config=false'
sign_case 'legacy turns off the bundle format and signing config' legacy \
  "sign --yes ${legacy} ${image}@${digest}"
sign_case 'an unknown format fails before signing' oci-1-1 error

if [ "${failures}" -gt 0 ]; then
  echo "${failures} case(s) failed"
  exit 1
fi
echo 'All cases passed'
