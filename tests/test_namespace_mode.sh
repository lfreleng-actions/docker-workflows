#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation

# Regression test for namespace_mode resolution. Each lane resolves
# the image namespace once, in its gerrit-validate job, and every job
# that names an image reads that job's 'namespace' output. The test
# extracts that step script from each lane and runs it as GitHub runs
# a 'shell: bash' step, checking the resolved value and that invalid
# combinations fail with an ::error:: annotation.
#
# Usage: tests/test_namespace_mode.sh
# Needs bash, yq (either the Go or the Python implementation).

set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

work=$(mktemp -d)
trap 'rm -rf "${work}"' EXIT

failures=0

# resolve_case DESCRIPTION EXPECTED MODE NAMESPACE REPOSITORY [DOCKERHUB]
# EXPECTED is the resolved namespace, or 'error' when the step must fail
resolve_case() {
  local status=0 actual
  : > "${work}/output"
  env -i PATH="${PATH}" HOME="${work}" GITHUB_OUTPUT="${work}/output" \
    NAMESPACE_MODE="$3" NAMESPACE="$4" REPOSITORY="$5" \
    DOCKERHUB_PUBLISH="${6:-false}" \
    bash --noprofile --norc -eo pipefail "${work}/step.sh" \
    > "${work}/log" 2>&1 || status=$?
  actual=$(sed -n 's/^namespace=//p' "${work}/output")
  if [ "$2" = 'error' ] && [ "${status}" -ne 0 ] &&
    grep -q '^::error::' "${work}/log"; then
    echo "ok: ${lane}: $1"
  elif [ "$2" != 'error' ] && [ "${status}" -eq 0 ] &&
    [ "${actual}" = "$2" ]; then
    echo "ok: ${lane}: $1"
  else
    echo "FAIL: ${lane}: $1: expected '$2', got '${actual}' (exit ${status})"
    sed 's/^/  | /' "${work}/log"
    failures=$((failures + 1))
  fi
}

for lane in build-test merge build-test-release; do
  workflow="${root}/.github/workflows/${lane}.yaml"
  yq -r '.jobs."gerrit-validate".steps[] | select(.id == "namespace") | .run' \
    "${workflow}" > "${work}/step.sh"
  if [ ! -s "${work}/step.sh" ]; then
    echo "FAIL: no 'namespace' step in the gerrit-validate job of ${lane}"
    failures=$((failures + 1))
    continue
  fi
  resolve_case 'none resolves no namespace' '' none '' Org/repo
  resolve_case 'auto lowercases the repository owner' \
    'onap-team' auto '' ONAP-Team/repo
  resolve_case 'manual takes the namespace input' onap manual onap Org/repo
  resolve_case 'manual takes a sub-path' 'onap/so' manual 'onap/so' Org/repo
  resolve_case 'an unknown mode fails' error Auto '' Org/repo
  resolve_case 'manual without a namespace fails' error manual '' Org/repo
  resolve_case 'a namespace with mode none fails' error none onap Org/repo
  resolve_case 'a namespace with mode auto fails' error auto onap Org/repo
  resolve_case 'an uppercase namespace fails' error manual ONAP Org/repo
  resolve_case 'a leading separator fails' error manual '-team' Org/repo
  resolve_case 'a trailing slash fails' error manual 'onap/' Org/repo
  resolve_case 'an empty component fails' error manual 'a//b' Org/repo
  if [ "${lane}" = 'build-test-release' ]; then
    resolve_case 'Docker Hub with mode none fails' \
      error none '' Org/repo true
    resolve_case 'Docker Hub with a sub-path fails' \
      error manual 'onap/so' Org/repo true
    resolve_case 'Docker Hub with mode auto resolves the owner' \
      org auto '' Org/repo true
  fi
done

if [ "${failures}" -gt 0 ]; then
  echo "${failures} failure(s)"
  exit 1
fi
echo "All namespace_mode cases passed"
