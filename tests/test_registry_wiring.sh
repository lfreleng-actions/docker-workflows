#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation

# Regression test for the registry host rule every lane shares (#139).
# docker-promote-action holds the rule (DNS labels of 1 to 63
# characters, a port of 1 to 5 digits within 1-65535, a host Docker
# reads as a host, and a repository path of Docker reference
# components), and its own suite tests it. This test checks each lane
# hands its registry inputs to that action, so the lanes accept and
# reject the same hosts:
# - each lane's 'registry-hosts' step uses docker-promote-action at
#   the commit SHA every other docker-promote-action step pins, in
#   mode validate, with the lane's registry inputs;
# - the step sits where the lane's registry check sat, before
#   anything writes: right after the lane-specific bash check, which
#   is first in merge.yaml's gerrit-validate job;
# - no bash step left beside it carries a pattern or port arithmetic;
# - merge.yaml's bash check, run as GitHub runs a 'shell: bash' step,
#   requires both registries (mode validate checks a base only when
#   it is set) and refuses whitespace (mode validate strips it, while
#   the lane uses each value as given).
#
# Usage: bash tests/test_registry_wiring.sh
# Needs bash and yq (either the Go or the Python implementation).

set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
workflows="${root}/.github/workflows"

failures=0

# check DESCRIPTION ACTUAL EXPECTED
check() {
  if [ "$2" = "$3" ]; then
    echo "ok: $1"
  else
    echo "FAIL: $1: got '$2', expected '$3'"
    failures=$((failures + 1))
  fi
}

# step_field LANE JOB ID FIELD: one field of a step, by its id
step_field() {
  yq -r ".jobs.\"$2\".steps[] | select(.id == \"$3\") | .$4" \
    "${workflows}/$1.yaml"
}

# step_index LANE JOB SELECTOR: the position of the selected step
step_index() {
  yq -r ".jobs.\"$2\".steps | to_entries[] | select(.value | $3) | .key" \
    "${workflows}/$1.yaml"
}

# --- The pin -------------------------------------------------------------

action='lfreleng-actions/docker-promote-action'
pin=''
for lane in merge build-test build-test-release; do
  while IFS= read -r uses; do
    if [[ ! "${uses}" =~ ^${action}@([0-9a-f]{40})$ ]]; then
      echo "FAIL: ${lane}: docker-promote-action is not pinned to a" \
        "commit SHA (got '${uses}')"
      failures=$((failures + 1))
      continue
    fi
    if [ -z "${pin}" ]; then
      pin="${BASH_REMATCH[1]}"
    fi
    check "${lane}: docker-promote-action is at the shared pin" \
      "${BASH_REMATCH[1]}" "${pin}"
  done < <(yq -r '.jobs[] | select(.steps != null) | .steps[]
    | select(.uses != null) | .uses' "${workflows}/${lane}.yaml" \
    | grep "^${action}@")
done
if [ -z "${pin}" ]; then
  echo 'FAIL: no lane uses docker-promote-action'
  exit 1
fi

# --- Each lane's registry-hosts step -------------------------------------

# expect_hosts LANE JOB PULL PUSH IF KEYS: the lane's registry-hosts
# step validates PULL and PUSH ('null' when absent) under condition IF
# ('null' when it has none), and passes the inputs KEYS alone
expect_hosts() {
  local lane="$1" job="$2"
  check "${lane}: the registry-hosts step uses docker-promote-action" \
    "$(step_field "${lane}" "${job}" registry-hosts uses)" \
    "${action}@${pin}"
  check "${lane}: the registry-hosts step runs mode validate" \
    "$(step_field "${lane}" "${job}" registry-hosts with.mode)" validate
  check "${lane}: the registry-hosts step validates pull_registry" \
    "$(step_field "${lane}" "${job}" registry-hosts with.pull_registry)" \
    "$3"
  check "${lane}: the registry-hosts step validates push_registry" \
    "$(step_field "${lane}" "${job}" registry-hosts with.push_registry)" \
    "$4"
  check "${lane}: the registry-hosts step passes nothing else" \
    "$(yq -r ".jobs.\"${job}\".steps[] | select(.id == \"registry-hosts\")
      | .with | keys | sort | join(\" \")" "${workflows}/${lane}.yaml")" \
    "$6"
  check "${lane}: the registry-hosts step condition" \
    "$(step_field "${lane}" "${job}" registry-hosts if)" "$5"
}

# shellcheck disable=SC2016  # literal workflow expressions
{
  expect_hosts merge gerrit-validate \
    '${{ inputs.snapshot_registry }}' '${{ inputs.release_registry }}' \
    null 'mode pull_registry push_registry'
  expect_hosts build-test check-release \
    '${{ inputs.snapshot_registry }}' '${{ inputs.release_registry }}' \
    null 'mode pull_registry push_registry'
  expect_hosts build-test-release gerrit-validate \
    null '${{ inputs.registry }}' "inputs.registry != ''" \
    'mode push_registry'
}

# --- Position: before anything writes ------------------------------------

check 'merge: the registries step is first in gerrit-validate' \
  "$(step_index merge gerrit-validate '.id == "registries"')" 0
# The registries step fails the job first, so the action only ever
# sees both registries set
for lane in merge:gerrit-validate build-test:check-release; do
  check "${lane%%:*}: the registry-hosts step follows the registries step" \
    "$(step_index "${lane%%:*}" "${lane#*:}" '.id == "registry-hosts"')" \
    "$(($(step_index "${lane%%:*}" "${lane#*:}" '.id == "registries"') + 1))"
done
check 'build-test-release: the registry-hosts step follows the lane check' \
  "$(step_index build-test-release gerrit-validate '.id == "registry-hosts"')" \
  "$(($(step_index build-test-release gerrit-validate \
    '.name == "Validate registry inputs"') + 1))"

# --- No host rule left in bash -------------------------------------------

# no_host_rule LANE JOB SELECTOR: the selected bash step neither
# matches a pattern nor does port arithmetic
no_host_rule() {
  local script
  script=$(yq -r ".jobs.\"$2\".steps[] | select($3) | .run" \
    "${workflows}/$1.yaml")
  if [ -z "${script}" ] || [ "${script}" = null ]; then
    echo "FAIL: $1: no bash registry step in $2"
    failures=$((failures + 1))
  elif grep -qE '=~|10#|65535' <<< "${script}"; then
    echo "FAIL: $1: the bash registry step in $2 still holds a host rule"
    failures=$((failures + 1))
  else
    echo "ok: $1: the bash registry step holds no host rule"
  fi
}

no_host_rule merge gerrit-validate '.id == "registries"'
no_host_rule build-test check-release '.id == "registries"'
no_host_rule build-test-release gerrit-validate \
  '.name == "Validate registry inputs"'
check 'merge: gerrit-validate has one bash registry step' \
  "$(yq -r '[.jobs."gerrit-validate".steps[]
    | select(.run != null and (.name | test("[Rr]egistr")))] | length' \
    "${workflows}/merge.yaml")" 1

# --- merge.yaml's registries step ----------------------------------------

work=$(mktemp -d)
trap 'rm -rf "${work}"' EXIT
step_field merge gerrit-validate registries run > "${work}/registries.sh"

# registries_case DESCRIPTION EXPECTED SNAPSHOT RELEASE
# EXPECTED is 'ok', or 'error' when the step must fail
registries_case() {
  local status=0
  env -i PATH="${PATH}" HOME="${work}" \
    SNAPSHOT_REGISTRY="$3" RELEASE_REGISTRY="$4" \
    bash --noprofile --norc -eo pipefail "${work}/registries.sh" \
    > "${work}/log" 2>&1 || status=$?
  if { [ "$2" = ok ] && [ "${status}" -eq 0 ]; } ||
    { [ "$2" = error ] && [ "${status}" -ne 0 ] &&
      grep -q '^::error::' "${work}/log"; }; then
    echo "ok: merge: registries: $1"
  else
    echo "FAIL: merge: registries: $1 (exit ${status})"
    sed 's/^/  | /' "${work}/log"
    failures=$((failures + 1))
  fi
}

registries_case 'Nexus 3 ports pass' ok \
  nexus3.onap.org:10003 nexus3.onap.org:10002
registries_case 'Artifactory repository paths pass' ok \
  acme.jfrog.io/docker-snapshot linuxfoundation.jfrog.io/docker-local
registries_case 'an empty release registry fails' error \
  nexus3.onap.org:10003 ''
registries_case 'an empty snapshot registry fails' error \
  '' nexus3.onap.org:10002
registries_case 'a whitespace-only release registry fails' error \
  nexus3.onap.org:10003 ' '
registries_case 'a trailing space fails' error \
  'acme.jfrog.io/docker-snapshot ' acme.jfrog.io/docker-release
registries_case 'a leading tab fails' error \
  acme.jfrog.io/docker-snapshot $'\tacme.jfrog.io/docker-release'
registries_case 'a trailing newline fails' error \
  acme.jfrog.io/docker-snapshot $'acme.jfrog.io/docker-release\n'
registries_case 'a non-ASCII space fails' error \
  $'nexus3.onap.org:10003\xc2\xa0' nexus3.onap.org:10002

if [ "${failures}" -ne 0 ]; then
  echo "${failures} check(s) failed"
  exit 1
fi
echo 'All registry wiring checks passed'
