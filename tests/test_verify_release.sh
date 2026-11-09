#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation

# Regression test for the verify lane's release-file checks (#119).
# build-test.yaml's check-release job validates a container release
# file offline before it merges, and its release-verify job runs the
# promotion's registry checks without writing anything. The test runs
# the shipped pieces rather than copies of them:
#
# - the wiring of both jobs, read from the workflow: the actions at
#   commit SHAs, the inputs merge.yaml's promotion also uses, and no
#   checkout in the job holding the registry credential
# - check-release's registry input step, extracted from the workflow
#   and run as GitHub runs a 'shell: bash' step
# - docker-release-detect-action, fetched at the commit the workflow
#   pins, against git histories shaped like a Gerrit patch set and a
#   pull request merge commit, with valid and malformed release files
# - docker-promote-action, fetched at its pinned commit, in verify
#   mode against a fake crane: a missing staged image and a release
#   tag holding other bits fail, an image already released passes
#
# Usage: tests/test_verify_release.sh [workflow-file]
# DETECT_ACTION_DIR and PROMOTE_ACTION_DIR may name local clones of the
# actions checked out at the pinned commits, to run without fetching.
# Needs bash, git, jq, python3 (3.10 or later) and mikefarah yq v4.25.3
# or later (the detect action refuses the Python yq).

set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
workflow="${1:-${root}/.github/workflows/build-test.yaml}"

work=$(mktemp -d)
trap 'rm -rf "${work}"' EXIT

failures=0

fail() {
  echo "FAIL: $*"
  failures=$((failures + 1))
}

# job_step JOB ID FIELD: one field of the step with that id in JOB
job_step() {
  yq -r ".jobs.\"$1\".steps[] | select(.id == \"$2\") | .$3" "${workflow}"
}

# output KEY FILE: a step output, written plainly or in heredoc form
output() {
  awk -v key="$1" '
    delim != "" { if ($0 == delim) exit; print; next }
    index($0, key "<<") == 1 { delim = substr($0, length(key) + 3); next }
    index($0, key "=") == 1 { print substr($0, length(key) + 2); exit }
  ' "$2"
}

# --- Wiring ---------------------------------------------------------------

# pin JOB ID ACTION: the commit SHA the step uses ACTION at
pin() {
  local uses
  uses=$(job_step "$1" "$2" uses)
  if [[ ! "${uses}" =~ ^lfreleng-actions/$3@([0-9a-f]{40})$ ]]; then
    echo "FAIL: step '$2' of job '$1' does not use $3 at a commit SHA" \
      "(got '${uses}')"
    exit 1
  fi
  echo "${BASH_REMATCH[1]}"
}

detect_pin=$(pin check-release detect docker-release-detect-action)
promote_pin=$(yq -r '.jobs."release-verify".steps[]
  | select(.name == "Verify staged images and release tags") | .uses' \
  "${workflow}")
if [[ ! "${promote_pin}" =~ ^lfreleng-actions/docker-promote-action@([0-9a-f]{40})$ ]]
then
  echo "FAIL: release-verify does not use docker-promote-action at a" \
    "commit SHA (got '${promote_pin}')"
  exit 1
fi
promote_pin="${BASH_REMATCH[1]}"

# expect JOB SELECTOR FIELD VALUE: a field of the selected step
expect() {
  local actual
  actual=$(yq -r ".jobs.\"$1\".steps[] | select($2) | .$3" "${workflow}")
  if [ "${actual}" = "$4" ]; then
    echo "ok: $1: $3"
  else
    fail "$1: $3 is '${actual}', expected '$4'"
  fi
}

# shellcheck disable=SC2016  # literal workflow expressions
{
  detect='.id == "detect"'
  expect check-release "${detect}" with.snapshot_registry \
    '${{ inputs.snapshot_registry }}'
  expect check-release "${detect}" with.release_registry \
    '${{ inputs.release_registry }}'
  promote='.name == "Verify staged images and release tags"'
  expect release-verify "${promote}" with.mode verify
  expect release-verify "${promote}" with.containers_json \
    '${{ needs.check-release.outputs.containers_json }}'
  expect release-verify "${promote}" with.release_tag \
    '${{ needs.check-release.outputs.version }}'
  expect release-verify "${promote}" with.pull_registry \
    '${{ needs.check-release.outputs.pull_registry || inputs.snapshot_registry }}'
  expect release-verify "${promote}" with.push_registry \
    '${{ needs.check-release.outputs.push_registry || inputs.release_registry }}'
  expect release-verify "${promote}" with.namespace \
    '${{ needs.gerrit-validate.outputs.namespace }}'
  expect release-verify "${promote}" with.on_conflict fail
}

# Both checkouts must reach HEAD's parent, or detection fails
for step in 'Checkout Gerrit change' 'Checkout repository'; do
  depth=$(yq -r ".jobs.\"check-release\".steps[]
    | select(.name == \"${step}\") | .with.\"fetch-depth\"" "${workflow}")
  if [ "${depth}" = 2 ]; then
    echo "ok: check-release: '${step}' fetches depth 2"
  else
    fail "check-release: '${step}' fetch-depth is '${depth}', expected 2"
  fi
done

# The credential job reads only check-release's validated outputs
checkouts=$(yq -r '[.jobs."release-verify".steps[].uses // ""
  | select(test("checkout"))] | length' "${workflow}")
if [ "${checkouts}" = 0 ]; then
  echo 'ok: release-verify checks out nothing'
else
  fail "release-verify holds ${checkouts} checkout step(s)"
fi

# --- check-release's registry input step ----------------------------------

job_step check-release registries run > "${work}/registries.sh"
if [ ! -s "${work}/registries.sh" ]; then
  echo "FAIL: no 'registries' step in the check-release job"
  exit 1
fi

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
    echo "ok: registries: $1"
  else
    fail "registries: $1 (exit ${status})"
    sed 's/^/  | /' "${work}/log"
  fi
}

registries_case 'Nexus 3 ports pass' ok \
  nexus3.onap.org:10003 nexus3.onap.org:10002
registries_case 'Artifactory repository paths pass' ok \
  acme.jfrog.io/docker-snapshot acme.jfrog.io/docker-release
registries_case 'a snapshot registry alone fails' error \
  nexus3.onap.org:10003 ''
registries_case 'a release registry alone fails' error \
  '' nexus3.onap.org:10002
registries_case 'a URL scheme fails' error \
  https://nexus3.onap.org:10003 nexus3.onap.org:10002
registries_case 'an uppercase path component fails' error \
  nexus3.onap.org:10003 acme.jfrog.io/Docker

# --- Fetch the pinned actions ---------------------------------------------

# fetch NAME SHA DIR_OVERRIDE: a checkout of the action at SHA
fetch() {
  local dir="${3:-}"
  if [ -n "${dir}" ]; then
    dir=$(cd "${dir}" && pwd)
  else
    dir="${work}/$1"
    git -c init.defaultBranch=main init -q "${dir}"
    git -C "${dir}" fetch -q --depth 1 \
      "https://github.com/lfreleng-actions/$1" "$2"
    git -C "${dir}" checkout -q FETCH_HEAD
  fi
  if [ "$(git -C "${dir}" rev-parse HEAD)" != "$2" ]; then
    echo "FAIL: ${dir} is not at $2, the commit the workflow pins" >&2
    exit 1
  fi
  echo "${dir}"
}

detect_action=$(fetch docker-release-detect-action "${detect_pin}" \
  "${DETECT_ACTION_DIR:-}")
promote_action=$(fetch docker-promote-action "${promote_pin}" \
  "${PROMOTE_ACTION_DIR:-}")

# --- Offline release-file check -------------------------------------------

# Fixture repositories ignore the user's and system's git settings: a
# global commit.gpgSign, a hook template or a default branch name
# would otherwise reach every commit below
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.org
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.org

valid='distribution_type: container
project: example
container_release_tag: 1.2.3
container_pull_registry: nexus3.onap.org:10004
containers:
  - name: base-alpine
    version: 1.2.3-20260101T000000Z
  - name: so/util-echo
    version: "1.2.3-20260101T000000Z"'

# repo NAME: a fresh repository whose target branch holds one commit
repo() {
  local dir="${work}/repos/$1"
  git -c init.defaultBranch=main init -q "${dir}"
  echo base > "${dir}/README"
  git -C "${dir}" add README
  git -C "${dir}" commit -q -m base
  echo "${dir}"
}

# change DIR FILE CONTENT: commit FILE holding CONTENT on top of HEAD,
# as a Gerrit patch set sits on the commit it was written against
change() {
  mkdir -p "$(dirname "$1/$2")"
  printf '%s\n' "$3" > "$1/$2"
  git -C "$1" add "$2"
  git -C "$1" commit -q -m "change $2"
}

# reason LOG: the error a failing case reported, shown so the log
# proves it failed for the reason its description gives; the prefix
# is dropped so the runner raises no annotation for it
reason() {
  sed -n 's/^::error::/  -> /p' "$1"
}

# detect_case DESCRIPTION DIR EXPECTED: run the action on DIR's HEAD
# from a depth-2 clone, as check-release checks it out. EXPECTED is
# the containers_json output as compact JSON, 'none' for no release,
# or 'error' when the step must fail with an annotation.
detect_case() {
  local description="$1" expected="$3" status=0
  local clone="${work}/clone" out="${work}/output" log="${work}/log"
  rm -rf "${clone}"
  git clone -q --depth 2 "file://$2" "${clone}"
  : > "${out}"
  (
    cd "${clone}"
    env -i PATH="${PATH}" HOME="${work}" GITHUB_OUTPUT="${out}" \
      INPUT_SNAPSHOT_REGISTRY='nexus3.onap.org:10003' \
      INPUT_RELEASE_REGISTRY='nexus3.onap.org:10002' \
      INPUT_BASE='' INPUT_PATH='.' INPUT_SUMMARY='false' \
      INPUT_NUMERIC_VERSIONS='literal' \
      python3 -I "${detect_action}/entrypoint.py"
  ) > "${log}" 2>&1 || status=$?
  local has containers
  has=$(output has_release "${out}")
  containers=$(output containers_json "${out}")
  if { [ "${expected}" = error ] && [ "${status}" -ne 0 ] &&
    grep -q '^::error::' "${log}"; } ||
    { [ "${expected}" = none ] && [ "${status}" -eq 0 ] &&
      [ "${has}" = false ]; } ||
    { [ "${expected}" != error ] && [ "${expected}" != none ] &&
      [ "${status}" -eq 0 ] && [ "${has}" = true ] &&
      [ "$(jq -c . <<< "${containers}")" = "${expected}" ]; }; then
    echo "ok: detect: ${description}"
    reason "${log}"
  else
    fail "detect: ${description}: expected ${expected}," \
      "got has_release='${has}' containers_json='${containers}'" \
      "(exit ${status})"
    sed 's/^/  | /' "${log}"
  fi
}

expected_containers='[{"name":"base-alpine","version":"1.2.3-20260101T000000Z"},{"name":"so/util-echo","version":"1.2.3-20260101T000000Z"}]'

dir=$(repo valid)
change "${dir}" releases/1.2.3-container.yaml "${valid}"
detect_case 'a valid release file passes' "${dir}" "${expected_containers}"

dir=$(repo none)
change "${dir}" src/app.txt 'no release here'
detect_case 'a change without a release file releases nothing' \
  "${dir}" none

dir=$(repo maven)
change "${dir}" releases/1.2.3-maven.yaml 'distribution_type: maven
project: example'
detect_case 'a maven release file is left to its own pipeline' \
  "${dir}" none

# A release file already on the target branch is not this change's
dir=$(repo merged)
change "${dir}" releases/1.2.3-container.yaml "${valid}"
change "${dir}" src/app.txt 'a later change'
detect_case 'a release file the target already holds is ignored' \
  "${dir}" none

# A pull request's merge commit: the release file arrives in the
# first of two commits on the pull request branch, and the merge
# commit's first parent is the target branch
dir=$(repo pull-request)
git -C "${dir}" checkout -q -b topic
change "${dir}" releases/1.2.3-container.yaml "${valid}"
change "${dir}" src/app.txt 'a second commit'
git -C "${dir}" checkout -q main
echo moved > "${dir}/README"
git -C "${dir}" commit -q -am 'target branch moves on'
git -C "${dir}" merge -q --no-ff -m 'merge pull request' topic
detect_case 'a pull request merge commit sees every commit' \
  "${dir}" "${expected_containers}"

# malformed DESCRIPTION CONTENT: a change adding CONTENT must fail
malformed() {
  local dir
  malformed_count=$((malformed_count + 1))
  dir=$(repo "malformed-${malformed_count}")
  change "${dir}" releases/1.2.3-container.yaml "$2"
  detect_case "$1" "${dir}" error
}
malformed_count=0

malformed 'invalid YAML fails' 'distribution_type: container
containers: [unclosed'
malformed 'a missing container_release_tag fails' \
  "$(sed '/^container_release_tag/d' <<< "${valid}")"
malformed 'a release tag Docker refuses fails' \
  "${valid/container_release_tag: 1.2.3/container_release_tag: 1.2.3+build}"
malformed 'an empty containers list fails' 'distribution_type: container
container_release_tag: 1.2.3
containers: []'
malformed 'an uppercase container name fails' \
  "${valid/name: base-alpine/name: Base-Alpine}"
malformed 'a duplicate container name fails' \
  "${valid/name: so\/util-echo/name: base-alpine}"
malformed 'a pull override on another host fails' \
  "${valid/nexus3.onap.org:10004/registry.example.org:10004}"
malformed 'a push override with a URL scheme fails' \
  "${valid}
container_push_registry: https://nexus3.onap.org:10002"

dir=$(repo two-files)
change "${dir}" releases/1.2.3-container.yaml "${valid}"
change "${dir}" releases/1.2.4-container.yaml \
  "${valid/container_release_tag: 1.2.3/container_release_tag: 1.2.4}"
git -C "${dir}" reset -q --soft HEAD~2
git -C "${dir}" commit -q -m 'two release files'
detect_case 'two container release files in one change fail' \
  "${dir}" error

# --- Registry checks, against a fake crane ----------------------------------

# crane digest answers from the "<reference> <digest>" lines in
# FAKE_REGISTRY, with real crane's MANIFEST_UNKNOWN for anything else;
# auth login accepts any credential, as crane does. A copy or tag
# would be a write, which verify must never attempt.
mkdir -p "${work}/bin"
cat > "${work}/bin/crane" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "${FAKE_CRANE_LOG}"
case "$1" in
  auth) cat > /dev/null; exit 0 ;;
  digest)
    digest=$(awk -v ref="$2" '$1 == ref { print $2 }' "${FAKE_REGISTRY}")
    if [ -n "${digest}" ]; then echo "${digest}"; exit 0; fi
    echo "Error: fetching manifest $2: GET https://registry/v2/: MANIFEST_UNKNOWN: manifest unknown" >&2
    exit 1
    ;;
  *) echo "Error: unexpected write: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "${work}/bin/crane"

a="sha256:$(printf 'a%.0s' {1..64})"
b="sha256:$(printf 'b%.0s' {1..64})"
pull='nexus3.onap.org:10004/onap'
push='nexus3.onap.org:10002/onap'
staged="${pull}/base-alpine:1.2.3-20260101T000000Z ${a}
${pull}/so/util-echo:1.2.3-20260101T000000Z ${b}"

# verify_case DESCRIPTION EXPECTED REGISTRY: promote in verify mode,
# as release-verify calls it with namespace onap. EXPECTED is the
# statuses of the promoted output, space separated, or 'error'.
verify_case() {
  local status=0 out="${work}/output" log="${work}/log"
  printf '%s\n' "$3" > "${work}/registry"
  : > "${out}"
  : > "${work}/crane.log"
  env -i PATH="${work}/bin:${PATH}" HOME="${work}" \
    GITHUB_OUTPUT="${out}" RUNNER_TEMP="${work}" \
    FAKE_REGISTRY="${work}/registry" FAKE_CRANE_LOG="${work}/crane.log" \
    INPUT_MODE='verify' \
    INPUT_CONTAINERS_JSON="${expected_containers}" \
    INPUT_RELEASE_TAG='1.2.3' \
    INPUT_PULL_REGISTRY='nexus3.onap.org:10004' \
    INPUT_PUSH_REGISTRY='nexus3.onap.org:10002' \
    INPUT_NAMESPACE='onap' INPUT_PUSH_LATEST='false' \
    INPUT_DRY_RUN='false' INPUT_ON_CONFLICT='fail' \
    INPUT_REGISTRY_USER='example' INPUT_REGISTRY_PASSWORD='not-a-secret' \
    INPUT_INSTALL_CRANE='false' INPUT_SUMMARY='false' \
    python3 -I "${promote_action}/entrypoint.py" \
    > "${log}" 2>&1 || status=$?
  local statuses
  statuses=$(output promoted "${out}" | jq -r '[.[].status] | join(" ")' \
    2> /dev/null || true)
  if grep -Eqv '^(auth|digest) ' "${work}/crane.log"; then
    fail "verify: $1: crane was asked to write"
    sed 's/^/  | /' "${work}/crane.log"
  elif { [ "$2" = error ] && [ "${status}" -ne 0 ] &&
    grep -q '^::error::' "${log}"; } ||
    { [ "$2" != error ] && [ "${status}" -eq 0 ] &&
      [ "${statuses}" = "$2" ]; }; then
    echo "ok: verify: $1"
    reason "${log}"
  else
    fail "verify: $1: expected '$2', got '${statuses}' (exit ${status})"
    sed 's/^/  | /' "${log}"
  fi
}

verify_case 'staged images and free release tags pass' 'ready ready' \
  "${staged}"
verify_case 'a missing staged image fails' error \
  "${pull}/base-alpine:1.2.3-20260101T000000Z ${a}"
verify_case 'a release tag holding other bits fails' error \
  "${staged}
${push}/so/util-echo:1.2.3 ${a}"
# global-jjb defect D2 (docs/PARITY.md 6.1): Jenkins aborts a release
# verify on an image released before; the same digest passes here
verify_case 'an image already released passes as skipped' \
  'skipped ready' \
  "${staged}
${push}/base-alpine:1.2.3 ${a}"

if [ "${failures}" -gt 0 ]; then
  echo "${failures} case(s) failed"
  exit 1
fi
echo 'All cases passed'
