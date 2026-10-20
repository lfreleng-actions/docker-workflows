# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation

# Self-test fixture for the build_artifacts input: target/hello.txt is
# not in the repository, so this image only builds once the lane has
# placed the artefact an earlier job of the run uploaded.
FROM alpine:3.22@sha256:14358309a308569c32bdc37e2e0e9694be33a9d99e68afb0f5ff33cc1f695dce
COPY target/hello.txt /hello.txt
