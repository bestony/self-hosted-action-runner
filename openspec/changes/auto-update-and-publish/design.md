# Design

## Context

The repository provides a containerized environment for GitHub Actions self-hosted runners (`runner-container`, `runner-lifecycle`). Upstream GitHub actively releases updates for `actions/runner`. See `proposal.md` for motivation. This design specifies the automation architecture for monitoring upstream releases, tagging repository releases, and building and publishing multi-platform images to GHCR and Docker Hub.

## Goals / Non-Goals

**Goals:**
- Provide a scheduled GitHub Actions workflow to check upstream `actions/runner` releases and detect new stable versions.
- Automate git tag and GitHub Release creation when a newer runner version is released.
- Provide a multi-platform build workflow using Docker Buildx and QEMU targeting `linux/amd64` and `linux/arm64`.
- Simultaneously push built container images to GitHub Packages (`ghcr.io`) and Docker Hub (`docker.io`).
- Standardize image tagging: semantic runner versions (`2.322.0`, `v2.322.0`), minor aliases (`2.322`), and rolling `latest`.
- Support manual dispatch (`workflow_dispatch`) with optional version overrides for testing or backfilling specific versions.
- Gracefully handle environments without Docker Hub secrets configured.

**Non-Goals:**
- In-place auto-updating of live running containers (updates occur by pulling the new image and recreating containers).
- Supporting non-Linux architectures (e.g. Windows/macOS native runner binaries).

## Decisions

### 1. Workflow Separation: Detection vs. Build & Publish
- **Decision**: Separate the automation into two distinct GitHub Actions workflows:
  1. `check-upstream-runner.yml`: Scheduled (cron every 6 hours) and manual dispatch. Queries the GitHub API for upstream releases, compares against tags in this repository, and creates a new tag/release when an update is found.
  2. `docker-publish.yml`: Triggered by release tags (`v*`) or manual dispatch. Builds multi-architecture images and pushes them to GHCR and Docker Hub.
- **Rationale**: Decoupling discovery from build makes each workflow single-purpose, easier to test, resilient against build failures without losing track of detected versions, and allows manual builds without creating git releases.
- **Alternatives Considered**: A single monolith workflow doing both check and build. Rejected because build failures would complicate release state tracking and prevent independent triggering.

### 2. Upstream Release Query and Tag Comparison
- **Decision**: Use `gh api /repos/actions/runner/releases` (filtering out `draft` and `prerelease`) to identify the latest stable upstream version. Compare the version against existing tags in this repository via `git tag -l`.
- **Rationale**: Official runner releases may have pre-releases or release candidates. Filtering for published stable releases prevents deploying unstable runner software into production environments.

### 3. Build & Multi-Architecture Strategy
- **Decision**: Use `docker/setup-qemu-action` and `docker/setup-buildx-action` to compile for `linux/amd64` and `linux/arm64`. Use GitHub Actions cache (`type=gha`) for Docker layer caching.
- **Rationale**: The Dockerfile downloads platform-specific binary tarballs (`linux-x64` vs `linux-arm64`) based on `TARGETPLATFORM`. QEMU allows single-runner execution across architectures, and GitHub Actions layer caching keeps build times manageable.

### 4. Dual Registry Publishing and Fallback Mechanism
- **Decision**: Authenticate with GHCR using `GITHUB_TOKEN` (`packages: write` permission). Authenticate with Docker Hub using repository secrets `DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN`.
- **Rationale**: GHCR works out-of-the-box in GitHub repositories with zero secret configuration. If Docker Hub secrets are omitted or unconfigured (such as in external forks or initial setup), the workflow issues a warning and pushes only to GHCR instead of failing the entire workflow run.

### 5. Tagging Conventions via `docker/metadata-action`
- **Decision**: Utilize `docker/metadata-action` to generate consistent tags for both registries:
  - Exact runner version: `2.322.0`, `v2.322.0`
  - Minor version floating tag: `2.322`
  - Floating `latest` tag (applied when building the newest stable release)

## Risks / Trade-offs

- **[Risk] QEMU build time for ARM64 on GitHub-hosted x86 runners**
  - *Mitigation*: The container build does not compile code from source; it unpacks pre-compiled runner binaries and installs deb packages. `type=gha` Docker caching further speeds up repeat builds.
- **[Risk] GitHub API rate limiting on scheduled cron**
  - *Mitigation*: The check workflow runs using `GITHUB_TOKEN` with authenticated rate limits (1,000+ requests/hour), and runs once every 6 hours (4 requests/day).
- **[Risk] Docker Hub secret misconfiguration or missing secrets in forks**
  - *Mitigation*: Use conditional checks (`if: env.DOCKERHUB_TOKEN != ''`) so Docker Hub push is skipped gracefully if secrets are not present.
- **[Risk] Runner Dockerfile build argument compatibility**
  - *Mitigation*: Ensure `Dockerfile` defines `ARG RUNNER_VERSION` so the CI workflow can explicitly pass `--build-arg RUNNER_VERSION=${VERSION}` during builds.

## Migration Plan

1. Configure GitHub repository secrets:
   - `DOCKERHUB_USERNAME`: Docker Hub account username
   - `DOCKERHUB_TOKEN`: Docker Hub Personal Access Token (PAT) with Read & Write access
2. Ensure repository workflow permissions allow `Read and write permissions` under **Settings > Actions > General > Workflow permissions**.
3. Trigger an initial run of `docker-publish.yml` via `workflow_dispatch` to publish the current latest runner image.
