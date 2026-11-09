#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation

# Regression test for namespace_mode resolution and its use by the
# merge lane's snapshot publish and promotion. Each lane resolves
# the image namespace once, in its gerrit-validate job, and every job
# that names an image reads that job's 'namespace' output. The test
# extracts that step script from each lane and runs it as GitHub runs
# a 'shell: bash' step, checking the resolved value and that invalid
# combinations fail with an ::error:: annotation. Promotion runs
# docker-promote-action at the commit merge.yaml pins.
#
# Usage: tests/test_namespace_mode.sh
# PROMOTE_ACTION_DIR may name a local clone of docker-promote-action
# checked out at the pinned commit, to run without fetching it.
# Needs bash, git, python3 (3.10 or later) and yq (either the Go or
# the Python implementation).

set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

work=$(mktemp -d)
trap 'rm -rf "${work}"' EXIT

failures=0

# resolve_case DESCRIPTION EXPECTED MODE NAMESPACE REPOSITORY [DOCKERHUB]
# EXPECTED is the resolved namespace, or 'error' when the step must fail
resolve_case() {
  local status=0 actual
  : > "${work}/output"
  env -i PATH="${PATH}" HOME="${work}" GITHUB_OUTPUT="${work}/output" \
    NAMESPACE_MODE="$3" NAMESPACE="$4" REPOSITORY="$5" \
    DOCKERHUB_PUBLISH="${6:-false}" \
    bash --noprofile --norc -eo pipefail "${work}/step.sh" \
    > "${work}/log" 2>&1 || status=$?
  actual=$(sed -n 's/^namespace=//p' "${work}/output")
  if [ "$2" = 'error' ] && [ "${status}" -ne 0 ] &&
    grep -q '^::error::' "${work}/log"; then
    echo "ok: ${lane}: $1"
  elif [ "$2" != 'error' ] && [ "${status}" -eq 0 ] &&
    [ "${actual}" = "$2" ]; then
    echo "ok: ${lane}: $1"
  else
    echo "FAIL: ${lane}: $1: expected '$2', got '${actual}' (exit ${status})"
    sed 's/^/  | /' "${work}/log"
    failures=$((failures + 1))
  fi
}

for lane in build-test merge build-test-release; do
  workflow="${root}/.github/workflows/${lane}.yaml"
  yq -r '.jobs."gerrit-validate".steps[] | select(.id == "namespace") | .run' \
    "${workflow}" > "${work}/step.sh"
  if [ ! -s "${work}/step.sh" ]; then
    echo "FAIL: no 'namespace' step in the gerrit-validate job of ${lane}"
    failures=$((failures + 1))
    continue
  fi
  resolve_case 'none resolves no namespace' '' none '' Org/repo
  resolve_case 'auto lowercases the repository owner' \
    'onap-team' auto '' ONAP-Team/repo
  resolve_case 'manual takes the namespace input' onap manual onap Org/repo
  resolve_case 'manual takes a sub-path' 'onap/so' manual 'onap/so' Org/repo
  resolve_case 'an unknown mode fails' error Auto '' Org/repo
  resolve_case 'manual without a namespace fails' error manual '' Org/repo
  resolve_case 'a namespace with mode none fails' error none onap Org/repo
  resolve_case 'a namespace with mode auto fails' error auto onap Org/repo
  resolve_case 'an uppercase namespace fails' error manual ONAP Org/repo
  resolve_case 'a leading separator fails' error manual '-team' Org/repo
  resolve_case 'a trailing slash fails' error manual 'onap/' Org/repo
  resolve_case 'an empty component fails' error manual 'a//b' Org/repo
  if [ "${lane}" = 'build-test-release' ]; then
    resolve_case 'Docker Hub with mode none fails' \
      error none '' Org/repo true
    resolve_case 'Docker Hub with a sub-path fails' \
      error manual 'onap/so' Org/repo true
    resolve_case 'Docker Hub with mode auto resolves the owner' \
      org auto '' Org/repo true
  fi
done

# Merge-lane promotion runs docker-promote-action. The lane's step must
# hand the action the resolved namespace and the release file's
# registries, and the action itself, fetched at the commit the lane
# pins and run under dry_run (which keeps crane and every registry out
# of the test), must resolve names under the namespace and check every
# path before anything copies.
lane=merge
# promote_step FIELD: one field of the release-publish promote step
promote_step() {
  yq -r ".jobs.\"release-publish\".steps[] | select(.id == \"promote\") | .$1" \
    "${root}/.github/workflows/merge.yaml"
}
uses=$(promote_step uses)
pattern='^lfreleng-actions/docker-promote-action@([0-9a-f]{40})$'
if [[ ! "${uses}" =~ ${pattern} ]]; then
  echo "FAIL: the release-publish promote step does not use"
  echo "  docker-promote-action at a commit SHA (got '${uses}')"
  exit 1
fi
pin="${BASH_REMATCH[1]}"

# promote_input NAME VALUE: the promote step passes VALUE as input NAME
promote_input() {
  local actual
  actual=$(promote_step "with.$1")
  if [ "${actual}" = "$2" ]; then
    echo "ok: promotion: step input $1"
  else
    echo "FAIL: promotion: step input $1 is '${actual}', expected '$2'"
    failures=$((failures + 1))
  fi
}
# shellcheck disable=SC2016  # literal workflow expressions
promote_input namespace '${{ needs.gerrit-validate.outputs.namespace }}'
# shellcheck disable=SC2016
promote_input pull_registry \
  '${{ needs.check-release.outputs.pull_registry || inputs.snapshot_registry }}'
# shellcheck disable=SC2016
promote_input push_registry \
  '${{ needs.check-release.outputs.push_registry || inputs.release_registry }}'
# shellcheck disable=SC2016
promote_input dry_run '${{ inputs.dry_run }}'

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
  echo "FAIL: ${action} is at ${head}, but merge.yaml pins ${pin}"
  exit 1
fi

# promote_case DESCRIPTION EXPECTED NAMESPACE CONTAINERS_JSON [PUSH] [LINE]
# EXPECTED is a 'would copy' line the log must hold, or 'error'; LINE
# is a further text the log must hold
promote_case() {
  local status=0
  env -i PATH="${PATH}" HOME="${work}" \
    GITHUB_OUTPUT="${work}/output" GITHUB_STEP_SUMMARY="${work}/summary" \
    INPUT_CONTAINERS_JSON="$4" INPUT_RELEASE_TAG=1.0.0 \
    INPUT_PULL_REGISTRY=pull.example INPUT_PUSH_REGISTRY="${5:-push.example}" \
    INPUT_NAMESPACE="$3" INPUT_PUSH_LATEST=false INPUT_DRY_RUN=true \
    python3 -I "${action}/entrypoint.py" > "${work}/log" 2>&1 || status=$?
  if { [ "$2" = 'error' ] && [ "${status}" -ne 0 ] &&
    grep -q '^::error::' "${work}/log" &&
    ! grep -q 'would copy' "${work}/log"; } ||
    { [ "$2" != 'error' ] && [ "${status}" -eq 0 ] &&
      grep -qxF "Dry run: would copy $2" "${work}/log" &&
      grep -qF "${6:-}" "${work}/log"; }; then
    echo "ok: promotion: $1"
  else
    echo "FAIL: promotion: $1 (exit ${status})"
    sed 's/^/  | /' "${work}/log"
    failures=$((failures + 1))
  fi
}

long=$(printf 'a%.0s' $(seq 251))
promote_case 'names resolve under the namespace' \
  'pull.example/onap/so/api:1.2 -> push.example/onap/so/api:1.0.0' \
  onap '[{"name":"so/api","version":"1.2"}]'
# Names are relative to the namespace, as in global-jjb's
# release-job.sh: no prefix is ever stripped
promote_case 'a prefixed name gains the namespace again, with a notice' \
  'pull.example/onap/onap/api:1.2 -> push.example/onap/onap/api:1.0.0' \
  onap '[{"name":"onap/api","version":"1.2"}]' push.example \
  '::notice::onap/api already starts with namespace'
promote_case 'a name listed twice fails before copying' \
  error onap \
  '[{"name":"api","version":"1"},{"name":"api","version":"2"}]'
promote_case 'a path over 255 characters once namespaced fails' \
  error onap "[{\"name\":\"${long}\",\"version\":\"1\"}]"
promote_case 'a registry path counts towards the limit' \
  error '' "[{\"name\":\"${long}\",\"version\":\"1\"}]" push.example/abcdef

# Snapshot publish must stage each image where promotion pulls it.
# A stub docker stands in for the daemon, and the step's archive
# directory moves into the scratch directory.
mkdir -p "${work}/bin" "${work}/archives"
touch "${work}/archives/image.tar"
cat > "${work}/bin/docker" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = image ]; then echo "sha256:$5"; fi
EOF
chmod +x "${work}/bin/docker"
yq -r '.jobs."snapshot-publish".steps[]
  | select(.name == "Publish snapshot/staging tags") | .run' \
  "${root}/.github/workflows/merge.yaml" |
  sed "s|/tmp/docker-archives|${work}/archives|g" > "${work}/publish.sh"
# publish_case DESCRIPTION EXPECTED_PATH NAMESPACE LOCAL_TAGS_JSON [REG]
# EXPECTED_PATH is the staged path under REG, or 'error' when the step
# must fail before pushing anything
publish_case() {
  local status=0 registry="${5:-snap.example}"
  env -i PATH="${work}/bin:${PATH}" HOME="${work}" \
    GITHUB_STEP_SUMMARY="${work}/summary" IMAGES="$4" VERSION=1.2.3 \
    SNAPSHOT_REGISTRY="${registry}" IMAGE_NAMESPACE="$3" DRY_RUN=true \
    bash --noprofile --norc -eo pipefail "${work}/publish.sh" \
    > "${work}/log" 2>&1 || status=$?
  if { [ "$2" = 'error' ] && [ "${status}" -ne 0 ] &&
    grep -q '^::error::' "${work}/log" &&
    ! grep -q 'would push' "${work}/log"; } ||
    { [ "$2" != 'error' ] && [ "${status}" -eq 0 ] &&
      grep -qxF \
        "Dry run: would push ${registry}/$2:1.2.3-SNAPSHOT-latest" \
        "${work}/log"; }; then
    echo "ok: snapshot: $1"
  else
    echo "FAIL: snapshot: $1 (exit ${status})"
    sed 's/^/  | /' "${work}/log"
    failures=$((failures + 1))
  fi
}
publish_case 'a namespaced sub-path stages where promotion pulls it' \
  onap/so/sdnc-adapter onap '["onap/so/sdnc-adapter:verify"]'
promote_case 'promotion pulls the same sub-path' \
  'pull.example/onap/so/sdnc-adapter:1 -> push.example/onap/so/sdnc-adapter:1.0.0' \
  onap '[{"name":"so/sdnc-adapter","version":"1"}]'
publish_case 'a bare build_command tag takes the namespace' \
  onap/so/api onap '["so/api:verify"]'
publish_case 'a registry host is dropped' \
  onap/api onap '["localhost:5000/api:verify"]'
publish_case 'an uppercase first component is a registry host' \
  onap/team/api onap '["Registry/team/api:verify"]'
publish_case 'no namespace keeps the path' team/api '' '["team/api:verify"]'
publish_case 'distinct images on one path fail before any push' \
  error onap '["other:verify","api:verify","onap/api:other"]'
publish_case 'a path over 255 characters with the registry path fails' \
  error onap "[\"${long:2}:verify\"]" snap.example/abc

if [ "${failures}" -gt 0 ]; then
  echo "${failures} failure(s)"
  exit 1
fi
echo "All namespace_mode, snapshot and promotion cases passed"
