#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation

# Regression test for the release lane's digest resolution (#96) and
# the wiring that feeds it. Docker reports RepoDigests in familiar form
# (probeorg/probe@..., not docker.io/probeorg/probe@...), so an exact
# match against the docker.io/ repository never resolved a Docker Hub
# push.
#
# The lane builds and pushes through docker-build-images-action, so the
# test runs the shipped pieces rather than copies of them, against a
# fake docker on PATH:
#
# - the build job's 'version' and 'registries' step scripts, extracted
#   from the workflow and run as GitHub runs a 'shell: bash' step; they
#   turn the release tag and the publish switches into the action's
#   tags and repositories inputs
# - the action itself, fetched at the commit the workflow pins and run
#   as its build step runs it, which resolves each pushed repository's
#   digest from RepoDigests
#
# Usage: tests/test_release_digest.sh [workflow-file]
# BUILD_IMAGES_ACTION_DIR may name a local clone of the action checked
# out at the pinned commit, to run without fetching it.
# Needs bash, git, jq, python3 (3.10 or later) and yq (either the Go or
# the Python implementation).

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

# build_step ID FIELD: one field of the build job step with that id
build_step() {
  yq -r ".jobs.build.steps[] | select(.id == \"$1\") | .$2" "${workflow}"
}

# output KEY FILE: a step output, written plainly or in heredoc form
output() {
  awk -v key="$1" '
    delim != "" { if ($0 == delim) exit; print; next }
    index($0, key "<<") == 1 { delim = substr($0, length(key) + 3); next }
    index($0, key "=") == 1 { print substr($0, length(key) + 2); exit }
  ' "$2"
}

# --- The build step's wiring -------------------------------------------

uses=$(build_step build uses)
pattern='^lfreleng-actions/docker-build-images-action@([0-9a-f]{40})$'
if [[ ! "${uses}" =~ ${pattern} ]]; then
  echo "FAIL: the build step of ${workflow} does not use"
  echo "  docker-build-images-action at a commit SHA (got '${uses}')"
  exit 1
fi
pin="${BASH_REMATCH[1]}"

# expect_input NAME VALUE: the build step passes VALUE as input NAME
expect_input() {
  local actual
  actual=$(build_step build "with.$1")
  if [ "${actual}" = "$2" ]; then
    echo "ok: build step input $1"
  else
    fail "build step input $1 is '${actual}', expected '$2'"
  fi
}

expect_input mode push
# shellcheck disable=SC2016  # literal workflow expressions
expect_input repositories '${{ steps.registries.outputs.repositories }}'
# shellcheck disable=SC2016
expect_input tags '${{ steps.version.outputs.version }}'
# shellcheck disable=SC2016
expect_input platforms '${{ inputs.platforms }}'

# --- The lane's own step scripts ---------------------------------------

# run_step ID [NAME=VALUE...]: run the build job step with that id as a
# 'shell: bash' step, in an environment holding only NAME=VALUE; its
# outputs land in ${work}/output, its log in ${work}/log
run_step() {
  local id="$1"
  shift
  build_step "${id}" run > "${work}/step.sh"
  if [ ! -s "${work}/step.sh" ]; then
    echo "FAIL: no '${id}' step script in the build job of ${workflow}"
    exit 1
  fi
  : > "${work}/output"
  env -i PATH="${PATH}" HOME="${work}" GITHUB_OUTPUT="${work}/output" "$@" \
    bash --noprofile --norc -eo pipefail "${work}/step.sh" \
    > "${work}/log" 2>&1
}

# version_case DESCRIPTION TAG EXPECTED ('error' when the step must fail)
version_case() {
  local status=0 actual
  run_step version TAG="$2" || status=$?
  actual=$(output version "${work}/output")
  if [ "$3" = 'error' ] && [ "${status}" -ne 0 ] &&
    grep -q '^::error::' "${work}/log"; then
    echo "ok: $1"
  elif [ "$3" != 'error' ] && [ "${status}" -eq 0 ] &&
    [ "${actual}" = "$3" ]; then
    echo "ok: $1"
  else
    fail "$1: expected '$3', got '${actual}' (exit ${status})"
    sed 's/^/  | /' "${work}/log"
  fi
}

version_case 'the v prefix strips' v1.2.3 1.2.3
version_case 'build metadata maps + to _' v1.2.3+build.5 1.2.3_build.5
version_case 'a tag without the v prefix fails' 1.2.3 error

# registries_case DESCRIPTION GHCR DOCKERHUB CREDS DRY_RUN EXPECTED
registries_case() {
  local status=0 actual
  run_step registries \
    GHCR_PUBLISH="$2" DOCKERHUB_PUBLISH="$3" HAS_DOCKERHUB_CREDS="$4" \
    DRY_RUN="$5" IMAGE_NAMESPACE=probeorg OWNER=ProbeOrg || status=$?
  actual=$(output repositories "${work}/output")
  if [ "${status}" -eq 0 ] && [ "${actual}" = "$6" ]; then
    echo "ok: $1"
  else
    fail "$1: expected '$6', got '${actual}' (exit ${status})"
    sed 's/^/  | /' "${work}/log"
  fi
}

registries_case 'GHCR pushes under the lowercased owner' \
  true false false false ghcr.io/probeorg
registries_case 'GHCR first, then Docker Hub' \
  true true true false ghcr.io/probeorg,docker.io/probeorg
registries_case 'Docker Hub without credentials resolves nothing' \
  false true false false ''
registries_case 'a dry run resolves no repository' \
  true true true true ''

# --- The pinned action ---------------------------------------------------

if [ -n "${BUILD_IMAGES_ACTION_DIR:-}" ]; then
  action=$(cd "${BUILD_IMAGES_ACTION_DIR}" && pwd)
else
  action="${work}/action"
  git -c init.defaultBranch=main init -q "${action}"
  git -C "${action}" fetch -q --depth 1 \
    https://github.com/lfreleng-actions/docker-build-images-action "${pin}"
  git -C "${action}" checkout -q FETCH_HEAD
fi
head=$(git -C "${action}" rev-parse HEAD)
if [ "${head}" != "${pin}" ]; then
  echo "FAIL: ${action} is at ${head}, but the workflow pins ${pin}"
  exit 1
fi

mkdir -p "${work}/bin" "${work}/src"
# Build, push and tag succeed silently; image inspect prints the
# RepoDigests the case supplies, as the daemon would after a push.
cat > "${work}/bin/docker" <<'EOF'
#!/usr/bin/env bash
if [ "$1 $2" = 'image inspect' ]; then
  printf '%s' "${FAKE_REPO_DIGESTS}"
fi
exit 0
EOF
chmod +x "${work}/bin/docker"

a="sha256:$(printf 'a%.0s' {1..64})"
b="sha256:$(printf 'b%.0s' {1..64})"
c="sha256:$(printf 'c%.0s' {1..64})"

# digest_case DESCRIPTION NAME NAMESPACE REPOSITORIES REPO_DIGESTS EXPECTED
#
# REPOSITORIES is the action's repositories input, as the registries
# step resolves it. EXPECTED is the action's 'pushed' output as compact
# JSON, or 'error' when digest resolution must fail the step.
digest_case() {
  local description="$1" name="$2" namespace="$3" repositories="$4"
  local digests="$5" expected="$6"
  local out="${work}/output" log="${work}/log"
  : > "${out}"
  local status=0
  # DOCKER_DEFAULT_PLATFORM fixes the native platform, so the default
  # linux/amd64 is a single-platform build on any host
  (
    cd "${work}"
    env -i \
      PATH="${work}/bin:${PATH}" \
      HOME="${work}" \
      DOCKER_DEFAULT_PLATFORM='linux/amd64' \
      FAKE_REPO_DIGESTS="${digests}" \
      INPUT_MODE='push' \
      INPUT_IMAGES="[{\"name\": \"${name}\", \"context\": \"${name}\"}]" \
      INPUT_PATH_PREFIX='src' \
      INPUT_IMAGE_NAMESPACE="${namespace}" \
      INPUT_REPOSITORIES="${repositories}" \
      INPUT_TAGS='1.2.3' \
      INPUT_PLATFORMS='linux/amd64' \
      INPUT_SUMMARY='false' \
      GITHUB_OUTPUT="${out}" \
      python3 -I "${action}/entrypoint.py"
  ) > "${log}" 2>&1 || status=$?

  local actual
  if [ "${expected}" = 'error' ]; then
    if [ "${status}" -ne 0 ] &&
      grep -q '^::error::Failed to resolve digest for' "${log}"; then
      echo "ok: ${description}"
      return
    fi
    actual="exit ${status}"
  else
    actual=$(output pushed "${out}")
    if [ "${status}" -eq 0 ] &&
      [ "$(jq -c . <<< "${actual}")" = "$(jq -c . <<< "${expected}")" ]; then
      echo "ok: ${description}"
      return
    fi
  fi
  fail "${description}"
  echo "  expected: ${expected}"
  echo "  actual:   ${actual:-<none>} (exit ${status})"
  sed 's/^/  | /' "${log}"
}

pushed() {
  jq -cn --args '[$ARGS.positional as $p
    | range(0; $p | length; 3)
    | {name: $p[.], image: $p[. + 1], digest: $p[. + 2]}]' "$@"
}

digest_case 'Docker Hub push resolves its familiar-form digest' \
  probe probeorg docker.io/probeorg \
  "probeorg/probe@${a}" \
  "$(pushed probe docker.io/probeorg/probe "${a}")"

digest_case 'official image resolves without library/' \
  alpine library docker.io/library \
  "alpine@${a}" \
  "$(pushed alpine docker.io/library/alpine "${a}")"

# The registries step admits only a single-component Docker Hub
# namespace, so this case feeds the action directly: library/ drops
# from a single-component name only.
digest_case 'library/ stays on a multi-component name' \
  probe library/team docker.io/library/team \
  "team/probe@${b}
library/team/probe@${a}" \
  "$(pushed probe docker.io/library/team/probe "${a}")"

digest_case 'a fully qualified entry still matches' \
  probe probeorg docker.io/probeorg \
  "docker.io/probeorg/probe@${a}" \
  "$(pushed probe docker.io/probeorg/probe "${a}")"

digest_case 'GHCR matches exactly, ignoring a Docker Hub entry' \
  probe probeorg ghcr.io/probeorg \
  "probeorg/probe@${b}
ghcr.io/probeorg/probe@${a}" \
  "$(pushed probe ghcr.io/probeorg/probe "${a}")"

digest_case 'each registry resolves its own digest' \
  probe probeorg ghcr.io/probeorg,docker.io/probeorg \
  "ghcr.io/probeorg/probe@${c}
probeorg/probe@${a}" \
  "$(pushed probe ghcr.io/probeorg/probe "${c}" \
    probe docker.io/probeorg/probe "${a}")"

digest_case 'no entry for the repository fails the step' \
  probe probeorg docker.io/probeorg \
  "otherorg/probe@${a}
probeorg/probe-extra@${a}
docker.io:5000/probeorg/probe@${a}
ghcr.io/probeorg/probe@${a}" \
  error

if [ "${failures}" -gt 0 ]; then
  echo "${failures} case(s) failed"
  exit 1
fi
echo 'All cases passed'
