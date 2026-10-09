<!--
SPDX-License-Identifier: Apache-2.0
SPDX-FileCopyrightText: 2026 The Linux Foundation
-->

# Jenkins Parity: Container Jobs

This document compares the Jenkins container jobs that ONAP and
OpenDaylight (ODL) run, built from global-jjb templates, with the
`docker-workflows` lanes and the actions they call. It lists what
each side does, function by function, the gaps with their tracking
issues, the decisions release engineering still has to make, and the
global-jjb defects the comparison turned up.

The design brief, [BRIEF.md](BRIEF.md), covers the ONAP container
census and the reasoning behind the lanes; this document does not
repeat it.

## 1. Scope and method

### 1.1 Sources

<!-- markdownlint-disable MD013 -->

| Source                  | Ref                                   | Notes                                                                                    |
| ----------------------- | ------------------------------------- | ---------------------------------------------------------------------------------------- |
| global-jjb              | `c2bdc8d` (v0.96.4, 2026-09-08)       | Line numbers below refer to this commit                                                  |
| ONAP `ci-management`    | `28227ec` (2026-09-22)                | Pins global-jjb v0.95.0 (`45de562`)                                                      |
| ODL `releng/builder`    | `551d53e` (2026-09-24)                | Pins global-jjb `301a07b`, absent from the local global-jjb clone, so its tag is unknown |
| ONAP repositories       | Local clones                          | 1,414 container release files (`distribution_type: container`) under `releases/`         |
| `docker-workflows`      | `ac1f910` (`main`, v0.7.1 plus hooks) | PR #107 (pending review) moves discovery and build into actions                          |
| `java-workflows` design | `main`, `docs/BRIEF.md`               | Section "Signing: Sigul now, the interface fixed"                                        |

<!-- markdownlint-enable MD013 -->

Between v0.95.0 and v0.96.4, `shell/release-job.sh` changed in how it
fetches cosign and its helper files, and nowhere else in the
container path. Behaviour described for v0.96.4 holds for ONAP,
except where section 6 says otherwise.

### 1.2 Counting method

A YAML loader that ignores JJB tags read every `- project:` block
under `jjb/`, expanded job groups from both `ci-management` and
global-jjb, and classified each job by template ID. Repository counts
use the Gerrit project name, so a repository with more than one
stream counts once; job-block counts are post-expansion. Job parameters
decide the "builds images" and "Maven merge with docker" rows: a
`pom.xml` binding a docker build into the default lifecycle would not
show, so treat those rows as lower bounds.

Release-file figures come from the local ONAP clones and reflect
whatever those clones held at survey time.

## 2. Jenkins footprint

### 2.1 ONAP

<!-- markdownlint-disable MD013 -->

| Mechanism                                 | Template(s)                                                                                                                                | Job blocks | Repositories      |
| ----------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------ | ---------- | ----------------- |
| Maven docker plugin, staged               | `gerrit-maven-docker-stage` (global-jjb)                                                                                                   | 79         | 61                |
| Maven merge with a docker profile or goal | `{project-name}-{stream}-merge-java`, `gerrit-maven-merge` with `-P docker` or similar                                                     | 25         | 14 (all in row 1) |
| Plain Dockerfile                          | `gerrit-docker-verify`, `gerrit-docker-merge` (global-jjb)                                                                                 | 32 + 32    | 14                |
| ONAP-local docker templates               | `docker-java-daily`, `docker-golang-shell-daily`, `3scm-docker-shell-daily`, `docker-java-version-shell-daily`, `integration-docker-merge` | 8          | 8                 |
| **Repositories publishing containers**    | Union of the rows above                                                                                                                    |            | **81**            |
| Of those, with release jobs               | `gerrit-release-verify`, `gerrit-release-merge`                                                                                            |            | 78                |

<!-- markdownlint-enable MD013 -->

The sets overlap by one repository each between the Maven stage and
plain Dockerfile rows, between the Maven merge and plain Dockerfile
rows, and between the ONAP-local row and the rest. The three
publishing repositories without release jobs are `integration`,
`integration/onap-component-simulators` and `testsuite/cds-modk-odl`.

Further measured facts:

- **Registries.** `jjb/global-defaults.yaml:69-74` sets the public
  registry to `nexus3.onap.org:10001`, snapshot to `:10003`, staging
  to `:10004`, and the push registry to the snapshot one. The Maven
  docker plugin pushes wherever `docker.push.registry` points;
  `oparent/pom.xml:60` sets it to `:10003`. The stage template also
  injects `CONTAINER_PUSH_REGISTRY={container-staging-registry}`
  (`jjb/lf-maven-jobs.yaml:1228`), which resolves to `:10004` in
  ONAP; nine `multicloud` poms read that variable instead.
- **Verify.** 8 of the 61 Maven docker repositories build images at
  verify time, judged by their job parameters. The other 53 run a
  Maven verify that does not request an image.
- **Staging trigger.** `gerrit-maven-docker-stage` runs on a
  `stage-release` or `stage-docker-release` Gerrit comment
  (`jjb/lf-maven-jobs.yaml:1247-1249`). Its cron defaults to empty
  (`:1013`); 5 of the 79 ONAP blocks set `@daily`.
  `gerrit-docker-merge` pushes on every merge, plus a weekly rebuild
  (`jjb/lf-docker-jobs.yaml:154,167-170`).
- **Tag methods** (plain Dockerfile jobs): `stream` 17 blocks,
  `latest` 12 (8 by default), `yaml-file` 3.
- **Release files.** Container names are relative to the project
  umbrella: 2,288 entries carry a bare name and 503 a sub-path
  (`so/`, `multicloud/`, `dmaap/`, `portal-ng/`, `oom/`, `vfc/`).
  None start with `onap/`. 97 files override the registries (95 to
  `:10003` and `:10002`, 2 to `docker.io`). 90 files promote from a
  mutable source tag (`latest` in 117 entries, a stream name in 18).
- **Docker Hub.** A daily job, `lf-onap-release-docker-hub`
  (`jjb/lf-infra-releasedockerhub.yaml:9-19`), runs
  `lftools nexus docker releasedockerhub --org onap` to copy release
  images from `:10002` to `docker.io`.
- **Not used.** No ONAP project instantiates the `multiarch` merge or
  `docker-manifest` templates in `jjb/global-templates-java.yaml`, nor
  global-jjb's `gerrit-docker-snyk-cli`. 36 Maven docker repositories
  set `sbom-generator: true`, which produces an SPDX SBOM of the Maven
  dependency tree (`shell/sbom-generator.sh`), not of the image.

### 2.2 OpenDaylight

ODL publishes one image, `opendaylight/opendaylight`, from
`integration/distribution` through `gerrit-docker-verify` and
`gerrit-docker-merge` on four streams
(`jjb/integration/distribution/distribution-jobs.yaml:86-109`). The
jobs use `container-tag-method: yaml-file`, a docker root of
`$WORKSPACE/docker`, `docker-build-args: --network=host`, and push to
`nexus3.opendaylight.org:10003`; a change under `docker/` triggers
them. The same repository carries release jobs (`:115-123`).
`integration/packaging` has the same job shape for `stable/phosphorus`
alone (`jjb/packaging/packaging.yaml:1-21`). A daily
`lf-odl-release-docker-hub` job mirrors releases to Docker Hub under
`opendaylight`.

The local `integration/distribution` clone dates from February 2025
and predates its `docker/` directory, so this survey did not read the
Dockerfile or its `container-tag.yaml`.

## 3. Parity matrix

Status key: **Parity**, **Partial**, **Gap**, **Exceeds** (the GitHub
side does more), **N/A** (estate-level, not per repository).

Unless noted, Jenkins paths below are global-jjb paths.

<!-- markdownlint-disable MD013 -->

| Function                 | Jenkins behaviour and source                                                                                                                                                                                                                          | docker-workflows                                                                                                                                              | Status  | Tracking             |
| ------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------- | -------------------- |
| Verify build             | One `docker build` per job from `docker-root` (`shell/docker-build.sh`); 53 of 61 Maven docker repositories build no image at verify (section 2.1)                                                                                                    | `build-test.yaml`: discovery, buildx build, hadolint, test hook, image SBOM, Grype; `build_command` runs project tooling                                      | Exceeds | #29, #34 (PR #107)   |
| Maven-built images       | `gerrit-maven-docker-stage`: JDK, Maven settings, `maven-patch-release.sh`, then `mvn` with the docker profile (`jjb/lf-maven-jobs.yaml:1201-1245`)                                                                                                   | `build_command` runs a command, but the lanes set up no JDK, Maven or `settings.xml`                                                                          | Gap     | #108                 |
| Staging push and tag set | Per pom for Maven images (`sdc-docker-base`: `${project.version}-${timestamp}`, `${project.version}-latest`); one tag per job for plain Dockerfiles; ONAP `jjb/include-docker-push.sh` pushes `SNAPSHOT-<ts>Z`, `STAGING-<ts>Z`, `X.Y-STAGING-latest` | `merge.yaml` pushes `X.Y.Z-SNAPSHOT-latest`, `X.Y-STAGING-latest`, `X.Y.Z-<ts>Z` per image on every merge                                                     | Partial | #31, #37             |
| Staging trigger          | Maven: Gerrit comment, optional cron; plain Dockerfile: every merge plus weekly                                                                                                                                                                       | Every merge                                                                                                                                                   | Partial | Decision, section 5  |
| Tag methods              | `latest`, `stream`, `git-describe`, `yaml-file` (`shell/docker-get-container-tag.sh:27-47`); `yaml-file` reads `container-tag.yaml` from `container-tag-yaml-dir`, else `docker-root`                                                                 | None; one tag set for every repository                                                                                                                        | Gap     | #109, #31, #37       |
| Release verify           | `gerrit-release-verify` on a change to `releases/*.yaml`: schema check, semver check, pull of each staged image, checkout of `ref`, locally signed tag; votes (`shell/release-job.sh:740-749,557-559,576-578`)                                        | `build-test.yaml`, with the release registries set: `check-release` validates the file offline; `release-verify` checks staged images and release tags        | Partial | #119                 |
| Release promotion        | `docker pull`, `docker tag`, `docker push` to `<registry>/<umbrella>/<name>:<tag>`; umbrella from `GERRIT_URL` (`shell/release-job.sh:520-571`)                                                                                                       | `crane copy` to `<registry>/<namespace>/<name>:<tag>`; keeps manifest lists; namespace from `namespace_mode`, names relative to it                            | Parity  | #30 (namespace done) |
| Skip existing release    | Pull of the release tag first; if present, no copy, and a signature check (`shell/release-job.sh:540-556`)                                                                                                                                            | None; `crane copy` overwrites the release tag                                                                                                                 | Gap     | #30                  |
| Registry overrides       | `container_pull_registry`, `container_push_registry` accepted as given (`shell/release-job.sh:141-151`)                                                                                                                                               | Accepted, but the host must match the workflow input, to protect the credential                                                                               | Exceeds | #36                  |
| Image signing            | cosign key pair, by digest, on promotion; signs an existing unsigned release on re-merge (`shell/release-job.sh:546-553,567-570`)                                                                                                                     | `merge.yaml` signs nothing. `build-test-release.yaml` signs keyless (OIDC) by digest                                                                          | Gap     | #110                 |
| Git tag                  | Annotated tag at the release file's `ref`, signed through Sigul, checked with `git tag -v`, pushed on merge; an existing annotated tag passes unverified, a lightweight one fails (`shell/release-job.sh:332-476`)                                    | `merge.yaml` creates no tag. `build-test-release.yaml` starts from an existing signed tag; validation accepts a GPG signature from a key GitHub does not know | Gap     | #110                 |
| Docker Hub mirroring     | Daily `lftools nexus docker releasedockerhub` job per project (section 2)                                                                                                                                                                             | `build-test-release.yaml` can push to Docker Hub itself; `merge.yaml` cannot                                                                                  | N/A     | None                 |
| Dry run                  | `DRY_RUN` parameter on release merge; image pushes and signing ignore it (section 6, D1)                                                                                                                                                              | `dry_run` in both publish lanes, self-tested on every pull request                                                                                            | Exceeds | #84, #89 (done), #28 |
| Multi-architecture       | Not used by ONAP or ODL; promotion would flatten a manifest list (section 6, D4)                                                                                                                                                                      | `build-test-release.yaml` builds multi-platform; `merge.yaml` builds for the runner's platform; promotion keeps lists                                         | Partial | #32                  |
| Scanning and SBOM        | Snyk template exists but neither project uses it; ONAP produces Maven dependency SBOMs, not image SBOMs                                                                                                                                               | Syft image SBOM (`sbom-action` image mode) and Grype in `build-test.yaml` and `build-test-release.yaml`; none in `merge.yaml`                                 | Exceeds | #35                  |

<!-- markdownlint-enable MD013 -->

## 4. Gaps

1. **Maven-built images (#108).** 61 ONAP repositories, the
   largest group, build images with the Maven docker plugin.
   `build_command` can run `mvn -P docker`, but nothing provisions the
   JDK, the Maven version or the Nexus `settings.xml` the build needs,
   and the estate actions that do (`maven-build-action`,
   `maven-xml-settings-action`, `maven-stage-prep-action`,
   `credential-load-action`) sit unused by these lanes.
2. **Tag methods (#109).** The plain Dockerfile repositories
   (14 in ONAP, plus ODL) tag by `stream`, `latest` or a per-image
   `container-tag.yaml`, and their release files reference those
   tags. The merge lane offers one fixed tag set.
3. **Release-file names (#30, addressed).** Jenkins prepends the
   umbrella taken from `GERRIT_URL` (`onap`, `opendaylight`) to each
   release-file name. `merge.yaml` used the name as the full
   repository path, so an ONAP release file promoted from the wrong
   path. It now applies the lane's image namespace (`namespace_mode`)
   to both sides of the promotion, after any release-file registry
   override, as the snapshot publish already did.
4. **Release verify (#119, addressed in part).** Jenkins rejects a
   bad release file before it merges. `build-test.yaml` now does
   too, once the caller passes the registries its merge lane uses:
   `check-release` runs `docker-release-detect-action` (#36) on the
   change, offline, as `merge.yaml` runs it on the merge, and
   `release-verify` runs `docker-promote-action` with `mode: verify`,
   which writes nothing and fails on a missing staged image or a
   release tag holding other bits. An image already released with
   the same digest passes, where Jenkins aborts (D2, section 6.1).
   The registry checks need the registry credential, so a fork pull
   request gets the offline check alone, with a warning. Jenkins'
   semver check of `container_release_tag`, its checkout of `ref`
   and the schema check (`verify-release-schema-action`) have no
   counterpart yet.
5. **Skip existing (#30).** A second merge of the same release file,
   or a re-run, copies again and overwrites the release tag.
   `docker-promote-action` (#30, in progress) adds skip-existing.
6. **Signing and git tag (#110).** The merge lane releases
   without an image signature or a git tag. The release lane signs
   keyless, which conflicts with the key-pair decision recorded in
   `java-workflows`. Neither side checks who signed a tag it did not
   create: Jenkins skips verification of an existing annotated tag
   (`release-job.sh:347-349`), and `tag-validate-action` 1.1.7 skips
   the GitHub key check when the runner cannot verify a GPG
   signature, so a tag signed by an unknown key passes. cosign v3
   stores signatures as Sigstore bundles in OCI 1.1 referrers;
   GHCR, which returns 404 for the referrers API, gets a
   `sha256-<hex>` fallback tag instead. cosign v3 verifies these by
   default; v2.6.0 and later need `--new-bundle-format=true`, and
   earlier releases cannot read them. global-jjb v0.96.x also pins
   cosign v3 (line 535).
7. **Docker Hub mirroring (untracked).** The daily lftools jobs run
   per Jenkins instance, not per repository. Moving them off Jenkins
   needs a scheduled workflow somewhere; no issue tracks it. Nobody
   has checked whether the mirror copies cosign signature tags.
8. **Merge-lane SBOM and scan (#35).** Verify and Model A produce
   image SBOMs and Grype results; the merge lane does neither.
9. **Multi-architecture merge builds (#32).**
10. **Publish-path validation (#28).** A non-dry-run
    `build-test-release.yaml` publish to a scratch GHCR namespace,
    at v0.7.0 and at PR #107's head, passed every check: digest
    capture, multi-architecture index, keyless cosign verification,
    SLSA provenance (`gh attestation verify`), the `latest` retag and
    release assets. Nobody has yet run the `merge.yaml` staging push
    or promotion against a real registry.

## 5. Decisions needed from release engineering

1. **Signing model (#110).** Key pair, as Jenkins does and as
   the `java-workflows` brief decides for container images, or
   keyless, as `build-test-release.yaml` does today. Images released
   through Jenkins carry key-pair signatures (`release-job.sh` lines
   553 and 570), so a switch to keyless gives one image line two
   verification methods. The `java-workflows` brief also notes that
   some Gerrit-mirrored and air-gapped consumers cannot reach the
   public Sigstore services keyless signing depends on.
2. **Staging trigger (#31).** `merge.yaml` stages a promotable,
   timestamped tag on every merge. Jenkins stages Maven images on
   request (`stage-release`) and plain Dockerfile images on every
   merge. Per-merge staging adds one immutable tag per image per
   merge to the snapshot registry, so registry retention needs
   setting either way.
3. **Timestamp format (#31).** Jenkins produces more than one
   format, because each pom or script sets its own: seconds and a
   `Z` in `1.7.0-20200619T121144Z` (`sdc-docker-base`), minutes and
   no `Z` in `5.0.1-20260703T1404` (`policy/docker`) and
   `0.3.2-20260714T0618` (`portal-ng/bff`), and
   `X.Y.Z-SNAPSHOT-<ts>Z` from ONAP's `include-docker-push.sh`.
   `release-job.sh` passes the staged version through verbatim (line
   559) and never parses it. This survey did not check tooling
   outside global-jjb.
4. **Mutable source tags (#109).** 90 ONAP release files
   promote `latest` or a stream tag, so the image released depends on
   what that tag pointed at on the day, not on the file's `ref`.
   Decide whether the GitHub lanes accept such files, warn, or
   reject them.
5. **Release-file name semantics (#30, decided).** Names stay
   relative to an umbrella namespace, as every existing ONAP file
   assumes; `merge.yaml` applies `namespace_mode` to them.

## 6. Observed global-jjb defects

Line numbers refer to `shell/release-job.sh` at v0.96.4 unless
stated.

### 6.1 Confirmed

These follow from the code at the cited lines.

- **D1: container promotion ignores `DRY_RUN`.** The `docker push`
  and `cosign sign` at lines 564-571, and the re-sign at line 553,
  check `JOB_NAME` alone. A `DRY_RUN=true` merge run publishes and
  signs the release images; the git tag push (line 455) is the one
  step that honours the flag.
- **D2: release verify aborts on an already released image.** When
  the release tag exists (line 541), line 546 expands
  `$COSIGN_PUBLIC_KEY`. The release-merge template binds that
  credential (`jjb/lf-release-jobs.yaml:275-284`); the verify
  template (`:35-101`, `:103-143`) does not, and the script runs
  under `set -u` (line 12). Bash aborts on an unbound variable even
  inside `cmd || exit_code=$?`; a local run confirmed it. Not
  observed in a live job, and it does not apply if the Jenkins
  instance defines `COSIGN_PUBLIC_KEY` globally.
- **D3: unverifiable signatures pass.** A cosign exit code other
  than 0 or 10 logs `INFO` and continues (lines 554-556), so a
  release completes with an image whose signature failed to verify.
- **D4: promotion flattens manifest lists.** `docker pull` (line
  559) fetches the node's platform alone, and `docker push` (line
  566) publishes that single image under the release tag. No ONAP or
  ODL job builds multi-architecture images today, so nothing breaks
  yet.
- **D5: ONAP's pin installs an unverified cosign.** At v0.95.0, the
  version ONAP pins, the script downloads cosign from
  `releases/latest` with no checksum. v0.96.x pins
  `COSIGN_VERSION` and checks the checksum (lines 535-539).

### 6.2 Inferred

These depend on conditions this survey did not reproduce.

- **I1: image ID lookup by `grep`.** Line 560 finds the pulled image
  with `docker images | grep "$name" | grep "$version"`. When one
  name contains another and both share a version, and the longer
  name came first in the file, the lookup returns two IDs and the
  `docker tag` fails. `integration/xtesting` 8.0.0 lists
  `xtesting-smoke-usecases-robot` and `...-robot-py3`, both at
  `master`, in the order that avoids it.
- **I2: GitHub-hosted projects abort.** Line 521 reads `$GERRIT_URL`
  without a default under `set -u`; `tag-git-repo` guards the same
  variable (line 338). Gerrit-hosted ONAP and ODL do not hit this.
- **I3: `.wgetrc` removal.** The `lf-maven-install` macro
  (`jjb/lf-macros.yaml:271-279`) creates `$HOME/.wgetrc`, runs Maven,
  then removes it with `rm` and no `-f`. A build failure between
  those steps leaves the file on the node; two builds sharing a
  `$HOME` could race, and the second `rm` would fail its build.
