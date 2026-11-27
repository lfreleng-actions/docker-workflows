#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation

# Regression test for select_changed (#126). The verify and merge
# lanes declare it alike; their docker-metadata job checks out deep
# enough to reach the comparison base, asks dependency-change-action
# for the changed paths before discovery, and hands them to
# docker-build-matrix-action as changed_files, unchanged, so an
# unresolved diff (empty) builds every image and is never turned into
# '[]'. The report step, extracted and run as GitHub runs a
# 'shell: bash' step, records whether the diff resolved and emits the
# notice when it did not. An empty selection skips the build job. The
# release lane builds every image, so it has none of this. Both
# actions keep one full commit pin per action across the lanes, with
# a version comment no older than the release the wiring needs.
# tests/test_image_select.sh covers the conflicting-input checks and
# allow_empty; the selection logic itself is tested in
# docker-build-matrix-action. Both lanes export selection_reason and
# changes_resolved. The resolved calls in testing.yaml build
# tests/fixtures/select-changed at the run's commit; this checks their
# wiring and runs tests/select_changed_oracle.sh, which predicts their
# selections, on fixed diffs.
#
# Usage: bash tests/test_change_selection_wiring.sh
# Needs bash, jq and yq (the Go implementation).

set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
workflows="${root}/.github/workflows"
release="${workflows}/build-test-release.yaml"
testing="${workflows}/testing.yaml"

work=$(mktemp -d)
trap 'rm -rf "${work}"' EXIT

failures=0

# check DESCRIPTION ACTUAL EXPECTED
check() {
  if [ "$2" = "$3" ]; then
    echo "ok: $1"
  else
    echo "FAIL: $1: expected '$3', got '$2'"
    failures=$((failures + 1))
  fi
}

matrix_action='lfreleng-actions/docker-build-matrix-action'
# Oldest release with changed_files, select_dependents, allow_empty
# and selection_reason
matrix_floor='0.2.0'
change_action='lfreleng-actions/dependency-change-action'
# Oldest release with the changed-paths output
change_floor='0.3.0'

# action_pin_of ACTION FLOOR FILE...: print the shared commit, or
# report the breaches. Each file must call ACTION, every call on a
# uses: line with a full commit SHA and a '# vX.Y.Z' comment, all
# calls on one pin, no older than FLOOR.
action_pin_of() {
  local action=$1 floor=$2
  shift 2
  local file entry line found pin='' version='' form errors=()
  form="^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]+${action}@([0-9a-f]{40})[[:space:]]+#[[:space:]]+v([0-9]+\.[0-9]+\.[0-9]+)\$"
  for file in "$@"; do
    found=0
    while IFS= read -r entry; do
      found=1
      line=${entry#*:}
      if [[ ! "${line}" =~ ${form} ]]; then
        errors+=("${file##*/}:${entry%%:*}: not a full commit SHA with its '# vX.Y.Z' comment")
      elif [ -z "${pin}" ]; then
        pin=${BASH_REMATCH[2]}
        version=${BASH_REMATCH[3]}
      elif [ "${BASH_REMATCH[2]} ${BASH_REMATCH[3]}" != \
        "${pin} ${version}" ]; then
        errors+=("${file##*/}:${entry%%:*}: pins ${BASH_REMATCH[2]} (v${BASH_REMATCH[3]}), but another call pins ${pin} (v${version})")
      fi
    done < <(grep -nE "uses:[[:space:]]*['\"]?${action}@" "${file}" || true)
    if [ "${found}" -eq 0 ]; then
      errors+=("${file##*/}: never calls ${action}")
    fi
  done
  if [ -n "${version}" ] && [ "$(printf '%s\n' "${floor}" "${version}" \
    | sort -V | head -n 1)" != "${floor}" ]; then
    errors+=("the pin names v${version}, older than v${floor}")
  fi
  if [ "${#errors[@]}" -ne 0 ]; then
    printf '%s\n' "${errors[@]}"
    return 1
  fi
  echo "${pin}"
}

# yaml_calls ACTION FILE: the calls YAML sees, whatever their form
yaml_calls() {
  yq -r "[.jobs[] | (.uses, .steps[]?.uses) | select(. != null)
    | select(split(\"@\")[0] == \"$1\")] | length" "$2"
}

# metadata_step ID FIELD: one field of a docker-metadata step
metadata_step() {
  yq -r ".jobs.\"docker-metadata\".steps[] | select(.id == \"$1\") | .$2" \
    "${workflow}"
}

# --- The two lanes that select by change -----------------------------

reference=''
for lane in build-test merge; do
  workflow="${workflows}/${lane}.yaml"

  check "${lane}: select_changed is a boolean" \
    "$(yq -r '.on.workflow_call.inputs.select_changed.type' "${workflow}")" \
    boolean
  check "${lane}: select_changed defaults to false" \
    "$(yq -r '.on.workflow_call.inputs.select_changed.default' \
      "${workflow}")" false
  check "${lane}: select_changed is optional" \
    "$(yq -r '.on.workflow_call.inputs.select_changed.required' \
      "${workflow}")" false
  description=$(yq -r '.on.workflow_call.inputs.select_changed.description' \
    "${workflow}")
  if [ -z "${reference}" ]; then
    reference="${description}"
  fi
  check "${lane}: select_changed description matches build-test" \
    "${description}" "${reference}"

  # Checkout, then the changed paths, then the report, then discovery
  check "${lane}: docker-metadata step order" \
    "$(yq -r '[.jobs."docker-metadata".steps[]
      | select(.name == "Checkout" or .id == "changes"
        or .id == "change-scope" or .id == "discover")
      | .id // .name] | join(" ")' "${workflow}")" \
    'Checkout changes change-scope discover'

  # A push compares against github.event.before, which a depth-2
  # clone lacks; the full history reaches it, and a Gerrit change
  # needs only its parent
  # shellcheck disable=SC2016
  check "${lane}: docker-metadata checks out deep enough for the base" \
    "$(yq -r '.jobs."docker-metadata".steps[] | select(.name == "Checkout")
      | .with."fetch-depth"' "${workflow}")" \
    "\${{ inputs.gerrit_refspec != '' && '2' || '0' }}"

  check "${lane}: changed paths come from ${change_action}" \
    "$(metadata_step changes uses | cut -d@ -f1)" "${change_action}"
  check "${lane}: changed paths only under select_changed" \
    "$(metadata_step changes if)" 'inputs.select_changed'
  check "${lane}: the change action takes the docker preset" \
    "$(metadata_step changes with.ecosystems)" docker
  # shellcheck disable=SC2016
  check "${lane}: the change action takes gerrit_refspec" \
    "$(metadata_step changes 'with."gerrit-refspec"')" \
    '${{ inputs.gerrit_refspec }}'
  # shellcheck disable=SC2016
  check "${lane}: the change action takes path_prefix" \
    "$(metadata_step changes 'with."path-prefix"')" \
    '${{ inputs.path_prefix }}'
  check "${lane}: the report runs only under select_changed" \
    "$(metadata_step change-scope if)" 'inputs.select_changed'

  # The paths pass through as they are: empty stays empty
  # shellcheck disable=SC2016
  check "${lane}: changed_files is the changed-paths output, unchanged" \
    "$(metadata_step discover with.changed_files)" \
    '${{ steps.changes.outputs.changed-paths }}'
  check "${lane}: discovery selects dependents" \
    "$(metadata_step discover with.select_dependents)" true
  # shellcheck disable=SC2016
  check "${lane}: docker-metadata exports selection_reason" \
    "$(yq -r '.jobs."docker-metadata".outputs.selection_reason' \
      "${workflow}")" '${{ steps.discover.outputs.selection_reason }}'
  check "${lane}: an empty selection skips the build job" \
    "$(yq -r '.jobs.build.if' "${workflow}")" \
    "needs.docker-metadata.outputs.selection_reason != 'none'"
  # shellcheck disable=SC2016
  check "${lane}: docker-metadata exports changes_resolved" \
    "$(yq -r '.jobs."docker-metadata".outputs.changes_resolved' \
      "${workflow}")" '${{ steps.change-scope.outputs.resolved }}'
  for output in selection_reason changes_resolved; do
    check "${lane}: the ${output} workflow output" \
      "$(yq -r ".on.workflow_call.outputs.${output}.value" "${workflow}")" \
      "\${{ jobs.docker-metadata.outputs.${output} }}"
  done
  check "${lane}: an empty selection is reported" \
    "$(yq -r '[.jobs."docker-metadata".steps[]
      | select(.if == "steps.discover.outputs.selection_reason == '"'none'"'")
      | .run | test("::notice::")] | join(" ")' "${workflow}")" true

  # Run the report step: resolved, then unresolved
  metadata_step change-scope run > "${work}/report.sh"
  for paths in '["a/Dockerfile","README.md"]' ''; do
    : > "${work}/output"
    status=0
    env -i PATH="${PATH}" HOME="${work}" GITHUB_OUTPUT="${work}/output" \
      CHANGED_PATHS="${paths}" \
      CHANGES_REASON=$'unresolved: HEAD is not GITHUB_SHA\n::error::forged' \
      bash --noprofile --norc -eo pipefail "${work}/report.sh" \
      > "${work}/log" 2>&1 || status=$?
    notices=$(grep -c '^::notice::' "${work}/log" || true)
    forged=$(grep -c '^::error::' "${work}/log" || true)
    if [ -n "${paths}" ]; then
      check "${lane}: a resolved diff reports quietly" \
        "${status} $(cat "${work}/output") ${notices}" '0 resolved=true 0'
    else
      check "${lane}: an unresolved diff reports with a notice" \
        "${status} $(cat "${work}/output") ${notices} ${forged}" \
        '0 resolved=false 1 0'
    fi
  done
done

# --- The release lane builds every image ------------------------------

check 'build-test-release: no select_changed input' \
  "$(yq -r '.on.workflow_call.inputs.select_changed' "${release}")" null
check "build-test-release: never calls ${change_action}" \
  "$(yaml_calls "${change_action}" "${release}")" 0
check 'build-test-release: discovery takes no changed_files' \
  "$(yq -r '.jobs."docker-metadata".steps[] | select(.id == "discover")
    | .with.changed_files' "${release}")" null

# --- Pins, by agreement and floor, never by value ---------------------

lanes=("${workflows}/build-test.yaml" "${workflows}/merge.yaml")
check "the verify and merge lanes call ${change_action} once each" \
  "$(yaml_calls "${change_action}" "${lanes[0]}") $(yaml_calls \
    "${change_action}" "${lanes[1]}")" '1 1'
for action_floor in "${matrix_action} ${matrix_floor} 3" \
  "${change_action} ${change_floor} 2"; do
  read -r action floor count <<< "${action_floor}"
  files=("${lanes[@]}")
  if [ "${count}" -eq 3 ]; then
    files+=("${release}")
  fi
  # The textual scan must see every call YAML sees
  for file in "${files[@]}"; do
    check "${file##*/}: every ${action} call is on a uses line" \
      "$(grep -cE "uses:[[:space:]]*['\"]?${action}@" "${file}" || true)" \
      "$(yaml_calls "${action}" "${file}")"
  done
  if pin=$(action_pin_of "${action}" "${floor}" "${files[@]}"); then
    echo "ok: the lanes share one ${action} pin, v${floor} or later"
  else
    echo "FAIL: the ${action} pins:"
    printf '  %s\n' "${pin}"
    failures=$((failures + 1))
  fi
done

# --- The self-test -----------------------------------------------------

check 'testing.yaml runs this script' \
  "$(yq -r '[.jobs[].steps[]?.run | select(. != null)
    | select(test("bash tests/test_change_selection_wiring.sh"))]
    | length' "${testing}")" 1
check 'testing.yaml calls build-test with select_changed' \
  "$(yq -r '.jobs."build-test-select-changed"
    | [.uses, .with.select_changed] | join(" ")' "${testing}")" \
  '$/.github/workflows/build-test.yaml true'
# shellcheck disable=SC2016
check 'the select_changed checks read the lane outputs' \
  "$(yq -r '.jobs."build-test-select-changed-checks".steps[].env
    | select(. != null) | to_entries[] | .key + "=" + .value' \
    "${testing}" | sort | paste -sd ' ' -)" \
  'CHANGES_RESOLVED=${{ needs.build-test-select-changed.outputs.changes_resolved }} SELECTION_REASON=${{ needs.build-test-select-changed.outputs.selection_reason }}'

# --- The resolved legs and their oracle --------------------------------

oracle="${root}/tests/select_changed_oracle.sh"
fixture='tests/fixtures/select-changed'

# predict PATH...: the oracle's output for a diff, on one line
predict() {
  if [ "$#" -gt 0 ]; then
    printf '%s\0' "$@"
  fi | bash "${oracle}" | paste -sd '|' -
}

check 'oracle: a change outside the fixture' "$(predict README.md)" \
  'discovered_reason=none|discovered_images=|leaf_reason=changed|leaf_images=select-leaf|base_reason=changed|base_images=select-base select-child'
check 'oracle: an empty diff selects nothing, even for paths ["."]' \
  "$(predict)" \
  'discovered_reason=none|discovered_images=|leaf_reason=none|leaf_images=|base_reason=none|base_images='
check 'oracle: a leaf change' \
  "$(predict "${fixture}/select-leaf/Dockerfile")" \
  'discovered_reason=changed|discovered_images=select-leaf|leaf_reason=changed|leaf_images=select-leaf|base_reason=changed|base_images=select-base select-child select-leaf'
check 'oracle: a base change brings its dependent' \
  "$(predict "${fixture}/select-base/Dockerfile")" \
  'discovered_reason=changed|discovered_images=select-base select-child|leaf_reason=changed|leaf_images=select-base select-child select-leaf|base_reason=changed|base_images=select-base select-child'
check 'oracle: a child change brings its base' \
  "$(predict "${fixture}/select-child/Dockerfile")" \
  'discovered_reason=changed|discovered_images=select-base select-child|leaf_reason=changed|leaf_images=select-base select-child select-leaf|base_reason=changed|base_images=select-base select-child'
check 'oracle: a fixture file no image reads is shared' \
  "$(predict "${fixture}/version.properties")" \
  'discovered_reason=shared|discovered_images=select-base select-child select-leaf|leaf_reason=changed|leaf_images=select-leaf|base_reason=changed|base_images=select-base select-child'
check 'oracle: a sibling directory sharing the prefix is outside' \
  "$(predict "${fixture}-other/select-leaf/Dockerfile")" \
  'discovered_reason=none|discovered_images=|leaf_reason=changed|leaf_images=select-leaf|base_reason=changed|base_images=select-base select-child'

# The oracle's chain is the fixture's: select-child alone builds FROM
# a sibling, and every image has its own context
check 'fixture: select-child builds FROM select-base' \
  "$(grep -h '^FROM' "${root}/${fixture}"/select-*/Dockerfile \
    | grep -c 'select-base:verify')" 1
check 'fixture: select-child is the image built FROM select-base' \
  "$(grep -l '^FROM select-base:verify' \
    "${root}/${fixture}"/select-*/Dockerfile | xargs -n1 dirname \
    | xargs -n1 basename)" select-child
check 'fixture: three image directories' \
  "$(find "${root}/${fixture}" -mindepth 1 -maxdepth 1 -type d \
    -printf '%f\n' | LC_ALL=C sort | paste -sd ' ')" \
  'select-base select-child select-leaf'

# shellcheck disable=SC2016
check 'testing.yaml runs the oracle on the lanes'"'"' two commits' \
  "$(yq -r '.jobs."select-changed-oracle".steps[]
    | select(.id == "oracle") | .run' "${testing}" \
    | grep -c 'git diff --name-only --no-renames -z HEAD^1 HEAD \\$' )" 1
check 'testing.yaml pipes that diff to the oracle' \
  "$(yq -r '.jobs."select-changed-oracle".steps[]
    | select(.id == "oracle") | .run' "${testing}" \
    | grep -c 'bash tests/select_changed_oracle.sh')" 1
check 'the oracle checks out both commits' \
  "$(yq -r '.jobs."select-changed-oracle".steps[]
    | select(.uses != null and (.uses | test("^actions/checkout@")))
    | .with."fetch-depth"' "${testing}")" 2

# resolved_leg JOB WORKFLOW PATH_PREFIX READER ORACLE_OUTPUT
resolved_leg() {
  local job=$1 lane=$2 prefix=$3 reader=$4 output=$5
  check "${job}: calls ${lane} at this commit" \
    "$(yq -r ".jobs.\"${job}\".uses" "${testing}")" \
    "\$/.github/workflows/${lane}.yaml"
  check "${job}: sets select_changed" \
    "$(yq -r ".jobs.\"${job}\".with.select_changed" "${testing}")" true
  check "${job}: needs the oracle" \
    "$(yq -r ".jobs.\"${job}\".needs" "${testing}")" select-changed-oracle
  check "${job}: builds this repository's commit" \
    "$(yq -r ".jobs.\"${job}\".with | [.repository, .ref]
      | map(. // \"\") | join(\"\")" "${testing}")" ''
  check "${job}: path_prefix" \
    "$(yq -r ".jobs.\"${job}\".with.path_prefix // \".\"" "${testing}")" \
    "${prefix}"
  # Explicit legs: the fixture's three contexts, one reading '.'
  if [ -n "${reader}" ]; then
    check "${job}: the fixture's images, ${reader} reading everything" \
      "$(yq -r ".jobs.\"${job}\".with.images" "${testing}" | jq -c '
        map([.name, .context, (.paths // [])])')" \
      "$(jq -nc --arg f "${fixture}" --arg r "${reader}" '
        ["select-base", "select-child", "select-leaf"]
        | map([., ($f + "/" + .), (if . == $r then ["."] else [] end)])')"
  else
    check "${job}: discovers the fixture's images" \
      "$(yq -r ".jobs.\"${job}\".with.images // \"\"" "${testing}")" ''
  fi
  check "${job}: the test compares the build with the oracle" \
    "$(yq -r ".jobs.\"${job}\".with.test_command" "${testing}" \
      | grep -c "'\${{ needs.select-changed-oracle.outputs.${output} }}' ]")" \
    1
}
resolved_leg build-test-select-changed-leaf build-test . select-leaf \
  leaf_images
resolved_leg build-test-select-changed-base build-test . select-base \
  base_images
resolved_leg build-test-select-changed-discovered build-test "${fixture}" \
  '' discovered_images
resolved_leg merge-select-changed merge "${fixture}" '' discovered_images

check 'the resolved checks wait for the oracle and every leg' \
  "$(yq -r '.jobs."select-changed-resolved-checks".needs | sort | join(" ")' \
    "${testing}")" \
  'build-test-select-changed-base build-test-select-changed-discovered build-test-select-changed-leaf merge-select-changed select-changed-oracle'
# shellcheck disable=SC2016
check 'the resolved checks read the oracle reason and the lane outputs' \
  "$(yq -r '.jobs."select-changed-resolved-checks".steps[].env
    | select(. != null) | to_entries[] | .value' "${testing}" \
    | sed -E 's/^\$\{\{ needs\.([^ ]+) \}\}$/\1/' | sort | paste -sd ' ' -)" \
  'build-test-select-changed-base.outputs.changes_resolved build-test-select-changed-base.outputs.selection_reason build-test-select-changed-discovered.outputs.changes_resolved build-test-select-changed-discovered.outputs.selection_reason build-test-select-changed-leaf.outputs.changes_resolved build-test-select-changed-leaf.outputs.selection_reason merge-select-changed.outputs.changes_resolved merge-select-changed.outputs.selection_reason merge-select-changed.outputs.snapshot_publish_result merge-select-changed.outputs.tests_result select-changed-oracle.outputs.base_reason select-changed-oracle.outputs.discovered_reason select-changed-oracle.outputs.leaf_reason'

if [ "${failures}" -gt 0 ]; then
  echo "${failures} failure(s)"
  exit 1
fi
echo "All change selection wiring checks passed"
