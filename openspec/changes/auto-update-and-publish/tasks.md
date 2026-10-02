# Tasks

## 1. Upstream Version Detection & Release Tagging Workflow

- [ ] 1.1 Create upstream version check workflow (`.github/workflows/check-upstream-runner.yml`) running on a cron schedule and `workflow_dispatch` that queries GitHub API for the latest stable `actions/runner` release, compares it with repository tags, and outputs new version targets. Verify workflow schema and step definitions.
- [ ] 1.2 Implement automated tag and GitHub Release creation logic within the check workflow using `GITHUB_TOKEN` when an unreleased runner version is detected. Verify tag generation formats (`v*.*.*`) and release notes linking.
- [ ] 1.3 Add manual workflow dispatch input parameters to allow manual release triggering and custom runner version overrides. Verify dispatch parameter validation and output generation.

## 2. Multi-Architecture Build & Dual-Registry Publishing Pipeline

- [ ] 2.1 Parameterize runner version in `Dockerfile` with `ARG RUNNER_VERSION` to ensure CI can build arbitrary runner versions dynamically. Verify Docker build argument parsing.
- [ ] 2.2 Create container build and publishing workflow (`.github/workflows/docker-publish.yml`) triggered on tag push (`v*`) and manual dispatch, configuring QEMU and Docker Buildx with GitHub Actions layer cache (`type=gha`). Verify workflow triggers and build configuration.
- [ ] 2.3 Configure registry authentication for GitHub Container Registry (`ghcr.io`) via `GITHUB_TOKEN` and Docker Hub (`docker.io`) via repository secrets, including conditional skipping with warning if Docker Hub secrets are missing. Verify credential handling and conditional steps.
- [ ] 2.4 Configure `docker/metadata-action` to generate multi-registry image tags for semantic versioning (`2.322.0`), git tag (`v2.322.0`), minor version (`2.322`), and rolling `latest`. Verify metadata configuration.

## 3. Documentation & Workflow Verification

- [ ] 3.1 Update `README.md` with instructions on repository secret configuration (`DOCKERHUB_USERNAME`, `DOCKERHUB_TOKEN`), workflow permissions setup, and usage examples for pulling images from both GHCR and Docker Hub. Verify documentation accuracy.
- [ ] 3.2 Verify workflow YAML syntax and trigger conditions across all workflow files. Verify all actions and steps parse cleanly without syntax errors.
