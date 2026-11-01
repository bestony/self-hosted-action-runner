# Spec Delta

## Purpose

Automates detection of upstream GitHub Actions runner releases, coordinates repository release creation, and compiles and publishes multi-architecture container images to both GitHub Packages and Docker Hub.

## ADDED Requirements

### Requirement: Scheduled Upstream Runner Version Detection
The system SHALL periodically query the official GitHub Actions runner (`actions/runner`) releases to detect new stable runner versions and compare them against existing releases in this repository.

#### Scenario: New upstream release detected
- **WHEN** the scheduled version check detects an official `actions/runner` release tag newer than any existing release tag in this repository
- **THEN** the workflow flags the new version and initiates the release and publishing workflow

#### Scenario: Runner versions are up to date
- **WHEN** the scheduled version check finds the latest upstream runner version already exists as a release tag in this repository
- **THEN** the workflow terminates successfully without creating new releases or building images

#### Scenario: Manual check or override
- **WHEN** a user triggers the workflow via manual dispatch with an optional runner version input
- **THEN** the workflow validates the specified version against official releases and proceeds with building that version

### Requirement: Automated Release Tagging
The system SHALL create a git tag and GitHub Release in this repository corresponding to the newly detected runner version, recording release metadata and changelog reference.

#### Scenario: Creating release tag for new runner version
- **WHEN** a new runner version (e.g. `2.322.0`) is identified for publication
- **THEN** a git tag and GitHub Release (e.g. `v2.322.0`) are generated with links to the upstream release notes

### Requirement: Multi-Architecture Image Build Matrix
The build workflow SHALL compile container images for both `linux/amd64` and `linux/arm64` architectures using Docker Buildx and QEMU, injecting the target runner version as a build argument.

#### Scenario: Multi-platform container build
- **WHEN** the publishing workflow builds an image for a specific runner version
- **THEN** Docker Buildx builds native binaries for both `linux/amd64` and `linux/arm64` platforms and bundles them into a multi-arch manifest list

### Requirement: Dual-Registry Image Publishing
The system SHALL publish the compiled multi-architecture container images simultaneously to GitHub Packages Container Registry (`ghcr.io`) and Docker Hub (`docker.io`).

#### Scenario: Simultaneous push to GHCR and Docker Hub
- **WHEN** the build workflow successfully builds the multi-arch images with valid registry credentials
- **THEN** image manifests and architecture layers are pushed to both `ghcr.io` and `docker.io` repositories

#### Scenario: Graceful fallback on missing Docker Hub credentials
- **WHEN** Docker Hub credentials (`DOCKERHUB_USERNAME` or `DOCKERHUB_TOKEN`) are not configured in repository secrets
- **THEN** the workflow publishes images to GHCR, logs a clear informational notice regarding Docker Hub credentials, and does not fail the primary build

### Requirement: Semantic Image Tagging Strategy
The publishing workflow SHALL tag container images across all target registries with semantic version aliases and a floating latest tag.

#### Scenario: Publishing versioned and latest tags
- **WHEN** an image for runner version `2.322.0` is published from a release event
- **THEN** image tags for `2.322.0`, `v2.322.0`, `2.322`, and `latest` are pushed to both target registries pointing to the new multi-arch manifest
