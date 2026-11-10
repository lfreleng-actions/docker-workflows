#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation

# Wiring test for the source checkout in the three lanes
# (build-test.yaml, merge.yaml and build-test-release.yaml, #127).
# Each job that checks out source does so in one step, through
# checkout-gerrit-change-action, which serves Gerrit and plain runs
# alike. It checks, for every job of each lane:
# - no step uses actions/checkout directly;
# - a job holds at most one checkout step, and every one uses
#   checkout-gerrit-change-action at the single commit the lanes
#   share, with no 'if:', so both modes go through it;
# - the step leaves no credential in the clone (persist-credentials
#   false), passes checkout_submodules as 'submodules', and passes
#   the Gerrit refspec, project, branch and URL inputs;
# - each lane declares checkout_submodules as a boolean, default
#   false, so a caller that omits it checks out no submodules;
# - each lane holds the number of checkout steps it had as pairs.
# A real submodule leg needs a fixture whose Dockerfile lives inside
# a submodule; none exists, so this test stands for it.
#
# Usage: bash tests/test_checkout_wiring.sh
# Needs bash and mikefarah yq.

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

action='lfreleng-actions/checkout-gerrit-change-action'

# shellcheck disable=SC2016  # literal workflow expressions
{
  refspec='${{ inputs.gerrit_refspec }}'
  # merge.yaml: a supplied gerrit_revision selects plain mode, which
  # checks out the merged commit from the mirror
  refspec_revision="\${{ inputs.gerrit_revision == '' && inputs.gerrit_refspec || '' }}"
  project='${{ inputs.gerrit_project }}'
  branch='${{ inputs.gerrit_branch }}'
  url="\${{ inputs.gerrit_url != '' && inputs.gerrit_url || vars.GERRIT_URL }}"
  submodules='${{ inputs.checkout_submodules }}'
}

pins=''
for lane in build-test:6 merge:7 build-test-release:8; do
  name="${lane%%:*}"
  expected="${lane##*:}"
  file="${workflows}/${name}.yaml"

  check "${name}: checkout_submodules is a boolean" \
    "$(yq -r '.on.workflow_call.inputs.checkout_submodules.type' "${file}")" \
    boolean
  check "${name}: checkout_submodules defaults to false" \
    "$(yq -r '.on.workflow_call.inputs.checkout_submodules.default' \
      "${file}")" false

  check "${name}: no step uses actions/checkout" \
    "$(yq -r '[.jobs[].steps[]? | select((.uses // "")
      | test("^actions/checkout@"))] | length' "${file}")" 0

  check "${name}: ${expected} checkout steps" \
    "$(yq -r "[.jobs[].steps[]? | select((.uses // \"\")
      | test(\"^${action}@\"))] | length" "${file}")" "${expected}"

  while IFS= read -r job; do
    steps=$(yq -r ".jobs.\"${job}\".steps[]? | select((.uses // \"\")
      | test(\"checkout\")) | .uses" "${file}")
    count=$(grep -c . <<< "${steps}" || true)
    if [ "${count}" -eq 0 ]; then
      continue
    fi
    check "${name}/${job}: one checkout step" "${count}" 1
    case "${steps}" in
      "${action}@"*) ;;
      *)
        echo "FAIL: ${name}/${job}: checks out with '${steps}'"
        failures=$((failures + 1))
        continue
        ;;
    esac
    pins="${pins}${steps}"$'\n'

    sel=".jobs.\"${job}\".steps[] | select((.uses // \"\")
      | test(\"^${action}@\"))"
    field() {
      yq -r "${sel} | .$1" "${file}"
    }
    check "${name}/${job}: the step runs in both modes" "$(field if)" null
    check "${name}/${job}: persist-credentials is false" \
      "$(field 'with."persist-credentials"')" false
    check "${name}/${job}: submodules follows checkout_submodules" \
      "$(field 'with.submodules')" "${submodules}"
    check "${name}/${job}: gerrit-project is passed" \
      "$(field 'with."gerrit-project"')" "${project}"
    check "${name}/${job}: gerrit-branch is passed" \
      "$(field 'with."gerrit-branch"')" "${branch}"
    check "${name}/${job}: gerrit-url is passed" \
      "$(field 'with."gerrit-url"')" "${url}"
    got=$(field 'with."gerrit-refspec"')
    if [ "${got}" = "${refspec}" ] ||
      { [ "${name}" = merge ] && [ "${got}" = "${refspec_revision}" ]; }; then
      echo "ok: ${name}/${job}: gerrit-refspec is passed"
    else
      echo "FAIL: ${name}/${job}: gerrit-refspec is '${got}'"
      failures=$((failures + 1))
    fi
  done < <(yq -r '.jobs | keys | .[]' "${file}")
done

check 'the lanes share one checkout-gerrit-change-action pin' \
  "$(sed '/^$/d; s/ *#.*//' <<< "${pins}" | sort -u | wc -l | tr -d ' ')" 1

if [ "${failures}" -ne 0 ]; then
  echo "${failures} check(s) failed"
  exit 1
fi
echo 'All checkout wiring checks passed'
