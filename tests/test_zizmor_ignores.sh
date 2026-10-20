#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation

# Keeps the impostor-commit ignores in .github/zizmor.yml in step with
# the all-zero placeholder 'uses:' lines in examples/ (#140).
#
# Each ignore entry is '<base filename>:<line>' and applies to that
# line in every example with that base name. The pre-commit hook runs
# zizmor --offline, where impostor-commit never runs, so an entry that
# drifts off its placeholder goes unnoticed. This test fails when:
#
#   - a placeholder 'uses:' line in examples/ has no matching entry;
#   - an entry matches no placeholder line in any example with its
#     base name;
#   - an entry lands on a real (non-placeholder) 'uses:' line in an
#     example with its base name, where it would hide a genuine
#     finding.
#
# Ported from the "Examples: zizmor placeholder ignores" section of
# lfreleng-actions/java-workflows .github/scripts/wiring-check.sh.
#
# Example files are parsed as YAML, so a 'uses' key counts in any
# form: block or flow mapping, plain, single- or double-quoted key and
# value. The check fails closed on what it cannot place on one line: a
# file that does not parse, a 'uses' key whose value is not a scalar on
# the key's own line, and a line mixing placeholder and real 'uses'.
# Regression cases run the check against generated fixtures first, so
# a matcher that misses a form fails here rather than letting a real
# line slip through.
#
# Usage: tests/test_zizmor_ignores.sh
# ZIZMOR_CONFIG and EXAMPLES_DIR override the default paths.
# Needs bash, awk, find, grep, sed, mktemp and python3 with PyYAML.

set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
repo_config=${ZIZMOR_CONFIG:-${root}/.github/zizmor.yml}
repo_examples=${EXAMPLES_DIR:-${root}/examples}

# Prints one tab-separated row per line carrying a 'uses' key:
# KIND, path, line and a message. KIND is placeholder, real, mixed or
# error; an error row may carry line 0 when it concerns a whole file.
read -r -d '' classify_py <<'EOF' || true
import re
import sys

import yaml

placeholder = re.compile(r"\S+@0{40}")
for path in sys.argv[1:]:
    try:
        with open(path, encoding="utf-8") as fh:
            docs = [d for d in yaml.compose_all(fh) if d is not None]
    except (OSError, yaml.YAMLError) as exc:
        print(f"error\t{path}\t0\tcannot parse: {' '.join(str(exc).split())}")
        continue
    kinds = {}
    seen = set()
    stack = list(docs)
    while stack:
        node = stack.pop()
        if id(node) in seen:
            continue
        seen.add(id(node))
        if isinstance(node, yaml.SequenceNode):
            stack.extend(node.value)
        if not isinstance(node, yaml.MappingNode):
            continue
        for key, value in node.value:
            stack.extend((key, value))
            if not (isinstance(key, yaml.ScalarNode) and key.value == "uses"):
                continue
            line = key.start_mark.line + 1
            if (
                not isinstance(value, yaml.ScalarNode)
                or value.start_mark.line != key.start_mark.line
                or value.end_mark.line != key.start_mark.line
            ):
                print(
                    f"error\t{path}\t{line}\tunsupported 'uses' form: "
                    "the value must be a scalar on the key's line"
                )
                continue
            kind = "placeholder" if placeholder.fullmatch(value.value) else "real"
            kinds.setdefault(line, set()).add(kind)
    for line in sorted(kinds):
        kind = kinds[line].pop() if len(kinds[line]) == 1 else "mixed"
        print(f"{kind}\t{path}\t{line}\t")
EOF

if ! python3 -c 'import yaml' 2> /dev/null; then
  echo "FAIL: python3 with PyYAML is required"
  exit 1
fi

# check_ignores CONFIG EXAMPLES: exit 0 when the ignores match the
# placeholders exactly, 1 with a FAIL line per problem otherwise.
check_ignores() (
  config=$1
  examples=$2
  fail=0
  err() {
    echo "FAIL: $*"
    fail=1
  }

  [ -f "${config}" ] || { echo "FAIL: no ${config}"; exit 1; }
  [ -d "${examples}" ] || { echo "FAIL: no ${examples}"; exit 1; }

  # The list items under rules.impostor-commit.ignore, in order.
  mapfile -t entries < <(awk '
    /^[^[:space:]#]/ { in_rules = ($0 ~ /^rules:/); rule = 0; ign = 0; next }
    !in_rules { next }
    /^  [^[:space:]#]/ { rule = ($0 ~ /^  impostor-commit:/); ign = 0; next }
    !rule { next }
    /^    [^[:space:]#-]/ { ign = ($0 ~ /^    ignore:/); next }
    ign && /^[[:space:]]*-[[:space:]]/ {
      sub(/^[[:space:]]*-[[:space:]]+/, "")
      sub(/[[:space:]]+#.*$/, "")
      gsub(/["'\''[:space:]]/, "")
      print
    }
  ' "${config}")

  if [ "${#entries[@]}" -eq 0 ]; then
    err "no rules.impostor-commit.ignore entries in ${config}"
  fi

  mapfile -t files < <(find "${examples}" -type f \
    \( -name '*.yaml' -o -name '*.yml' \) | LC_ALL=C sort)

  # Every placeholder, as '<base>:<line>' with its path for messages,
  # and every real or mixed 'uses' line, as '<path>:<line>'.
  declare -A placeholders=() reals=()
  rows=""
  if [ "${#files[@]}" -gt 0 ]; then
    rows=$(python3 -c "${classify_py}" "${files[@]}") \
      || err "python3 failed to classify the 'uses' lines"
  fi
  while IFS=$'\t' read -r kind f n msg; do
    case "${kind}" in
      placeholder)
        key="$(basename "${f}"):${n}"
        placeholders["${key}"]+="${f#"${root}"/} "
        ;;
      real) reals["${f}:${n}"]=1 ;;
      mixed)
        reals["${f}:${n}"]=1
        err "${f#"${root}"/}:${n} mixes placeholder and real 'uses';" \
          "put each on its own line"
        ;;
      error) err "${f#"${root}"/}:${n}: ${msg}" ;;
      "") ;;
      *) err "unexpected classifier output: ${kind} ${f} ${n} ${msg}" ;;
    esac
  done <<< "${rows}"

  if [ "${#placeholders[@]}" -eq 0 ]; then
    err "no placeholder 'uses:' lines found under ${examples}"
  fi

  declare -A listed=()
  for e in "${entries[@]}"; do
    if [[ ! "${e}" =~ ^([^:/]+):([1-9][0-9]*)$ ]]; then
      err "malformed entry '${e}': expected <base filename>:<line>"
      continue
    fi
    if [ -n "${listed[${e}]:-}" ]; then
      err "duplicate entry '${e}'"
      continue
    fi
    listed["${e}"]=1
    base=${BASH_REMATCH[1]}
    line=${BASH_REMATCH[2]}

    same_name=0
    for f in "${files[@]}"; do
      [ "$(basename "${f}")" = "${base}" ] || continue
      same_name=1
      if [ -n "${reals[${f}:${line}]:-}" ]; then
        text=$(sed -n "${line}p" "${f}")
        err "entry '${e}' lands on a real 'uses:' line in" \
          "${f#"${root}"/}: ${text#"${text%%[![:space:]]*}"}"
      fi
    done
    if [ "${same_name}" -eq 0 ]; then
      err "entry '${e}' names no example file under ${examples}"
    elif [ -z "${placeholders[${e}]:-}" ]; then
      err "entry '${e}' matches no placeholder 'uses:' line (stale)"
    fi
  done

  for key in "${!placeholders[@]}"; do
    if [ -z "${listed[${key}]:-}" ]; then
      for path in ${placeholders[${key}]}; do
        err "placeholder at ${path}:${key##*:} has no '${key}' entry"
      done
    fi
  done

  if [ "${fail}" -ne 0 ]; then
    echo "Update rules.impostor-commit.ignore in ${config#"${root}"/}" \
      "to list exactly the placeholder lines."
    exit 1
  fi
  echo "PASS: ${#entries[@]} impostor-commit ignores match" \
    "${#placeholders[@]} placeholder lines"
)

# --- Regression cases against generated fixtures ------------------------

work=$(mktemp -d)
trap 'rm -rf "${work}"' EXIT

placeholder="o/w/.github/workflows/x.yaml@$(printf '0%.0s' {1..40})"
real="o/a@$(printf 'a%.0s' {1..40})"
case_failures=0

# fixture NAME USES_LINE ENTRY...: an examples tree holding one
# github.yaml whose line 3 is USES_LINE, and a config listing ENTRY...
fixture() {
  local dir="${work}/$1" line=$2 e
  shift 2
  mkdir -p "${dir}/examples/lane"
  printf 'jobs:\n  call:\n%s\n' "${line}" \
    > "${dir}/examples/lane/github.yaml"
  {
    printf 'rules:\n  impostor-commit:\n    ignore:\n'
    for e in "$@"; do
      printf '      - %s\n' "${e}"
    done
  } > "${dir}/zizmor.yml"
}

# also NAME LANE USES_LINE: add LANE/github.yaml, whose line 3 is
# USES_LINE, to fixture NAME's examples tree.
also() {
  mkdir -p "${work}/$1/examples/$2"
  printf 'jobs:\n  call:\n%s\n' "$3" \
    > "${work}/$1/examples/$2/github.yaml"
}

# expect NAME STATUS [PATTERN]: check fixture NAME exits STATUS and,
# when PATTERN is given, says so in its output.
expect() {
  local dir="${work}/$1" want="exit $2" out rc
  [ -z "${3:-}" ] || want+=" with '$3'"
  out=$(check_ignores "${dir}/zizmor.yml" "${dir}/examples") && rc=0 \
    || rc=$?
  if [ "${rc}" -ne "$2" ] || \
     { [ -n "${3:-}" ] && ! grep -qF -- "$3" <<< "${out}"; }; then
    echo "FAIL: case '$1': exit ${rc}, want ${want}"
    printf '  %s\n' "${out}"
    case_failures=$((case_failures + 1))
  fi
}

# Each form wraps a 'uses' pair in block or flow YAML on line 3.
forms=(
  '    %s: %s'
  '    - %s: %s'
  '    with: {%s: %s}'
  '    - {%s: %s, name: x}'
)
n=0
for form in "${forms[@]}"; do
  for k in uses "'uses'" '"uses"'; do
    for v in "${placeholder}" "'${placeholder}'" "\"${placeholder}\""; do
      n=$((n + 1))
      # shellcheck disable=SC2059
      line=$(printf "${form}" "${k}" "${v}")
      fixture "listed-${n}" "${line}" github.yaml:3
      expect "listed-${n}" 0
      fixture "missing-${n}" "${line}" github.yaml:4
      expect "missing-${n}" 1 "has no 'github.yaml:3' entry"
    done
    for v in "${real}" "'${real}'" "\"${real}\""; do
      n=$((n + 1))
      # shellcheck disable=SC2059
      line=$(printf "${form}" "${k}" "${v}")
      fixture "real-${n}" "${line}" github.yaml:3
      expect "real-${n}" 1 "lands on a real 'uses:' line"
    done
  done
done
fixture step-placeholder "    - uses: ${placeholder}  # x" github.yaml:3
expect step-placeholder 0
fixture stale "    uses: ${placeholder}" github.yaml:3 github.yaml:2
expect stale 1 "entry 'github.yaml:2' matches no placeholder"
# A block placeholder satisfies the entry, but a flow-style real
# reference on the same line of a same-named file must still fail.
fixture shared-flow "    uses: ${placeholder}" github.yaml:3
also shared-flow other "    call: { uses: ${real} }"
expect shared-flow 1 "lands on a real 'uses:' line in"
fixture split-value $'    uses:\n      '"${placeholder}" github.yaml:3
expect split-value 1 "unsupported 'uses' form"
fixture split-flow $'    - {uses:\n        '"${placeholder}}" github.yaml:3
expect split-flow 1 "unsupported 'uses' form"
fixture mixed "    - [{uses: ${placeholder}}, {uses: ${real}}]" github.yaml:3
expect mixed 1 "mixes placeholder and real 'uses'"
fixture unparsable "    - {uses: ${placeholder}" github.yaml:3
expect unparsable 1 "cannot parse"

if [ "${case_failures}" -ne 0 ]; then
  echo "FAIL: ${case_failures} regression case(s) failed"
  exit 1
fi

# --- The repository's own ignores and examples --------------------------

check_ignores "${repo_config}" "${repo_examples}"
