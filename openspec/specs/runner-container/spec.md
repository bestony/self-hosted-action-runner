# Runner Container Specification

## Purpose

Provides a containerized runtime environment and multi-architecture Docker image for running GitHub Actions self-hosted runners across Linux, macOS, and Windows hosts, including Docker workflow action execution and external cache server integration.

## Requirements

### Requirement: Multi-Architecture Container Support
The container image SHALL support both `linux/amd64` and `linux/arm64` architectures, downloading the architecture-specific GitHub runner tarball (`linux-x64` or `linux-arm64`) during the build.

#### Scenario: Multi-platform build
- **WHEN** the container image is built with Docker buildx targeting `linux/amd64` and `linux/arm64`
- **THEN** buildx downloads corresponding `linux-x64` and `linux-arm64` runner binaries and produces valid multi-arch image manifests

#### Scenario: Running on ARM64 host
- **WHEN** the container image is launched on an ARM64 host machine
- **THEN** the container starts using the native `linux/arm64` runner binaries

#### Scenario: Running on x86_64 host
- **WHEN** the container image is launched on an x86_64 host machine
- **THEN** the container starts using the native `linux/amd64` runner binaries

### Requirement: Essential Runner Prerequisites
The container image SHALL include all essential system packages and dynamic libraries required by the GitHub Actions runner runtime and typical workflow steps, including `zstd` for cache compression.

#### Scenario: Required utilities available
- **WHEN** commands `curl`, `tar`, `git`, `jq`, `zstd`, and `ca-certificates` are executed inside the container
- **THEN** each command executes successfully with exit code 0

#### Scenario: .NET and runner dynamic libraries present
- **WHEN** the runner executable initializes its .NET runtime dependencies
- **THEN** all prerequisite shared libraries (including libicu and libssl) resolve without runtime errors

### Requirement: Docker Workflow Execution Support
The container image SHALL install Docker CLI tools and support execution of Docker-based GitHub Actions steps and container actions via host Docker socket mounting or containerized Docker daemon.

#### Scenario: Docker CLI client execution
- **WHEN** `docker --version` or `docker compose version` is executed inside the runner container
- **THEN** the command succeeds and reports the installed client version

#### Scenario: Running Docker container actions
- **WHEN** a GitHub Actions workflow executes a container action (e.g. `uses: docker://...` or `docker run`) with `/var/run/docker.sock` mounted
- **THEN** the runner user interacts with Docker daemon and the container action executes successfully

### Requirement: External Cache Server Compatibility
The container image SHALL patch the runner worker library (`Runner.Worker.dll`) to allow retaining custom `ACTIONS_RESULTS_URL` environment variables for external GitHub Actions cache servers.

#### Scenario: Binary patch verification
- **WHEN** the runner image build inspects `Runner.Worker.dll`
- **THEN** the original hardcoded string `ACTIONS_RESULTS_URL` has been patched to `ACTIONS_RESULTS_ORL`, allowing custom cache endpoints to persist during workflow execution

#### Scenario: Workflow caching with external cache server
- **WHEN** `ACTIONS_RESULTS_URL` is set to an external cache server and an `actions/cache` step runs
- **THEN** cache payloads upload to and restore from the specified external cache endpoint instead of GitHub default results receiver

### Requirement: Non-Root Execution Security
The runner process inside the container SHALL execute under an unprivileged user account while retaining read/write access to the runner workspace and access to mounted Docker sockets.

#### Scenario: Runner executes as unprivileged user
- **WHEN** the container entrypoint starts the runner process
- **THEN** the process runs under a non-root UID and has ownership or write access to the runner data directory
