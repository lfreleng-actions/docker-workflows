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
#   tags and repositories inputs, the registry input's login, and a
#   dry run's plan
# - the gerrit-validate job's check of the registry input
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

# run_script [NAME=VALUE...]: run ${work}/step.sh as GitHub runs a
# 'shell: bash' step, in an environment holding only NAME=VALUE; its
# outputs land in ${work}/output, its step summary in ${work}/summary,
# its log in ${work}/log
run_script() {
  : > "${work}/output"
  : > "${work}/summary"
  env -i PATH="${PATH}" HOME="${work}" GITHUB_OUTPUT="${work}/output" \
    GITHUB_STEP_SUMMARY="${work}/summary" "$@" \
    bash --noprofile --norc -eo pipefail "${work}/step.sh" \
    > "${work}/log" 2>&1
}

# run_step ID [NAME=VALUE...]: run the build job step with that id
run_step() {
  local id="$1"
  shift
  build_step "${id}" run > "${work}/step.sh"
  if [ ! -s "${work}/step.sh" ]; then
    echo "FAIL: no '${id}' step script in the build job of ${workflow}"
    exit 1
  fi
  run_script "$@"
}

# check_run DESCRIPTION STATUS CHECK...: judge the last run_script.
# Each CHECK is 'error' (the step fails with an ::error::), KEY=VALUE
# (the step output KEY is VALUE), 'log:TEXT' or 'summary:TEXT' (the
# log or step summary contains TEXT). Without 'error' the step must
# succeed.
check_run() {
  local description="$1" status="$2" check key want got problems=''
  local want_error='false'
  shift 2
  for check in "$@"; do
    case "${check}" in
      error)
        want_error='true'
        if [ "${status}" -eq 0 ] ||
          ! grep -q '^::error::' "${work}/log"; then
          problems+="; expected an ::error:: failure"
        fi
        ;;
      log:* | summary:*)
        if ! grep -qF -- "${check#*:}" "${work}/${check%%:*}"; then
          problems+="; ${check%%:*} lacks '${check#*:}'"
        fi
        ;;
      *=*)
        key="${check%%=*}"
        want="${check#*=}"
        got=$(output "${key}" "${work}/output")
        if [ "${got}" != "${want}" ]; then
          problems+="; ${key}: expected '${want}', got '${got}'"
        fi
        ;;
    esac
  done
  if [ "${want_error}" = 'false' ] && [ "${status}" -ne 0 ]; then
    problems+="; exit ${status}"
  fi
  if [ -z "${problems}" ]; then
    echo "ok: ${description}"
  else
    fail "${description}${problems}"
    sed 's/^/  | /' "${work}/log"
  fi
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

# registries_case DESCRIPTION [NAME=VALUE...] -- CHECK...: run the
# registries step with NAME=VALUE over a baseline that requests no
# registry, then judge it as check_run does
registries_case() {
  local description="$1" status=0
  shift
  local -a env=(
    GHCR_PUBLISH=false DOCKERHUB_PUBLISH=false HAS_DOCKERHUB_CREDS=false
    REGISTRY='' REGISTRY_USER_INPUT='' HAS_REGISTRY_CREDS=false
    TARGET_REPOSITORY=ProbeOrg/probe-repo IMAGE_NAMESPACE=probeorg
    OWNER=ProbeOrg DRY_RUN=false VERSION=1.2.3
    IMAGES_JSON='[{"name": "probe"}, {"name": "probe-tools"}]'
  )
  while [ "$1" != '--' ]; do
    env+=("$1")
    shift
  done
  shift
  run_step registries "${env[@]}" || status=$?
  check_run "${description}" "${status}" "$@"
}

nexus='nexus3.onap.org:10002'
with_nexus=(REGISTRY="${nexus}" HAS_REGISTRY_CREDS=true)
no_registry=(registry=false registry_login='' registry_user=''
  credential_name='')

registries_case 'GHCR pushes under the lowercased owner' \
  GHCR_PUBLISH=true -- \
  repositories=ghcr.io/probeorg ghcr=true dockerhub=false \
  "${no_registry[@]}"
registries_case 'GHCR first, then Docker Hub' \
  GHCR_PUBLISH=true DOCKERHUB_PUBLISH=true HAS_DOCKERHUB_CREDS=true -- \
  repositories=ghcr.io/probeorg,docker.io/probeorg dockerhub=true
registries_case 'Docker Hub without credentials resolves nothing' \
  DOCKERHUB_PUBLISH=true -- \
  repositories='' dockerhub=false \
  'log:::warning::DOCKERHUB_USERNAME/DOCKERHUB_PASSWORD unavailable'
registries_case 'the registry input publishes after GHCR and Docker Hub' \
  GHCR_PUBLISH=true DOCKERHUB_PUBLISH=true HAS_DOCKERHUB_CREDS=true \
  "${with_nexus[@]}" -- \
  "repositories=ghcr.io/probeorg,docker.io/probeorg,${nexus}/probeorg" \
  registry=true "registry_login=${nexus}" registry_user=probe-repo \
  credential_name=probe-repo
registries_case 'a path-bearing registry logs in to its host' \
  "${with_nexus[@]}" REGISTRY=acme.jfrog.io/docker-release -- \
  repositories=acme.jfrog.io/docker-release/probeorg registry=true \
  registry_login=acme.jfrog.io
registries_case "namespace_mode 'none' pushes under the registry alone" \
  "${with_nexus[@]}" IMAGE_NAMESPACE='' -- \
  "repositories=${nexus}" registry=true
registries_case 'registry_user overrides the username only' \
  "${with_nexus[@]}" REGISTRY_USER_INPUT=svc-ci@example.org -- \
  registry_user=svc-ci@example.org credential_name=probe-repo
registries_case 'an invalid registry username fails' \
  "${with_nexus[@]}" REGISTRY_USER_INPUT='svc ci' -- error
registries_case 'the registry input skips without credentials' \
  GHCR_PUBLISH=true "${with_nexus[@]}" HAS_REGISTRY_CREDS=false -- \
  repositories=ghcr.io/probeorg "${no_registry[@]}" \
  "log:::warning::OP_SERVICE_ACCOUNT_TOKEN/VAULT_MAPPING_JSON unavailable"
registries_case 'a dry run resolves no repository' \
  GHCR_PUBLISH=true DOCKERHUB_PUBLISH=true HAS_DOCKERHUB_CREDS=true \
  DRY_RUN=true -- \
  repositories='' ghcr=false dockerhub=false
registries_case 'a dry run reports the plan for every requested registry' \
  GHCR_PUBLISH=true "${with_nexus[@]}" HAS_REGISTRY_CREDS=false \
  DRY_RUN=true -- \
  repositories='' "${no_registry[@]}" \
  'log:Dry run: would log in to ghcr.io with GITHUB_TOKEN' \
  'log:Dry run: would push ghcr.io/probeorg/probe:1.2.3' \
  "log:Dry run: would log in to ${nexus} as probe-repo" \
  "log:Dry run: would push ${nexus}/probeorg/probe:1.2.3" \
  "log:Dry run: would push ${nexus}/probeorg/probe-tools:1.2.3" \
  'log:OP_SERVICE_ACCOUNT_TOKEN/VAULT_MAPPING_JSON unavailable' \
  "log:a real run would skip ${nexus} with a warning" \
  'summary:## Registry plan (dry run)' \
  "summary:- Dry run: would push ${nexus}/probeorg/probe:1.2.3"
# The plan output carries the same lines, one array element each
if output plan "${work}/output" | jq -e --arg nexus "${nexus}" '
    length == 7 and
    index("Dry run: would push \($nexus)/probeorg/probe-tools:1.2.3")
    != null' > /dev/null; then
  echo 'ok: the plan output lists every plan line'
else
  fail "the plan output lists every plan line: $(output plan "${work}/output")"
fi
registries_case 'a real run reports no plan' \
  GHCR_PUBLISH=true -- plan=''

# validate_case DESCRIPTION REGISTRY REGISTRY_USER CHECK...: run the
# gerrit-validate job's registry input check
validate_case() {
  local description="$1" status=0
  yq -r '.jobs."gerrit-validate".steps[]
    | select(.name == "Validate registry inputs") | .run' \
    "${workflow}" > "${work}/step.sh"
  if [ ! -s "${work}/step.sh" ]; then
    echo "FAIL: no 'Validate registry inputs' step in ${workflow}"
    exit 1
  fi
  run_script REGISTRY="$2" REGISTRY_USER="$3" || status=$?
  shift 3
  check_run "${description}" "${status}" "$@"
}

validate_case 'no registry input passes' '' ''
validate_case 'registry_user without registry fails' '' svc-ci error
validate_case 'a port-addressed registry passes' "${nexus}" ''
validate_case 'a path-bearing registry passes' \
  acme.jfrog.io/docker-release svc-ci@example.org
validate_case 'a scheme fails' "https://${nexus}" '' error
validate_case 'an uppercase path component fails' \
  acme.jfrog.io/Docker-Release '' error
validate_case 'a trailing slash fails' "${nexus}/" '' error
validate_case 'an empty host label fails' 'nexus3..onap.org:10002' '' error
validate_case "a lone '.' fails" '.' '' error
label63=$(printf 'a%.0s' {1..63})
validate_case 'a 63-character host label passes' "${label63}.example:5000" ''
validate_case 'a 64-character host label fails' \
  "${label63}a.example:5000" '' error
validate_case 'a dotless host without a port fails' registry/team '' error
validate_case 'a dotless host with a port passes' registry:5000 ''
validate_case 'localhost passes' localhost/team ''
validate_case 'GHCR is refused' ghcr.io/probeorg '' error
validate_case 'Docker Hub is refused, case and port aside' \
  Docker.IO:443 '' error

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

digest_case 'a port-addressed registry matches exactly' \
  probe probeorg nexus3.onap.org:10002/probeorg \
  "probeorg/probe@${b}
nexus3.onap.org:10002/probeorg/probe@${a}" \
  "$(pushed probe nexus3.onap.org:10002/probeorg/probe "${a}")"

digest_case "the registry input resolves under namespace_mode 'none'" \
  probe '' nexus3.onap.org:10002 \
  "nexus3.onap.org:10002/probe@${a}" \
  "$(pushed probe nexus3.onap.org:10002/probe "${a}")"

digest_case 'GHCR, Docker Hub and the registry input resolve apart' \
  probe probeorg \
  ghcr.io/probeorg,docker.io/probeorg,nexus3.onap.org:10002/probeorg \
  "ghcr.io/probeorg/probe@${c}
probeorg/probe@${a}
nexus3.onap.org:10002/probeorg/probe@${b}" \
  "$(pushed probe ghcr.io/probeorg/probe "${c}" \
    probe docker.io/probeorg/probe "${a}" \
    probe nexus3.onap.org:10002/probeorg/probe "${b}")"

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
