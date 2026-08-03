<!--
SPDX-License-Identifier: Apache-2.0
SPDX-FileCopyrightText: 2026 The Linux Foundation
-->

# 🐳 Docker Reusable Workflows

<!-- prettier-ignore-start -->
<!-- markdownlint-disable-next-line MD013 -->
[![Linux Foundation](https://img.shields.io/badge/Linux-Foundation-blue)](https://linuxfoundation.org/) [![Source Code](https://img.shields.io/badge/GitHub-100000?logo=github&logoColor=white&color=blue)](https://github.com/lfreleng-actions/docker-workflows) [![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)
<!-- prettier-ignore-end -->

Reusable GitHub workflows that build, lint, test and scan Docker
container images for the Linux Foundation. The workflows support both
GitHub-native projects and projects where Gerrit serves as the source
of truth (dispatched through gerrit_to_platform), and handle single
Dockerfile repositories through to multi-image monorepos with
same-repository FROM chains.

The design research behind this repository, including the ONAP
container-build census the workflows target, lives in
[docs/BRIEF.md](docs/BRIEF.md).

## Workflow Inventory

<!-- markdownlint-disable MD013 -->

| Workflow                                    | Trigger context       | Status      | Purpose                                                              |
| ------------------------------------------- | --------------------- | ----------- | -------------------------------------------------------------------- |
| `.github/workflows/build-test.yaml`         | Pull request / verify | Implemented | Image discovery, buildx build, hadolint, test hook, SBOM, Grype scan |
| `.github/workflows/build-test-release.yaml` | Tag push (Model A)    | Planned     | Template skeleton; publish/sign/attest lanes follow                  |
| `.github/workflows/merge.yaml`              | Merge (Model B)       | Planned     | Template skeleton; snapshot/staging registry publish follows         |

<!-- markdownlint-enable MD013 -->

Thin caller examples live under `examples/`, with a GitHub-native and
a Gerrit-wrapped variant per workflow.

## Job Graph

`build-test.yaml` (`->` denotes sequence; `{ }` runs in parallel):

```text
gerrit-validate -> { repository-metadata | docker-metadata }
docker-metadata -> { audit | build }
build -> { tests | sbom -> grype }
```

The audit (hadolint) job gates on docker-metadata rather than build:
Dockerfile lint needs no built image, so lint findings surface even
when the build itself fails.

## Image Discovery

With no `images` input, the docker-metadata job walks `path_prefix`
for Dockerfiles at the locations observed across the LF project
estate:

1. `Dockerfile` (repository root)
2. `docker/Dockerfile`
3. `src/main/docker/Dockerfile` (Maven convention)
4. `<dir>/Dockerfile` (one-level per-image directories)

Image names derive from the repository or directory name. Pass the
`images` JSON input to override discovery; its array order is the
build order, which also serves same-repository FROM chains (an image
can build `FROM <earlier-image>:verify`). Each entry takes `name` and
`context` (required), plus optional `dockerfile`, `target` and
`build_args` (a list of KEY=VALUE strings).

The build job exports every built image as a docker archive, so the
test, SBOM and scan jobs consume the exact bits built. Verify-lane
builds run single-platform; multi-architecture builds belong to the
publish lanes.

## Inputs

### build-test.yaml

<!-- markdownlint-disable MD013 -->

| Input                         | Type    | Default    | Description                                                          |
| ----------------------------- | ------- | ---------- | -------------------------------------------------------------------- |
| `repository`                  | string  | `''`       | Repository to check out (owner/name); empty uses the caller          |
| `ref`                         | string  | `''`       | Branch/tag/SHA to check out (empty = default branch)                 |
| `path_prefix`                 | string  | `'.'`      | Path to the project root directory                                   |
| `images`                      | string  | `''`       | JSON image list (see Image Discovery); empty string auto-discovers   |
| `image_namespace`             | string  | `''`       | Namespace prefixed to image names (e.g. `onap` -> `onap/<name>`)     |
| `build_command`               | string  | `''`       | Escape hatch: project tooling builds the images (make/mvn/gradle)    |
| `build_timeout_minutes`       | number  | `30`       | Timeout for the build job in whole minutes                           |
| `test_command`                | string  | `''`       | Smoke-test hook; built images load first, IMAGES env carries tags    |
| `test_permit_fail`            | boolean | `false`    | Permit test failures without failing the workflow                    |
| `audit_permit_fail`           | boolean | `false`    | Permit hadolint findings (the NO_BLOCK pattern)                      |
| `grype_fail_on`               | string  | `'medium'` | Severity threshold that fails the Grype scan                         |
| `grype_permit_fail`           | boolean | `false`    | Permit Grype findings without failing the job                        |
| `harden_runner_egress`        | string  | `'block'`  | Harden-runner egress policy: `block` or `audit`                      |
| `harden_runner_allowlist`     | string  | (pinned)   | Out-of-band harden-runner allow-list configuration                   |
| `build_permit_egress_traffic` | boolean | `false`    | Audit egress scoped to the build job (un-enumerable base registries) |
| `gerrit_refspec`              | string  | `''`       | Gerrit refspec of the change under test                              |
| `gerrit_project`              | string  | `''`       | Gerrit project name                                                  |
| `gerrit_branch`               | string  | `''`       | Gerrit target branch                                                 |
| `gerrit_url`                  | string  | `''`       | Gerrit server URL; empty falls back to the `GERRIT_URL` variable     |

<!-- markdownlint-enable MD013 -->

The workflow takes no secrets. Lint, test and scan failures honour
the org-wide `NO_BLOCK_AUDIT_FAIL` repository variable as a runtime
escape hatch alongside the per-call `*_permit_fail` inputs.

## Usage

### GitHub-native caller

```yaml
jobs:
  build-test:
    permissions:
      contents: read
      pull-requests: read
    uses: lfreleng-actions/docker-workflows/.github/workflows/build-test.yaml@main
```

Pin the `uses:` reference to a specific release SHA in production
instead of the mutable `@main` reference. See
`examples/build-test/` for complete callers.

### Gerrit-wrapped caller

For projects where Gerrit serves as the source of truth,
gerrit_to_platform dispatches caller workflows through
`workflow_dispatch` with nine `GERRIT_*` inputs. The naming contract
requires the verify caller filename to contain both `gerrit` and
`verify` (for example `gerrit-verify.yaml`). See the `gerrit.yaml`
variant under `examples/build-test/`, including vote/comment
plumbing.

## Self-testing

`.github/workflows/testing.yaml` exercises `build-test.yaml` on pull
requests against pinned fixture releases:
[test-docker-project](https://github.com/lfreleng-actions/test-docker-project)
(single image under `docker/`) and
[test-docker-monorepo](https://github.com/lfreleng-actions/test-docker-monorepo)
(three images with a same-repository FROM chain), covering
auto-discovery, explicit image lists with per-image build arguments,
image namespacing, the `build_command` escape hatch and the
`test_command` hook.
