# Proposal

## Why

Currently, running GitHub Actions self-hosted runners requires manual downloading, unpacking, and interactive configuration on host machines. Providing a containerized Docker image allows users to deploy and run GitHub self-hosted runners easily across different host operating systems (Linux, macOS Docker Desktop, Windows Docker Desktop/WSL2) and CPU architectures (x86_64 and ARM64). Furthermore, users need to register runners at either the Organization or Repository level, run workflows that execute Docker-based Actions (`docker build`, `docker run`, `uses: docker://...`), ensure runner state persists across container restarts without manual re-registration, and seamlessly accelerate CI jobs using self-hosted GitHub Actions Cache Servers (e.g. `gha-cache-server`) without hitting GitHub central limits.

## What Changes

- Introduce a multi-architecture Dockerfile supporting both `linux/amd64` (x86_64) and `linux/arm64` (ARM64), dynamically downloading the official GitHub runner package matching the target architecture.
- Install Docker CLI client and dependencies inside the container image, supporting Docker-outside-of-Docker (DooD via `/var/run/docker.sock` mount) and Docker-in-Docker patterns so workflows can run containerized Actions and Docker commands.
- Add compatibility for GitHub Actions Cache Server (`gha-cache-server`): pre-install `zstd` for high-speed cache compression, apply binary patch to `Runner.Worker.dll` to prevent runner from overriding custom `ACTIONS_RESULTS_URL`, and support `--disableupdate` to prevent auto-updates from undoing the patch.
- Provide an entrypoint startup script (`entrypoint.sh`) that automates runner registration (`./config.sh`) on first run using user-provided URL and Token environment variables (`RUNNER_URL` and `RUNNER_TOKEN`), supporting both Organization-level (e.g. `https://github.com/my-org`) and Repository-level (e.g. `https://github.com/owner/repo`) URLs.
- Support state persistence via a dedicated runner volume/directory mount: detect existing runner credentials (`.runner`, `.credentials`) on startup to directly run `./run.sh` without re-registration upon container restarts.
- Include required system dependencies and tools (curl, tar, git, jq, zstd, certificates, libicu, etc.) needed for GitHub Actions runner execution and standard workflow steps.
- Provide a `docker-compose.yml` and documentation/scripts demonstrating how to build, run, and persist the runner container across architectures with Docker socket integration and optional local GHA Cache Server deployment.

## Capabilities

### New Capabilities

- `runner-container`: Multi-architecture Docker container image build and runtime environment supporting `linux/amd64` and `linux/arm64` with system dependencies, Docker CLI tools, `zstd`, and GHA Cache Server binary patch for GitHub Actions workflows.
- `runner-lifecycle`: Automated runner configuration, registration with GitHub using Organization or Repository URLs and Token, credential persistence across container restarts, Docker socket permission adaptation, Cache Server environment configuration, and signal-handling runtime startup.

### Modified Capabilities

*(None)*

## Impact

- Repository files: Adds `Dockerfile`, `entrypoint.sh`, `docker-compose.yml`, `.dockerignore`, `.env.example`, and `README.md`.
- Runtime dependencies: Requires Docker engine with buildx for multi-architecture builds.
- Security/Operational impact: Short-lived runner registration tokens can be passed safely via environment variables; runner configuration data is stored securely in persistent volumes; Docker socket mounts provide non-root runner user access via dynamic group configuration; custom cache server routing keeps cache artifacts inside private infrastructure.
