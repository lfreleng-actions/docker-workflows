#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation

# Regression test for image selection. Every lane declares the select
# and select_dependencies inputs identically and hands both to
# docker-build-matrix-action in its docker-metadata job, without
# allow_empty, so a selection matching nothing still fails. Each lane
# offering build_command refuses it alongside select in its
# gerrit-validate job: the test extracts that step script and runs it
# as GitHub runs a 'shell: bash' step. The build-test legs in
# testing.yaml check which images a selection builds.
#
# Usage: bash tests/test_image_select.sh
# Needs bash and yq (either the Go or the Python implementation).

set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

work=$(mktemp -d)
trap 'rm -rf "${work}"' EXIT

failures=0

# check DESCRIPTION ACTUAL EXPECTED
check() {
  if [ "$2" = "$3" ]; then
    echo "ok: ${lane}: $1"
  else
    echo "FAIL: ${lane}: $1: expected '$3', got '$2'"
    failures=$((failures + 1))
  fi
}

# input NAME FIELD: one field of the lane's workflow_call input NAME
input() {
  yq -r ".on.workflow_call.inputs.$1.$2" "${workflow}"
}

# discover FIELD: one field of the docker-metadata discover step
discover() {
  yq -r ".jobs.\"docker-metadata\".steps[] | select(.id == \"discover\")
    | .$1" "${workflow}"
}

# select_case DESCRIPTION EXPECTED SELECT BUILD_COMMAND
# EXPECTED is 'ok', or 'error' when the step must fail
select_case() {
  local status=0
  env -i PATH="${PATH}" HOME="${work}" SELECT="$3" BUILD_COMMAND="$4" \
    bash --noprofile --norc -eo pipefail "${work}/step.sh" \
    > "${work}/log" 2>&1 || status=$?
  if { [ "$2" = 'error' ] && [ "${status}" -ne 0 ] &&
    grep -q '^::error::select cannot combine with build_command' \
      "${work}/log"; } ||
    { [ "$2" = 'ok' ] && [ "${status}" -eq 0 ] &&
      ! grep -q '^::error::' "${work}/log"; }; then
    echo "ok: ${lane}: $1"
  else
    echo "FAIL: ${lane}: $1: expected ${2} (exit ${status})"
    sed 's/^/  | /' "${work}/log"
    failures=$((failures + 1))
  fi
}

reference=''
for lane in build-test merge build-test-release; do
  workflow="${root}/.github/workflows/${lane}.yaml"

  check 'select is a string' "$(input select type)" string
  check 'select defaults to empty' "$(input select default)" ''
  check 'select_dependencies is a boolean' \
    "$(input select_dependencies type)" boolean
  check 'select_dependencies defaults to true' \
    "$(input select_dependencies default)" true
  check 'select is optional' "$(input select required)" false
  check 'select_dependencies is optional' \
    "$(input select_dependencies required)" false

  # Descriptions must match the first lane's word for word
  descriptions=$(input select description; input select_dependencies description)
  if [ -z "${reference}" ]; then
    reference="${descriptions}"
  fi
  check 'select descriptions match build-test' "${descriptions}" "${reference}"

  # shellcheck disable=SC2016  # literal workflow expressions
  check 'discovery takes select' "$(discover with.select)" \
    '${{ inputs.select }}'
  # shellcheck disable=SC2016
  check 'discovery takes select_dependencies' \
    "$(discover with.select_dependencies)" '${{ inputs.select_dependencies }}'
  check 'discovery does not pass allow_empty' \
    "$(discover with.allow_empty)" null

  yq -r '.jobs."gerrit-validate".steps[] | select(.id == "select") | .run' \
    "${workflow}" > "${work}/step.sh"
  if [ "$(input build_command type)" = null ]; then
    # The release lane offers no build_command, so has nothing to refuse
    check 'no build_command, so no select check' \
      "$(wc -c < "${work}/step.sh" | tr -d ' ')" 0
    continue
  fi
  if [ ! -s "${work}/step.sh" ]; then
    echo "FAIL: ${lane}: no 'select' step in the gerrit-validate job"
    failures=$((failures + 1))
    continue
  fi
  select_case 'neither input set passes' ok '' ''
  select_case 'select alone passes' ok 'api-*' ''
  select_case 'build_command alone passes' ok '' 'make images'
  select_case 'select with build_command fails' error 'api-*' 'make images'
done

if [ "${failures}" -gt 0 ]; then
  echo "${failures} failure(s)"
  exit 1
fi
echo "All image selection cases passed"
