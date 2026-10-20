#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation

# Regression test for the build_artifacts input. Each lane's build job
# validates the input, downloads the named artefacts of this run into
# a staging directory, and places them in the checkout before the
# images build. The test checks the three lanes define the input and
# the steps identically and in that order, then extracts the validate
# and place step scripts and runs them as GitHub runs a 'shell: bash'
# step. A stand-in for actions/download-artifact fills the staging
# directory as that action does: the first name by name, into first/,
# and two or more names by pattern, into set/, where a single match
# unpacks straight into set/ and several into one directory per name.
#
# Usage: tests/test_build_artifacts.sh
# Needs bash, jq, coreutils and yq (either the Go or the Python
# implementation).

set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

work=$(mktemp -d)
trap 'rm -rf "${work}"' EXIT

failures=0
lanes=(build-test merge build-test-release)

fail() {
  echo "FAIL: $*"
  failures=$((failures + 1))
}

# build_step LANE ID FIELD: one field of a build job step, by step id
build_step() {
  yq -r ".jobs.build.steps[] | select(.id == \"$2\") | .$3" \
    "${root}/.github/workflows/$1.yaml"
}

# input_block LANE: the build_artifacts input definition, verbatim
input_block() {
  sed -n '/^      build_artifacts:$/,/^        default:/p' \
    "${root}/.github/workflows/$1.yaml"
}

# --- Wiring: the same input and steps in every lane ---------------------

for lane in "${lanes[@]}"; do
  if [ -z "$(input_block "${lane}")" ]; then
    fail "${lane}: no build_artifacts input"
  fi
  for id in build-artifacts download-build-artifacts \
    download-build-artifacts-set place-build-artifacts; do
    if ! build_step "${lane}" "${id}" name | grep -qv '^null$'; then
      fail "${lane}: no '${id}' step in the build job"
    fi
  done
done
for lane in merge build-test-release; do
  if [ "$(input_block "${lane}")" != "$(input_block build-test)" ]; then
    fail "${lane}: build_artifacts input differs from build-test"
  fi
  for id in build-artifacts download-build-artifacts \
    download-build-artifacts-set place-build-artifacts; do
    for field in if run uses with env '["continue-on-error"]'; do
      if [ "$(build_step "${lane}" "${id}" "${field}")" != \
        "$(build_step build-test "${id}" "${field}")" ]; then
        fail "${lane}: step '${id}' ${field} differs from build-test"
      fi
    done
  done
done
echo "ok: the three lanes define build_artifacts alike"

# shellcheck disable=SC2016  # literal workflow expressions
expected_if="inputs.build_artifacts != '' && inputs.build_artifacts != '[]'"
for lane in "${lanes[@]}"; do
  actual=$(build_step "${lane}" build-artifacts if)
  if [ "${actual}" != "${expected_if}" ]; then
    fail "${lane}: the validate step runs on '${actual}'," \
      "so an empty or '[]' input would not skip it"
  fi
  # Same-run artefacts only: each download names its artefacts and a
  # staging path outside the checkout, and nothing else
  for spec in download-build-artifacts:name:first \
    download-build-artifacts-set:pattern:set; do
    IFS=: read -r id key dir <<< "${spec}"
    keys=$(build_step "${lane}" "${id}" 'with | keys | sort | join(",")')
    if [ "${keys}" != "${key},path" ] && [ "${keys}" != "path,${key}" ]
    then
      fail "${lane}: step '${id}' takes '${keys}', expected only" \
        "path and ${key} (no run-id, no github-token)"
    fi
    # shellcheck disable=SC2016
    if [ "$(build_step "${lane}" "${id}" with.path)" != \
      "\${{ runner.temp }}/build-artifacts/${dir}" ]; then
      fail "${lane}: step '${id}' does not stage under runner.temp"
    fi
    uses=$(build_step "${lane}" "${id}" uses)
    if [[ ! "${uses}" =~ ^actions/download-artifact@[0-9a-f]{40}$ ]]; then
      fail "${lane}: step '${id}' is not pinned by SHA ('${uses}')"
    fi
  done
  # A missing first artefact must reach the place step's error
  if [ "$(build_step "${lane}" download-build-artifacts \
    '["continue-on-error"]')" != true ]; then
    fail "${lane}: the by-name download does not continue on error"
  fi
  pinned=$(grep -o 'actions/download-artifact@[0-9a-f]\{40\}' \
    "${root}/.github/workflows/${lane}.yaml" | sort -u)
  if [ "$(wc -l <<< "${pinned}")" -ne 1 ]; then
    fail "${lane}: download-artifact is pinned at more than one SHA"
  fi
  # Order: after every checkout, before the build
  order=$(yq -r '.jobs.build.steps | to_entries[]
    | [.key, (.value.id // ""), (.value.name // "")] | @tsv' \
    "${root}/.github/workflows/${lane}.yaml")
  index() { awk -F'\t' -v k="$1" -v c="$2" '$c == k { print $1 }' \
    <<< "${order}"; }
  last_checkout=$(awk -F'\t' '$3 ~ /^Checkout / { n = $1 } END { print n }' \
    <<< "${order}")
  validate=$(index build-artifacts 2)
  download=$(index download-build-artifacts 2)
  download_set=$(index download-build-artifacts-set 2)
  place=$(index place-build-artifacts 2)
  build=$(index build 2)
  if ! [ "${last_checkout}" -lt "${validate}" ] ||
    ! [ "${validate}" -lt "${download}" ] ||
    ! [ "${download}" -lt "${download_set}" ] ||
    ! [ "${download_set}" -lt "${place}" ] ||
    ! [ "${place}" -lt "${build}" ]; then
    fail "${lane}: expected checkout < validate < download <" \
      "download set < place < build, got ${last_checkout} ${validate}" \
      "${download} ${download_set} ${place} ${build}"
  fi
  if [ "$(yq -r '.jobs.build.permissions.actions // "none"' \
    "${root}/.github/workflows/${lane}.yaml")" != 'none' ]; then
    fail "${lane}: the build job gained an actions permission"
  fi
done
echo "ok: the steps run after the checkout and before the build"

# --- Behaviour: the step scripts ----------------------------------------

case_dir="${work}/case"
store="${work}/store"

# fresh: a checkout holding a Dockerfile and a script under proj/,
# and an empty artefact store
fresh() {
  rm -rf "${case_dir}" "${store}"
  mkdir -p "${case_dir}/ws/proj/scripts" "${case_dir}/tmp" "${store}"
  echo 'FROM scratch' > "${case_dir}/ws/proj/Dockerfile"
  echo 'echo hi' > "${case_dir}/ws/proj/scripts/run.sh"
  echo 'outside' > "${case_dir}/outside.txt"
}

# artefact NAME RELPATH CONTENT: an artefact uploaded earlier in the run
artefact() {
  local file="${store}/$1/$2"
  mkdir -p "${file%/*}"
  printf '%s\n' "$3" > "${file}"
}

# download FIRST PATTERN: what the two download-artifact steps leave in
# the staging directory, FIRST by name and PATTERN ('{a,b}') when set;
# sets outcome to the by-name step's outcome
download() {
  local staging="${case_dir}/tmp/build-artifacts" requested name
  local -a matched=()
  if [ -d "${store}/$1" ]; then
    mkdir -p "${staging}/first"
    cp -R "${store}/$1/." "${staging}/first/"
    outcome=success
  else
    outcome=failure
  fi
  if [ -z "$2" ]; then
    return 0
  fi
  staging+=/set
  requested="${2#\{}"
  requested="${requested%\}}"
  IFS=, read -r -a wanted <<< "${requested}"
  for name in "${wanted[@]}"; do
    if [ -d "${store}/${name}" ]; then
      matched+=("${name}")
    fi
  done
  if [ "${#matched[@]}" -eq 1 ]; then
    mkdir -p "${staging}"
    cp -R "${store}/${matched[0]}/." "${staging}/"
  else
    for name in "${matched[@]}"; do
      mkdir -p "${staging}/${name}"
      cp -R "${store}/${name}/." "${staging}/${name}/"
    done
  fi
}

# run_step SCRIPT SPEC: one step, as GitHub runs it, from the workspace
run_step() {
  (cd "${case_dir}/ws" &&
    env -i PATH="${PATH}" HOME="${work}" \
      GITHUB_OUTPUT="${case_dir}/output" RUNNER_TEMP="${case_dir}/tmp" \
      BUILD_ARTIFACTS="$2" PATH_PREFIX="${prefix}" \
      FIRST_OUTCOME="${outcome}" \
      bash --noprofile --norc -eo pipefail "$1")
}

# tree: every file in the checkout and its content
tree() {
  (cd "${case_dir}/ws" && find . -type f -print0 | sort -z |
    xargs -0 -r grep -H '')
}

# run_case DESCRIPTION EXPECTED SPEC [PATTERN] [FILE=CONTENT ...]
# EXPECTED is 'noop' (nothing downloads), 'ok', or 'error:TEXT' where
# TEXT must appear on an ::error:: line and the checkout must be left
# as it was. PATTERN is the download pattern an 'ok' case expects,
# empty for a single name; each FILE=CONTENT names a file under the
# workspace it must hold afterwards.
run_case() {
  local description="$1" expected="$2" spec="$3" pattern="${4:-}"
  local status=0 first actual before after check
  shift 4 2> /dev/null || shift $#
  : > "${case_dir}/output"
  rm -rf "${case_dir}/tmp/build-artifacts"
  outcome=''
  before=$(tree)
  run_step "${work}/validate.sh" "${spec}" > "${case_dir}/log" 2>&1 ||
    status=$?
  first=$(sed -n 's/^first=//p' "${case_dir}/output")
  actual=$(sed -n 's/^pattern=//p' "${case_dir}/output")
  if [ "${status}" -eq 0 ] && [ -n "${first}" ]; then
    download "${first}" "${actual}"
    run_step "${work}/place.sh" '' >> "${case_dir}/log" 2>&1 ||
      status=$?
  fi
  after=$(tree)
  check=ok
  case "${expected}" in
    noop)
      if [ "${status}" -ne 0 ] || [ -n "${first}" ] ||
        [ -n "${actual}" ] || [ "${before}" != "${after}" ]; then
        check=bad
      fi
      ;;
    ok)
      if [ "${status}" -ne 0 ] || [ "${actual}" != "${pattern}" ]; then
        check=bad
      fi
      for file in "$@"; do
        if [ "$(cat "${case_dir}/ws/${file%%=*}" 2> /dev/null)" != \
          "${file#*=}" ]; then
          check=bad
        fi
      done
      ;;
    error:*)
      if [ "${status}" -eq 0 ] ||
        ! grep '^::error::' "${case_dir}/log" |
        grep -qF -- "${expected#error:}" ||
        [ "${before}" != "${after}" ]; then
        check=bad
      fi
      ;;
  esac
  if [ "${check}" = ok ]; then
    echo "ok: ${lane}: ${description}"
  else
    fail "${lane}: ${description}: expected ${expected}," \
      "got exit ${status}, first '${first}', pattern '${actual}'"
    sed 's/^/  | /' "${case_dir}/log"
  fi
}

outcome=''
prefix=proj
same_run='uploaded earlier in the same workflow run'
for lane in "${lanes[@]}"; do
  build_step "${lane}" build-artifacts run > "${work}/validate.sh"
  build_step "${lane}" place-build-artifacts run > "${work}/place.sh"

  # No-ops
  fresh
  run_case 'an empty input downloads nothing' noop ''
  run_case "'[]' downloads nothing" noop '[]'
  run_case "a spaced '[ ]' downloads nothing" noop ' [ ] '

  # Placement
  fresh
  artefact app-jars app/target/app-1.0.jar jar
  run_case 'the default path places at path_prefix' ok \
    '[{"name": "app-jars"}]' '' \
    'proj/app/target/app-1.0.jar=jar'
  fresh
  artefact app-jars app-1.0.jar jar
  run_case 'a path places below path_prefix' ok \
    '[{"name": "app-jars", "path": "app/target"}]' '' \
    'proj/app/target/app-1.0.jar=jar'
  fresh
  artefact wheels dist/pkg.whl wheel
  artefact jars target/app.jar jar
  run_case 'several artefacts each place at their path' ok \
    '[{"name": "wheels", "path": "py"}, {"name": "jars", "path": ""}]' \
    '{jars,wheels}' 'proj/py/dist/pkg.whl=wheel' 'proj/target/app.jar=jar'
  fresh
  artefact jars app.jar jar
  run_case 'one artefact may place at two paths' ok \
    '[{"name": "jars", "path": "a"}, {"name": "jars", "path": "b"}]' \
    '' 'proj/a/app.jar=jar' 'proj/b/app.jar=jar'

  # Malformed input
  fresh
  run_case 'input that is not JSON fails' \
    'error:must be a JSON array' 'not json'
  run_case 'two JSON values fail' \
    'error:must be a JSON array' '[] []'
  run_case 'an object rather than an array fails' \
    'error:must be a JSON array' '{"name": "a"}'
  run_case 'an entry that is not an object fails' \
    'error:build_artifacts[0] "a": each entry must be an object' '["a"]'
  run_case 'an entry without a name fails' \
    "error:build_artifacts[1] {\"path\":\"x\"}: 'name' must be" \
    '[{"name": "a"}, {"path": "x"}]'
  run_case 'an empty name fails' \
    "error:build_artifacts[0] {\"name\":\"\"}: 'name' must be" \
    '[{"name": ""}]'
  run_case 'a name that is not a string fails' \
    "error:build_artifacts[0] {\"name\":5}: 'name' must be" \
    '[{"name": 5}]'
  run_case 'a name with a slash fails' \
    "error:build_artifacts[0] {\"name\":\"a/b\"}: 'name' may only" \
    '[{"name": "a/b"}]'
  run_case 'a name with a glob character fails' \
    "error:build_artifacts[0] {\"name\":\"a*\"}: 'name' may only" \
    '[{"name": "a*"}]'
  run_case 'a name with a trailing newline fails' \
    "error:build_artifacts[0] {\"name\":\"a\\n\"}: 'name' may only" \
    '[{"name": "a\n"}]'
  run_case "a name of '..' fails" \
    "error:build_artifacts[0] {\"name\":\"..\"}: 'name' may only" \
    '[{"name": ".."}]'
  run_case 'a path that is not a string fails' \
    "error:build_artifacts[0] {\"name\":\"a\",\"path\":5}: 'path'" \
    '[{"name": "a", "path": 5}]'
  run_case 'an absolute path fails' \
    "error:build_artifacts[0] {\"name\":\"a\",\"path\":\"/tmp\"}: 'path'" \
    '[{"name": "a", "path": "/tmp"}]'
  run_case "a leading '..' segment fails" \
    "error:build_artifacts[0] {\"name\":\"a\",\"path\":\"../x\"}: 'path'" \
    '[{"name": "a", "path": "../x"}]'
  run_case "an inner '..' segment fails, even inside path_prefix" \
    "error:build_artifacts[0] {\"name\":\"a\",\"path\":\"x/../y\"}" \
    '[{"name": "a", "path": "x/../y"}]'
  run_case 'a path with a control character fails' \
    "error:'path' must not contain control characters" \
    '[{"name": "a", "path": "x\ny"}]'
  ln -s "${case_dir}" "${case_dir}/ws/proj/escape"
  run_case 'a path through a symlink out of path_prefix fails' \
    "error:build_artifacts[0] {\"name\":\"a\",\"path\":\"escape\"}" \
    '[{"name": "a", "path": "escape"}]'

  # Missing artefacts
  fresh
  run_case 'a missing artefact fails, naming the same-run rule' \
    "error:entry 'jars': no artefact of that name exists in this run" \
    '[{"name": "jars"}]'
  run_case 'the missing-artefact error names needs:' \
    "error:must 'needs:' the job that uploads them" \
    '[{"name": "jars"}]'
  artefact jars app.jar jar
  artefact wheels pkg.whl wheel
  run_case 'one missing of three fails, naming it' \
    "error:entry 'docs': no artefact of that name exists" \
    '[{"name": "jars"}, {"name": "docs"}, {"name": "wheels"}]'
  run_case 'a missing name after the first fails, naming it' \
    "error:entry 'zzz': no artefact of that name exists" \
    '[{"name": "jars"}, {"name": "wheels"}, {"name": "zzz"}]'
  fresh
  artefact app app/target/app.jar jar
  artefact lib lib/target/lib.jar lib
  run_case 'module directories survive several artefacts' ok \
    '[{"name": "app"}, {"name": "lib"}]' '{app,lib}' \
    'proj/app/target/app.jar=jar' 'proj/lib/target/lib.jar=lib'
  # A lone match unpacks without its name, so these directories must
  # not pass for the artefacts they are named after
  fresh
  artefact app app/target/app.jar jar
  artefact app lib/target/lib.jar lib
  run_case 'directories named like the others do not stand in for them' \
    "error:entry 'lib': no artefact of that name exists in this run" \
    '[{"name": "app"}, {"name": "lib"}]'
  fresh
  artefact lib app/target/app.jar jar
  artefact lib lib/target/lib.jar lib
  run_case 'nor when the artefact present is not the first' \
    "error:entry 'app': no artefact of that name exists in this run" \
    '[{"name": "app"}, {"name": "lib"}]'
  fresh
  artefact jars app.jar jar
  run_case 'one found of two still fails' \
    "error:${same_run}" \
    '[{"name": "jars"}, {"name": "docs"}]'

  # Artefacts never replace the checkout
  fresh
  artefact evil Dockerfile 'FROM evil'
  run_case 'an artefact replacing the Dockerfile fails' \
    "error:build_artifacts[0] (name 'evil', path '.'): 'proj/Dockerfile'" \
    '[{"name": "evil"}]'
  fresh
  artefact evil run.sh 'rm -rf /'
  artefact good app.jar jar
  run_case 'an artefact replacing a script fails, placing nothing' \
    "error:build_artifacts[1] (name 'evil', path 'scripts')" \
    '[{"name": "good"}, {"name": "evil", "path": "scripts"}]'
  fresh
  artefact evil Dockerfile/x 'nested'
  run_case 'an artefact directory over a checkout file fails' \
    "error:would overwrite 'proj/Dockerfile' from the checkout" \
    '[{"name": "evil"}]'
  fresh
  artefact evil $'Dockerfile\n' 'FROM evil'
  run_case 'a name with a trailing newline cannot replace the Dockerfile' \
    ok '[{"name": "evil"}]' '' 'proj/Dockerfile=FROM scratch' \
    $'proj/Dockerfile\n=FROM evil'
  fresh
  artefact evil $'scripts\n/run.sh' 'rm -rf /'
  run_case 'a directory with a trailing newline cannot replace a script' \
    ok '[{"name": "evil"}]' '' 'proj/scripts/run.sh=echo hi' \
    $'proj/scripts\n/run.sh=rm -rf /'
  fresh
  artefact a app.jar one
  artefact b app.jar two
  run_case 'two artefacts placing the same file fail' \
    "error:build_artifacts[1] (name 'b', path '.'): 'proj/app.jar'" \
    '[{"name": "a"}, {"name": "b"}]'
  fresh
  artefact a lib 'a file'
  artefact b lib/x.jar 'below it'
  run_case 'one artefact file under another fails' \
    "error:collides with a file another build_artifacts entry places" \
    '[{"name": "a"}, {"name": "b"}]'
  fresh
  artefact a link.jar jar
  ln -sf "${case_dir}/outside.txt" "${store}/a/link.jar"
  run_case 'a symlink in an artefact fails' \
    "error:'link.jar' is not a regular file" '[{"name": "a"}]'
  fresh
  ln -s "${case_dir}" "${case_dir}/ws/proj/escape"
  artefact a escape/x.jar jar
  run_case 'a file through a checkout symlink out of path_prefix fails' \
    'error:resolves outside path_prefix' '[{"name": "a"}]'

  # path_prefix '.'
  prefix=.
  fresh
  artefact jars target/app.jar jar
  run_case "path_prefix '.' places at the workspace root" ok \
    '[{"name": "jars"}]' '' 'target/app.jar=jar'
  prefix=proj
done

if [ "${failures}" -gt 0 ]; then
  echo "${failures} failure(s)"
  exit 1
fi
echo "All build_artifacts cases passed"
