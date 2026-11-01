# Docker GitHub Actions Self-Hosted Runner

A containerized, multi-architecture GitHub Actions self-hosted runner with Docker workflow support (Docker-outside-of-Docker) and GitHub Actions Cache Server integration.

**Languages:** [English](README.md) | [简体中文](README.zh-CN.md) | [日本語](README.ja.md) | [Español](README.es.md)

- **GitHub Repository**: [https://github.com/bestony/self-hosted-action-runner](https://github.com/bestony/self-hosted-action-runner)
- **Docker Hub Repository**: [https://hub.docker.com/r/bestony/self-hosted-runner](https://hub.docker.com/r/bestony/self-hosted-runner)

<img src="https://mobile.thematrixcrop.com/p/cKRqSiJRg" width="1" height="1" alt="" />

---

## Why This Project? (Comparison)

| Dimension | GitHub-Hosted Runner | Native Self-Hosted Runner | This Project |
|---|---|---|---|
| **Cost & Minutes** | Billed per minute on private repos ($0.008+/min). | Free run time on your hardware. | **Free run time** on your own hardware / cloud servers. |
| **Hardware & Architecture** | Fixed configurations (mostly 2 vCPUs). ARM / high-spec runners are costly. | Depends on host machine, but setup is manual. | **Full control** over CPU/RAM. Native multi-arch support (`amd64`, `arm64` / Apple Silicon / Raspberry Pi). |
| **Deployment & Lifecycle** | Managed by GitHub (zero maintenance). | Complex manual steps (download tarball, configure systemd, manage dependencies). | **One-line installer** (`curl \| bash`). Auto Docker / Podman (Quadlet) detection and clean service management. |
| **Actions Cache (`actions/cache`)** | 10 GB limit per repository; slower remote download/upload. | No built-in local cache server (requires complex S3 / MinIO setup or fails). | **Built-in shared cache server** with binary patch and `zstd` compression. High-speed local disk caching with no repository limit. |
| **Host Cleanliness & Security** | Ephemeral clean VM for each job. | Executes directly on host OS. Pollutes host packages and risks leftover artifacts. | **Containerized isolation**. Workflows run via Docker-outside-of-Docker (DooD) without polluting host environment. |
| **File Permissions** | Handled automatically by GitHub. | Frequent permission errors when Docker tasks generate root-owned files on host. | **Automatic permission repair**. Built-in job hook reclaims root-owned files for the `runner` user automatically. |
| **Multi-Repo & Multi-Runner** | High concurrency built-in (subject to plan). | Laborious manual setup for each runner instance in separate directories. | **Single-command multi-runner setup**. Support for multiple repositories and scaling via Compose profiles or Podman. |
| **Marketplace Actions Compatibility** | 100% compatible. | Frequent failures due to missing toolcache (`/opt/hostedtoolcache`) or basic tools. | **Full compatibility contract**. Includes pre-configured toolcache, build tools, passwordless sudo, and `runner-doctor` diagnostics. |

---

## 1. One-Line Interactive Installer

The easiest way to deploy single or multi-repository runners with an optional shared Actions Cache Server:

```bash
curl -fsSL https://raw.githubusercontent.com/bestony/self-hosted-action-runner/main/install.sh | bash
```

### Highlights
- **Preflight & Automatic Setup**: Detects Docker Engine and Compose v2; installs dependencies automatically on Linux and macOS.
- **Interactive Configuration**: Prompts for repository/organization URLs, hidden registration tokens, runner names, and labels. Supports configuring multiple runners in one pass.
- **Shared Cache Server**: Deploys an integrated cache server (`falcondev-oss/github-actions-cache-server`) with automatic DooD host IP resolution.
- **Safe & Deterministic**: Creates `docker-compose.yml` and `.env` with strict `chmod 600` permissions. Registration tokens are never written into Compose files.

### Key Flags
- `--dir <path>`: Target installation directory (default: `/opt/github-runner` or `$HOME/github-runner`).
- `--non-interactive`: Automate deployment without interactive prompts using `GHR_*` environment variables.
- `--no-start`: Generate configuration files without starting containers.
- `--uninstall`: Stop containers and prompt to delete persistent volumes.

> For Linux hosts using Podman instead of Docker, use our Podman Quadlet installer:
> ```bash
> curl -fsSL https://raw.githubusercontent.com/bestony/self-hosted-action-runner/main/install-podman.sh | sudo bash
> ```
> See [deployments/podman/README.md](deployments/podman/README.md) for complete details.

---

## 2. Docker Quick Start (Manual Single Container)

To start a single runner container quickly without the installer:

### Step 1: Obtain a Registration Token
Generate a runner registration token from your GitHub repository or organization:
- **Repository**: Go to `Settings` > `Actions` > `Runners` > `New runner`.
- **Organization**: Go to `Organization Settings` > `Actions` > `Runners` > `New runner`.

### Step 2: Run the Container
Run this command on your host:

```bash
docker run -d \
  --name github-runner \
  --restart unless-stopped \
  -e RUNNER_URL="https://github.com/your-org/your-repo" \
  -e RUNNER_TOKEN="YOUR_REGISTRATION_TOKEN" \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v runner_data:/runner \
  bestony/self-hosted-runner:latest
```

The runner configures itself, registers with GitHub, and begins listening for jobs. Credentials persist in the `runner_data` volume. Container restarts do not require re-registration.

---

## 3. Docker Compose Deployment

You can manage runners and an optional cache server together using Docker Compose:

### `docker-compose.yml`

```yaml
services:
  runner-1: &runner-base
    image: bestony/self-hosted-runner:latest
    restart: unless-stopped
    environment:
      - RUNNER_URL=${RUNNER_URL}
      - RUNNER_TOKEN=${RUNNER_TOKEN}
      - RUNNER_NAME=${RUNNER_NAME_1:-${RUNNER_NAME:-}}
      - RUNNER_NAME_PREFIX=${RUNNER_NAME_PREFIX_1:-${RUNNER_NAME_PREFIX:-runner-1-}}
      - RUNNER_LABELS=${RUNNER_LABELS:-}
      - RUNNER_GROUP=${RUNNER_GROUP:-}
      - RUNNER_WORKDIR=${RUNNER_WORKDIR_1:-${RUNNER_WORKDIR:-${PWD}/work/runner-1}}
      - ACTIONS_RESULTS_URL=${ACTIONS_RESULTS_URL:-}
      - DISABLE_AUTO_UPDATE=${DISABLE_AUTO_UPDATE:-}
      - LOG_LEVEL=${LOG_LEVEL:-info}
      - FIX_WORKSPACE_OWNERSHIP=${FIX_WORKSPACE_OWNERSHIP:-true}
    volumes:
      - runner_1_data:/runner
      - /var/run/docker.sock:/var/run/docker.sock
      - ${RUNNER_WORKDIR_1:-${RUNNER_WORKDIR:-${PWD}/work/runner-1}}:${RUNNER_WORKDIR_1:-${RUNNER_WORKDIR:-${PWD}/work/runner-1}}
    depends_on:
      cache-server:
        condition: service_started
        required: false

  runner-2:
    <<: *runner-base
    environment:
      - RUNNER_URL=${RUNNER_URL}
      - RUNNER_TOKEN=${RUNNER_TOKEN}
      - RUNNER_NAME=${RUNNER_NAME_2:-}
      - RUNNER_NAME_PREFIX=${RUNNER_NAME_PREFIX_2:-${RUNNER_NAME_PREFIX:-runner-2-}}
      - RUNNER_LABELS=${RUNNER_LABELS:-}
      - RUNNER_GROUP=${RUNNER_GROUP:-}
      - RUNNER_WORKDIR=${RUNNER_WORKDIR_2:-${PWD}/work/runner-2}
      - ACTIONS_RESULTS_URL=${ACTIONS_RESULTS_URL:-}
      - DISABLE_AUTO_UPDATE=${DISABLE_AUTO_UPDATE:-}
      - LOG_LEVEL=${LOG_LEVEL:-info}
      - FIX_WORKSPACE_OWNERSHIP=${FIX_WORKSPACE_OWNERSHIP:-true}
    volumes:
      - runner_2_data:/runner
      - /var/run/docker.sock:/var/run/docker.sock
      - ${RUNNER_WORKDIR_2:-${PWD}/work/runner-2}:${RUNNER_WORKDIR_2:-${PWD}/work/runner-2}
    profiles:
      - multi
      - scale
      - all

  cache-server:
    image: ghcr.io/falcondev-oss/github-actions-cache-server:latest
    restart: unless-stopped
    environment:
      API_BASE_URL: ${CACHE_API_BASE_URL:-http://cache-server:3000}
      STORAGE_DRIVER: filesystem
      STORAGE_FILESYSTEM_PATH: /data/cache
      DB_DRIVER: sqlite
      DB_SQLITE_PATH: /data/cache-server.db
    volumes:
      - cache_data:/data
    profiles:
      - cache
      - full
      - all

volumes:
  runner_1_data:
  runner_2_data:
  cache_data:
```

### Usage Instructions

1. **Prepare configuration**:
   ```bash
   cp .env.example .env
   # Edit RUNNER_URL and RUNNER_TOKEN in .env
   ```

2. **Start services**:
   ```bash
   # Start single runner (default)
   docker compose up -d

   # Start 2 concurrent runners
   docker compose --profile multi up -d

   # Start runner with shared Actions Cache Server
   docker compose --profile cache up -d
   ```

3. **Check logs**:
   ```bash
   docker compose logs -f
   ```

---

## 4. Documentation & Advanced Topics

For specialized deployments, architectural specifications, and operations guides, refer to:

| Topic | Document | Description |
|---|---|---|
| **Podman + systemd** | [deployments/podman/README.md](deployments/podman/README.md) | Quadlet unit generation, systemd boot lifecycle, egress firewall rules, and cache modes. |
| **Shared Cache Server** | [deployments/docker-compose/multi-repo-cache/README.md](deployments/docker-compose/multi-repo-cache/README.md) | Shared cache architecture, DooD host IP routing, and `actions/cache` acceleration. |
| **Multi-Stack Isolation** | [deployments/docker-compose/README.md](deployments/docker-compose/README.md) | Running multiple independent stacks on a single host without volume or network collisions. |
| **Kubernetes Deployment** | [deployments/kubernetes/README.md](deployments/kubernetes/README.md) | Scalable StatefulSet clusters, Deployment + PVC manifests, and Kustomize setups. |
| **CapRover PaaS** | [deployments/caprover/README.md](deployments/caprover/README.md) | One-click app templates and independent single/multi-runner configurations. |
| **Compatibility Contract** | [development.md#8-hosted-runner-compatibility-contract](development.md#8-hosted-runner-compatibility-contract) | Toolcache standards (`/opt/hostedtoolcache`), `runner-doctor` diagnostics, and permission hooks. |
| **Development & Env Reference** | [development.md](development.md) | Complete environment variable table, DooD workspace setup, and multi-arch image builds. |
