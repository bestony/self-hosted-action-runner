# Design

## Context

See [proposal.md](proposal.md) for motivation.
This project provides a clean, automated container packaging for GitHub Actions self-hosted runners. A standard GitHub Actions runner installation consists of the runner runtime (.NET binaries), configuration files generated upon registration (`.runner`, `.credentials`), and working directories (`_work`, `_diag`).

To run across different platforms (Linux, macOS Docker Desktop, Windows Docker Desktop/WSL2) on both x86_64 and ARM64 architectures, the image must leverage Docker Buildx multi-arch manifests, download the architecture-specific official GitHub runner release, automatically configure and persist runner state without manual intervention, support Docker actions/commands, and seamlessly integrate with self-hosted GitHub Actions Cache Servers (e.g. `gha-cache-server`).

## Goals / Non-Goals

**Goals:**
- Provide a single multi-arch Docker image supporting `linux/amd64` and `linux/arm64`.
- Download architecture-matched official runner tarballs (`linux-x64` and `linux-arm64`) with checksum validation.
- Support both Organization-level (e.g. `https://github.com/my-org`) and Repository-level (e.g. `https://github.com/owner/repo`) registration.
- Enable Docker workflow execution (Docker Actions, `docker build`, `docker run`) by installing Docker CLI tools and providing seamless Docker-outside-of-Docker (DooD) socket mounting with automated GID adaptation.
- Support self-hosted GitHub Actions Cache Server (`gha-cache-server`): install `zstd`, patch `Runner.Worker.dll` to retain custom `ACTIONS_RESULTS_URL`, normalize trailing slashes, and configure `--disableupdate` to preserve patched binaries.
- Automate first-boot registration via `RUNNER_URL` and `RUNNER_TOKEN` environment variables.
- Persist runner credentials and job workspaces across container restarts via volume mounting, ensuring that restarting the container never fails due to expired registration tokens.
- Gracefully handle container lifecycle events (e.g. `docker stop`) by propagating signals to the runner process.
- Provide a ready-to-use `docker-compose.yml` and `.env.example` including optional local cache-server deployment.

**Non-Goals:**
- Emulating macOS or Windows native kernels: The container runs Linux workloads (can be hosted on macOS or Windows hosts via Docker Desktop, but execute as Linux runners).
- Replacing Kubernetes cluster operators (e.g. Actions Runner Controller / ARC): This image is targeted at standalone Docker and Docker Compose host environments.

## Decisions

### 1. Base Operating System: Ubuntu 22.04 LTS
- **Choice**: `ubuntu:22.04` (Jammy).
- **Rationale**: GitHub's runner binaries are officially built and tested on Ubuntu LTS releases. Ubuntu 22.04 offers broad binary compatibility for .NET 6/8 runtime dependencies (libicu, OpenSSL 3), standard CLI utilities, and minimal package drift.
- **Alternatives considered**:
  - `alpine`: Incompatible out-of-the-box with GitHub Actions runner due to musl libc; requires glibc compatibility layers which can be fragile.
  - `debian:bookworm-slim`: Good alternative, but Ubuntu matches official GitHub Actions runner environments closer and simplifies dependency resolution.

### 2. Multi-Architecture Build Matrix using `TARGETARCH`
- **Choice**: Use Docker Buildx build arguments `ARG TARGETARCH` inside the Dockerfile.
  - When `TARGETARCH=amd64` → download `actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz`
  - When `TARGETARCH=arm64` → download `actions-runner-linux-arm64-${RUNNER_VERSION}.tar.gz`
- **Rationale**: Single Dockerfile with Docker Buildx handles multi-architecture builds natively without maintaining separate Dockerfiles per architecture.

### 3. GHA Cache Server Compatibility & Binary Patch
- **Choice**:
  - Pre-install `zstd` in the base image for high-speed cache compression/decompression.
  - During image build, apply the official `gha-cache-server` UTF-16 binary patch to `bin/Runner.Worker.dll`:
    `sed -i 's/\x41\x00\x43\x00\x54\x00\x49\x00\x4F\x00\x4E\x00\x53\x00\x5F\x00\x52\x00\x45\x00\x53\x00\x55\x00\x4C\x00\x54\x00\x53\x00\x5F\x00\x55\x00\x52\x00\x4C\x00/\x41\x00\x43\x00\x54\x00\x49\x00\x4F\x00\x4E\x00\x53\x00\x5F\x00\x52\x00\x45\x00\x53\x00\x55\x00\x4C\x00\x54\x00\x53\x00\x5F\x00\x4F\x00\x52\x00\x4C\x00/g' /opt/runner-dist/bin/Runner.Worker.dll`
  - In `entrypoint.sh`:
    - Ensure `ACTIONS_RESULTS_URL` ends with a trailing slash (`/`).
    - When `ACTIONS_RESULTS_URL` is set or `DISABLE_AUTO_UPDATE=true`, add `--disableupdate` to `./config.sh` so GitHub cannot overwrite the patched DLL via auto-updates.
- **Rationale**: Official runners reset `ACTIONS_RESULTS_URL` unless patched. The patch renames the internal variable to `ACTIONS_RESULTS_ORL`, allowing user-provided `ACTIONS_RESULTS_URL` to route cache queries to the self-hosted cache server.

### 4. Docker Workflow Action Support (Docker-outside-of-Docker / DooD with Dynamic GID)
- **Choice**:
  - Install the official Docker CLI (`docker-ce-cli`), Docker Compose plugin (`docker-compose-plugin`), and Docker Buildx plugin (`docker-buildx-plugin`) in the runner image.
  - Support Docker-outside-of-Docker (DooD) by mounting `/var/run/docker.sock` from the host.
  - In `entrypoint.sh`, if `/var/run/docker.sock` is detected:
    - Inspect the socket file's GID using `stat -c '%g' /var/run/docker.sock`.
    - If no local group has that GID, create one (e.g. `docker-host-group`).
    - Add the unprivileged `runner` user to that group so Docker commands run without `sudo` or permission denied errors.
- **Rationale**: DooD avoids the security and storage overhead of running a full Docker daemon inside the container (DinD), allows workflows to share host image caches, and enables standard GitHub Actions Docker steps (`uses: docker://...` and `docker build/run`) seamlessly.

### 5. Registration Scope: Repository vs. Organization
- **Choice**: Pass `RUNNER_URL` directly to `./config.sh --url "${RUNNER_URL}"`.
  - Organization URL: `https://github.com/${ORG_NAME}`
  - Repository URL: `https://github.com/${OWNER}/${REPO_NAME}`
- **Rationale**: The official GitHub runner `config.sh` accepts either URL format natively, as long as the provided `RUNNER_TOKEN` corresponds to that level (obtained from Repo Settings > Actions > Runners or Org Settings > Actions > Runners).

### 6. Distribution-to-Volume Hydration Pattern for Persistence
- **Choice**:
  - Install runner binaries to `/opt/runner-dist` during image build.
  - Set working directory and volume mount point to `/runner`.
  - In `entrypoint.sh`, if `/runner` does not yet contain runner binaries (e.g. fresh volume mount), copy or populate the runtime files from `/opt/runner-dist`.
  - Persist `.runner`, `.credentials`, and `_work` in `/runner`.
- **Rationale**: If a Docker volume is mounted directly over the runner directory, mounting an empty volume would mask pre-baked files. Populating from `/opt/runner-dist` on first run preserves the pre-installed binaries while ensuring all registered state and credentials persist in the volume across container restarts.

### 7. Registration and Restart Logic in `entrypoint.sh`
- **Choice**:
  - Check if `/runner/.runner` exists:
    - **If exists**: Runner is already configured. Skip `./config.sh` and directly execute `./run.sh`.
    - **If not exists**: Verify `RUNNER_URL` and `RUNNER_TOKEN`. Execute:
      `./config.sh --unattended --url "${RUNNER_URL}" --token "${RUNNER_TOKEN}" --name "${RUNNER_NAME}" --labels "${RUNNER_LABELS}" --replace [extra_flags]`
  - Append `--disableupdate` if `ACTIONS_RESULTS_URL` is configured or `DISABLE_AUTO_UPDATE=true`.

### 8. Signal Trapping and Graceful Termination
- **Choice**: Use bash `trap` in `entrypoint.sh` to forward `SIGTERM` and `SIGINT` to the runner child process (`./run.sh`), followed by `wait "$PID"`.
- **Rationale**: Docker sends `SIGTERM` on `docker stop`. Forwarding ensures GitHub Actions runner finishes or cancels current listener requests without being abruptly `SIGKILL`ed after the 10-second timeout.

## Risks / Trade-offs

- **[Risk] Disabled Auto-Update Maintenance**: Because `--disableupdate` prevents GitHub's automatic in-place runner updates, runners could eventually fall behind GitHub's supported version window (~30 days).
  - *Mitigation*: Clearly document that users should periodically pull updated container images (or trigger automated image rebuilds) to track new runner releases.
- **[Risk] Docker Socket Access Security**: Giving a container access to `/var/run/docker.sock` allows root-equivalent access to the host Docker daemon.
  - *Mitigation*: Clearly document that this runner should be deployed on trusted hosts/VMs, consistent with GitHub's security recommendations for self-hosted runners.
- **[Risk] Host Volume Permissions**: Mounted volume directories from the host may have root ownership, preventing the unprivileged `runner` user from writing credentials.
  - *Mitigation*: Entrypoint entry script runs initial permission checks and directory preparation before dropping privileges or ensures `runner` UID ownership.
