#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation

# Regression test for the release container schema check (#155).
# Both lanes' check-release jobs detect a container release file under
# releases/ or .releases/ with docker-release-detect-action, then run
# verify-release-schema-action, Jenkins' lftools schema verify, on the
# file detection reports. The test runs the shipped pieces rather than
# copies of them:
#
# - the wiring, read from build-test.yaml and merge.yaml: the schema
#   step at a commit SHA, after detection, only when it found a file,
#   on its release_file output, with lftools-uv pinned; no other path
#   to a release directory in the job; and the job after it gated on
#   check-release passing, since a failed job still exports the
#   has_release its detection set
# - docker-release-detect-action at its pinned commit, then the schema
#   action's bundled container schema at its pinned commit through
#   lftools-uv at the pinned version, against git histories holding a
#   valid .releases/ file, files detection accepts and the schema
#   rejects, and a change adding a file in each directory
#
# Usage: bash tests/test_release_schema.sh
# DETECT_ACTION_DIR and SCHEMA_ACTION_DIR may name local clones of the
# actions checked out at the pinned commits, to run without fetching
# them; lftools-uv still comes from PyPI.
# Needs bash, git, python3 (3.10 or later), mikefarah yq v4.25.3 or
# later (the detect action refuses the Python yq) and uv.

set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

work=$(mktemp -d)
trap 'rm -rf "${work}"' EXIT

failures=0

fail() {
  echo "FAIL: $*"
  failures=$((failures + 1))
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

# The job each lane runs once check-release has found a file
declare -A consumer=([build-test]=release-verify [merge]=release-publish)

schema_pins=()
detect_pins=()
lftools_versions=()

# step WORKFLOW ID FIELD: one field of check-release's step with that id
step() {
  yq -r ".jobs.\"check-release\".steps[] | select(.id == \"$2\") | .$3" "$1"
}

for lane in build-test merge; do
  workflow="${root}/.github/workflows/${lane}.yaml"

  uses=$(step "${workflow}" schema uses)
  if [[ "${uses}" =~ ^lfreleng-actions/verify-release-schema-action@([0-9a-f]{40})$ ]]
  then
    schema_pins+=("${BASH_REMATCH[1]}")
    echo "ok: ${lane}: schema step uses verify-release-schema-action at a SHA"
  else
    echo "FAIL: ${lane}: check-release has no 'schema' step using" \
      "verify-release-schema-action at a commit SHA (got '${uses}')"
    exit 1
  fi
  uses=$(step "${workflow}" detect uses)
  if [[ "${uses}" =~ ^lfreleng-actions/docker-release-detect-action@([0-9a-f]{40})$ ]]
  then
    detect_pins+=("${BASH_REMATCH[1]}")
  else
    echo "FAIL: ${lane}: check-release's 'detect' step does not use" \
      "docker-release-detect-action at a commit SHA (got '${uses}')"
    exit 1
  fi

  # expect FIELD VALUE: a field of the schema step
  expect() {
    local actual
    actual=$(step "${workflow}" schema "$1")
    if [ "${actual}" = "$2" ]; then
      echo "ok: ${lane}: schema step $1"
    else
      fail "${lane}: schema step $1 is '${actual}', expected '$2'"
    fi
  }
  # shellcheck disable=SC2016  # literal workflow expressions
  {
    expect if "steps.detect.outputs.has_release == 'true'"
    expect with.distribution-type container
    expect with.release-file '${{ steps.detect.outputs.release_file }}'
  }

  version=$(step "${workflow}" schema 'with."lftools-uv-version"')
  if [[ "${version}" =~ ^[0-9]+(\.[0-9]+)+$ ]]; then
    lftools_versions+=("${version}")
    echo "ok: ${lane}: lftools-uv pinned to ${version}"
  else
    fail "${lane}: lftools-uv-version is '${version}', expected an" \
      "exact version"
  fi

  # Detection's untrusted-input guards run before any other tool reads
  # the file
  # shellcheck disable=SC2016  # a yq variable, not a shell one
  order=$(yq -r '[.jobs."check-release".steps[].id // ""]
    | (to_entries | map(select(.value == "detect")) | .[0].key) as $d
    | (to_entries | map(select(.value == "schema")) | .[0].key) as $s
    | $s > $d' "${workflow}")
  if [ "${order}" = true ]; then
    echo "ok: ${lane}: schema step follows detection"
  else
    fail "${lane}: schema step does not follow detection"
  fi

  # Only detection decides which file is checked: no step names a
  # release directory itself. JSON output drops the YAML comments.
  if yq -o json '.jobs."check-release".steps' "${workflow}" |
    grep -q 'releases/'; then
    fail "${lane}: a check-release step names a release directory"
  else
    echo "ok: ${lane}: no check-release step names a release directory"
  fi

  gate=$(yq -r ".jobs.\"${consumer[${lane}]}\".if" "${workflow}")
  if [[ "${gate}" == *"needs.check-release.result == 'success'"* ]]; then
    echo "ok: ${lane}: ${consumer[${lane}]} requires check-release to pass"
  else
    fail "${lane}: ${consumer[${lane}]} runs on '${gate}', which does" \
      "not require check-release to pass"
  fi
done

# same NAME VALUES...: the lanes agree, so verify predicts merge
same() {
  local name="$1"
  shift
  if [ "$1" = "$2" ]; then
    echo "ok: both lanes pin the same ${name}"
  else
    fail "the lanes pin different ${name}s: '$1' and '$2'"
  fi
}
same verify-release-schema-action "${schema_pins[@]}"
same docker-release-detect-action "${detect_pins[@]}"
same lftools-uv-version "${lftools_versions[@]}"

if [ "${failures}" -gt 0 ]; then
  echo "${failures} case(s) failed"
  exit 1
fi

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
    echo "FAIL: ${dir} is not at $2, the commit the workflows pin" >&2
    exit 1
  fi
  echo "${dir}"
}

detect_action=$(fetch docker-release-detect-action "${detect_pins[0]}" \
  "${DETECT_ACTION_DIR:-}")
schema_action=$(fetch verify-release-schema-action "${schema_pins[0]}" \
  "${SCHEMA_ACTION_DIR:-}")
schema="${schema_action}/schemas/release-container-schema.yaml"
lftools="lftools-uv==${lftools_versions[0]}"

# --- Detection, then the schema -------------------------------------------

# Fixture repositories ignore the user's and system's git settings: a
# global commit.gpgSign, a hook template or a default branch name
# would otherwise reach every commit below
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.org
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.org

ref=0123456789abcdef0123456789abcdef01234567
valid="distribution_type: container
project: example
container_release_tag: 1.2.3
ref: ${ref}
container_pull_registry: nexus3.onap.org:10004
containers:
  - name: base-alpine
    version: 1.2.3-20260101T000000Z
  - name: so/util-echo
    version: '1.2.3-20260101T000000Z'"

# repo NAME: a fresh repository whose target branch holds one commit
repo() {
  local dir="${work}/repos/$1"
  git -c init.defaultBranch=main init -q "${dir}"
  echo base > "${dir}/README"
  git -C "${dir}" add README
  git -C "${dir}" commit -q -m base
  echo "${dir}"
}

# add DIR FILE CONTENT: write FILE holding CONTENT and stage it
add() {
  mkdir -p "$(dirname "$1/$2")"
  printf '%s\n' "$3" > "$1/$2"
  git -C "$1" add "$2"
}

# change DIR FILE CONTENT: commit FILE holding CONTENT on top of HEAD,
# as a Gerrit patch set sits on the commit it was written against
change() {
  add "$@"
  git -C "$1" commit -q -m "change $2"
}

# release_case DESCRIPTION DIR EXPECTED [FILE MESSAGE]: run detection
# on DIR's HEAD from a depth-2 clone, as check-release checks it out,
# then the schema step's check on the file detection reports, as the
# step runs it. EXPECTED is 'pass' (detection reports FILE and the
# schema accepts it), 'schema' (detection reports FILE and the schema
# rejects it with a line matching MESSAGE) or 'detect' (detection
# fails with an annotation, so the schema never runs).
release_case() {
  local description="$1" expected="$3" file="${4:-}" message="${5:-}"
  local clone="${work}/clone" out="${work}/output" log="${work}/log"
  local status=0 has release_file
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
  has=$(output has_release "${out}")
  release_file=$(output release_file "${out}")

  if [ "${expected}" = detect ]; then
    if [ "${status}" -ne 0 ] && grep -q '^::error::' "${log}"; then
      echo "ok: ${description}"
      sed -n 's/^::error::/  -> /p' "${log}"
    else
      fail "${description}: expected detection to fail, got" \
        "has_release='${has}' (exit ${status})"
      sed 's/^/  | /' "${log}"
    fi
    return
  fi
  if [ "${status}" -ne 0 ] || [ "${has}" != true ] ||
    [ "${release_file}" != "${file}" ]; then
    fail "${description}: expected detection to report '${file}', got" \
      "has_release='${has}' release_file='${release_file}'" \
      "(exit ${status})"
    sed 's/^/  | /' "${log}"
    return
  fi

  status=0
  (
    cd "${clone}"
    uv tool run --quiet --no-config --from "${lftools}" \
      lftools-uv schema verify "${release_file}" "${schema}"
  ) > "${log}" 2>&1 || status=$?
  if { [ "${expected}" = pass ] && [ "${status}" -eq 0 ]; } ||
    { [ "${expected}" = schema ] && [ "${status}" -ne 0 ] &&
      grep -Eq -- "${message}" "${log}"; }; then
    echo "ok: ${description}"
    if [ "${expected}" = schema ]; then
      grep -E -- "${message}" "${log}" | head -n 1 | sed 's/^/  -> /'
    fi
  else
    fail "${description}: expected the schema check to ${expected}" \
      "(exit ${status})"
    sed 's/^/  | /' "${log}"
  fi
}

dir=$(repo dot-releases)
change "${dir}" .releases/container-release-capif.yaml "${valid}"
release_case 'a valid .releases/ file is detected and passes the schema' \
  "${dir}" pass .releases/container-release-capif.yaml

dir=$(repo releases)
change "${dir}" releases/1.2.3-container.yaml "${valid}"
release_case 'a valid releases/ file is detected and passes the schema' \
  "${dir}" pass releases/1.2.3-container.yaml

# schema_case DESCRIPTION FILE CONTENT MESSAGE: detection accepts a
# change adding CONTENT at FILE, and the schema rejects it
schema_case() {
  local dir
  schema_count=$((schema_count + 1))
  dir=$(repo "schema-${schema_count}")
  change "${dir}" "$2" "$3"
  release_case "$1" "${dir}" schema "$2" "$4"
}
schema_count=0

schema_case 'a file without ref passes detection and fails the schema' \
  releases/1.2.3-container.yaml "$(sed '/^ref:/d' <<< "${valid}")" \
  "'ref' is a required property"
schema_case 'a .releases/ file without project fails the schema' \
  .releases/container-release-app.yaml \
  "$(sed '/^project:/d' <<< "${valid}")" \
  "'project' is a required property"
schema_case 'an empty ref fails the schema' \
  releases/1.2.3-container.yaml "${valid/ref: ${ref}/ref:}" \
  "None is not of type 'string'"
schema_case 'an unquoted numeric release tag fails the schema' \
  releases/1.10-container.yaml \
  "${valid/container_release_tag: 1.2.3/container_release_tag: 1.10}" \
  "is not of type 'string'"

# One container release file per change, across both directories
dir=$(repo both-directories)
add "${dir}" releases/1.2.3-container.yaml "${valid}"
add "${dir}" .releases/container-release-capif.yaml \
  "${valid/container_release_tag: 1.2.3/container_release_tag: 1.2.4}"
git -C "${dir}" commit -q -m 'a release file in each directory'
release_case 'a release file in each directory fails detection' \
  "${dir}" detect

if [ "${failures}" -gt 0 ]; then
  echo "${failures} case(s) failed"
  exit 1
fi
echo 'All cases passed'
