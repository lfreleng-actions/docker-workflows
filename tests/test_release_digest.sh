#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation

# Regression test for the release lane's single-platform digest
# resolution (#96). Docker reports RepoDigests in familiar form
# (probeorg/probe@..., not docker.io/probeorg/probe@...), so an exact
# match against the docker.io/ repository never resolved a Docker Hub
# push.
#
# The build step's script is extracted from the workflow and run as
# GitHub runs a 'shell: bash' step, against a fake docker on PATH, so
# the test exercises the shipped logic rather than a copy of it.
#
# Usage: tests/test_release_digest.sh [workflow-file]
# Needs bash, jq and yq (either the Go or the Python implementation).

set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
workflow="${1:-${root}/.github/workflows/build-test-release.yaml}"

work=$(mktemp -d)
trap 'rm -rf "${work}"' EXIT

yq -r '.jobs.build.steps[] | select(.id == "build") | .run' \
  "${workflow}" > "${work}/build.sh"
if ! grep -q 'RepoDigests' "${work}/build.sh"; then
  echo "FAIL: no RepoDigests lookup in the build step of ${workflow}"
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

failures=0

# run_case DESCRIPTION NAME NAMESPACE GHCR DOCKERHUB REPO_DIGESTS EXPECTED
#
# EXPECTED is the build step's 'pushed' output as compact JSON, or
# 'error' when digest resolution must fail the step.
run_case() {
  local description="$1" name="$2" namespace="$3" ghcr="$4" hub="$5"
  local digests="$6" expected="$7"
  local out="${work}/output" summary="${work}/summary" log="${work}/log"
  : > "${out}"
  : > "${summary}"
  local status=0
  env -i \
    PATH="${work}/bin:${PATH}" \
    HOME="${work}" \
    FAKE_REPO_DIGESTS="${digests}" \
    PATH_PREFIX="${work}/src" \
    IMAGES_JSON="[{\"name\": \"${name}\", \"context\": \"${name}\"}]" \
    IMAGE_NAMESPACE="${namespace}" \
    PLATFORMS='linux/amd64' \
    TAG='v1.2.3' \
    GHCR_PUBLISH="${ghcr}" \
    DOCKERHUB="${hub}" \
    OWNER='ProbeOrg' \
    GITHUB_OUTPUT="${out}" \
    GITHUB_STEP_SUMMARY="${summary}" \
    bash --noprofile --norc -eo pipefail "${work}/build.sh" \
    > "${log}" 2>&1 || status=$?

  local actual
  if [ "${expected}" = 'error' ]; then
    if [ "${status}" -ne 0 ] &&
      grep -q '^::error::Failed to resolve digest for' "${log}"; then
      echo "ok: ${description}"
      return
    fi
    actual="exit ${status}"
  else
    actual=$(sed -n 's/^pushed=//p' "${out}")
    if [ "${status}" -eq 0 ] &&
      [ "$(jq -c . <<< "${actual}")" = "$(jq -c . <<< "${expected}")" ]; then
      echo "ok: ${description}"
      return
    fi
  fi
  echo "FAIL: ${description}"
  echo "  expected: ${expected}"
  echo "  actual:   ${actual:-<none>} (exit ${status})"
  sed 's/^/  | /' "${log}"
  failures=$((failures + 1))
}

pushed() {
  jq -cn --args '[$ARGS.positional as $p
    | range(0; $p | length; 3)
    | {name: $p[.], image: $p[. + 1], digest: $p[. + 2]}]' "$@"
}

run_case 'Docker Hub push resolves its familiar-form digest' \
  probe probeorg false true \
  "probeorg/probe@${a}" \
  "$(pushed probe docker.io/probeorg/probe "${a}")"

run_case 'official image resolves without library/' \
  alpine library false true \
  "alpine@${a}" \
  "$(pushed alpine docker.io/library/alpine "${a}")"

run_case 'library/ stays on a multi-component name' \
  probe library/team false true \
  "team/probe@${b}
library/team/probe@${a}" \
  "$(pushed probe docker.io/library/team/probe "${a}")"

run_case 'a fully qualified entry still matches' \
  probe probeorg false true \
  "docker.io/probeorg/probe@${a}" \
  "$(pushed probe docker.io/probeorg/probe "${a}")"

run_case 'GHCR matches exactly, ignoring a Docker Hub entry' \
  probe probeorg true false \
  "probeorg/probe@${b}
ghcr.io/probeorg/probe@${a}" \
  "$(pushed probe ghcr.io/probeorg/probe "${a}")"

run_case 'each registry resolves its own digest' \
  probe probeorg true true \
  "ghcr.io/probeorg/probe@${c}
probeorg/probe@${a}" \
  "$(pushed probe ghcr.io/probeorg/probe "${c}" \
    probe docker.io/probeorg/probe "${a}")"

run_case 'no entry for the repository fails the step' \
  probe probeorg false true \
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
