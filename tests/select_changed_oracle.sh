#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation

# The selections the resolved select_changed legs in testing.yaml
# must report (#126). Those legs build tests/fixtures/select-changed
# at the run's own commit, so dependency-change-action resolves the
# pull request's diff; this script reads the same diff and predicts,
# by docker-build-matrix-action's rules for this fixture, what each
# leg selects:
#
#   discovered: path_prefix is the fixture and discovery finds its
#     three images. A pull request that leaves the fixture alone
#     selects none; a changed file in the fixture that no image reads
#     (version.properties) selects every image.
#   leaf: path_prefix '.', and select-leaf declares paths ['.'], so
#     every change touches it; it builds alone unless the change also
#     touches the base chain.
#   base: the same, with select-base reading '.', so every change
#     rebuilds it and select-child, which builds FROM it.
#   An empty diff, such as a pull request whose commits cancel out,
#     resolves to '[]': no path for '.' to match, so every leg
#     selects none.
#
# select-child builds FROM select-base, so selecting either selects
# both: the lanes pass select_dependents and select_dependencies.
#
# Usage: git diff --name-only --no-renames -z BASE HEAD |
#          bash tests/select_changed_oracle.sh
# Reads NUL-separated paths, relative to the repository root, and
# prints <leg>_reason=<reason> and <leg>_images=<sorted names> lines
# for GITHUB_OUTPUT.

set -euo pipefail

fixture='tests/fixtures/select-changed'
images=(select-base select-child select-leaf)

declare -A touched=()
shared=false
any=false
while IFS= read -r -d '' changed; do
  any=true
  hit=false
  for image in "${images[@]}"; do
    dir="${fixture}/${image}"
    # A file in the context, the context itself, or a file replacing
    # a directory on the way to it
    if [[ "${changed}" == "${dir}" || "${changed}" == "${dir}/"* ||
      "${dir}" == "${changed}/"* ]]; then
      touched[${image}]=1
      hit=true
    fi
  done
  if [ "${hit}" = false ] && [[ "${changed}" == "${fixture}/"* ]]; then
    shared=true
  fi
done

# selection SEED...: the touched images plus SEED, with the base chain
# closed, as sorted names
selection() {
  local -A chosen=()
  local name
  for name in "${!touched[@]}" "$@"; do
    chosen[${name}]=1
  done
  if [ -n "${chosen[select-base]:-}" ] || [ -n "${chosen[select-child]:-}" ]
  then
    chosen[select-base]=1
    chosen[select-child]=1
  fi
  if [ "${#chosen[@]}" -gt 0 ]; then
    printf '%s\n' "${!chosen[@]}" | LC_ALL=C sort | paste -sd ' ' -
  else
    echo ''
  fi
}

if [ "${shared}" = true ]; then
  discovered_reason='shared'
  discovered_images="${images[*]}"
elif [ "${#touched[@]}" -gt 0 ]; then
  discovered_reason='changed'
  discovered_images=$(selection)
else
  discovered_reason='none'
  discovered_images=''
fi

echo "discovered_reason=${discovered_reason}"
echo "discovered_images=${discovered_images}"
if [ "${any}" = true ]; then
  echo 'leaf_reason=changed'
  echo "leaf_images=$(selection select-leaf)"
  echo 'base_reason=changed'
  echo "base_images=$(selection select-base)"
else
  echo 'leaf_reason=none'
  echo 'leaf_images='
  echo 'base_reason=none'
  echo 'base_images='
fi
