#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation

# Pins the workflow-level concurrency settings of the merge and
# release caller examples (#138). Both lanes must queue pending runs
# ('queue: max') rather than let a newer run replace them, and must
# never cancel a run in progress: a dropped merge run can skip a
# container release file, and a cancelled release run can leave a
# release half published.
#
# Usage: bash tests/test_example_concurrency.sh
# EXAMPLES_DIR overrides the default path.
# Needs bash and yq (either the Go or the Python implementation).

set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
examples=${EXAMPLES_DIR:-${root}/examples}

failures=0
for file in merge/github.yaml merge/gerrit.yaml \
  build-test-release/github.yaml build-test-release/gerrit.yaml; do
  path="${examples}/${file}"
  queue=$(yq -r '.concurrency.queue' "${path}")
  cancel=$(yq -r '.concurrency."cancel-in-progress"' "${path}")
  if [ "${queue}" != 'max' ]; then
    echo "FAIL: ${file}: concurrency.queue is '${queue}', want 'max'"
    failures=$((failures + 1))
  fi
  if [ "${cancel}" != 'false' ]; then
    echo "FAIL: ${file}: concurrency.cancel-in-progress is" \
      "'${cancel}', want 'false'"
    failures=$((failures + 1))
  fi
done

if [ "${failures}" -ne 0 ]; then
  exit 1
fi
echo 'PASS: merge and release examples queue runs and never cancel'
