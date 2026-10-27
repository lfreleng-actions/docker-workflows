#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation

# Regression test for latest_policy, the rule that never moves
# 'latest' backwards (#115), in the merge lane (merge.yaml) and the
# release lane (build-test-release.yaml). It checks:
# - each lane's latest_policy input defaults to 'highest', and the
#   gerrit-validate job's 'latest-policy' step, extracted and run as
#   GitHub runs a 'shell: bash' step, accepts 'highest' and 'always'
#   and fails anything else with an ::error:: annotation;
# - both lanes hand the policy to docker-promote-action at the same
#   pinned commit, and no workflow retags 'latest' with crane itself;
# - the release lane checks the pushed images with
#   docker-promote-action under dry_run before the GitHub release
#   publishes, and the action, in mode latest fetched at its pinned
#   commit and run under dry_run, accepts the build job's pushed
#   output, overlapping registries included, and refuses one
#   repository pushed with two digests;
# - the release lane's 'latest-release' step, which decides whether
#   the release becomes the repository's Latest GitHub release, run
#   against a stub gh serving a release list;
# - the release lane's 'latest-recheck' step, which hands Latest to a
#   higher release published outside the promote-release job's queue,
#   or that an earlier attempt of a re-run left behind, run against a
#   stub gh whose release list changes between reads and which keeps
#   the repository's Latest release;
# - the promote-release and release-publish jobs' shared concurrency
#   group, which serialises promotion per target repository and
#   queues waiting releases.
# docker-promote-action's own suite covers the image-side comparison.
#
# Usage: tests/test_latest_policy.sh
# PROMOTE_ACTION_DIR may name a local clone of docker-promote-action
# checked out at the pinned commit, to run without fetching it.
# Needs bash, git, jq, python3 (3.10 or later) and yq (either the Go
# or the Python implementation).

set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
workflows="${root}/.github/workflows"

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

# --- Input and validation, in both lanes ---------------------------------

# validate_case DESCRIPTION EXPECTED POLICY: EXPECTED is 'ok' or 'error'
validate_case() {
  local status=0
  env -i PATH="${PATH}" HOME="${work}" LATEST_POLICY="$3" \
    bash --noprofile --norc -eo pipefail "${work}/validate.sh" \
    > "${work}/log" 2>&1 || status=$?
  if { [ "$2" = 'ok' ] && [ "${status}" -eq 0 ]; } ||
    { [ "$2" = 'error' ] && [ "${status}" -ne 0 ] &&
      grep -q '^::error::' "${work}/log"; }; then
    echo "ok: ${lane}: validation: $1"
  else
    echo "FAIL: ${lane}: validation: $1 (exit ${status})"
    sed 's/^/  | /' "${work}/log"
    failures=$((failures + 1))
  fi
}

for lane in merge build-test-release; do
  workflow="${workflows}/${lane}.yaml"
  check "${lane}: latest_policy defaults to highest" \
    "$(yq -r '.on.workflow_call.inputs.latest_policy.default' \
      "${workflow}")" highest
  yq -r '.jobs."gerrit-validate".steps[]
    | select(.id == "latest-policy") | .run' \
    "${workflow}" > "${work}/validate.sh"
  if [ ! -s "${work}/validate.sh" ]; then
    echo "FAIL: no 'latest-policy' step in the gerrit-validate job of ${lane}"
    failures=$((failures + 1))
    continue
  fi
  validate_case 'highest is accepted' ok highest
  validate_case 'always is accepted' ok always
  validate_case 'another value fails' error newest
  validate_case 'a differently cased value fails' error Highest
  validate_case 'an empty value fails' error ''
done

# --- Wiring ----------------------------------------------------------------

# step_field FILE JOB ID FIELD: one field of a step, by its id
step_field() {
  yq -r ".jobs.\"$2\".steps[] | select(.id == \"$3\") | .$4" \
    "${workflows}/$1"
}

pattern='^lfreleng-actions/docker-promote-action@([0-9a-f]{40})$'
merge_uses=$(step_field merge.yaml release-publish promote uses)
release_uses=$(step_field build-test-release.yaml promote-release \
  latest-tags uses)
if [[ ! "${release_uses}" =~ ${pattern} ]]; then
  echo "FAIL: the promote-release latest-tags step does not use"
  echo "  docker-promote-action at a commit SHA (got '${release_uses}')"
  exit 1
fi
pin="${BASH_REMATCH[1]}"
check 'both lanes pin the same docker-promote-action' \
  "${merge_uses}" "${release_uses}"

# shellcheck disable=SC2016  # literal workflow expressions
check 'merge: the promote step passes latest_policy' \
  "$(step_field merge.yaml release-publish promote with.latest_policy)" \
  '${{ inputs.latest_policy }}'
# shellcheck disable=SC2016
check 'merge: the promote step passes push_latest' \
  "$(step_field merge.yaml release-publish promote with.push_latest)" \
  '${{ inputs.push_latest }}'

# release_input NAME VALUE: the latest-tags step passes VALUE as NAME
release_input() {
  check "build-test-release: the latest-tags step passes $1" \
    "$(step_field build-test-release.yaml promote-release latest-tags \
      "with.$1")" "$2"
}
release_input mode latest
# shellcheck disable=SC2016
release_input release_tag '${{ needs.build.outputs.version }}'
# shellcheck disable=SC2016
release_input images_json '${{ needs.build.outputs.pushed }}'
# shellcheck disable=SC2016
release_input latest_policy '${{ inputs.latest_policy }}'
# shellcheck disable=SC2016
check 'build-test-release: the build job exports the registry version' \
  "$(yq -r '.jobs.build.outputs.version' \
    "${workflows}/build-test-release.yaml")" \
  '${{ steps.version.outputs.version }}'

if grep -nE 'crane[[:space:]]+tag[^#]*latest' "${workflows}"/*.yaml; then
  echo "FAIL: a workflow still retags 'latest' with crane directly"
  failures=$((failures + 1))
else
  echo "ok: no workflow retags 'latest' with crane directly"
fi

# --- Checking pushed images before publication ----------------------------

# check_input NAME VALUE: the latest-check step passes VALUE as NAME
check_input() {
  check "build-test-release: the latest-check step passes $1" \
    "$(step_field build-test-release.yaml promote-release latest-check \
      "with.$1")" "$2"
}
check 'build-test-release: the latest-check step pins the same action' \
  "$(step_field build-test-release.yaml promote-release latest-check \
    uses)" "${release_uses}"
check_input mode latest
check_input dry_run true
# shellcheck disable=SC2016
check_input images_json '${{ needs.build.outputs.pushed }}'
# shellcheck disable=SC2016
check_input latest_policy '${{ inputs.latest_policy }}'

check 'build-test-release: pushed images are checked before publishing' \
  "$(yq -r '.jobs."promote-release".steps | to_entries
    | (map(select(.value.id == "latest-check")) | .[0].key)
      < (map(select(.value.id == "promote-release")) | .[0].key)' \
    "${workflows}/build-test-release.yaml")" true

digest="sha256:$(printf 'a%.0s' $(seq 64))"
other="sha256:$(printf 'b%.0s' $(seq 64))"
# entry IMAGE [DIGEST]: one entry of the build job's pushed output
entry() {
  printf '{"name":"api","image":"%s","digest":"%s"}' "$1" \
    "${2:-${digest}}"
}
# pushed IMAGE...: the build job's pushed output naming each IMAGE
pushed() {
  local image separator=''
  printf '['
  for image in "$@"; do
    printf '%s%s' "${separator}" "$(entry "${image}")"
    separator=','
  done
  printf ']'
}

# --- docker-promote-action, mode latest ------------------------------------

if [ -n "${PROMOTE_ACTION_DIR:-}" ]; then
  action=$(cd "${PROMOTE_ACTION_DIR}" && pwd)
else
  action="${work}/promote-action"
  git -c init.defaultBranch=main init -q "${action}"
  git -C "${action}" fetch -q --depth 1 \
    https://github.com/lfreleng-actions/docker-promote-action "${pin}"
  git -C "${action}" checkout -q FETCH_HEAD
fi
head=$(git -C "${action}" rev-parse HEAD)
if [ "${head}" != "${pin}" ]; then
  echo "FAIL: ${action} is at ${head}, but the workflows pin ${pin}"
  exit 1
fi

# latest_case DESCRIPTION EXPECTED IMAGES: runs the action in mode
# latest under dry_run; EXPECTED is 'ok' or 'error'
latest_case() {
  local status=0
  env -i PATH="${PATH}" HOME="${work}" \
    GITHUB_OUTPUT="${work}/output" GITHUB_STEP_SUMMARY="${work}/summary" \
    INPUT_MODE=latest INPUT_RELEASE_TAG=1.2.3 INPUT_IMAGES_JSON="$3" \
    INPUT_LATEST_POLICY=highest INPUT_DRY_RUN=true INPUT_INSTALL_CRANE=false \
    python3 -I "${action}/entrypoint.py" > "${work}/log" 2>&1 || status=$?
  if { [ "$2" = 'ok' ] && [ "${status}" -eq 0 ] &&
    ! grep -q '^::error::' "${work}/log"; } ||
    { [ "$2" = 'error' ] && [ "${status}" -ne 0 ]; }; then
    echo "ok: build-test-release: mode latest: $1"
  else
    echo "FAIL: build-test-release: mode latest: $1 (exit ${status})"
    sed 's/^/  | /' "${work}/log"
    failures=$((failures + 1))
  fi
}

latest_case 'accepts the pushed output of distinct registries' ok \
  "$(pushed ghcr.io/org/api docker.io/org/api)"
latest_case 'accepts overlapping registries with one digest' ok \
  "$(pushed ghcr.io/org/api ghcr.io/org/api)"
latest_case 'refuses one repository pushed with two digests' error \
  "[$(entry ghcr.io/org/api),$(entry ghcr.io/org/api "${other}")]"

# --- The Latest GitHub release ----------------------------------------------

step_field build-test-release.yaml promote-release latest-release run \
  > "${work}/decide.sh"
if [ ! -s "${work}/decide.sh" ]; then
  echo "FAIL: no 'latest-release' step in the promote-release job"
  exit 1
fi

# The stub gh answers the release listing the steps make, applying
# the step's own --jq filter to a REST releases page: RELEASES_JSON,
# or with RELEASES_DIR set, that directory's 1.json, 2.json and so on
# for successive reads, the last repeating. It answers the Latest
# release from the file LATEST, and records each
# 'gh release edit TAG --latest' in EDITS and LATEST.
mkdir -p "${work}/bin"
cat > "${work}/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${GH_FAIL:-}" = 'true' ]; then
  echo 'HTTP 502: Bad Gateway' >&2
  exit 1
fi
if [ "$1" = release ] && [ "$2" = edit ] && [ "$#" -eq 4 ] &&
  [ "$4" = --latest ]; then
  echo "$3" >> "${EDITS}"
  echo "$3" > "${LATEST}"
  exit 0
fi
[ "$1" = api ] || { echo "stub gh: unexpected command $*" >&2; exit 2; }
shift
endpoint='' filter='' paginate=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    --paginate) paginate=true ;;
    --jq) filter="$2"; shift ;;
    *) endpoint="$1" ;;
  esac
  shift
done
if [ "${endpoint}" = "repos/${REPOSITORY}/releases/latest" ] &&
  [ "${paginate}" = false ] && [ -s "${LATEST:-}" ]; then
  jq -r "${filter}" <<< "{\"tag_name\": \"$(cat "${LATEST}")\"}"
  exit 0
fi
if [ "${endpoint}" != "repos/${REPOSITORY}/releases" ] ||
  [ "${paginate}" != true ]; then
  echo "stub gh: unexpected endpoint ${endpoint} (paginate ${paginate})" >&2
  exit 2
fi
if [ -n "${RELEASES_DIR:-}" ]; then
  read_count=$(( $(cat "${RELEASES_DIR}/reads" 2>/dev/null || echo 0) + 1 ))
  echo "${read_count}" > "${RELEASES_DIR}/reads"
  while [ "${read_count}" -gt 1 ] &&
    [ ! -f "${RELEASES_DIR}/${read_count}.json" ]; do
    read_count=$((read_count - 1))
  done
  RELEASES_JSON=$(cat "${RELEASES_DIR}/${read_count}.json")
fi
jq -r "${filter}" <<< "${RELEASES_JSON}"
EOF
chmod +x "${work}/bin/gh"

# releases TAG...: a releases page of published releases; a tag
# suffixed ':draft' or ':prerelease' carries that flag instead
releases() {
  local entry tag flag json='[]'
  for entry in "$@"; do
    tag="${entry%%:*}"
    flag=''
    [ "${tag}" = "${entry}" ] || flag="${entry#*:}"
    json=$(jq -c --arg tag "${tag}" --arg flag "${flag}" \
      '. + [{tag_name: $tag, draft: ($flag == "draft"),
        prerelease: ($flag == "prerelease")}]' <<< "${json}")
  done
  echo "${json}"
}

# decide_case DESCRIPTION EXPECTED POLICY TAG [RELEASE...]
# EXPECTED is 'true', 'false' or 'error'; the release list holds the
# repository's releases other than the draft being promoted
decide_case() {
  local description="$1" expected="$2" policy="$3" tag="$4" status=0
  local actual
  shift 4
  : > "${work}/output"
  : > "${work}/summary"
  env -i PATH="${work}/bin:${PATH}" HOME="${work}" \
    GITHUB_OUTPUT="${work}/output" GITHUB_STEP_SUMMARY="${work}/summary" \
    RUNNER_TEMP="${work}" \
    GH_TOKEN=token TAG="${tag}" LATEST_POLICY="${policy}" \
    REPOSITORY=org/repo RELEASES_JSON="$(releases "$@")" \
    GH_FAIL="${GH_FAIL:-}" \
    bash --noprofile --norc -eo pipefail "${work}/decide.sh" \
    > "${work}/log" 2>&1 || status=$?
  actual=$(sed -n 's/^latest=//p' "${work}/output")
  if { [ "${expected}" = 'error' ] && [ "${status}" -ne 0 ] &&
    [ -z "${actual}" ]; } ||
    { [ "${expected}" != 'error' ] && [ "${status}" -eq 0 ] &&
      [ "${actual}" = "${expected}" ] &&
      grep -qxF "candidate=${tag}" "${work}/output" &&
      grep -qF "| \`${tag}\` |" "${work}/summary"; }; then
    echo "ok: Latest release: ${description}"
  else
    echo "FAIL: Latest release: ${description}: expected '${expected}'," \
      "got '${actual}' (exit ${status})"
    sed 's/^/  | /' "${work}/log" "${work}/output" "${work}/summary"
    failures=$((failures + 1))
  fi
}

# highest_is EXPECTED: the last case reported EXPECTED as the highest
highest_is() {
  check "Latest release: the highest published release is '$1'" \
    "$(sed -n 's/^highest=//p' "${work}/output")" "$1"
}

decide_case 'the first release is Latest' true highest v1.0.0
highest_is ''
decide_case 'a patch on the newest line is Latest' \
  true highest v2.0.1 v1.0.0 v2.0.0
highest_is v2.0.0
decide_case 'a patch on an older line is not Latest' \
  false highest v1.2.5 v1.2.4 v2.0.0
highest_is v2.0.0
decide_case 'a re-run of an older release is not Latest' \
  false highest v2.0.0 v2.0.0 v2.0.1
decide_case 'a re-run of the highest release stays Latest' \
  true highest v2.0.1 v2.0.0 v2.0.1
decide_case 'tags compare with or without the v prefix' \
  false highest v1.9.0 2.0.0
decide_case 'an unprefixed candidate compares with v-prefixed tags' \
  true highest 2.0.1 v2.0.0
decide_case 'a pre-release is never Latest' \
  false highest v3.0.0-rc1 v2.0.1
decide_case 'a pre-release tag never counts as the highest' \
  true highest v2.0.2 v2.0.1 v3.0.0-rc1
decide_case 'a pre-release GitHub release never counts as the highest' \
  true highest v2.0.2 v2.0.1 v3.0.0:prerelease
decide_case 'a draft never counts as the highest' \
  true highest v2.0.2 v2.0.1 v3.0.0:draft
decide_case 'tags that are not SemVer are ignored' \
  true highest v1.1.0 latest release-99 v10 v1.0 1.0.0.0 v01.0.0 v1.0.0
highest_is v1.0.0
decide_case 'only tags that are not SemVer is a first release' \
  true highest v0.1.0 latest nightly
decide_case 'build metadata does not count in the candidate' \
  true highest v2.0.0+build.5 v2.0.0
decide_case 'build metadata does not count in published tags' \
  false highest v1.9.9 v2.0.0+build.9
decide_case 'numbers compare by value, not as text' \
  true highest v10.0.0 v9.0.0 v2.10.0
decide_case 'minor numbers compare by value, not as text' \
  true highest v2.10.0 v2.9.0
decide_case 'always marks an older release Latest' \
  true always v1.2.5 v2.0.0
if grep -q '^::warning::' "${work}/log"; then
  echo "ok: Latest release: always warns"
else
  echo "FAIL: Latest release: always does not warn"
  failures=$((failures + 1))
fi
decide_case 'always marks a re-run of an older release Latest' \
  true always v2.0.0 v2.0.1
GH_FAIL=true decide_case 'an unreadable release list fails' \
  error highest v2.0.1 v2.0.0

# --- Rechecking Latest after publication --------------------------------

step_field build-test-release.yaml promote-release latest-recheck run \
  > "${work}/recheck.sh"
if [ ! -s "${work}/recheck.sh" ]; then
  echo "FAIL: no 'latest-recheck' step in the promote-release job"
  exit 1
fi
# shellcheck disable=SC2016
check 'Latest recheck: runs after marking a release Latest and on re-runs' \
  "$(step_field build-test-release.yaml promote-release latest-recheck \
    if)" \
  "\${{ !inputs.dry_run && inputs.latest_policy == 'highest' && (steps.check-promoted.outputs.already_promoted == 'true' || steps.latest-release.outputs.latest == 'true') }}"
# The rules file the recheck sources, as a decision writes it
decide_case 'a decision saves its rules for the recheck' \
  true highest v1.0.0
if [ ! -s "${work}/latest-release-rules.sh" ]; then
  echo "FAIL: the decision saved no rules for the recheck"
  failures=$((failures + 1))
fi

# recheck_case DESCRIPTION EXPECTED EDITS LATEST LIST...: LATEST is
# the repository's Latest release when the step starts; each LIST, a
# comma-separated release list as 'releases' takes it, answers one
# read in turn. EXPECTED is the release left Latest, empty when the
# step has nothing to compare, or 'error'
# (the step fails, though it may still write an output); EDITS the
# space-separated releases the step marked Latest, in order.
recheck_case() {
  local description="$1" expected="$2" edits="$3" latest="$4" status=0
  local actual list n=0
  local -a entries
  shift 4
  rm -rf "${work}/lists"
  mkdir "${work}/lists"
  for list in "$@"; do
    n=$((n + 1))
    IFS=, read -ra entries <<< "${list}"
    releases "${entries[@]}" > "${work}/lists/${n}.json"
  done
  : > "${work}/output"
  : > "${work}/summary"
  : > "${work}/edits"
  echo "${latest}" > "${work}/latest"
  env -i PATH="${work}/bin:${PATH}" HOME="${work}" \
    GITHUB_OUTPUT="${work}/output" GITHUB_STEP_SUMMARY="${work}/summary" \
    RUNNER_TEMP="${work}" GH_TOKEN=token \
    REPOSITORY=org/repo RELEASES_DIR="${work}/lists" \
    EDITS="${work}/edits" LATEST="${work}/latest" GH_FAIL="${GH_FAIL:-}" \
    bash --noprofile --norc -eo pipefail "${work}/recheck.sh" \
    > "${work}/log" 2>&1 || status=$?
  actual=$(sed -n 's/^latest=//p' "${work}/output")
  if { [ "${expected}" = 'error' ] && [ "${status}" -ne 0 ] &&
    [ "$(paste -sd ' ' "${work}/edits")" = "${edits}" ]; } ||
    { [ "${expected}" != 'error' ] && [ "${status}" -eq 0 ] &&
      [ "${actual}" = "${expected}" ] &&
      { [ -z "${expected}" ] ||
        [ "$(cat "${work}/latest")" = "${expected}" ]; } &&
      [ "$(paste -sd ' ' "${work}/edits")" = "${edits}" ]; }; then
    echo "ok: Latest recheck: ${description}"
  else
    echo "FAIL: Latest recheck: ${description}: expected '${expected}'" \
      "after '${edits}', got '${actual}' after" \
      "'$(paste -sd ' ' "${work}/edits")' (exit ${status})"
    sed 's/^/  | /' "${work}/log" "${work}/output" "${work}/summary"
    failures=$((failures + 1))
  fi
}

recheck_case 'the highest release stays Latest' \
  v2.0.0 '' v2.0.0 v1.0.0,v2.0.0
recheck_case 'the first release stays Latest' \
  v1.0.0 '' v1.0.0 v1.0.0
recheck_case 'an equal release counts as the highest' \
  v2.0.0 '' v2.0.0 v2.0.0,2.0.0+build.1
recheck_case 'a pre-release published meanwhile does not take Latest' \
  v2.0.1 '' v2.0.1 v2.0.1,v3.0.0-rc1,v3.0.0:prerelease
recheck_case 'a higher release published meanwhile takes Latest back' \
  v2.0.0 v2.0.0 v1.2.5 v1.2.5,v2.0.0
if grep -qF "Latest moved on to \`v2.0.0\`" "${work}/summary"; then
  echo "ok: Latest recheck: the step summary says why Latest moved on"
else
  echo "FAIL: Latest recheck: the step summary does not say why"
  failures=$((failures + 1))
fi
recheck_case 'releases publishing during the recheck converge' \
  v2.1.0 'v2.0.0 v2.1.0' v1.2.5 \
  v1.2.5,v2.0.0 v1.2.5,v2.0.0,v2.1.0
recheck_case 'releases publishing through every move fail the step' \
  error 'v2.0.0 v3.0.0 v4.0.0 v5.0.0 v6.0.0' v1.0.0 \
  v1.0.0,v2.0.0 v1.0.0,v2.0.0,v3.0.0 v1.0.0,v2.0.0,v3.0.0,v4.0.0 \
  v1.0.0,v2.0.0,v3.0.0,v4.0.0,v5.0.0 \
  v1.0.0,v2.0.0,v3.0.0,v4.0.0,v5.0.0,v6.0.0 \
  v1.0.0,v2.0.0,v3.0.0,v4.0.0,v5.0.0,v6.0.0,v7.0.0
check 'Latest recheck: the last move is read back' \
  "$(cat "${work}/lists/reads")" 6
if grep -q '^::error::Latest is v6.0.0, but v7.0.0' "${work}/log" &&
  grep -qF 'Latest is unconfirmed' "${work}/summary" &&
  grep -qxF 'latest=v6.0.0' "${work}/output"; then
  echo "ok: Latest recheck: an unconfirmed Latest is reported"
else
  echo "FAIL: Latest recheck: an unconfirmed Latest is not reported"
  failures=$((failures + 1))
fi
recheck_case 'a re-run repairs a Latest left on an older release' \
  v2.0.0 v2.0.0 v1.2.5 v1.2.5,v2.0.0
recheck_case 'a re-run leaves the highest release Latest' \
  v2.0.1 '' v2.0.1 v1.2.5,v2.0.0,v2.0.1
recheck_case 'a Latest release that is not SemVer yields to the highest' \
  v2.0.0 v2.0.0 nightly nightly,v2.0.0
recheck_case 'no published SemVer release leaves Latest alone' \
  '' '' nightly nightly,v3.0.0-rc1:prerelease
check 'Latest recheck: no published SemVer release keeps the Latest' \
  "$(cat "${work}/latest")" nightly
GH_FAIL=true recheck_case 'an unreadable release list fails' \
  error '' v2.0.0 v2.0.0

# --- Marking a published release Latest under 'always' ------------------

step_field build-test-release.yaml promote-release latest-always run \
  > "${work}/always.sh"
if [ ! -s "${work}/always.sh" ]; then
  echo "FAIL: no 'latest-always' step in the promote-release job"
  exit 1
fi
: > "${work}/edits"
echo v2.0.0 > "${work}/latest"
status=0
env -i PATH="${work}/bin:${PATH}" HOME="${work}" GH_TOKEN=token \
  TAG=v1.2.5 EDITS="${work}/edits" LATEST="${work}/latest" \
  bash --noprofile --norc -eo pipefail "${work}/always.sh" \
  > "${work}/log" 2>&1 || status=$?
if [ "${status}" -eq 0 ] && [ "$(cat "${work}/edits")" = v1.2.5 ] &&
  [ "$(cat "${work}/latest")" = v1.2.5 ]; then
  echo "ok: Latest always: a re-run marks the published release Latest"
else
  echo "FAIL: Latest always: a re-run did not mark v1.2.5 Latest" \
    "(exit ${status}, edits '$(cat "${work}/edits")')"
  sed 's/^/  | /' "${work}/log"
  failures=$((failures + 1))
fi

# --- Which steps act on the Latest decision -------------------------------

# Each 'if:' of the steps that write the Latest release, evaluated as
# GitHub would over every input and step output they read. Every
# non-dry run whose decision is 'true' must leave something marking
# or confirming Latest, a fresh release and a re-run alike, and a
# dry run must write nothing.
status=0
IF_PROMOTE=$(step_field build-test-release.yaml promote-release \
  promote-release if) \
IF_NOT_LATEST=$(step_field build-test-release.yaml promote-release \
  promote-release-not-latest if) \
IF_ALWAYS=$(step_field build-test-release.yaml promote-release \
  latest-always if) \
IF_RECHECK=$(step_field build-test-release.yaml promote-release \
  latest-recheck if) \
  python3 - > "${work}/log" 2>&1 <<'EOF' || status=$?
import itertools
import os
import re
import sys

TOKEN = re.compile(
    r"\s+|\(|\)|&&|\|\||==|!=|!|'[^']*'"
    r"|inputs\.[A-Za-z0-9_]+|steps\.[A-Za-z0-9_-]+\.outputs\.[A-Za-z0-9_]+"
)


def compile_if(source):
    body = re.fullmatch(r"\$\{\{(.*)\}\}", source.strip(), re.S)
    if not body:
        sys.exit(f"FAIL: not a ${{{{ }}}} expression: {source}")
    body, out, pos = body.group(1), [], 0
    while pos < len(body):
        match = TOKEN.match(body, pos)
        if not match:
            sys.exit(f"FAIL: unsupported syntax at: {body[pos:pos + 40]!r}")
        token = match.group(0)
        pos = match.end()
        if token.isspace():
            continue
        out.append({"&&": " and ", "||": " or ", "!": " not "}.get(
            token,
            f"v[{token!r}]" if token[0] in "is" else token,
        ))
    return compile("".join(out).strip(), source, "eval")


steps = {
    name: compile_if(os.environ[f"IF_{name}"])
    for name in ("PROMOTE", "NOT_LATEST", "ALWAYS", "RECHECK")
}
failures = 0
for dry, policy, promoted, latest in itertools.product(
    (False, True), ("highest", "always"), ("true", "false", ""),
    ("true", "false"),
):
    if policy == "always" and latest == "false":
        continue  # 'always' always decides 'true'
    if not dry and promoted == "":
        continue  # check-promoted always runs outside a dry run
    v = {
        "inputs.dry_run": dry,
        "inputs.latest_policy": policy,
        "steps.check-promoted.outputs.already_promoted": promoted,
        "steps.latest-release.outputs.latest": latest,
    }
    runs = {name for name, code in steps.items() if eval(code)}
    case = (f"dry_run={dry} policy={policy} "
            f"already_promoted={promoted!r} latest={latest}")
    if dry:
        problem = runs and f"a dry run writes: {sorted(runs)}"
    elif latest == "true":
        problem = not runs & {"PROMOTE", "ALWAYS", "RECHECK"} and (
            "nothing marks or confirms Latest")
    else:
        problem = runs & {"PROMOTE", "ALWAYS"} and (
            f"a 'false' decision marks Latest: {sorted(runs)}")
    publishes = runs & {"PROMOTE", "NOT_LATEST"}
    if not dry and promoted == "false" and len(publishes) != 1:
        problem = f"a draft publishes {len(publishes)} times"
    if not dry and promoted == "true" and publishes:
        problem = "a published release publishes again"
    if problem:
        failures += 1
        print(f"FAIL: Latest gates: {case}: {problem}")
    else:
        print(f"ok: Latest gates: {case}: {sorted(runs)}")
sys.exit(1 if failures else 0)
EOF
if [ "${status}" -eq 0 ]; then
  grep -c '^ok:' "${work}/log" | xargs -I{} \
    echo "ok: Latest gates: {} input combinations act on the decision"
else
  echo "FAIL: Latest gates (exit ${status})"
  sed 's/^/  | /' "${work}/log"
  failures=$((failures + 1))
fi

# --- Serialising promotion ------------------------------------------------

# job_field FILE JOB FIELD: one field of a job
job_field() {
  yq -r ".jobs.\"$2\".$3" "${workflows}/$1"
}

# One promotion at a time per target repository, in one group both
# lanes share; a dry run, which writes nothing, queues only behind its
# own run
for lane in 'build-test-release.yaml promote-release' \
  'merge.yaml release-publish'; do
  read -r file job <<< "${lane}"
  # shellcheck disable=SC2016
  check "${file}: ${job} serialised per target repository" \
    "$(job_field "${file}" "${job}" concurrency.group)" \
    "\${{ inputs.dry_run && format('docker-release-promote-dry-run-{0}-{1}', github.run_id, github.run_attempt) || format('docker-release-promote-{0}', inputs.repository || github.repository) }}"
  check "${file}: ${job} queues waiting releases rather than cancel" \
    "$(job_field "${file}" "${job}" concurrency.queue)" max
  check "${file}: ${job} never cancels a running promotion" \
    "$(job_field "${file}" "${job}" 'concurrency."cancel-in-progress"')" \
    false
done

if [ "${failures}" -gt 0 ]; then
  echo "${failures} failure(s)"
  exit 1
fi
echo "All latest_policy cases passed"
