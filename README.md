# Docker GitHub Actions Self-Hosted Runner

A containerized, multi-architecture GitHub Actions self-hosted runner supporting Linux (`amd64` and `arm64`), persistent volume configuration, Docker-in-Docker / Docker-outside-of-Docker workflow execution, and native GitHub Actions Cache Server integration.

---

## Features

- **Multi-Architecture Support**: Built for both `linux/amd64` (x86_64) and `linux/arm64` (Apple Silicon, AWS Graviton, Raspberry Pi 4/5).
- **Automated Lifecycle Management**: Automatically configures and registers with GitHub on initial launch using environment variables (`RUNNER_URL` and `RUNNER_TOKEN`).
- **Organization & Repository Support**: Register at either the organization level (e.g. `https://github.com/my-org`) or repository level (e.g. `https://github.com/owner/repo`).
- **State Persistence**: Runner credentials (`.runner`, `.credentials`) and job workspaces (`_work`) persist in a dedicated volume, so container restarts never fail or require re-registration.
- **Docker Workflow Support**: Bundles Docker CLI tools and dynamically adapts permissions to `/var/run/docker.sock` so workflows can run containerized actions and `docker` commands without `sudo`.
- **GHA Cache Server Compatibility**: Pre-installed `zstd` and patched `Runner.Worker.dll` to prevent runner from discarding custom `ACTIONS_RESULTS_URL` cache endpoints.
- **Graceful Termination**: Handles `SIGTERM` / `SIGINT` signals to gracefully stop runner jobs upon `docker stop`.

---

## Prerequisites

- [Docker Engine](https://docs.docker.com/engine/) 20.10+
- [Docker Compose](https://docs.docker.com/compose/) v2+
- (Optional) Docker Buildx for multi-platform image builds

---

## Configuration Variables

Copy `.env.example` to `.env` and fill in your values:

```bash
cp .env.example .env
```

| Variable | Required | Default | Description |
|---|---|---|---|
| `RUNNER_URL` | **Yes** | - | Target URL: repository (`https://github.com/org/repo`) or organization (`https://github.com/org`). |
| `RUNNER_TOKEN` | **Yes** | - | Runner registration token generated from GitHub Settings. |
| `RUNNER_NAME` | No | Container hostname | Unique runner name shown in GitHub UI. |
| `RUNNER_NAME_PREFIX` | No | - | Prefix for runner name when `RUNNER_NAME` is unset (generates `${RUNNER_NAME_PREFIX}${HOSTNAME}`, e.g. `ci-runner-`). |
| `RUNNER_WORKDIR` | No | `/runner/_work` | Work directory for jobs. For DooD, host path must match container path (e.g. `/tmp/github-runner/work`). |
| `RUNNER_LABELS` | No | - | Comma-separated custom labels (e.g. `gpu,docker,self-hosted`). |
| `RUNNER_GROUP` | No | `Default` | Organization runner group (for organization runners). |
| `ACTIONS_RESULTS_URL` | No | - | External GHA Cache Server endpoint (must start with `http://` or `https://`). Trailing slash is enforced automatically. |
| `DISABLE_AUTO_UPDATE` | No | `false` | Disable auto-update from GitHub. Set to `true` automatically if `ACTIONS_RESULTS_URL` is configured. |
| `LOG_LEVEL` | No | `info` | Logging verbosity: `debug`, `info`, `warn`, or `error`. |

---

## Quick Start (Docker Compose)

### 1. Configure Registration Token

Generate a registration token:
- **Repository runner**: Go to `https://github.com/<owner>/<repo>/settings/actions/runners/new`
- **Organization runner**: Go to `https://github.com/organizations/<org>/settings/actions/runners/new`

Edit `.env`:

```env
RUNNER_URL=https://github.com/your-org/your-repo
RUNNER_TOKEN=AXXXXXXXXXXXXXXXXXXXX
RUNNER_NAME=docker-runner-01
RUNNER_LABELS=self-hosted,docker,linux
```

### 2. Start the Runner

```bash
docker compose up -d
```

Check the logs to verify registration and startup:

```bash
docker compose logs -f runner
```

---

## Docker Workflow Execution (DooD)

The runner container mounts `/var/run/docker.sock` from the host. At startup, `entrypoint.sh` reads the socket's host GID, creates a matching group inside the container if needed, and adds the unprivileged `runner` user to it.

> [!IMPORTANT]
> **DooD Workspace Path Matching**:
> When workflows use container actions (such as `container:` jobs or `uses: docker://...`), the runner requests the **host** Docker daemon to bind-mount the job workspace into the newly created job container. If the workspace is inside an isolated Docker volume (like `/runner/_work`), that path does NOT exist on the host filesystem, causing job containers to see an empty directory!
> To resolve this, `RUNNER_WORKDIR` must be bind-mounted from the host using the **identical path on both the host and the container** (e.g. `/tmp/github-runner/work:/tmp/github-runner/work`).
> **Note**: The `--work` directory is permanently recorded at initial registration time in `/runner/.runner`. Changing `RUNNER_WORKDIR` requires removing `/runner/.runner` and re-registering.

Workflows can directly execute:

```yaml
steps:
  - name: Build and push Docker image
    run: |
      docker build -t my-app:latest .
      docker run --rm my-app:latest test
```

Or containerized actions:

```yaml
steps:
  - name: Run container action
    uses: docker://golang:1.22
    with:
      args: go test ./...
```

---

## GitHub Actions Cache Server Integration

To use an external cache server (such as [`falcondev-oss/github-actions-cache-server`](https://github.com/falcondev-oss/github-actions-cache-server)):

1. Launch both the runner and cache server using the `cache` profile:
   ```bash
   docker compose --profile cache up -d
   ```
2. Configure `ACTIONS_RESULTS_URL`:
   ```env
   ACTIONS_RESULTS_URL=http://cache-server:3000/
   ```
3. The image has a binary patch applied to `Runner.Worker.dll` replacing internal `ACTIONS_RESULTS_URL` with `ACTIONS_RESULTS_ORL`, ensuring runner jobs use your private cache endpoint.
4. Auto-update is disabled (`--disableupdate`) to prevent official updates from reverting the binary patch.
5. **Network Reachability Note**: When running container actions via DooD, job containers run directly on the host Docker daemon's bridge network rather than the compose internal network. For job steps inside containers to reach the cache server, ensure `ACTIONS_RESULTS_URL` is set to an address reachable from the host (such as `http://host.docker.internal:3000/` or your host IP).

---

## Building Multi-Architecture Images

To build images locally for both `amd64` and `arm64`:

```bash
# Set up Docker Buildx builder instance
docker buildx create --use --name multiarch-builder

# Build and push or load
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  --build-arg RUNNER_VERSION=2.337.0 \
  -t your-registry/github-runner:latest \
  --push \
  .
```

---

## Persistence Verification

To verify that credentials survive container restarts:

1. Start the container and wait for registration:
   ```bash
   docker compose up -d
   ```
2. Check `docker compose logs runner` to confirm:
   `No existing runner configuration detected. Performing initial registration...`
3. Restart the container:
   ```bash
   docker compose restart runner
   ```
4. Check the logs again to confirm re-registration was skipped:
   `Existing runner configuration detected (.runner file present). Skipping registration.`

---

## Automated CI/CD & Registry Publishing

This repository includes automated workflows for detecting upstream runner updates and publishing multi-architecture images to GitHub Packages (`ghcr.io`) and Docker Hub (`docker.io`).

### 1. Workflow Permissions Setup
Ensure the repository permits automated release creation and package publishing:
1. Go to **Settings** > **Actions** > **General**.
2. Under **Workflow permissions**, select **Read and write permissions**.
3. Check **Allow GitHub Actions to create and approve pull requests**.

### 2. Configure Docker Hub Secrets & Variables (Optional)
If pushing images to Docker Hub in addition to GHCR, configure the following in **Settings** > **Secrets and variables** > **Actions**:
- **Repository Secrets**:
  - `DOCKERHUB_USERNAME`: Your Docker Hub account username.
  - `DOCKERHUB_TOKEN`: A Personal Access Token from Docker Hub with Read & Write permissions.
- **Repository Variables**:
  - `DOCKERHUB_REPOSITORY`: The full target Docker Hub repository name (e.g. `your-user/github-runner`).

> *Note: If any of these credentials/variables are omitted, the workflow will publish to GHCR and safely skip Docker Hub without failing.*

### 3. Pulling Pre-Built Images

#### From GitHub Container Registry (GHCR):
```bash
docker pull ghcr.io/<owner>/<repo>:latest
# Or a specific runner version:
docker pull ghcr.io/<owner>/<repo>:2.337.0
```

#### From Docker Hub:
```bash
docker pull <dockerhub-username>/github-runner:latest
# Or a specific runner version:
docker pull <dockerhub-username>/github-runner:2.337.0
```

### 4. Automated Upstream Check Workflow
- `.github/workflows/check-upstream-runner.yml` runs on a schedule (every 6 hours) or manual dispatch (`workflow_dispatch`).
- When a new stable version of `actions/runner` is released upstream, it automatically tags the repository and creates a GitHub Release.
- Tag creation triggers `.github/workflows/docker-publish.yml`, which compiles multi-arch manifests and publishes images to both registries.

