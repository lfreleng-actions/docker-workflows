#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation

# Regression test for the merge lane's gate-then-stage condition
# (#120). snapshot-publish must run only when every enabled gate has
# passed, and a gate disabled by its input must not hold it back
# (#90). The dry-run legs in testing.yaml prove the passing and
# disabled cases end to end, but cannot fail a gate without failing
# the run, so this test covers the failure cases.
#
# It extracts the job's 'if:' expression from merge.yaml and
# evaluates it, as GitHub would, over named cases and then over every
# combination of gate results and toggles, checking that no failed or
# cancelled gate ever admits a publish.
#
# Usage: tests/test_merge_gating.sh
# Needs bash, python3, yq (either the Go or the Python implementation).

set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

expr=$(yq -r '.jobs."snapshot-publish".if' \
  "${root}/.github/workflows/merge.yaml")
if [ -z "${expr}" ] || [ "${expr}" = 'null' ]; then
  echo "FAIL: no 'if' on the snapshot-publish job of merge.yaml"
  exit 1
fi

EXPR="${expr}" python3 - <<'EOF'
import itertools
import os
import re
import sys

GATES = ("dockerfile-lint", "tests", "sbom", "grype")
TOGGLES = ("lint_enabled", "sbom_enabled", "grype_enabled")
RESULTS = ("success", "failure", "skipped", "cancelled")

source = os.environ["EXPR"].strip()
body = re.fullmatch(r"\$\{\{(.*)\}\}", source, re.S)
if not body:
    sys.exit(f"FAIL: not a ${{{{ }}}} expression: {source}")
body = body.group(1)

# Translate the subset of the expression language the condition uses
# into Python. Anything outside that subset fails the test rather
# than being guessed at.
allowed = re.compile(
    r"""\s+|\(|\)|&&|\|\||==|!=|!|'[^']*'|cancelled\(\)
    |needs\.[A-Za-z0-9_-]+\.result|inputs\.[A-Za-z0-9_]+""",
    re.X,
)
out, pos = [], 0
while pos < len(body):
    m = allowed.match(body, pos)
    if not m:
        sys.exit(f"FAIL: unsupported syntax at: {body[pos:pos + 40]!r}")
    tok = m.group(0)
    if tok == "&&":
        tok = " and "
    elif tok == "||":
        tok = " or "
    elif tok == "!":
        tok = " not "
    elif tok == "cancelled()":
        tok = "cancelled"
    elif tok.startswith("needs."):
        tok = f"needs[{tok.split('.')[1]!r}]"
    elif tok.startswith("inputs."):
        tok = f"inputs[{tok.split('.')[1]!r}]"
    out.append(tok)
    pos = m.end()
code = compile("".join(out).strip(), "snapshot-publish.if", "eval")

missing = [g for g in GATES if f"needs.{g}.result" not in body]
if missing:
    sys.exit(f"FAIL: condition ignores gate(s): {', '.join(missing)}")


def publishes(results=None, cancelled=False, **toggles):
    needs = {"resolve-version": "success", "build": "success"}
    needs.update(dict.fromkeys(GATES, "success"))
    needs.update(results or {})
    inputs = dict.fromkeys(TOGGLES, True)
    inputs.update(toggles)
    return bool(eval(code, {}, {
        "needs": needs, "inputs": inputs, "cancelled": cancelled}))


failures = 0


def case(description, expected, *args, **kwargs):
    global failures
    actual = publishes(*args, **kwargs)
    if actual == expected:
        print(f"ok: {description}")
    else:
        print(f"FAIL: {description}: publish={actual}, want {expected}")
        failures += 1


case("every gate passes", True)
for gate in GATES:
    case(f"{gate} failing blocks the publish", False, {gate: "failure"})
case("a cancelled run publishes nothing", False, cancelled=True)
case("a failed build publishes nothing", False, {"build": "failure"})
case("a failed version resolution publishes nothing", False,
     {"resolve-version": "failure"})
case("lint disabled does not block", True,
     {"dockerfile-lint": "skipped"}, lint_enabled=False)
case("SBOM disabled (so no scan) does not block", True,
     {"sbom": "skipped", "grype": "skipped"}, sbom_enabled=False)
case("Grype disabled does not block", True,
     {"grype": "skipped"}, grype_enabled=False)
case("every optional gate disabled does not block", True,
     {"dockerfile-lint": "skipped", "sbom": "skipped",
      "grype": "skipped"},
     lint_enabled=False, sbom_enabled=False, grype_enabled=False)
case("an SBOM failure blocks even with Grype disabled", False,
     {"sbom": "failure", "grype": "skipped"}, grype_enabled=False)
case("a scan skipped by an SBOM failure blocks", False,
     {"sbom": "failure", "grype": "skipped"})
case("lint skipped while enabled blocks", False,
     {"dockerfile-lint": "skipped"})
case("SBOM skipped while enabled blocks", False,
     {"sbom": "skipped", "grype": "skipped"})
case("SBOM skipped while enabled blocks with Grype disabled", False,
     {"sbom": "skipped", "grype": "skipped"}, grype_enabled=False)
case("Grype skipped while enabled blocks", False,
     {"grype": "skipped"})
case("tests skipped blocks (tests has no toggle)", False,
     {"tests": "skipped"})

# Exhaustively: whatever the toggles, a failed or cancelled gate
# never admits a publish, and all gates passing always does.
combos = 0
for results in itertools.product(RESULTS, repeat=len(GATES)):
    for flags in itertools.product((True, False), repeat=len(TOGGLES)):
        combos += 1
        res = dict(zip(GATES, results))
        tog = dict(zip(TOGGLES, flags))
        got = publishes(res, **tog)
        bad = {"failure", "cancelled"} & set(results)
        if bad and got:
            print(f"FAIL: publishes despite {res} with {tog}")
            failures += 1
        if set(results) == {"success"} and not got:
            print(f"FAIL: all gates passed but no publish with {tog}")
            failures += 1
print(f"ok: {combos} result/toggle combinations hold the invariants")

if failures:
    print(f"{failures} failure(s)")
    sys.exit(1)
print("All merge gating tests passed")
EOF
