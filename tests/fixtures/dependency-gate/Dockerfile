# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation

# Self-test fixture for the Grype dependency-change gate: the
# build-test-dependency-gate-resolved call in testing.yaml builds this
# image from the pull request's own commit, so dependency-change-action
# compares it with the base branch and writes a sidecar saying whether
# the change touched this file. A pull request that leaves it alone
# must see the gate withheld, which proves the sidecar reached the
# scan; one that edits it must see the gate armed.
FROM alpine:3.22@sha256:14358309a308569c32bdc37e2e0e9694be33a9d99e68afb0f5ff33cc1f695dce
CMD ["true"]
