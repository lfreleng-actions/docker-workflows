<!--
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
-->

# Design Brief: Docker Workflows — Gap Analysis

Research brief for building the `docker-workflows` reusable workflows.
Tracking issue:
[lfreleng-actions/.github#142](https://github.com/lfreleng-actions/.github/issues/142)

Issue requirements: build and publish container images to **DockerHub**,
**GHCR** and **Nexus 3** (project servers); integrate container security
auditing; support credential retrieval from **1Password**; vote in
**Gerrit**; first test deployment target is ONAP
[`sdc/sdc-docker-base`](https://gerrit.onap.org/r/c/sdc/sdc-docker-base/+/146311)
(currently missing a Verified +1 voting job).

## 1. Source material consulted

- Local clones of the ONAP Gerrit estate (183 repositories) — full
  Dockerfile/build-tooling census
- `project-reporting-artifacts` data for ONAP (2026-07-29 run,
  177 repositories, schema v5)
- `onap-release-mapping-tool` manifest (2026-07-31 run, OOM master,
  217 repositories, 89 in-release Docker images, 88 of them
  attributable to specific repositories — attributable counts used
  throughout this document)
- The sibling workflow repositories: `python-workflows`,
  `node-workflows`, `go-workflows`, `java-workflows`,
  `generic-workflows`, `security-workflows` (and their `docs/BRIEF.md`
  decision logs)
- The `lfreleng-actions` action estate (~100 repos surveyed)
- `workflows-template` / `actions-template` and the current (pristine)
  state of `docker-workflows`
- Third-party Docker action ecosystem (`docker/*`, Anchore, Aqua,
  Sigstore, Google container tools)

## 2. The real-world requirement: ONAP's Docker landscape

### 2.1 Scale

<!-- markdownlint-disable MD013 -->

| Metric                                                  | Value              |
| ------------------------------------------------------- | ------------------ |
| Repos containing Dockerfiles (local census)             | **99 of 183**      |
| Total Dockerfiles                                       | **306**            |
| Dockerfiles under `src/main/docker/` (Maven convention) | 93                 |
| Dockerfiles under a `docker/` subdirectory              | 59                 |
| Dockerfiles at repository root                          | 19                 |
| Dockerfiles in per-image / other subdirectories         | ~135               |
| Repos shipping images in the **current release map**    | **57** (88 images) |

<!-- markdownlint-enable MD013 -->

⚠️ **Reporting-tool caveat**: the project report's `Dockerfile`
classification flags only 23 repos (4 primary) because detection is
top-level-file based. ONAP's heaviest Docker producers
(`policy/docker`, `sdc/sdc-docker-base`, `ccsdk/distribution`, `so`,
`multicloud/*`) keep Dockerfiles in subdirectories and are missed.
**Use the local census (99 repos) and the release map (57 repos) as
the target lists, not the report's type field.** Follow-up: the
report's classifier (and `repository-content-action`, section 5.3)
should learn to detect nested Dockerfiles.

### 2.2 Build orchestration mechanisms (what a workflow must coexist with)

<!-- markdownlint-disable MD013 -->

| Mechanism                                    | Footprint                                                                                                        | Exemplars                                                                                     |
| -------------------------------------------- | ---------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------- |
| **fabric8 `docker-maven-plugin`** (dominant) | 136 poms / **63 repos**                                                                                          | `sdc/sdc-docker-base`, `aai/aai-common`, `so`, `ccsdk/distribution`, all `policy/*` PDPs      |
| Spotify Maven plugins (legacy)               | 18 poms / 9 repos                                                                                                | `dcaegen2/*` mostly                                                                           |
| Plain `docker build` via shell/Make          | ~30 repos                                                                                                        | `multicloud/openstack` (`build_image.sh`), `optf/has`, `oom/offline-installer`                |
| Gradle + push script                         | 4 repos                                                                                                          | `portal-ng/*` (`docker-push-staging-tags.sh` mimics fabric8 tags, reads `version.properties`) |
| Google jib                                   | 2 repos                                                                                                          | `cps`, `cps/ncmp-dmi-plugin`                                                                  |
| docker-compose                               | test harness only (46 repos have compose; only 13 files contain `build:`)                                        | `integration/csit`                                                                            |
| buildx multi-arch                            | fabric8 `<buildx><platforms>` (`ccsdk/distribution/alpine/pom.xml`); Jenkins `multiarch` JJB assembles manifests | `ccsdk/distribution`                                                                          |

<!-- markdownlint-enable MD013 -->

Not found anywhere: `docker-bake.hcl`, kaniko, buildah, podman.

### 2.3 Versioning and tagging conventions

- **`version.properties` at repo root in 110 repos** — canonical LF
  format: `major=`/`minor=`/`patch=` (or
  `release_name`/`sprint_number`/`feature_revision`) →
  `base_version`, `release_version`, `snapshot_version=X.Y.Z-SNAPSHOT`.
  Already parsed by our `build-metadata-action` (Model B in
  `node-workflows/merge.yaml` uses it).
- **Tag idioms** (Jenkins heritage, 120 files reference
  `STAGING-latest`):
  - `X.Y.Z-SNAPSHOT-latest`, `X.Y.Z-SNAPSHOT-<timestamp>Z` (merge)
  - `X.Y-STAGING-latest`, `X.Y-STAGING-<timestamp>` (staging)
  - `latest`
  - fabric8 poms compute these via `${parsedVersion.*}` +
    `${maven.build.timestamp}`; Jenkins
    `ci-management/jjb/include-docker-push.sh` sources
    `version.properties` and derives the same
- **`container-tag.yaml`**: only 3 files, all under `integration/` —
  support it as a minor version source, not the primary one
- **Self-release files**: `releases/<version>-container.yaml`
  (**1,286 files** across the estate) — schema:
  `distribution_type: container`, `container_release_tag`, `ref`
  (git sha), `containers: [{name, version}]`. This is the ONAP
  release trigger and must drive the release-promotion lane.
  Example: `sdc/sdc-docker-base/releases/1.7.0-container.yaml`
  promotes six images at `1.7.0-20200619T121144Z` → `1.7.0`.

### 2.4 Registries

<!-- markdownlint-disable MD013 -->

| Endpoint                | Role                                                                                      | Refs in tree |
| ----------------------- | ----------------------------------------------------------------------------------------- | ------------ |
| `nexus3.onap.org:10001` | anonymous pull / docker.io mirror (used in `FROM` lines)                                  | 1,675        |
| `nexus3.onap.org:10003` | snapshot/staging **push** (default `docker.push.registry`)                                | 917          |
| `nexus3.onap.org:10002` | release registry                                                                          | 500          |
| `nexus3.onap.org:10004` | staging pull                                                                              | 388          |
| `docker.io`             | final release destination (self-release yaml; multi-arch JJB uses `registry-1.docker.io`) | sparse       |
| `ghcr.io`               | not used by ONAP today; required by issue #142 for LF-native projects                     | —            |

<!-- markdownlint-enable MD013 -->

All of these endpoints (Docker Hub auth/registry/CDN hosts, `ghcr.io`,
`hub.docker.com`, `nexus3.onap.org:10001-10004`) are **already in the
org harden-runner `allow_list.txt` (v0.12.1)**. Base images pulled
from arbitrary third-party registries are the un-enumerable case —
exactly what the `build_permit_egress_traffic` hatch (already in the
template family) exists for.

### 2.5 Repository layouts the workflows MUST handle

1. **Single image, root Dockerfile** — `oom/readiness`,
   `test-docker-project` (fixture; Dockerfile under `docker/`)
2. **Single image, Maven module** — `dcaegen2/platform/ves-openapi-manager`,
   `sdc/sdc-helm-validator`
3. **Multi-image monorepo, per-image directories** —
   `sdc/sdc-docker-base` (6 sibling dirs, one root pom),
   `policy/docker` (5+), `multicloud/k8s` (18 Dockerfiles), `so`
   (10 poms + adapter repos)
4. **Base-image chains** (images `FROM` other project images, some
   same-repo, some cross-repo):
   - `integration/docker/onap-java11|onap-python` → consumed as
     `FROM nexus3.onap.org:10001/onap/integration-java11:8.0.0`
     across dozens of repos
   - `sdc/sdc-docker-base` → `sdc` images
   - `ccsdk/distribution` (`ccsdk-alpine-j21-image` etc.) →
     `sdnc/oam`, `ccsdk/cds`, sometimes at the **same tag** built in
     the same reactor
   - `so/base-image`, `policy-jre-alpine` chains
5. **Artifact-first builds** — Maven/Gradle produces a jar/war, the
   Dockerfile copies it in (the dominant Java pattern); the image
   build cannot run before the language build
6. **Multi-arch** — amd64 + arm64 with manifest-list assembly
   (Jenkins does parallel builds + `docker manifest`; buildx
   `--platform` collapses this)

### 2.6 Priority order (release-mapping tool, 2026-07-31, OOM master)

57 repos ship the 88 repo-attributable images in the deployed
release. Highest-value
targets by image count:

<!-- markdownlint-disable MD013 -->

| Repo                                                                                                            | Images | Notes                                                                                                                                    |
| --------------------------------------------------------------------------------------------------------------- | ------ | ---------------------------------------------------------------------------------------------------------------------------------------- |
| `so`                                                                                                            | 10     | fabric8 monorepo + 3 adapter repos ×1                                                                                                    |
| `policy/clamp`                                                                                                  | 6      | fabric8, participant images                                                                                                              |
| `ccsdk/cds`                                                                                                     | 5      | fabric8; consumes ccsdk base chain                                                                                                       |
| `sdc`                                                                                                           | 4      | fabric8; consumes sdc-docker-base                                                                                                        |
| `sdnc/oam`                                                                                                      | 4      | fabric8; consumes ccsdk base chain                                                                                                       |
| `dcaegen2/services`                                                                                             | 3      | Spotify-plugin legacy                                                                                                                    |
| `cps`, `dcaegen2/deployments`, `multicloud/framework`, `oom/platform/cert-service`, `sdc/sdc-workflow-designer` | 2 each | cps uses **jib**                                                                                                                         |
| ~45 single-image repos                                                                                          | 1 each | aai/*(8), policy/* PDPs (7), portal-ng/*(4, Gradle), dcaegen2/*, `sdc/sdc-helm-validator`, `oom/readiness` (Go), `policy/opa-pdp` (Go) … |

<!-- markdownlint-enable MD013 -->

Plus the **base-image repos** that everything depends on but are not
themselves "deployed": `integration/docker/onap-java11`,
`integration/docker/onap-python`, `sdc/sdc-docker-base`,
`ccsdk/distribution`, `policy/docker`. These should migrate first —
they are simple (no app build step) and unblock the chains.
`sdc/sdc-docker-base` is the designated pilot (issue #142).

## 3. Exemplar walk-through: `sdc/sdc-docker-base`

```text
sdc-docker-base/
├── pom.xml                     # one fabric8 config, six <image> blocks
├── version.properties          # major=1 minor=7 patch=0
├── releases/1.7.0-container.yaml
├── base_sdc-jetty/Dockerfile   # FROM jetty:9.4.18-jre8-alpine
├── base_sdc-cassandra/Dockerfile
├── base_sdc-cqlsh/Dockerfile
├── base_sdc-python/Dockerfile
├── base_sdc-sanity/Dockerfile
└── base_sdc-vnc/Dockerfile
```

- Six images (`onap/base_sdc-*`), each `<image>` block pointing
  `dockerFileDir` at a sibling directory; tags `${docker.tag}` +
  `${docker.latest.tag}`; OCI-ish labels
  `{"vcs_branch":"${scmBranch}","vcs_ref":"${scmRevision}"}`
- No unit tests; "verify" = all six images build
- Merge (Jenkins `maven-docker-stage`) pushes
  `1.7.0-SNAPSHOT-latest` / `1.7.0-STAGING-<ts>` to
  `nexus3.onap.org:10003`
- Release = merging `releases/1.7.0-container.yaml`, which pulls the
  staged `1.7.0-20200619T121144Z` images and republishes as `1.7.0`
  (docker.io + nexus release registry)
- **What it needs from us today**: a Gerrit-verify caller that builds
  all six Dockerfiles and votes +1/-1 — no Maven strictly required
  (the poms only orchestrate docker builds), which makes the
  **native-buildx path viable even for this fabric8 repo**

## 4. What we already have

### 4.1 House patterns to inherit (from the template + siblings)

`docker-workflows` is a pristine `workflows-template` instantiation:
skeleton `build-test.yaml` / `build-test-release.yaml` (Model A) /
`merge.yaml` (Model B) with `# TEMPLATE:` placeholders, plus
housekeeping workflows, `examples/{...}/{github,gerrit}.yaml`,
`testing.yaml`, hygiene files. The established vocabulary to keep:

- **Inputs**: `repository`, `ref`, `path_prefix`,
  `harden_runner_egress` + pinned `harden_runner_allowlist`,
  `build_permit_egress_traffic` (single harden-runner step per job
  with **computed** egress policy — the java-workflows fixed
  pattern), `gerrit_refspec|project|branch|url`, `*_permit_fail`
  soft-fail booleans + `NO_BLOCK_AUDIT_FAIL` variable, job-enable
  toggles, `*_timeout_minutes`, `dry_run`
- **Job graph**: `gerrit-validate` → { `repository-metadata` |
  `docker-metadata` } → `build` → { `test` | `audit/scan` | `sbom` →
  `grype` }; dual checkout (Gerrit vs standard); artifacts between
  jobs; `permissions: {}` top-level
- **Release models**: Model A tag-driven (tag-validate → build →
  sign/attest → draft-release promote) and Model B merge-driven
  (`version.properties` snapshot publish; `releases/` file triggers
  release publish) — **Model B maps 1:1 onto ONAP's
  docker-stage/docker-release Jenkins lanes**
- **Credential contract**: optional secrets
  `OP_SERVICE_ACCOUNT_TOKEN` + `VAULT_MAPPING_JSON`, admin variable
  `CREDENTIAL_LOAD_GRANTS`, credential at
  `op://<vault>/<repo-name>/password`, Nexus username defaults to
  repo name (Gerrit `/` → `-`), `nexus_user` override; publish steps
  skip-with-warning when unset so PR/self-test contexts work.
  Plain username/password/token inputs must ALSO work (issue #142)
- **Scaffolding**: per-workflow `examples/` github+gerrit callers
  (gerrit caller = nine `GERRIT_*` dispatch inputs + `GERRIT_DISABLED`,
  clear-vote/vote jobs via `gerrit-review-action`), `testing.yaml`
  self-test matrix of one modern fixture + one legacy ONAP repo

### 4.2 Existing lfreleng actions we can reuse directly

<!-- markdownlint-disable MD013 -->

| Action                                                  | Role in docker-workflows                                                                                                                                       |
| ------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `nexus-docker-login-action`                             | `docker login` to Nexus3 ports 10001-10004 + DockerHub; skips unconfigured targets                                                                             |
| `credential-load-action`                                | 1Password credential fetch (contract above)                                                                                                                    |
| `build-metadata-action`                                 | **already has a Dockerfile extractor** + `version.properties`/`releases/` parsing (`project_version`, `snapshot_version`, `release_files`, `is_release_ready`) |
| `repository-metadata-action`                            | event/branch/tag context + summaries                                                                                                                           |
| `tag-validate-action` (+semantic/calver)                | Model A tag gate                                                                                                                                               |
| `checkout-gerrit-change-action`, `gerrit-review-action` | Gerrit dispatch + voting                                                                                                                                       |
| `harden-runner-block-action`                            | pinned egress allow-list resolution                                                                                                                            |
| `sbom-action`                                           | syft backend — **syft scans container images directly** (`docker:<image>` source)                                                                              |
| `release-assets-action`, `draft-release-promote-action` | Model A release plumbing                                                                                                                                       |
| `docker-save-images-action`                             | image handoff between jobs (verify lane: build once, scan/test in parallel jobs)                                                                               |
| `version-extract-action`, `path-check-action`           | version/path helpers                                                                                                                                           |
| `verify-release-schema-action`                          | validates `releases/` yaml — check container schema coverage                                                                                                   |
| `sigul-sign-docker`                                     | LF Sigul signing (legacy; cosign preferred for images)                                                                                                         |
| `test-docker-project`                                   | testing.yaml fixture (nginx, `docker/Dockerfile`, Makefile)                                                                                                    |
| `helm-chart-publish-action`, `chartmuseum-action`       | out of scope here (helm lane), but adjacent                                                                                                                    |

<!-- markdownlint-enable MD013 -->

### 4.3 Third-party actions — buy, don't build

Vibrant, well-maintained ecosystem; pin by commit SHA as usual:

<!-- markdownlint-disable MD013 -->

| Action                                                    | Purpose                                                                                                         |
| --------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------- |
| `docker/setup-buildx-action` + `docker/setup-qemu-action` | BuildKit builder + emulation for arm64                                                                          |
| `docker/login-action`                                     | GHCR (`ghcr.io` + `GITHUB_TOKEN`), DockerHub, any registry incl. Nexus3 host:port                               |
| `docker/metadata-action`                                  | tag/label templating (OCI labels, semver tags, sha tags) — covers Model A tagging                               |
| `docker/build-push-action`                                | buildx build/push: multi-platform, GHA cache, `outputs`, build-args, targets, `provenance`/`sbom` flags         |
| `docker/bake-action`                                      | HCL-defined multi-image builds (optional power-user path for monorepos)                                         |
| `hadolint/hadolint-action`                                | Dockerfile lint                                                                                                 |
| `aquasecurity/trivy-action`                               | image vulnerability scan (alternative/complement to house grype lane)                                           |
| `anchore/scan-action` (grype)                             | house-standard scanner; accepts image or SBOM input                                                             |
| `sigstore/cosign-installer`                               | keyless image signing (`cosign sign <image>@<digest>`)                                                          |
| `actions/attest-build-provenance`                         | SLSA provenance **for images** (`subject-name: <registry>/<image>`, `subject-digest`, `push-to-registry: true`) |
| GoogleContainerTools `container-structure-test`           | declarative image tests (optional test hook)                                                                    |
| `google/go-containerregistry` (`crane`)                   | registry-side retag/copy for the promote lane (no pull/push of layers)                                          |

<!-- markdownlint-enable MD013 -->

**Conclusion: we need very few new in-house actions.** The gaps are
in orchestration (workflows) and two or three thin composite actions
(section 6).

## 5. Gap analysis

### 5.1 Workflows to build (in `docker-workflows`)

<!-- markdownlint-disable MD013 -->

| Workflow                  | Lane                            | Content                                                                                                                                                                                                                                                                                                                                      |
| ------------------------- | ------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `build-test.yaml`         | PR / Gerrit verify              | discover images → hadolint → buildx build (`push: false`, `load: true`, per-image matrix or ordered loop) → optional image test hook → image SBOM (syft) → grype/trivy scan → summary. **This alone satisfies issue #142's sdc-docker-base voting job.**                                                                                     |
| `merge.yaml`              | Model B (ONAP heritage)         | resolve version from `version.properties` → build → login (Nexus/DockerHub/GHCR) → push snapshot/staging tag set (`X.Y.Z-SNAPSHOT-latest`, `X.Y-STAGING-latest`, timestamped variants — templatable) → when a `releases/*-container.yaml` merges: parse it, `crane copy` staged `name:version` → release tag on release registry + docker.io |
| `build-test-release.yaml` | Model A (tag-driven, LF-native) | tag-validate → build multi-platform → `docker/metadata-action` tags → push GHCR/DockerHub/Nexus → cosign sign by digest + SLSA provenance attestation → SBOM attach → draft-release promote                                                                                                                                                  |

<!-- markdownlint-enable MD013 -->

Open question: split the ONAP release-promotion out of `merge.yaml`
into a fourth `container-release.yaml`? node-workflows folds it into
`merge.yaml` (check-release job) — recommend the same here for
consistency, revisit if the promote logic grows.

### 5.2 Input surface (proposal)

Beyond the standard family inputs (4.1), Docker-specific:

<!-- markdownlint-disable MD013 -->

| Input                                                         | Default                          | Purpose                                                                                                                                                                                                                              |
| ------------------------------------------------------------- | -------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `images`                                                      | `''` (auto-discover)             | JSON list of `{name, context, dockerfile, target, build_args, platforms}`; explicit ordering doubles as base-chain build order                                                                                                       |
| `image_discovery`                                             | `true`                           | walk `path_prefix` for Dockerfiles (root, `docker/`, `src/main/docker/`, per-image dirs); derive names from directory / repo                                                                                                         |
| `image_namespace`                                             | `''`                             | e.g. `onap` → `onap/<name>`; GHCR derives `ghcr.io/<owner>/<name>`                                                                                                                                                                   |
| `platforms`                                                   | `'linux/amd64'`                  | csv; adding `linux/arm64` engages QEMU + manifest list                                                                                                                                                                               |
| `build_command`                                               | `''`                             | **escape hatch**: run a project command (`make`, `mvn -P docker …`, `gradle`, script) to produce images, then the workflow enumerates/tags/scans/publishes them — covers fabric8/jib/script repos without reimplementing their build |
| `prebuild_scripts` / artifact download                        | `''`                             | hook for artifact-first builds (jar/war before image)                                                                                                                                                                                |
| `registry_mirror`                                             | `''`                             | rewrite/pull-through for `FROM nexus3…:10001/...` style bases                                                                                                                                                                        |
| `container_tag_method`                                        | `'auto'`                         | `version.properties` \| `container-tag.yaml` \| `git-tag` \| explicit input                                                                                                                                                          |
| `tag_suffix_style`                                            | `'lf'`                           | LF snapshot/staging idiom on/off; custom template                                                                                                                                                                                    |
| `dockerhub_publish`, `ghcr_publish`, `nexus_publish`          | `false`                          | independent per-registry toggles                                                                                                                                                                                                     |
| `snapshot_registry`, `release_registry`, `dockerhub_registry` | org defaults                     | e.g. `nexus3.onap.org:10003` / `:10002` / `docker.io`                                                                                                                                                                                |
| `hadolint_enabled` / `hadolint_permit_fail`                   | `true` / `false`                 | Dockerfile lint gate                                                                                                                                                                                                                 |
| `scan_tool` / `scan_fail_on` / `scan_permit_fail`             | `'grype'` / `'medium'` / `false` | image CVE gate (trivy selectable)                                                                                                                                                                                                    |
| `test_command` / `structure_test_config`                      | `''`                             | smoke/structure test hook per image                                                                                                                                                                                                  |
| `sbom_enabled`, `attestations`, `cosign_sign`                 | `true`                           | supply-chain outputs (release lanes)                                                                                                                                                                                                 |
| `push_latest`                                                 | `false`                          | guard the `latest` tag explicitly                                                                                                                                                                                                    |

<!-- markdownlint-enable MD013 -->

Secrets: `DOCKERHUB_USERNAME`/`DOCKERHUB_PASSWORD` (or token),
`NEXUS3_PASSWORD` (+ `nexus_user` input / repo-name derivation),
GHCR via `GITHUB_TOKEN` `packages: write`, all optional; 1Password
(`OP_SERVICE_ACCOUNT_TOKEN` + `VAULT_MAPPING_JSON`) as the managed
alternative, resolved through `credential-load-action`. Publish jobs
check availability and skip-with-warning (family convention).

### 5.3 Gaps in existing in-house actions

<!-- markdownlint-disable MD013 -->

| Gap                                                                                                                    | Recommendation                                                                                                                                                                         |
| ---------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| No image discovery / build-matrix generation (Dockerfile walk, fabric8 pom parse, FROM-graph ordering for base chains) | **New action: `docker-build-matrix-action`** (from `actions-template`). Outputs JSON matrix + topological build order. Single biggest enabler for monorepos                            |
| No registry-side promote/retag (staged `name:ver` → release tag, multi-arch manifest preserved)                        | **New action: `docker-promote-action`** wrapping `crane copy` / `buildx imagetools create`                                                                                             |
| ONAP snapshot/staging tag templating (`X.Y-STAGING-<ts>` etc.)                                                         | small composite **`docker-tags-action`** OR in-workflow bash (node `merge.yaml` precedent); `docker/metadata-action` covers Model A but not the LF idiom                               |
| `repository-content-action` detects only a **root** `Dockerfile`                                                       | extend to nested detection (also fixes reporting-tool undercount)                                                                                                                      |
| `build-metadata-action` Docker extractor: confirm multi-Dockerfile + `container-tag.yaml` coverage                     | verify/extend; it already owns `version.properties`/`releases/` parsing                                                                                                                |
| `nexus-docker-login-action` lacks GHCR                                                                                 | don't extend — use `docker/login-action` for GHCR alongside it                                                                                                                         |
| `verify-release-schema-action`: confirm `distribution_type: container` schema support                                  | verify/extend for the release lane                                                                                                                                                     |
| No multi-image test fixture                                                                                            | **new fixture repo `test-docker-monorepo`** (2-3 images + same-repo base chain); `testing.yaml` matrix = `test-docker-project` + `onap/sdc-sdc-docker-base` (mirror) + the new fixture |
| `1password-secrets-action`                                                                                             | **disregard** (to be archived); use `credential-load-action`                                                                                                                           |

<!-- markdownlint-enable MD013 -->

### 5.4 Security lane (issue #142 "consider container security auditing")

- **Dockerfile lint**: hadolint (verify lane, soft-fail input)
- **Image CVE scan**: grype on the built image (house pattern; SBOM →
  grype chain already established) with trivy selectable
- **Image SBOM**: syft against the image (not just the source tree);
  attach to releases
- **Signing/provenance** (release lanes): cosign keyless by digest +
  `actions/attest-build-provenance` with `push-to-registry` —
  identical verification story to the other workflow families;
  Note: GHCR supports both cleanly; Nexus 3 OCI/cosign-artifact
  support must be validated (older Nexus versions reject non-image
  OCI artifacts) — flag as an integration risk
- **Egress**: keep block mode; all target registries already in
  allow_list v0.12.1; third-party base images are the un-enumerable
  case → document `build_permit_egress_traffic` as the sanctioned
  hatch (or `registry_mirror` through Nexus 10001)

### 5.5 Explicit non-goals (for now)

- Reimplementing fabric8/jib semantics — `build_command` hatch instead
- Helm chart publishing (exists: `helm-chart-publish-action`; OOM is
  a separate problem space)
- docker-compose orchestration (ONAP uses it for CSIT tests, not
  builds)
- Windows/other-OS containers (no demand found)

## 6. New repositories/actions to create

1. **`docker-build-matrix-action`** — discovery + matrix + build
   order (Go or composite; from `actions-template`)
2. **`docker-promote-action`** — crane-based retag/copy for the
   release-promotion lane
3. *(maybe)* **`docker-tags-action`** — LF tag-idiom resolver; decide
   during implementation whether in-workflow bash suffices
4. **`test-docker-monorepo`** — multi-image + base-chain fixture

Everything else: third-party pinned actions + existing estate.

## 7. Rollout / validation plan

1. `build-test.yaml` (verify lane) + examples + `testing.yaml`
   (fixtures: `test-docker-project`, `onap/sdc-sdc-docker-base`)
2. **Pilot: `sdc/sdc-docker-base` `gerrit-verify.yaml` caller** →
   closes the missing +1 vote on change 146311 (issue #142); block
   mode, soft-fail scans initially (supplementary), then gate
3. `merge.yaml` snapshot/staging publish → pilot on sdc-docker-base
   (Nexus 10003), validate against Jenkins-produced tags
4. Release promotion (`releases/*-container.yaml`) + Model A lane
5. Scale out by priority: base-image repos
   (`integration/docker/*`, `ccsdk/distribution`, `policy/docker`) →
   top release-map repos (`so`, `policy/clamp`, `ccsdk/cds`, `sdc`,
   `sdnc/oam`) → single-image long tail
6. Portal-ng (Gradle) and cps (jib) exercise the `build_command`
   hatch; multicloud (shell) exercises plain discovery

## 8. Open questions

1. Maven-coupled repos: verify-lane parity — build images natively
   (fast, registry-agnostic) vs `mvn -P docker` via `build_command`
   (bit-exact with Jenkins)? Recommendation: native for
   Dockerfile-only repos (sdc-docker-base), `build_command` for
   artifact-first repos until java-workflows grows a docker profile
   handoff
2. Same-tag base chains built in one reactor (`ccsdk/distribution` →
   `odlsli` images): in-run `FROM` resolution needs the just-built
   image visible — buildx `--load` + local tag ordering handles the
   same-repo case; document the cross-repo case as
   staging-registry-mediated
3. Multi-arch strategy: single buildx `--platform` job vs parallel
   per-arch jobs + manifest assembly (Jenkins style)? Start with
   buildx single-job; QEMU cost may force the split for heavy images
4. Timestamped tag format: adopt Jenkins `<ver>-SNAPSHOT-<ts>Z`
   exactly (consumer tooling may parse it) — confirm with release
   engineering
5. Nexus 3 cosign/OCI-artifact compatibility (5.4) — test early
6. Does `policy/docker`-style CSIT image tooling need anything from
   us, or stay project-side?

## 9. Conventions inherited from the template (unchanged)

Pinned third-party actions by commit SHA; SPDX headers + REUSE;
pre-commit (yamllint, actionlint, gitlint, codespell); zizmor clean;
`permissions: {}` top-level; single computed harden-runner step per
job; examples as thin callers with github + gerrit variants;
`testing.yaml` self-tests on PR; tag-push + release-drafter +
scorecard + clear-action-cache housekeeping workflows.
