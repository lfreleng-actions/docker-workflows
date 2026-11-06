#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation

# Regression test for the Grype dependency-change gate (#200, #204) in
# the verify lane (build-test.yaml) and the policy inputs it shares
# with the release lane (build-test-release.yaml). It checks:
# - both lanes declare the Grype policy inputs with the same types and
#   defaults and pass each to grype-scan-action; the verify lane alone
#   takes grype_gate_when and grype_dependency_ecosystems, and alone
#   forwards a dependency change verdict, since a release always gates;
# - the gerrit-validate step that validates those inputs through
#   grype-scan-action in validate-only mode: at the scan's pin, with
#   validate-only the string 'true' and, for every input the scan
#   passes as one grype_* input of the lane, the same expression and
#   nothing else, no shell step reading a grype_* input beside it, and
#   each breach of that contract, made on a copy of the workflow,
#   failing the check; the grype_dependency_ecosystems shell check
#   the verify lane keeps, as an input of repository-metadata-action,
#   extracted and run as GitHub runs a 'shell: bash' step against
#   valid and invalid values; the build of each lane needing
#   gerrit-validate with no condition, so a rejected input leaves it
#   unstarted; and the testing.yaml job that runs the validator with
#   build-test's defaults and a bad gate-when and requires the
#   rejection;
# - the verify lane's wiring: repository-metadata-action at its v0.5.1
#   commit in every workflow that calls it; in build-test.yaml its
#   metadata step running the detection behind the
#   dependencies-changed gate, after the scope step and a checkout of
#   depth 2 or more, and exporting dependencies_changed as a job
#   output; the grype job needing that job, keeping its !cancelled()
#   guard and forwarding the output only from a job that succeeded;
#   no dependency-change-action call, sidecar file or manifest input
#   left in any workflow; and the gate outputs the lane reports;
# - the two testing.yaml calls that prove the verdict's round trip:
#   the unresolved one against a fixture at a tag and the resolved one
#   against this repository's own fixture at the commit under test;
# - the repository-metadata step that resolves the detection scope: the
#   docker preset joined to the caller's ecosystems, the dockerfile
#   names in the images input turned into the action's extra
#   patterns, the scope widened to the repository root for a context,
#   a local named build context (an OCI layout included) in
#   build_flags, or a recipe outside path_prefix, detection skipped
#   for a path no pattern can express, that the action's reading of
#   its patterns input would alter, or that a build context value
#   buildx refuses leaves unproven, and for a build_command, whose
#   builds discovery does not describe, run against named,
#   './'-prefixed, standard, sibling, remote, unrepresentable,
#   control-character and whitespace-edged paths, the last list
#   checked against Python, and the patterns heredoc closed by a
#   delimiter no pattern equals;
# - dependency-change-action itself, fetched at the commit
#   repository-metadata-action pins and run against a scratch
#   repository: a change to a Dockerfile with a
#   custom name goes unnoticed by the docker preset alone and counts
#   once the step's patterns reach the action, under the repository
#   root, under a path_prefix, and as a sibling of the path_prefix; a
#   sibling context's Dockerfile and manifest, and a sibling named
#   build context's manifest, count through the widened scope; an
#   unresolved run removes a planted sidecar; and a name the action
#   strips or splits misses its own recipe, which is why the step
#   skips the detection for one;
# - the resolved self-test's verdict check, run against the action on
#   a scratch repository shaped like this one: both read a recipe
#   under the fixture and one directly in each ancestor directory,
#   and neither reads a sibling's.
# The action's own suite covers the rest of what it detects.
#
# Usage: bash tests/test_dependency_change.sh
# REPOSITORY_METADATA_ACTION_DIR and DEPENDENCY_CHANGE_ACTION_DIR may
# name local clones of repository-metadata-action and
# dependency-change-action checked out at their pinned commits, to run
# without fetching them.
# Needs bash, git, jq, python3 and yq (either the Go or the Python
# implementation).

set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
workflows="${root}/.github/workflows"
verify="${workflows}/build-test.yaml"
release="${workflows}/build-test-release.yaml"

work=$(mktemp -d)
trap 'rm -rf "${work}"' EXIT

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

# step_field FILE JOB ID FIELD: one field of a step, by its id
step_field() {
  yq -r ".jobs.\"$2\".steps[] | select(.id == \"$3\") | .$4" "$1"
}

# input_field FILE INPUT FIELD: one field of a workflow_call input
input_field() {
  yq -r ".on.workflow_call.inputs.\"$2\".$3" "$1"
}

# --- Inputs and their route to grype-scan-action --------------------------

# policy_input NAME TYPE DEFAULT PASSED_AS: declared alike in both lanes
# and handed to grype-scan-action under its own name
policy_input() {
  local lane workflow
  for lane in build-test build-test-release; do
    workflow="${workflows}/${lane}.yaml"
    check "${lane}: $1 is a $2" "$(input_field "${workflow}" "$1" type)" "$2"
    check "${lane}: $1 defaults to '$3'" \
      "$(input_field "${workflow}" "$1" default)" "$3"
    check "${lane}: grype-audit passes $1 as $4" \
      "$(step_field "${workflow}" grype grype-audit "with.\"$4\"")" \
      "\${{ inputs.$1 }}"
  done
}
policy_input grype_dependency_policy string declared dependency-policy
policy_input grype_transitive_fail_on string critical transitive-fail-on
policy_input grype_only_fixed boolean true only-fixed
policy_input grype_remediation_window_days string '' remediation-window-days
policy_input grype_remediation_window_start string '' \
  remediation-window-start

# The verify lane alone takes the gate and the ecosystems
check 'build-test: grype_gate_when is a string' \
  "$(input_field "${verify}" grype_gate_when type)" string
check 'build-test: grype_gate_when defaults to always (opt-in)' \
  "$(input_field "${verify}" grype_gate_when default)" always
check 'build-test: grype_dependency_ecosystems is a string' \
  "$(input_field "${verify}" grype_dependency_ecosystems type)" string
check 'build-test: grype_dependency_ecosystems defaults to docker' \
  "$(input_field "${verify}" grype_dependency_ecosystems default)" docker
# shellcheck disable=SC2016  # literal workflow expressions
check 'build-test: grype-audit passes grype_gate_when as gate-when' \
  "$(step_field "${verify}" grype grype-audit 'with."gate-when"')" \
  '${{ inputs.grype_gate_when }}'
check 'build-test: grype-audit reads no sidecar' \
  "$(step_field "${verify}" grype grype-audit \
    'with."dependency-change-manifest"')" null
for name in grype_gate_when grype_dependency_ecosystems; do
  check "build-test-release: no ${name} input (a release always gates)" \
    "$(input_field "${release}" "${name}" type)" null
done
check 'build-test-release: grype-audit sets no gate-when' \
  "$(step_field "${release}" grype grype-audit 'with."gate-when"')" null
check 'build-test-release: grype-audit reads no sidecar' \
  "$(step_field "${release}" grype grype-audit \
    'with."dependency-change-manifest"')" null
check 'build-test-release: grype-audit takes no verdict' \
  "$(step_field "${release}" grype grype-audit \
    'with."dependencies-changed"')" null

# lane_passes LANE NAME TYPE DEFAULT PASSED_AS: one lane declares NAME
# and hands it to grype-scan-action under its own name
lane_passes() {
  local workflow="${workflows}/$1.yaml"
  check "$1: $2 is a $3" "$(input_field "${workflow}" "$2" type)" "$3"
  check "$1: $2 defaults to '$4'" \
    "$(input_field "${workflow}" "$2" default)" "$4"
  check "$1: grype-audit passes $2 as $5" \
    "$(step_field "${workflow}" grype grype-audit "with.\"$5\"")" \
    "\${{ inputs.$2 }}"
}
# Every lane: the existing scan inputs keep their defaults, and the
# bypass repository is new
for lane in build-test build-test-release merge; do
  lane_passes "${lane}" grype_fail_on string medium fail-on
  lane_passes "${lane}" grype_cache_db string true cache-db
  lane_passes "${lane}" grype_bypass_repository string '' bypass-repository
done
# The merge lane's policy inputs default to grype-scan-action's own,
# so its verdict is the one it gave before they existed
lane_passes merge grype_only_fixed boolean false only-fixed
lane_passes merge grype_dependency_policy string all dependency-policy
lane_passes merge grype_transitive_fail_on string none transitive-fail-on
for name in grype_gate_when grype_dependency_ecosystems \
  grype_dependency_patterns grype_remediation_window_days \
  grype_remediation_window_start; do
  check "merge: no ${name} input" \
    "$(input_field "${workflows}/merge.yaml" "${name}" type)" null
done
check 'merge: grype-audit sets no gate-when' \
  "$(step_field "${workflows}/merge.yaml" grype grype-audit \
    'with."gate-when"')" null

# The verify lane alone takes extra detection patterns
check 'build-test: grype_dependency_patterns is a string' \
  "$(input_field "${verify}" grype_dependency_patterns type)" string
check "build-test: grype_dependency_patterns defaults to ''" \
  "$(input_field "${verify}" grype_dependency_patterns default)" ''
check 'build-test-release: no grype_dependency_patterns input' \
  "$(input_field "${release}" grype_dependency_patterns type)" null

# --- gerrit-validate: the Grype inputs, validated through the action -------

grype_action='lfreleng-actions/grype-scan-action'
grype_pin='f65dca2762823cfc8f376e32fee9baa6f3292696'
grype_uses="${grype_action}@${grype_pin}"
validator_name='Validate Grype inputs'

# Each lane as JSON, so jq can read the two steps and alter a copy
for lane in build-test build-test-release merge; do
  yq -r 'tojson' "${workflows}/${lane}.yaml" > "${work}/${lane}.json"
done

# The contract between the validator and the scan, as a jq program
# over a workflow: it prints one line per breach and nothing when the
# workflow keeps it. Lookups by name fail when they match more than
# one step, and the validator's with: block is derived from the
# scan's, so an input added to the scan and not to the validator is a
# breach. $uses is the pin both must run; $required the inputs the
# scan must pass as one grype_* input of the lane, so the comparison
# cannot pass vacuously; $ecosystems is the one grype_* input a run:
# step may still read, or empty.
cat > "${work}/contract.jq" <<'JQ'
def policy_expression:
  type == "string" and test("^\\$\\{\\{ inputs\\.grype_[a-z_]+ \\}\\}$");
def reads_grype_inputs:
  [((.env // {}) | tostring), (.run // "")] | join(" ")
  | [match("inputs\\.grype_[a-z_]+"; "g").string] | unique;
(.jobs."gerrit-validate".steps // []) as $steps
| [$steps[] | select(.name == $name)] as $validators
| [(.jobs.grype.steps // [])[] | select(.id == "grype-audit")] as $scans
| if ($validators | length) != 1 then
    "expected one '\($name)' step in gerrit-validate, found \($validators | length)"
  elif ($scans | length) != 1 then
    "expected one grype-audit step in grype, found \($scans | length)"
  else
    $validators[0] as $validator
    | $scans[0] as $scan
    | (($scan.with // {}) | with_entries(select(.value | policy_expression)))
      as $policy
    | ({"validate-only": "true"} + $policy) as $expected
    | ($validator.with // {}) as $passed
    | (
      ($required - ($policy | keys)) as $missing
      | if ($missing | length) > 0 then
          "the scan does not pass \($missing | join(", ")) as the lane's own input"
        else empty end
    ),
    (if $validator.uses != $uses then
        "the validator runs \($validator.uses | tojson), not \($uses)"
      else empty end),
    (if $scan.uses != $uses then
        "the scan runs \($scan.uses | tojson), not \($uses)"
      else empty end),
    (if $passed."validate-only" != "true" then
        "validate-only is \($passed."validate-only" | tojson), not the string \"true\""
      else empty end),
    (if $validator.run != null then "the validator has a run: script"
      else empty end),
    (if $validator.if != null then "the validator has a condition"
      else empty end),
    (($expected | keys[]) as $input
      | if $passed[$input] != $expected[$input] then
          "the validator passes \($input) as \($passed[$input] | tojson), the scan as \($expected[$input] | tojson)"
        else empty end),
    (($passed | keys[]) as $input
      | if ($expected | has($input)) then empty
        else "the validator passes \($input), which the scan does not pass as the lane's own input"
        end),
    ([$steps[] | select(.run != null) | reads_grype_inputs[]
      | select(. != "inputs.grype_\($ecosystems)")] as $shell
      | if ($shell | length) > 0 then
          "a run: step still reads \($shell | join(", "))"
        else empty end)
  end
JQ

# contract LANE_JSON REQUIRED ECOSYSTEMS: the breaches, one per line,
# of a workflow given as JSON; REQUIRED is a JSON array of the inputs
# the scan must pass as the lane's own, ECOSYSTEMS the grype_* input a
# shell step may still read, or empty
contract() {
  jq -r --arg name "${validator_name}" --arg uses "${grype_uses}" \
    --argjson required "$2" --arg ecosystems "$3" \
    -f "${work}/contract.jq" "$1"
}

# expect_contract DESCRIPTION LANE_JSON REQUIRED ECOSYSTEMS OUTCOME:
# OUTCOME is 'kept' or 'breached'
expect_contract() {
  local breaches
  breaches=$(contract "$2" "$3" "$4")
  if { [ "$5" = 'kept' ] && [ -z "${breaches}" ]; } ||
    { [ "$5" = 'breached' ] && [ -n "${breaches}" ]; }; then
    echo "ok: contract: $1"
  else
    echo "FAIL: contract: $1 (expected ${5}, got '${breaches:-no breach}')"
    failures=$((failures + 1))
  fi
}

# The inputs each lane's scan passes as its own, which the validator
# must mirror; the window and the gate are the verify lanes' own
scan_inputs='["fail-on", "only-fixed", "dependency-policy",
  "transitive-fail-on", "cache-db", "bypass-repository"]'
verify_inputs=$(jq -c '. + ["remediation-window-days",
  "remediation-window-start"]' <<< "${scan_inputs}")
gate_inputs=$(jq -c '. + ["gate-when"]' <<< "${verify_inputs}")
merge_inputs=$(jq -c '.' <<< "${scan_inputs}")

expect_contract 'build-test validates through the action' \
  "${work}/build-test.json" "${gate_inputs}" dependency_ecosystems kept
expect_contract 'build-test-release validates through the action' \
  "${work}/build-test-release.json" "${verify_inputs}" '' kept
expect_contract 'merge validates through the action' \
  "${work}/merge.json" "${merge_inputs}" '' kept

# The validator passes no scan target: validate-only needs neither
# and rejects both. The equality above implies it; this names it.
for lane in build-test build-test-release merge; do
  for input in sbom target; do
    check "${lane}: the validator passes no ${input}" \
      "$(jq -r --arg name "${validator_name}" --arg input "${input}" \
        '.jobs."gerrit-validate".steps[] | select(.name == $name)
          | .with[$input] // "absent"' "${work}/${lane}.json")" absent
  done
done

# Every grype-scan-action reference in a lane is the one pinned line,
# twice, with its version comment, which the YAML parser drops
for lane in build-test build-test-release merge; do
  workflow="${workflows}/${lane}.yaml"
  check "${lane}: grype-scan-action appears at the pin twice" \
    "$(grep -cE "uses: ${grype_uses}[[:space:]]+# v0\.6\.2$" "${workflow}")" 2
  check "${lane}: grype-scan-action appears at no other reference" \
    "$(grep -c "${grype_action}@" "${workflow}")" 2
done

# mutate LANE_JSON FILTER: a copy of a lane's JSON with a jq filter
# applied, in ${work}/mutated.json; the filter may name the validator
# and the scan as 'validator' and 'scan'
mutate() {
  jq --arg name "${validator_name}" \
    'def validator: .jobs."gerrit-validate".steps[] | select(.name == $name);
    def scan: .jobs.grype.steps[] | select(.id == "grype-audit");
    '"$2" "$1" > "${work}/mutated.json"
}

# breach DESCRIPTION LANE FILTER: the lane mutated by FILTER breaches
# the contract
breach() {
  local required ecosystems
  case "$2" in
    build-test) required="${gate_inputs}" ecosystems=dependency_ecosystems ;;
    build-test-release) required="${verify_inputs}" ecosystems='' ;;
    merge) required="${merge_inputs}" ecosystems='' ;;
  esac
  mutate "${work}/$2.json" "$3"
  expect_contract "$2: $1" "${work}/mutated.json" "${required}" \
    "${ecosystems}" breached
}

# The workflows as they stand, run through the same path, keep it
for lane in build-test build-test-release merge; do
  mutate "${work}/${lane}.json" '.'
  case "${lane}" in
    build-test) required="${gate_inputs}" ecosystems=dependency_ecosystems ;;
    *) required="${verify_inputs}" ecosystems='' ;;
  esac
  [ "${lane}" = merge ] && required="${merge_inputs}"
  expect_contract "${lane}: an unaltered copy keeps the contract" \
    "${work}/mutated.json" "${required}" "${ecosystems}" kept
done

# Each breach of the contract fails the check
# shellcheck disable=SC2016  # literal workflow expressions in jq filters
{
  breach 'an expression that differs from the scan' build-test \
    '(validator | .with."fail-on") = "${{ inputs.grype_fail_on || inputs.grype_fail_on }}"'
  breach 'a trailing space in an expression' build-test \
    '(validator | .with."gate-when") = "${{ inputs.grype_gate_when }} "'
  breach 'a scan input the validator omits' build-test \
    '(validator | .with) |= del(."cache-db")'
  breach 'an input added to the scan alone' build-test \
    '(scan | .with."declared-source") = "${{ inputs.grype_declared_source }}"'
  breach 'a validator without validate-only' build-test \
    '(validator | .with) |= del(."validate-only")'
  breach 'validate-only as a YAML boolean' build-test \
    '(validator | .with."validate-only") = true'
  breach 'validate-only false' build-test \
    '(validator | .with."validate-only") = "false"'
  breach 'a validator passing an SBOM' build-test \
    '(validator | .with.sbom) = "sbom-cyclonedx-*.json"'
  breach 'a validator passing a target' build-test \
    '(validator | .with.target) = "dir:."'
  breach 'a validator passing the scan token' build-test \
    '(validator | .with."github-token") = "${{ secrets.GITHUB_TOKEN }}"'
  breach 'a validator at another pin' build-test \
    '(validator | .uses) = "lfreleng-actions/grype-scan-action@5c81b23afb2ea771b2d247807a12d90783328675"'
  breach 'a scan at another pin' build-test \
    '(scan | .uses) = "lfreleng-actions/grype-scan-action@5c81b23afb2ea771b2d247807a12d90783328675"'
  breach 'a floating reference' build-test \
    '(validator | .uses) = "lfreleng-actions/grype-scan-action@v0.6.2"'
  breach 'a conditional validator' build-test \
    '(validator | .if) = "inputs.grype_enabled"'
  breach 'a scan that drops a required input' build-test \
    '(scan | .with) |= del(."gate-when")'
  breach 'a scan passing a required input as a literal' build-test \
    '(scan | .with."gate-when") = "always"'
  breach 'two validators' build-test \
    '.jobs."gerrit-validate".steps += [validator]'
  breach 'no validator' build-test \
    '.jobs."gerrit-validate".steps |= map(select(.name != $name))'
  breach 'a shell step reading a Grype input' build-test \
    '.jobs."gerrit-validate".steps += [{name: "Validate Grype gate inputs",
      shell: "bash", env: {GRYPE_GATE_WHEN: "${{ inputs.grype_gate_when }}"},
      run: "test -n \"${GRYPE_GATE_WHEN}\""}]'
  breach 'a shell step inlining a Grype input' build-test \
    '.jobs."gerrit-validate".steps += [{name: "Validate Grype fail-on",
      shell: "bash", run: "test -n \"${{ inputs.grype_fail_on }}\""}]'
  breach 'a window input the validator omits' build-test-release \
    '(validator | .with) |= del(."remediation-window-start")'
  breach 'an ecosystems step in a lane without the input' merge \
    '.jobs."gerrit-validate".steps += [{name: "Validate Grype ecosystems",
      shell: "bash", env: {E: "${{ inputs.grype_dependency_ecosystems }}"},
      run: "test -n \"${E}\""}]'
}

# --- gerrit-validate: the verify lane's ecosystems step --------------------

# grype_dependency_ecosystems belongs to repository-metadata-action,
# not grype-scan-action, so it keeps a shell check that reads that
# input alone; the release lane has no such input and no such step
# shellcheck disable=SC2016  # literal workflow expressions
check 'build-test: the ecosystems step reads grype_dependency_ecosystems alone' \
  "$(jq -r '.jobs."gerrit-validate".steps[]
    | select(.id == "validate-grype-ecosystems") | .env | to_entries
    | map("\(.key)=\(.value)") | join(" ")' "${work}/build-test.json")" \
  'GRYPE_DEPENDENCY_ECOSYSTEMS=${{ inputs.grype_dependency_ecosystems }}'
check 'build-test: the ecosystems step runs on every call' \
  "$(step_field "${verify}" gerrit-validate validate-grype-ecosystems if)" null
check 'build-test-release: no ecosystems step' \
  "$(step_field "${release}" gerrit-validate validate-grype-ecosystems name)" ''
check 'merge: no ecosystems step' \
  "$(step_field "${workflows}/merge.yaml" gerrit-validate \
    validate-grype-ecosystems name)" ''

yq -r '.jobs."gerrit-validate".steps[]
  | select(.id == "validate-grype-ecosystems") | .run' "${verify}" \
  > "${work}/ecosystems.sh"
if [ ! -s "${work}/ecosystems.sh" ]; then
  echo "FAIL: no 'validate-grype-ecosystems' step in gerrit-validate" \
    "of build-test"
  exit 1
fi

# run_step SCRIPT VAR=VALUE...: runs an extracted step as GitHub runs a
# 'shell: bash' step, with only the variables named; the exit status
# lands in status and the log in ${work}/log
run_step() {
  local script="$1"
  shift
  status=0
  env -i PATH="${PATH}" HOME="${work}" "$@" \
    bash --noprofile --norc -eo pipefail "${script}" \
    > "${work}/log" 2>&1 || status=$?
}

# expect_step DESCRIPTION EXPECTED NAME: EXPECTED is 'ok' or 'error';
# an error must carry an ::error:: naming the input NAME, and a
# rejected value must not forge a second workflow command
expect_step() {
  if { [ "$2" = 'ok' ] && [ "${status}" -eq 0 ]; } ||
    { [ "$2" = 'error' ] && [ "${status}" -ne 0 ] &&
      grep -q "^::error::Invalid $3 input:" "${work}/log" &&
      ! grep -q '^::warning::forged' "${work}/log"; }; then
    echo "ok: validation: $1"
  else
    echo "FAIL: validation: $1 (exit ${status})"
    sed 's/^/  | /' "${work}/log"
    failures=$((failures + 1))
  fi
}

# ecosystems_case DESCRIPTION EXPECTED ECOSYSTEMS
ecosystems_case() {
  run_step "${work}/ecosystems.sh" GRYPE_DEPENDENCY_ECOSYSTEMS="$3"
  expect_step "$1" "$2" grype_dependency_ecosystems
}
ecosystems_case 'the default ecosystems are accepted' ok docker
for ecosystem in node python go maven gradle rust docker; do
  ecosystems_case "ecosystem ${ecosystem} is accepted" ok "${ecosystem}"
done
ecosystems_case 'a preset union is accepted' ok docker,python
ecosystems_case 'an empty ecosystem list fails' error ''
ecosystems_case 'an unknown preset fails' error docker,ruby
ecosystems_case 'a capitalised preset fails' error Docker
ecosystems_case 'a space-separated list fails' error 'docker python'
ecosystems_case 'a trailing comma fails' error docker,
ecosystems_case 'a newline cannot forge a command' error \
  "$(printf 'x\n::warning::forged')"

# --- A failed validation leaves the build unstarted -----------------------

# Every job in each lane descends from gerrit-validate, and the build
# needs it directly with no condition, so a rejected input skips the
# build rather than running it. The testing.yaml job below proves the
# action rejects such an input at this pin.
for lane in build-test build-test-release merge; do
  check "${lane}: build needs gerrit-validate" \
    "$(jq -r '.jobs.build.needs | index("gerrit-validate") != null' \
      "${work}/${lane}.json")" true
  check "${lane}: build runs on success alone" \
    "$(jq -r '.jobs.build.if // "none"' "${work}/${lane}.json")" none
  check "${lane}: every other job descends from gerrit-validate" \
    "$(jq -r '.jobs as $jobs
      | def needs: ($jobs[.].needs // []) | if type == "string" then [.] else . end;
      def descends: . as $job
        | ($job | needs) as $direct
        | ($direct | index("gerrit-validate") != null)
          or any($direct[]; descends);
      [$jobs | keys[] | select(. != "gerrit-validate") | select(descends | not)]
      | length' "${work}/${lane}.json")" 0
done

# --- The rejection, proven against the action in testing.yaml -------------

# A reusable workflow call cannot fail without failing the testing run,
# so testing.yaml runs the validator itself, as the lanes do, with
# build-test's defaults and a gate-when the action does not know, and
# a following step requires that step to have failed
testing="${workflows}/testing.yaml"
yq -r 'tojson' "${testing}" > "${work}/testing.json"
reject_job='grype-validate-rejects'

# rejection FILTER: one jq result over testing.yaml; the filter may
# name the job as 'job' and its validator step as 'reject'
rejection() {
  jq -r --arg job "${reject_job}" \
    'def job: .jobs[$job]; def reject: job.steps[] | select(.id == "reject");
    '"$1" "${work}/testing.json"
}
check 'testing: the rejection job runs no other action' \
  "$(rejection '[job.steps[] | select(.uses != null) | .uses] | join(" ")')" \
  "${grype_uses}"
check 'testing: the rejection job grants no permission' \
  "$(rejection 'job.permissions | tojson')" '{}'
check 'testing: the rejected step continues on error' \
  "$(rejection 'reject | ."continue-on-error"')" true
check 'testing: the rejected step validates only' \
  "$(rejection 'reject | .with."validate-only" | tojson')" '"true"'
# shellcheck disable=SC2016  # literal workflow expressions
check 'testing: the rejected step passes a gate-when the action does not know' \
  "$(rejection 'reject | .with."gate-when"
    | IN("always", "dependencies-changed") or contains("${{")')" false
# The other inputs are build-test's defaults, as literals, so the
# rejection is the gate-when's alone and the defaults stay valid
for input in fail-on:grype_fail_on only-fixed:grype_only_fixed \
  dependency-policy:grype_dependency_policy \
  transitive-fail-on:grype_transitive_fail_on \
  remediation-window-days:grype_remediation_window_days \
  remediation-window-start:grype_remediation_window_start \
  cache-db:grype_cache_db bypass-repository:grype_bypass_repository; do
  check "testing: the rejected step passes build-test's ${input#*:} default" \
    "$(rejection "reject | .with.\"${input%%:*}\" | tostring")" \
    "$(input_field "${verify}" "${input#*:}" default)"
done
check 'testing: the rejected step passes the inputs build-test validates' \
  "$(rejection 'reject | .with | keys | join(" ")')" \
  "$(jq -r --arg name "${validator_name}" \
    '.jobs."gerrit-validate".steps[] | select(.name == $name)
      | .with | keys | join(" ")' "${work}/build-test.json")"
# shellcheck disable=SC2016  # literal workflow expressions
check 'testing: one step after the rejection reads its outcome and can fail' \
  "$(rejection 'job.steps | (map(.id == "reject") | index(true)) as $at
    | [.[$at + 1:][] | select(.run != null and (."continue-on-error" | not))
      | .env // {} | .[] | select(. == "${{ steps.reject.outcome }}")]
    | length')" 1

# --- Wiring in the verify lane --------------------------------------------

metadata_action='lfreleng-actions/repository-metadata-action'
metadata_pin='f0e5d2d8dc1154a5d702b75acc551eff6ba072dc'
gate_if="inputs.grype_enabled && inputs.grype_gate_when == 'dependencies-changed'"

# Every workflow that calls repository-metadata-action pins the one
# commit v0.5.1 names (not the tag object), with its version comment,
# which the YAML parser drops
for lane in build-test build-test-release merge; do
  workflow="${workflows}/${lane}.yaml"
  check "${lane}: repository-metadata calls the action at the v0.5.1 pin" \
    "$(step_field "${workflow}" repository-metadata repo-metadata uses)" \
    "${metadata_action}@${metadata_pin}"
  if grep -qE "uses: ${metadata_action}@${metadata_pin}[[:space:]]+# v0\.5\.1$" \
    "${workflow}"; then
    echo "ok: ${lane}: the pin carries its v0.5.1 comment"
  else
    echo "FAIL: ${lane}: the pin lacks its '# v0.5.1' comment"
    failures=$((failures + 1))
  fi
done

# The detection runs in repository-metadata, on the metadata step,
# behind the gate and the scope step's skip
# metadata_input NAME VALUE: the metadata step passes VALUE as NAME
metadata_input() {
  check "build-test: the metadata step takes $1" \
    "$(step_field "${verify}" repository-metadata repo-metadata \
      "with.\"$1\"")" "$2"
}
metadata_input dependency_change \
  "\${{ ${gate_if} && steps.dependency-scope.outputs.skip != 'true' }}"
# shellcheck disable=SC2016  # literal workflow expressions
metadata_input gerrit_refspec '${{ inputs.gerrit_refspec }}'
# shellcheck disable=SC2016
metadata_input dependency_ecosystems \
  '${{ steps.dependency-scope.outputs.ecosystems }}'
# shellcheck disable=SC2016
metadata_input dependency_path_prefix \
  '${{ steps.dependency-scope.outputs.path_prefix }}'
# shellcheck disable=SC2016
check 'build-test: the metadata step takes the scope patterns first' \
  "$(step_field "${verify}" repository-metadata repo-metadata \
    'with.dependency_patterns' | head -n 1)" \
  '${{ steps.dependency-scope.outputs.patterns }}'
# shellcheck disable=SC2016
check "build-test: the caller's patterns follow the scope patterns" \
  "$(step_field "${verify}" repository-metadata repo-metadata \
    'with.dependency_patterns')" \
  "$(printf '%s\n%s' '${{ steps.dependency-scope.outputs.patterns }}' \
    '${{ inputs.grype_dependency_patterns }}')"
check 'build-test: the metadata step sets no dependency_base' \
  "$(step_field "${verify}" repository-metadata repo-metadata \
    'with.dependency_base')" null
# shellcheck disable=SC2016
check 'build-test: repository-metadata exports dependencies_changed' \
  "$(yq -r '.jobs."repository-metadata".outputs.dependencies_changed' \
    "${verify}")" '${{ steps.repo-metadata.outputs.dependencies_changed }}'
check 'build-test: the scope step runs for the same gate' \
  "$(step_field "${verify}" repository-metadata dependency-scope if)" \
  "${gate_if}"
# The scope step must run ahead of the metadata step it feeds
check 'build-test: the scope step runs ahead of the metadata step' \
  "$(yq -r '[.jobs."repository-metadata".steps[].id]
    | (to_entries | map(select(.value == "dependency-scope")) | .[0].key)
      < (to_entries | map(select(.value == "repo-metadata")) | .[0].key)' \
    "${verify}")" true
# It reads workflow inputs alone: no other job, step or checkout
# shellcheck disable=SC2016
check 'build-test: the scope step reads workflow inputs alone' \
  "$(yq -r '.jobs."repository-metadata".steps[]
    | select(.id == "dependency-scope") | .env | to_entries[]
    | .key + "=" + .value' "${verify}" | sort | paste -sd ' ' -)" \
  'BUILD_COMMAND=${{ inputs.build_command }} GRYPE_DEPENDENCY_ECOSYSTEMS=${{ inputs.grype_dependency_ecosystems }} IMAGES=${{ inputs.images }} PATH_PREFIX=${{ inputs.path_prefix }}'
check 'build-test: docker-metadata has no dependency-scope step' \
  "$(step_field "${verify}" docker-metadata dependency-scope name)" ''

# The detection compares HEAD with its base, so both checkouts of the
# job must hold it: actions/checkout defaults to depth 1 and needs 2
# or more set (0 fetches everything); checkout-gerrit-change-action
# defaults to 2, so an unset depth passes and a set one must reach 2
# checkout_depth ACTION DEFAULT
checkout_depth() {
  local count depth
  count=$(yq -r ".jobs.\"repository-metadata\".steps[]
    | select(.uses | test(\"^$1@\")) | .uses" "${verify}" | wc -l)
  check "build-test: repository-metadata has one $1 step" "${count}" 1
  depth=$(yq -r ".jobs.\"repository-metadata\".steps[]
    | select(.uses | test(\"^$1@\")) | .with.\"fetch-depth\"" "${verify}")
  if [ "${depth}" = 'null' ]; then
    depth="$2"
  fi
  if [[ "${depth}" =~ ^[0-9]+$ ]] &&
    { [ "${depth}" -eq 0 ] || [ "${depth}" -ge 2 ]; }; then
    echo "ok: build-test: $1 in repository-metadata fetches depth ${depth}"
  else
    echo "FAIL: build-test: $1 in repository-metadata fetches depth" \
      "'${depth}'; the dependency change base needs 2 or more"
    failures=$((failures + 1))
  fi
}
checkout_depth actions/checkout 1
checkout_depth lfreleng-actions/checkout-gerrit-change-action 2

# The grype job reads the verdict from repository-metadata: it needs
# the job, keeps running when that job failed or skipped (its 'if:'
# starts from !cancelled() and never asks for repository-metadata's
# result), and forwards the output only from a job that succeeded,
# since a failed job can still expose an earlier step's output
grype_if=$(yq -r '.jobs.grype.if' "${verify}")
grype_needs=$(yq -r '.jobs.grype.needs
  | map(select(. == "repository-metadata")) | length' "${verify}")
# shellcheck disable=SC2016
grype_guard=$(grep -c '^\${{ !cancelled() && ' <<< "${grype_if}" || true)
grype_result=$(grep -c 'repository-metadata' <<< "${grype_if}" || true)
check 'build-test: grype needs repository-metadata, guarded by !cancelled()' \
  "needs ${grype_needs}, guard ${grype_guard}, result ${grype_result}" \
  'needs 1, guard 1, result 0'
check 'build-test: grype-audit forwards a verdict only from a success' \
  "$(step_field "${verify}" grype grype-audit \
    'with."dependencies-changed"')" \
  "\${{ needs.repository-metadata.result == 'success' && needs.repository-metadata.outputs.dependencies_changed || '' }}"
check 'build-test: grype runs without a checkout' \
  "$(yq -r '[.jobs.grype.steps[] | select(.uses | test("checkout"))]
    | length' "${verify}")" 0
check 'build-test: the sbom artefact still requires its SBOMs' \
  "$(yq -r '.jobs.sbom.steps[] | select(.name == "Upload SBOM artifacts")
    | .with."if-no-files-found"' "${verify}")" error

# The old sidecar wiring is gone from every workflow: no direct
# dependency-change-action call, no sidecar file and no manifest
# input, so the job output is the verdict's one route
for token in 'dependency-change-action@' 'dependency-change.json' \
  'dependency-change-manifest'; do
  check "workflows: no '${token}' remains" \
    "$(cat "${verify}" "${release}" "${workflows}/merge.yaml" \
      | grep -c -- "${token}" || true)" 0
done

# No inline detection may stand beside the action, where the two
# would drift apart
for job in repository-metadata docker-metadata sbom grype; do
  inline=$(yq -r ".jobs.\"${job}\".steps[] | select(.run != null)
    | select(.run | test(\"changed=|dependency-change.json\")) | .name" \
    "${verify}")
  check "build-test: ${job} has no inline dependency change handling" \
    "${inline}" ''
done

# The gate decision reaches the caller as workflow outputs
# shellcheck disable=SC2016
check 'build-test: grype reports gate_active' \
  "$(yq -r '.jobs.grype.outputs.gate_active' "${verify}")" \
  '${{ steps.grype-audit.outputs.gate-active }}'
# shellcheck disable=SC2016
check 'build-test: grype reports gate_reason' \
  "$(yq -r '.jobs.grype.outputs.gate_reason' "${verify}")" \
  '${{ steps.grype-audit.outputs.gate-reason }}'
# shellcheck disable=SC2016
check 'build-test: the workflow outputs grype_gate_active' \
  "$(yq -r '.on.workflow_call.outputs.grype_gate_active.value' \
    "${verify}")" '${{ jobs.grype.outputs.gate_active }}'
# shellcheck disable=SC2016
check 'build-test: the workflow outputs grype_gate_reason' \
  "$(yq -r '.on.workflow_call.outputs.grype_gate_reason.value' \
    "${verify}")" '${{ jobs.grype.outputs.gate_reason }}'

# --- The self-test calls in testing.yaml ----------------------------------

# Two calls prove the verdict's round trip from repository-metadata to
# the scan. The fixture-at-a-tag call has no base, so the verdict is
# empty and the gate must stay on; the resolved call builds a fixture
# in this repository at the run's own commit, where the detection
# compares HEAD with HEAD^1 and the scan must read its verdict to
# withhold the gate. That needs the default repository and ref (the
# checkout's HEAD must be GITHUB_SHA), a path_prefix holding the
# fixture Dockerfile and the gate asked for.
testing="${workflows}/testing.yaml"
# lane_input JOB INPUT
lane_input() {
  yq -r ".jobs.\"$1\".with.\"$2\"" "${testing}"
}
for job in build-test-dependency-gate build-test-dependency-gate-resolved; do
  check "testing: ${job} calls build-test" \
    "$(yq -r ".jobs.\"${job}\".uses" "${testing}")" \
    '$/.github/workflows/build-test.yaml'
  check "testing: ${job} asks to gate on dependency changes" \
    "$(lane_input "${job}" grype_gate_when)" dependencies-changed
  check "testing: ${job} keeps the SBOM on, which the grype job needs" \
    "$(lane_input "${job}" sbom_enabled)" null
  check "testing: ${job} keeps the Grype scan on" \
    "$(lane_input "${job}" grype_enabled)" null
done
check 'testing: the unresolved call builds another repository' \
  "$(lane_input build-test-dependency-gate repository)" \
  lfreleng-actions/test-docker-project
check 'testing: the resolved call builds this repository' \
  "$(lane_input build-test-dependency-gate-resolved repository)" null
check 'testing: the resolved call builds the commit under test' \
  "$(lane_input build-test-dependency-gate-resolved ref)" null
gate_fixture=$(lane_input build-test-dependency-gate-resolved path_prefix)
check 'testing: the resolved call builds the dependency-gate fixture' \
  "${gate_fixture}" tests/fixtures/dependency-gate
check 'testing: the dependency-gate fixture holds a Dockerfile' \
  "$(ls "${root}/${gate_fixture}")" Dockerfile
check 'testing: the resolved check job diffs the fixture the call built' \
  "$(yq -r '.jobs."build-test-dependency-gate-resolved-checks".steps[]
    | select(.run != null) | .run' "${testing}" \
    | sed -n "s/^prefix='\(.*\)'$/\1/p")" "${gate_fixture}"
checks_depth=$(yq -r '.jobs."build-test-dependency-gate-resolved-checks"
  .steps[] | select(.uses | test("^actions/checkout@"))
  | .with."fetch-depth"' "${testing}")
check 'testing: the resolved check job fetches the base too' \
  "${checks_depth}" 2

# --- The dependency change scope step -------------------------------------

yq -r '.jobs."repository-metadata".steps[]
  | select(.id == "dependency-scope") | .run' "${verify}" \
  > "${work}/scope.sh"
if [ ! -s "${work}/scope.sh" ]; then
  echo "FAIL: no 'dependency-scope' step in repository-metadata of build-test"
  exit 1
fi

# scope_for IMAGES PATH_PREFIX ECOSYSTEMS [BUILD_COMMAND]: runs the
# step with the inputs; its outputs land in ${work}/output and its
# step summary in ${work}/summary
scope_for() {
  : > "${work}/output"
  : > "${work}/summary"
  run_step "${work}/scope.sh" IMAGES="$1" PATH_PREFIX="$2" \
    GRYPE_DEPENDENCY_ECOSYSTEMS="$3" BUILD_COMMAND="${4:-}" \
    GITHUB_OUTPUT="${work}/output" \
    GITHUB_STEP_SUMMARY="${work}/summary"
  if [ "${status}" -ne 0 ]; then
    echo "FAIL: the scope step failed on images '$1' (exit ${status})"
    sed 's/^/  | /' "${work}/log"
    failures=$((failures + 1))
  fi
}

# scope_output NAME: one output of the last scope_for run; patterns
# come back one per line from the heredoc the step writes, whose
# delimiter the step chooses so that no pattern equals it
scope_output() {
  local delimiter
  if [ "$1" = patterns ]; then
    delimiter=$(sed -n 's/^patterns<<//p' "${work}/output")
    awk -v d="${delimiter}" '
      $0 == d { body = 0 }
      body { print }
      $0 == "patterns<<" d { body = 1 }' "${work}/output"
  else
    sed -n "s/^$1=//p" "${work}/output"
  fi
}

# scope_case DESCRIPTION IMAGES PATH_PREFIX ECOSYSTEMS EXPECTED_PATTERNS
# EXPECTED_PATH_PREFIX EXPECTED_SKIP: runs the step and checks the
# three outputs that steer the detection
scope_case() {
  scope_for "$2" "$3" "$4"
  check "scope: $1: patterns" "$(scope_output patterns)" "$5"
  check "scope: $1: path_prefix" "$(scope_output path_prefix)" "$6"
  check "scope: $1: skip" "$(scope_output skip)" "$7"
}

# The docker preset is always in, once, ahead of the caller's presets
scope_for '' . docker
check 'scope: the default ecosystems are docker' \
  "$(scope_output ecosystems)" docker
scope_for '' . python
check 'scope: docker joins an application ecosystem' \
  "$(scope_output ecosystems)" docker,python
scope_for '' . docker,python
check 'scope: docker named first stays once' \
  "$(scope_output ecosystems)" docker,python
scope_for '' . python,docker,go
check 'scope: docker named later stays once' \
  "$(scope_output ecosystems)" docker,python,go
scope_for '' . python,python
check 'scope: a repeated preset appears once' \
  "$(scope_output ecosystems)" docker,python

scope_case 'an empty images input yields no patterns' '' . docker '' . false
scope_case 'an image without a dockerfile yields no patterns' \
  '[{"name": "app", "context": "docker"}]' . docker '' . false
scope_case 'a context the dialect refuses needs no pattern' \
  '[{"name": "app", "context": "images[arm]"}]' . docker '' . false
scope_case 'a named dockerfile is passed as given' \
  '[{"name": "app", "context": "docker",
    "dockerfile": "docker/Dockerfile-alpine"}]' . docker \
  docker/Dockerfile-alpine . false
scope_case 'a standard name is passed too (over-matching is safe)' \
  '[{"name": "app", "context": "docker",
    "dockerfile": "docker/Dockerfile"}]' . docker docker/Dockerfile . false
scope_case 'a leading ./ is dropped, which the dialect refuses' \
  '[{"name": "app", "context": ".", "dockerfile": "./build/image.df"}]' \
  . docker build/image.df . false
scope_case 'dot segments and doubled slashes are resolved' \
  '[{"name": "app", "context": ".",
    "dockerfile": "a/../docker//./image.df"}]' . docker docker/image.df \
  . false
scope_case 'one pattern per image, in order' \
  '[{"name": "a", "context": "a", "dockerfile": "a/A.df"},
    {"name": "b", "context": "b"},
    {"name": "c", "context": "c", "dockerfile": "c/C.df"}]' . docker \
  "$(printf 'a/A.df\nc/C.df')" . false
scope_case 'a dockerfile inside path_prefix keeps that scope' \
  '[{"name": "app", "context": "docker",
    "dockerfile": "docker/Dockerfile-alpine"}]' app docker \
  docker/Dockerfile-alpine app false
scope_case 'a path_prefix is passed through as given' \
  '[{"name": "app", "context": "docker",
    "dockerfile": "docker/Dockerfile-alpine"}]' ./app/ docker \
  docker/Dockerfile-alpine ./app/ false
# A recipe outside path_prefix: the scope widens to the repository
# root and every pattern becomes repository-relative, so the sibling
# still counts (the Copilot finding on #201: the file name alone
# matched nothing under a scope that excluded it)
scope_case 'a sibling recipe widens the scope to the repository root' \
  '[{"name": "app", "context": "docker",
    "dockerfile": "../shared/Image.df"}]' app docker shared/Image.df . false
scope_case 'a widened scope makes every pattern repository-relative' \
  '[{"name": "a", "context": "docker", "dockerfile": "docker/A.df"},
    {"name": "b", "context": "docker", "dockerfile": "../shared/B.df"}]' \
  app docker "$(printf 'app/docker/A.df\nshared/B.df')" . false
scope_case 'a sibling under a nested path_prefix' \
  '[{"name": "app", "context": "docker",
    "dockerfile": "../../shared/Image.df"}]' src/app docker \
  shared/Image.df . false
scope_case 'a .. segment that stays inside path_prefix keeps the scope' \
  '[{"name": "app", "context": "docker",
    "dockerfile": "x/../docker/Image.df"}]' app docker docker/Image.df \
  app false
# A sibling context: its manifests and its Dockerfile lie outside
# path_prefix, where no preset looks, so the scope widens for the
# context as it does for a named recipe (the second Copilot finding on
# #201: a loop over 'dockerfile' alone left a sibling context's
# application files, and its unnamed Dockerfile, out of the detection);
# the presets then match both at any depth, so no pattern is needed
scope_case 'a sibling context widens the scope to the repository root' \
  '[{"name": "app", "context": "../shared"}]' app docker '' . false
scope_case 'a sibling context with a recipe inside path_prefix widens too' \
  '[{"name": "app", "context": "../shared",
    "dockerfile": "docker/Image.df"}]' app docker app/docker/Image.df \
  . false
scope_case 'a sibling context under a nested path_prefix' \
  '[{"name": "app", "context": "../../shared"}]' src/app docker '' . \
  false
scope_case 'a context that stays inside path_prefix keeps the scope' \
  '[{"name": "app", "context": "x/../docker"}]' app docker '' app false
# A named build context: '--build-context name=source' in the image's
# build_flags, in either spelling, names a directory the recipe copies
# from, which resolves against path_prefix as the context does (the
# fourth-round Copilot finding on #201: a sibling named context left
# its manifests outside the detection with the gate withheld). A local
# source is scoped as a context; a remote one is not a path at all.
scope_case 'a named build context inside path_prefix keeps the scope' \
  '[{"name": "app", "context": "docker",
    "build_flags": ["--build-context", "deps=vendor"]}]' app docker '' \
  app false
scope_case 'a sibling named build context widens the scope' \
  '[{"name": "app", "context": ".",
    "build_flags": ["--build-context", "deps=../shared"]}]' app docker '' \
  . false
scope_case 'a sibling named build context in one argument widens too' \
  '[{"name": "app", "context": ".",
    "build_flags": ["--network=host", "--build-context=deps=../shared"]}]' \
  app docker '' . false
scope_case 'a widened scope from a build context roots the patterns' \
  '[{"name": "app", "context": ".", "dockerfile": "Image.df",
    "build_flags": ["--build-context", "deps=../shared"]}]' app docker \
  app/Image.df . false
scope_case 'the second of two named build contexts widens as well' \
  '[{"name": "app", "context": ".",
    "build_flags": ["--build-context", "a=vendor",
      "--build-context", "b=../shared"]}]' app docker '' . false
scope_case 'a named build context under a nested path_prefix' \
  '[{"name": "app", "context": ".",
    "build_flags": ["--build-context", "deps=../../shared"]}]' src/app \
  docker '' . false
scope_case 'a named build context with a source holding = widens' \
  '[{"name": "app", "context": ".",
    "build_flags": ["--build-context", "deps=../shared/a=b"]}]' app docker \
  '' . false
scope_case 'a remote image build context is not a path' \
  '[{"name": "app", "context": ".",
    "build_flags": ["--build-context", "alpine=docker-image://alpine:3"]}]' \
  app docker '' app false
scope_case 'a URL build context is not a path' \
  '[{"name": "app", "context": ".", "build_flags":
    ["--build-context", "src=https://github.com/o/r.git#main"]}]' \
  app docker '' app false
scope_case 'a git build context is not a path' \
  '[{"name": "app", "context": ".",
    "build_flags": ["--build-context", "src=git@github.com:o/r.git"]}]' \
  app docker '' app false
scope_case 'a github.com build context is not a path' \
  '[{"name": "app", "context": ".",
    "build_flags": ["--build-context", "src=github.com/o/r"]}]' app \
  docker '' app false
scope_case 'a stage build context is not a path' \
  '[{"name": "app", "context": ".",
    "build_flags": ["--build-context", "base=target:builder"]}]' app \
  docker '' app false
# An OCI layout build context is a local directory (the fifth-round
# Copilot finding on #201: it was read as remote, so a layout beside
# path_prefix left the gate withheld): buildx reads
# oci-layout://PATH[:TAG][@DIGEST], and the path is scoped as a
# context is, whatever tag or digest follows it
scope_case 'an OCI layout build context inside path_prefix keeps the scope' \
  '[{"name": "app", "context": ".",
    "build_flags": ["--build-context", "base=oci-layout://layout"]}]' \
  app docker '' app false
scope_case 'a sibling OCI layout build context widens the scope' \
  '[{"name": "app", "context": ".",
    "build_flags": ["--build-context", "base=oci-layout://../layout"]}]' \
  app docker '' . false
scope_case 'a sibling OCI layout with a tag widens the scope' \
  '[{"name": "app", "context": ".",
    "build_flags": ["--build-context=base=oci-layout://../layout:3.22"]}]' \
  app docker '' . false
scope_case 'a sibling OCI layout with a digest widens the scope' \
  '[{"name": "app", "context": ".", "build_flags": ["--build-context",
    "base=oci-layout://../layout@sha256:0123456789abcdef"]}]' \
  app docker '' . false
scope_case 'a sibling OCI layout with a tag and a digest widens the scope' \
  '[{"name": "app", "context": ".", "build_flags": ["--build-context",
    "base=oci-layout://../layout:3.22@sha256:0123456789abcdef"]}]' \
  app docker '' . false
scope_case 'an OCI layout with a tag inside path_prefix keeps the scope' \
  '[{"name": "app", "context": ".", "build_flags": ["--build-context",
    "base=oci-layout://layout:3.22@sha256:0123456789abcdef"]}]' \
  app docker '' app false
scope_case 'other build flags are left alone' \
  '[{"name": "app", "context": ".",
    "build_flags": ["--network=host", "--no-cache", "--pull"]}]' app \
  docker '' app false
scope_case 'build_flags that is not a list adds no context' \
  '[{"name": "app", "context": ".", "build_flags": "--network=host"}]' \
  app docker '' app false

# A recipe no pattern can express skips the detection: no verdict,
# so the gate stays on, and the step summary names the file
# skipped_case DESCRIPTION IMAGES PATH_PREFIX FILE
skipped_case() {
  scope_case "$1" "$2" "$3" docker '' "$3" true
  if grep -q '^::notice::' "${work}/log" &&
    grep -qF -- "- \`$4\`" "${work}/summary"; then
    echo "ok: scope: $1: the skipped file is named in the summary"
  else
    echo "FAIL: scope: $1: the skipped file went unreported"
    sed 's/^/  | /' "${work}/log" "${work}/summary"
    failures=$((failures + 1))
  fi
}
skipped_case 'a file name the dialect refuses skips the detection' \
  '[{"name": "app", "context": "docker",
    "dockerfile": "docker/Dockerfile[1]"}]' . 'docker/Dockerfile[1]'
skipped_case 'a recipe outside the repository skips the detection' \
  '[{"name": "app", "context": "docker",
    "dockerfile": "../elsewhere/Dockerfile"}]' . ../elsewhere/Dockerfile
skipped_case 'a recipe climbing past the repository skips the detection' \
  '[{"name": "app", "context": "docker",
    "dockerfile": "../../elsewhere/Dockerfile"}]' app \
  ../../elsewhere/Dockerfile
skipped_case 'an absolute path skips the detection' \
  '[{"name": "app", "context": "docker",
    "dockerfile": "/src/docker/Dockerfile"}]' . /src/docker/Dockerfile
skipped_case 'a context outside the repository skips the detection' \
  '[{"name": "app", "context": "../elsewhere"}]' . ../elsewhere
skipped_case 'a context climbing past the repository skips the detection' \
  '[{"name": "app", "context": "../../elsewhere",
    "dockerfile": "docker/Dockerfile"}]' app ../../elsewhere
skipped_case 'an absolute context skips the detection' \
  '[{"name": "app", "context": "/src"}]' . /src
skipped_case 'a named build context outside the repository skips' \
  '[{"name": "app", "context": ".",
    "build_flags": ["--build-context", "deps=../elsewhere"]}]' . \
  ../elsewhere
skipped_case 'a named build context climbing past the repository skips' \
  '[{"name": "app", "context": ".",
    "build_flags": ["--build-context=deps=../../elsewhere"]}]' app \
  ../../elsewhere
skipped_case 'an absolute named build context skips the detection' \
  '[{"name": "app", "context": ".",
    "build_flags": ["--build-context", "deps=/srv/deps"]}]' . /srv/deps
skipped_case 'an OCI layout outside the repository skips the detection' \
  '[{"name": "app", "context": ".",
    "build_flags": ["--build-context", "base=oci-layout://../elsewhere"]}]' \
  . oci-layout://../elsewhere
skipped_case 'an OCI layout climbing past the repository skips' \
  '[{"name": "app", "context": ".", "build_flags":
    ["--build-context=base=oci-layout://../../elsewhere:3.22"]}]' app \
  oci-layout://../../elsewhere:3.22
skipped_case 'an absolute OCI layout skips the detection' \
  '[{"name": "app", "context": ".",
    "build_flags": ["--build-context", "base=oci-layout:///srv/layout"]}]' \
  . oci-layout:///srv/layout
skipped_case 'an OCI layout without a path skips the detection' \
  '[{"name": "app", "context": ".",
    "build_flags": ["--build-context", "base=oci-layout://"]}]' . \
  '--build-context base=oci-layout://'
skipped_case 'an OCI layout with a tag alone skips the detection' \
  '[{"name": "app", "context": ".",
    "build_flags": ["--build-context", "base=oci-layout://:3.22"]}]' . \
  '--build-context base=oci-layout://:3.22'
# A value buildx refuses names no directory to scope, so the step
# fails closed rather than guess
skipped_case 'a build context without a value skips the detection' \
  '[{"name": "app", "context": ".",
    "build_flags": ["--build-context"]}]' . '--build-context '
skipped_case 'a build context without = skips the detection' \
  '[{"name": "app", "context": ".",
    "build_flags": ["--build-context", "deps"]}]' . '--build-context deps'
skipped_case 'a build context without a name skips the detection' \
  '[{"name": "app", "context": ".",
    "build_flags": ["--build-context", "=vendor"]}]' . \
  '--build-context =vendor'
skipped_case 'a build context without a source skips the detection' \
  '[{"name": "app", "context": ".",
    "build_flags": ["--build-context=deps="]}]' . '--build-context deps='
skipped_case 'a bare dot skips the detection' \
  '[{"name": "app", "context": "docker", "dockerfile": "."}]' . .
skipped_case 'one unexpressible recipe skips the detection for all' \
  '[{"name": "a", "context": "docker", "dockerfile": "docker/A.df"},
    {"name": "b", "context": "docker", "dockerfile": "docker/B[1].df"}]' \
  . 'docker/B[1].df'
scope_for '[{"name": "app", "context": "docker",
  "dockerfile": "docker/Dockerfile[1]"}]' . docker
check 'scope: a skipped detection still reports the ecosystems' \
  "$(scope_output ecosystems)" docker

# A build_command replaces the discovered builds (the fifth-round
# Copilot finding on #201: the command may build a recipe from a
# directory outside the detection scope, so with the detection still
# running a change there left the gate withheld): the step skips the
# detection whatever the images input says, and the summary names the
# input
# custom_build_case DESCRIPTION IMAGES PATH_PREFIX
custom_build_case() {
  scope_for "$2" "$3" docker 'make images'
  check "scope: $1: patterns" "$(scope_output patterns)" ''
  check "scope: $1: path_prefix" "$(scope_output path_prefix)" "$3"
  check "scope: $1: skip" "$(scope_output skip)" true
  # shellcheck disable=SC2016  # a literal backquoted name
  if grep -q '^::notice::build_command' "${work}/log" &&
    grep -qF 'The `build_command` input' "${work}/summary"; then
    echo "ok: scope: $1: the summary names build_command"
  else
    echo "FAIL: scope: $1: the custom build went unreported"
    sed 's/^/  | /' "${work}/log" "${work}/summary"
    failures=$((failures + 1))
  fi
}
custom_build_case 'a build_command without images skips the detection' \
  '' .
custom_build_case 'a build_command with discovered images skips too' \
  '[{"name": "app", "context": "docker",
    "dockerfile": "docker/Dockerfile-alpine"}]' .
custom_build_case 'a build_command under a path_prefix skips the detection' \
  '[{"name": "app", "context": "."}]' app
scope_for '' . python 'make images'
check 'scope: a custom build still reports the ecosystems' \
  "$(scope_output ecosystems)" docker,python
# shellcheck disable=SC2016
check 'build-test: the scope step reads build_command' \
  "$(step_field "${verify}" repository-metadata dependency-scope \
    env.BUILD_COMMAND)" '${{ inputs.build_command }}'

# A name with a newline, or any control character, is one JSON string
# that a line-based reader would split into two patterns matching
# nothing (the third Copilot finding on #201): the step checks the
# JSON string before any split, skips the detection, and names the
# file with the control characters removed, so the name cannot forge a
# workflow command either
# control_case DESCRIPTION IMAGES PATH_PREFIX LABEL
control_case() {
  skipped_case "$1" "$2" "$3" "$4"
  if grep -q '^::warning::' "${work}/log"; then
    echo "FAIL: scope: $1: the name forged a workflow command"
    sed 's/^/  | /' "${work}/log"
    failures=$((failures + 1))
  else
    echo "ok: scope: $1: no workflow command forged"
  fi
}
control_case 'a newline in a dockerfile name skips the detection' \
  '[{"name": "app", "context": "docker",
    "dockerfile": "docker/recipe\n::warning::forged"}]' . \
  'docker/recipe::warning::forged'
control_case 'a carriage return in a dockerfile name skips the detection' \
  '[{"name": "app", "context": "docker",
    "dockerfile": "docker/recipe\rextra"}]' . docker/recipeextra
control_case 'a tab in a dockerfile name skips the detection' \
  '[{"name": "app", "context": "docker",
    "dockerfile": "docker/re\tcipe"}]' . docker/recipe
control_case 'a newline in a context skips the detection' \
  '[{"name": "app", "context": "doc\nker"}]' . docker
control_case 'a newline in a named build context skips the detection' \
  '[{"name": "app", "context": ".",
    "build_flags": ["--build-context", "deps=ven\n::warning::forged"]}]' \
  . 'deps=ven::warning::forged'
control_case 'a newline in one image skips the detection for all' \
  '[{"name": "a", "context": "docker", "dockerfile": "docker/A.df"},
    {"name": "b", "context": "docker", "dockerfile": "docker/B\n.df"}]' \
  . docker/B.df

# A name the action's reading of its patterns input alters (the
# third-round Copilot finding on #201): the action splits the input
# into lines as Python's str.splitlines does and strips each line as
# str.strip does, so whitespace at either end of a Dockerfile name, or
# a Unicode line separator inside it, makes the action watch another
# path and report 'changed: false' for a change to the recipe alone.
# The step fails closed when the scoped or the repository-relative
# pattern would not come through that reading unchanged.
# images_for DOCKERFILE [CONTEXT]: one image naming the recipe, built
# by jq so any character travels as JSON
images_for() {
  jq -cn --arg d "$1" --arg c "${2:-docker}" \
    '[{name: "app", context: $c, dockerfile: $d}]'
}
# altered_case DESCRIPTION DOCKERFILE PATH_PREFIX: the name, with
# printf escapes for the characters that matter, skips the detection
altered_case() {
  local name
  name=$(printf '%b' "$2")
  skipped_case "$1" "$(images_for "${name}")" "$3" "${name}"
}
altered_case 'a trailing space in a dockerfile name skips the detection' \
  'docker/Image.df ' .
altered_case 'a leading space in a dockerfile name skips the detection' \
  ' docker/Image.df' .
altered_case 'a trailing no-break space skips the detection' \
  'docker/Image.df\u00a0' .
altered_case 'a leading ideographic space skips the detection' \
  '\u3000docker/Image.df' .
altered_case 'a line separator inside a dockerfile name skips the detection' \
  'docker/Im\u2028age.df' .
altered_case 'a paragraph separator inside a name skips the detection' \
  'docker/Im\u2029age.df' .
altered_case 'a next-line character inside a name skips the detection' \
  'docker/Im\u0085age.df' .
# Either form fails closed: under path_prefix app the scoped pattern
# ' docker/Image.df' would be stripped while the repository-relative
# 'app/ docker/Image.df' would not, and a path_prefix with a leading
# space spoils the repository-relative form alone
altered_case 'a scoped pattern the action would strip skips the detection' \
  ' docker/Image.df' app
altered_case 'a repository-relative pattern the action would strip skips' \
  'docker/Image.df' ' app'
# What the action leaves alone passes through: whitespace inside a
# name, a non-ASCII letter, and characters Python does not count as
# whitespace, so the step is no stricter than the action's reading
# intact_case DESCRIPTION DOCKERFILE
intact_case() {
  local name
  name=$(printf '%b' "$2")
  scope_case "$1" "$(images_for "${name}")" . docker "${name}" . false
}
intact_case 'a space inside a dockerfile name passes through' \
  'docker/My Image.df'
intact_case 'a non-ASCII letter in a dockerfile name passes through' \
  'docker/\u00cdmage.df'
intact_case 'a zero-width space is not whitespace to the action' \
  'docker/Image\u200b.df'
intact_case 'a byte order mark is not whitespace to the action' \
  'docker/Image.df\ufeff'
intact_case 'a Mongolian vowel separator is not whitespace to the action' \
  '\u180edocker/Image.df'

# The heredoc that carries the patterns ends at the first line equal
# to its delimiter, and a recipe named DOCKERFILE_PATTERNS is a valid
# pattern (the fourth-round Copilot finding on #201: it ended the
# output early and left the closing delimiter as a malformed line), so
# the step lengthens the delimiter until no pattern equals it
scope_case 'a recipe named as the delimiter comes through' \
  '[{"name": "app", "context": ".", "dockerfile": "DOCKERFILE_PATTERNS"}]' \
  . docker DOCKERFILE_PATTERNS . false
check 'scope: the delimiter steps aside for a recipe named as it' \
  "$(sed -n 's/^patterns<<//p' "${work}/output")" DOCKERFILE_PATTERNS_
check 'scope: the heredoc closes with that delimiter' \
  "$(tail -n 1 "${work}/output")" DOCKERFILE_PATTERNS_
scope_case 'recipes named as the delimiter and its successor come through' \
  '[{"name": "a", "context": ".", "dockerfile": "DOCKERFILE_PATTERNS_"},
    {"name": "b", "context": ".", "dockerfile": "DOCKERFILE_PATTERNS"}]' \
  . docker "$(printf 'DOCKERFILE_PATTERNS_\nDOCKERFILE_PATTERNS')" . false
check 'scope: the delimiter steps past both' \
  "$(sed -n 's/^patterns<<//p' "${work}/output")" DOCKERFILE_PATTERNS__
scope_case 'a recipe named as the delimiter under a widened scope' \
  '[{"name": "app", "context": "../shared",
    "dockerfile": "DOCKERFILE_PATTERNS"}]' \
  app docker app/DOCKERFILE_PATTERNS . false
check 'scope: the delimiter stays put when no emitted pattern equals it' \
  "$(sed -n 's/^patterns<<//p' "${work}/output")" DOCKERFILE_PATTERNS
# The lists the step encodes, against Python itself: every code point
# (control characters aside, which the step refuses earlier) that
# str.splitlines splits on anywhere, or that str.strip removes from
# either end, must skip the detection. Python prints each as eight
# hex digits with 'any' or 'edge'.
python3 - > "${work}/altered" <<'PYTHON'
for cp in range(0x110000):
    if cp < 32 or cp == 127 or 0xD800 <= cp <= 0xDFFF:
        continue
    char = chr(cp)
    inside, head, tail = "a" + char + "b", char + "a", "a" + char
    if inside.splitlines() != [inside]:
        print(f"{cp:08x} any")
    elif head.strip() != head or tail.strip() != tail:
        print(f"{cp:08x} edge")
PYTHON
check 'scope: Python alters a known number of code points' \
  "$(wc -l < "${work}/altered" | tr -d ' ')" 20
while read -r cp kind; do
  char=$(printf '%b' "\\U${cp}")
  if [ "${kind}" = any ]; then
    skipped_case "U+${cp} inside a dockerfile name skips the detection" \
      "$(images_for "docker/Im${char}age.df")" . "docker/Im${char}age.df"
  else
    skipped_case "U+${cp} at the end of a dockerfile name skips the detection" \
      "$(images_for "docker/Image.df${char}")" . "docker/Image.df${char}"
    skipped_case "U+${cp} at the start of a dockerfile name skips the detection" \
      "$(images_for "${char}docker/Image.df")" . "${char}docker/Image.df"
  fi
done < "${work}/altered"

# --- dependency-change-action at its pin ----------------------------------

# The detector repository-metadata-action runs at its pin: read its
# pin from that action's own metadata, so the two cannot drift apart
action='lfreleng-actions/dependency-change-action'
if [ -n "${REPOSITORY_METADATA_ACTION_DIR:-}" ]; then
  metadata_dir=$(cd "${REPOSITORY_METADATA_ACTION_DIR}" && pwd)
else
  metadata_dir="${work}/repository-metadata-action"
  git -c init.defaultBranch=main init -q "${metadata_dir}"
  git -C "${metadata_dir}" fetch -q --depth 1 \
    "https://github.com/${metadata_action}" "${metadata_pin}"
  git -C "${metadata_dir}" checkout -q FETCH_HEAD
fi
head=$(git -C "${metadata_dir}" rev-parse HEAD)
if [ "${head}" != "${metadata_pin}" ]; then
  echo "FAIL: ${metadata_dir} is at ${head}, but the workflows pin" \
    "${metadata_pin}"
  exit 1
fi
pin=$(sed -nE "s#^ *uses: ${action}@([0-9a-f]{40})([[:space:]].*)?\$#\1#p" \
  "${metadata_dir}/action.yaml")
if [[ ! "${pin}" =~ ^[0-9a-f]{40}$ ]]; then
  echo "FAIL: no single ${action} pin in ${metadata_action}'s action.yaml"
  exit 1
fi
echo "ok: ${metadata_action} runs ${action}@${pin}"

if [ -n "${DEPENDENCY_CHANGE_ACTION_DIR:-}" ]; then
  action_dir=$(cd "${DEPENDENCY_CHANGE_ACTION_DIR}" && pwd)
else
  action_dir="${work}/dependency-change-action"
  git -c init.defaultBranch=main init -q "${action_dir}"
  git -C "${action_dir}" fetch -q --depth 1 \
    "https://github.com/${action}" "${pin}"
  git -C "${action_dir}" checkout -q FETCH_HEAD
fi
head=$(git -C "${action_dir}" rev-parse HEAD)
if [ "${head}" != "${pin}" ]; then
  echo "FAIL: ${action_dir} is at ${head}, but ${metadata_action} pins" \
    "${pin}"
  exit 1
fi
entry="${action_dir}/scripts/dependency_change/__main__.py"
if [ ! -f "${entry}" ]; then
  echo "FAIL: ${entry} is missing; the action's layout changed"
  exit 1
fi

# A repository whose second commit changes a Dockerfile with a name
# the docker preset does not match, at the root and under sub/, plus
# an unrelated file, so the preset alone must report no change
fixture="${work}/fixture"
git -c init.defaultBranch=main init -q "${fixture}"
git -C "${fixture}" config user.name 'Fixture'
git -C "${fixture}" config user.email 'fixture@example.invalid'
mkdir -p "${fixture}/docker" "${fixture}/sub/docker"
printf 'FROM alpine\n' > "${fixture}/docker/Dockerfile-alpine"
printf 'FROM alpine\n' > "${fixture}/sub/docker/Dockerfile-alpine"
printf 'v1\n' > "${fixture}/app.txt"
git -C "${fixture}" add -A
git -C "${fixture}" commit -q -m 'Add the images'
printf 'RUN true\n' >> "${fixture}/docker/Dockerfile-alpine"
printf 'RUN true\n' >> "${fixture}/sub/docker/Dockerfile-alpine"
printf 'v2\n' > "${fixture}/app.txt"
git -C "${fixture}" commit -q -a -m 'Change the images'

# detect DESCRIPTION EXPECTED_CHANGED PATH_PREFIX IMAGES [ECOSYSTEMS
# [CALLER_PATTERNS]]:
# runs the action with the ecosystems, patterns and scope the step
# resolves for IMAGES under PATH_PREFIX against the fixture's last
# commit, as repository-metadata would with 'base' standing in for the
# event-derived base, and compares the 'changed' output and the
# sidecar's verdict; EXPECTED_CHANGED is 'true' or 'false', and
# ECOSYSTEMS is the caller's grype_dependency_ecosystems (docker);
# CALLER_PATTERNS, grype_dependency_patterns, joins the step's
# patterns on a new line, as the metadata step's block scalar does
detect() {
  local ecosystems patterns scope changed sidecar_changed
  scope_for "$4" "$3" "${5:-docker}"
  check "action: $1: the step does not skip the detection" \
    "$(scope_output skip)" false
  ecosystems=$(scope_output ecosystems)
  patterns=$(scope_output patterns)
  if [ "$#" -ge 6 ]; then
    patterns="${patterns}"$'\n'"$6"
  fi
  scope=$(scope_output path_prefix)
  : > "${work}/output"
  rm -f "${fixture}/dependency-change.json"
  if ! (cd "${fixture}" && env -i PATH="${PATH}" HOME="${work}" \
    GITHUB_OUTPUT="${work}/output" INPUT_ECOSYSTEMS="${ecosystems}" \
    INPUT_PATTERNS="${patterns}" INPUT_PATH_PREFIX="${scope}" \
    INPUT_GERRIT_REFSPEC='' INPUT_BASE='HEAD^1' \
    INPUT_OUTPUT=dependency-change.json \
    python3 -I "${entry}" > "${work}/log" 2>&1); then
    echo "FAIL: action: $1: the action failed"
    sed 's/^/  | /' "${work}/log"
    failures=$((failures + 1))
    return 0
  fi
  changed=$(sed -n '/^changed<</,/^ghadelim/p' "${work}/output" \
    | sed '1d;$d')
  check "action: $1: changed output" "${changed}" "$2"
  sidecar_changed=$(jq -r '.changed' "${fixture}/dependency-change.json")
  check "action: $1: sidecar verdict" "${sidecar_changed}" "$2"
}
detect 'the docker preset alone misses the custom name' false . ''
detect 'an empty caller pattern list adds nothing' false . '' docker ''
detect 'a caller pattern counts after no step patterns' true . '' docker \
  app.txt
detect 'caller patterns count one per line' true . '' docker \
  "$(printf 'README.md\napp.txt')"
# The image names a recipe the commit leaves alone, so the step emits
# a pattern that matches nothing and the caller's must still count
detect 'a step pattern for an unchanged recipe sees no change' false . \
  '[{"name": "app", "context": "docker",
    "dockerfile": "docker/Unchanged.df"}]' docker ''
detect 'a caller pattern counts after the step patterns' true . \
  '[{"name": "app", "context": "docker",
    "dockerfile": "docker/Unchanged.df"}]' docker app.txt
check 'action: the caller pattern lists its file in the sidecar' \
  "$(jq -r '.files | index("app.txt") != null' \
    "${fixture}/dependency-change.json")" true
detect 'the step pattern matches the custom name at the root' true . \
  '[{"name": "app", "context": "docker",
    "dockerfile": "docker/Dockerfile-alpine"}]'
detect 'the step pattern matches the custom name under a path_prefix' \
  true sub \
  '[{"name": "app", "context": "docker",
    "dockerfile": "docker/Dockerfile-alpine"}]'
check 'action: the matched file is listed in the sidecar' \
  "$(jq -r '.files | index("sub/docker/Dockerfile-alpine") != null' \
    "${fixture}/dependency-change.json")" true

# The sibling recipe: a third commit changes the root docker/ recipe
# alone, which no pattern under path_prefix sub can see. The image
# names it as ../docker/Dockerfile-alpine, so the step widens the
# scope to the repository root and the change counts; the control
# without the image shows the prefix alone misses it.
printf 'RUN false\n' >> "${fixture}/docker/Dockerfile-alpine"
git -C "${fixture}" commit -q -a -m 'Change the root image alone'
detect 'the docker preset under the prefix misses the sibling' false sub ''
detect 'the sibling recipe counts through the widened scope' true sub \
  '[{"name": "app", "context": "../docker",
    "dockerfile": "../docker/Dockerfile-alpine"}]'
check 'action: the sibling recipe is listed in the sidecar' \
  "$(jq -r '.files | index("docker/Dockerfile-alpine") != null' \
    "${fixture}/dependency-change.json")" true

# The sibling context: a fourth commit adds a conventional Dockerfile
# and a Python manifest under the root docker/, and two more change
# each alone. With path_prefix sub, an image whose context is
# ../docker names neither, so the step widens the scope: the
# Dockerfile counts through the docker preset and the manifest
# through the python preset. The controls without the image show the
# prefix alone misses both.
printf 'FROM alpine\n' > "${fixture}/docker/Dockerfile"
printf 'requests==1.0\n' > "${fixture}/docker/requirements.txt"
git -C "${fixture}" add -A
git -C "${fixture}" commit -q -m 'Add the sibling context files'
printf 'RUN true\n' >> "${fixture}/docker/Dockerfile"
git -C "${fixture}" commit -q -a -m 'Change the sibling Dockerfile alone'
detect 'the docker preset under the prefix misses the sibling Dockerfile' \
  false sub ''
detect 'the sibling context Dockerfile counts through the widened scope' \
  true sub '[{"name": "app", "context": "../docker"}]'
check 'action: the sibling context Dockerfile is listed in the sidecar' \
  "$(jq -r '.files | index("docker/Dockerfile") != null' \
    "${fixture}/dependency-change.json")" true
printf 'requests==2.0\n' > "${fixture}/docker/requirements.txt"
git -C "${fixture}" commit -q -a -m 'Change the sibling manifest alone'
detect 'the python preset under the prefix misses the sibling manifest' \
  false sub '' python
detect 'the sibling context manifest counts through the widened scope' \
  true sub '[{"name": "app", "context": "../docker"}]' python
check 'action: the sibling context manifest is listed in the sidecar' \
  "$(jq -r '.files | index("docker/requirements.txt") != null' \
    "${fixture}/dependency-change.json")" true
# The named build context: the same manifest change, reached by an
# image whose context stays under path_prefix sub but whose
# build_flags pass '--build-context deps=../docker', the directory its
# recipe copies the manifest from. The scope widens for it as for a
# context; the control without the flag shows the prefix alone misses
# it.
detect 'the python preset under the prefix misses the named build context' \
  false sub '[{"name": "app", "context": "."}]' python
detect 'a named build context manifest counts through the widened scope' \
  true sub '[{"name": "app", "context": ".",
    "build_flags": ["--build-context", "deps=../docker"]}]' python
check 'action: the named build context manifest is listed in the sidecar' \
  "$(jq -r '.files | index("docker/requirements.txt") != null' \
    "${fixture}/dependency-change.json")" true
# The same directory named as an OCI layout: a local path to buildx,
# so the scope widens for it as for any named build context
detect 'an OCI layout build context widens the scope as a local path' \
  true sub '[{"name": "app", "context": ".",
    "build_flags": ["--build-context", "base=oci-layout://../docker:v1"]}]' \
  python

# --- The resolved self-test's oracle, against the action ------------------

# The check job of build-test-dependency-gate-resolved predicts the
# verdict from the diff; it must predict what the action reports for
# the same two commits, or the self-test fails a correct run. The
# action anchors the docker preset at any depth under path_prefix and
# directly in each of its ancestors (the fourth-round Copilot finding
# on #201: a recipe added to tests/fixtures, tests or the root arms the
# gate, which the oracle then called wrong), and nowhere else.
yq -r '.jobs."build-test-dependency-gate-resolved-checks".steps[]
  | select(.name == "Require the verdict the diff predicts") | .run' \
  "${workflows}/testing.yaml" > "${work}/oracle.sh"
if [ ! -s "${work}/oracle.sh" ]; then
  echo "FAIL: no verdict step in build-test-dependency-gate-resolved-checks"
  exit 1
fi
# The step runs in the checkout, so a wrapper enters the fixture first
# shellcheck disable=SC2016  # the wrapper expands them when it runs
printf 'cd "${ORACLE_DIR}" && . "${ORACLE_SCRIPT}"\n' \
  > "${work}/oracle-wrapper.sh"
oracle="${work}/oracle"
git -c init.defaultBranch=main init -q "${oracle}"
git -C "${oracle}" config user.name 'Fixture'
git -C "${oracle}" config user.email 'fixture@example.invalid'
mkdir -p "${oracle}/${gate_fixture}"
printf 'FROM alpine\n' > "${oracle}/${gate_fixture}/Dockerfile"
printf 'v1\n' > "${oracle}/README.md"
git -C "${oracle}" add -A
git -C "${oracle}" commit -q -m 'Add the fixture'

# oracle_case DESCRIPTION FILE CHANGED: a commit that adds or changes
# FILE alone; the action must report CHANGED for it under the fixture's
# path_prefix, the oracle must accept that verdict and reject the other
oracle_case() {
  local changed reason other other_reason
  mkdir -p "${oracle}/$(dirname "$2")"
  printf 'RUN true\n' >> "${oracle}/$2"
  git -C "${oracle}" add -A
  git -C "${oracle}" commit -q -m "Change $2"
  : > "${work}/output"
  rm -f "${oracle}/dependency-change.json"
  if ! (cd "${oracle}" && env -i PATH="${PATH}" HOME="${work}" \
    GITHUB_OUTPUT="${work}/output" INPUT_ECOSYSTEMS=docker \
    INPUT_PATTERNS='' INPUT_PATH_PREFIX="${gate_fixture}" \
    INPUT_GERRIT_REFSPEC='' INPUT_BASE='HEAD^1' \
    INPUT_OUTPUT=dependency-change.json \
    python3 -I "${entry}" > "${work}/log" 2>&1); then
    echo "FAIL: oracle: $1: the action failed"
    sed 's/^/  | /' "${work}/log"
    failures=$((failures + 1))
    return 0
  fi
  changed=$(sed -n '/^changed<</,/^ghadelim/p' "${work}/output" \
    | sed '1d;$d')
  check "oracle: $1: the action reports changed '$3'" "${changed}" "$3"
  if [ "${changed}" = true ]; then
    reason='this change touched the dependency chain'
    other=false
    other_reason='this change did not touch the dependency chain'
  else
    reason='this change did not touch the dependency chain'
    other=true
    other_reason='this change touched the dependency chain'
  fi
  run_step "${work}/oracle-wrapper.sh" ORACLE_DIR="${oracle}" \
    ORACLE_SCRIPT="${work}/oracle.sh" GATE_ACTIVE="${changed}" \
    GATE_REASON="${reason}"
  if [ "${status}" -eq 0 ]; then
    echo "ok: oracle: $1: the oracle accepts the action's verdict"
  else
    echo "FAIL: oracle: $1: the oracle rejects the action's verdict"
    sed 's/^/  | /' "${work}/log"
    failures=$((failures + 1))
  fi
  run_step "${work}/oracle-wrapper.sh" ORACLE_DIR="${oracle}" \
    ORACLE_SCRIPT="${work}/oracle.sh" GATE_ACTIVE="${other}" \
    GATE_REASON="${other_reason}"
  if [ "${status}" -ne 0 ] && grep -q '^::error::' "${work}/log"; then
    echo "ok: oracle: $1: the oracle rejects the other verdict"
  else
    echo "FAIL: oracle: $1: the oracle accepted the other verdict"
    sed 's/^/  | /' "${work}/log"
    failures=$((failures + 1))
  fi
}
oracle_case 'the fixture Dockerfile' "${gate_fixture}/Dockerfile" true
oracle_case 'a recipe beneath the fixture' \
  "${gate_fixture}/sub/Containerfile" true
oracle_case 'a custom-suffix recipe beneath the fixture' \
  "${gate_fixture}/image.Dockerfile" true
oracle_case 'a recipe in the fixture parent' \
  "$(dirname "${gate_fixture}")/Dockerfile" true
oracle_case 'a recipe in the fixture grandparent' \
  "$(dirname "$(dirname "${gate_fixture}")")/Dockerfile.alpine" true
oracle_case 'a recipe at the repository root' Dockerfile true
oracle_case 'a recipe in a sibling of the fixture' \
  "$(dirname "${gate_fixture}")/other/Dockerfile" false
oracle_case 'a recipe in a sibling of the fixture parent' \
  "$(dirname "$(dirname "${gate_fixture}")")/other/Dockerfile" false
oracle_case 'a file under the fixture the preset ignores' \
  "${gate_fixture}/README.md" false
oracle_case 'a file at the root the preset ignores' README.md false
oracle_case 'a near-miss name beneath the fixture' \
  "${gate_fixture}/Dockerfiles" false
check 'oracle: the fixture lies two directories deep, so each ancestor case is real' \
  "$(tr -cd / <<< "${gate_fixture}" | wc -c | tr -d ' ')" 2

# A planted sidecar: the action removes a dependency-change.json the
# checkout brought along before it looks, and names no manifest on an
# unresolved result, so a stale {"changed": false} never stands in for
# a verdict. Without GITHUB_SHA the action has no base and reports
# unresolved.
printf '{"changed": false}\n' > "${fixture}/dependency-change.json"
: > "${work}/output"
if (cd "${fixture}" && env -i PATH="${PATH}" HOME="${work}" \
  GITHUB_OUTPUT="${work}/output" INPUT_ECOSYSTEMS=docker \
  INPUT_PATTERNS='' INPUT_PATH_PREFIX=. INPUT_GERRIT_REFSPEC='' \
  INPUT_BASE='' INPUT_OUTPUT=dependency-change.json \
  python3 -I "${entry}" > "${work}/log" 2>&1); then
  echo "ok: action: an unresolved run exits 0"
else
  echo "FAIL: action: an unresolved run failed"
  sed 's/^/  | /' "${work}/log"
  failures=$((failures + 1))
fi
check 'action: an unresolved run names no manifest' \
  "$(sed -n '/^manifest<</,/^ghadelim/p' "${work}/output" | sed '1d;$d')" ''
if [ -e "${fixture}/dependency-change.json" ]; then
  echo "FAIL: action: a planted sidecar survived an unresolved run"
  failures=$((failures + 1))
else
  echo "ok: action: a planted sidecar is removed on an unresolved run"
fi

# The hazard behind the intact check: a recipe named with a trailing
# space, and one with a line separator inside, each changed alone. The
# patterns the step emitted before the check (the names as given)
# come through the action's reading as other paths, so the action
# reports 'changed: false' for a change to the recipes themselves;
# the step now skips the detection for either name instead.
space_name='docker/Image.df '
separator_name=$(printf '%b' 'docker/Im\u2028age.df')
printf 'FROM alpine\n' > "${fixture}/${space_name}"
printf 'FROM alpine\n' > "${fixture}/${separator_name}"
git -C "${fixture}" add -A
git -C "${fixture}" commit -q -m 'Add the recipes the action misreads'
printf 'RUN true\n' >> "${fixture}/${space_name}"
printf 'RUN true\n' >> "${fixture}/${separator_name}"
git -C "${fixture}" commit -q -a -m 'Change the misread recipes alone'
: > "${work}/output"
rm -f "${fixture}/dependency-change.json"
if (cd "${fixture}" && env -i PATH="${PATH}" HOME="${work}" \
  GITHUB_OUTPUT="${work}/output" INPUT_ECOSYSTEMS=docker \
  INPUT_PATTERNS="${space_name}"$'\n'"${separator_name}" \
  INPUT_PATH_PREFIX=. INPUT_GERRIT_REFSPEC='' INPUT_BASE='HEAD^1' \
  INPUT_OUTPUT=dependency-change.json \
  python3 -I "${entry}" > "${work}/log" 2>&1); then
  check 'action: the names as given miss the misread recipes' \
    "$(sed -n '/^changed<</,/^ghadelim/p' "${work}/output" | sed '1d;$d')" \
    false
else
  echo "FAIL: action: the run with the misread names failed"
  sed 's/^/  | /' "${work}/log"
  failures=$((failures + 1))
fi
scope_for "$(images_for "${space_name}")" . docker
check 'action: the step skips the detection for the trailing space' \
  "$(scope_output skip)" true
scope_for "$(images_for "${separator_name}")" . docker
check 'action: the step skips the detection for the line separator' \
  "$(scope_output skip)" true

if [ "${failures}" -ne 0 ]; then
  echo "${failures} check(s) failed"
  exit 1
fi
echo "All checks passed"
