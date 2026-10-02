# Docker GitHub Actions Self-Hosted Runner

A containerized, multi-architecture GitHub Actions self-hosted runner with Docker workflow support (Docker-outside-of-Docker) and GitHub Actions Cache Server integration.

- **GitHub Repository**: [https://github.com/bestony/self-hosted-action-runner](https://github.com/bestony/self-hosted-action-runner)
- **Docker Hub Repository**: [https://hub.docker.com/r/bestony/self-hosted-runner](https://hub.docker.com/r/bestony/self-hosted-runner)

---

## One-Line Interactive Installer

The easiest way to deploy single or multi-repository runners with an optional shared Actions Cache Server:

```bash
curl -fsSL https://raw.githubusercontent.com/bestony/self-hosted-action-runner/main/install.sh | bash
```

### What It Does
- **Preflight & Dependencies**: Checks for Docker Engine, Docker Compose v2, and reachable daemon. Offers automated installation on Linux (via `get.docker.com`) and Homebrew setup on macOS.
- **Interactive Configuration**: Prompts for repository/organization URLs, hidden registration tokens, runner prefixes, and labels. Supports configuring multiple runners in one deployment.
- **Shared Cache Server**: Optionally deploys and configures `ghcr.io/falcondev-oss/github-actions-cache-server:9.8.0` with automatic DooD host IP detection.
- **Deterministic Compose & Security**: Generates `docker-compose.yml` and `.env` with strict `chmod 600` permissions. Tokens are never inlined into Compose files.
- **Automatic Health & Log Verification**: Starts the stack and tails registration logs to verify runner connectivity with GitHub.

### Installer CLI Flags
- `--dir <path>`: Target directory (default: `/opt/github-runner` for root, `$HOME/github-runner` for non-root).
- `--non-interactive`: Automate deployment without interactive prompts using `GHR_*` environment variables.
- `--no-start`: Generate configuration files and directory structure without starting containers.
- `--skip-docker-install`: Skip automatic Docker and Compose plugin installation attempts.
- `--uninstall`: Stop containers and prompt to delete persistent volumes.
- `--debug`: Enable verbose debug logging.
- `-h, --help`: Show help text and options.

### Non-Interactive Example (CI / Automation)
```bash
curl -fsSL https://raw.githubusercontent.com/bestony/self-hosted-action-runner/main/install.sh | \
  GHR_RUNNER_1_URL="https://github.com/my-org/repo-a" \
  GHR_RUNNER_1_TOKEN="YOUR_REPO_A_TOKEN" \
  GHR_RUNNER_2_URL="https://github.com/my-org/repo-b" \
  GHR_RUNNER_2_TOKEN="YOUR_REPO_B_TOKEN" \
  GHR_CACHE=1 \
  bash -s -- --non-interactive --dir /opt/github-runner
```

---

## Deployment Options Matrix

| Topology | Docker Compose | CapRover | Kubernetes |
|---|---|---|---|
| **Single Runner** | [docker-compose.yml](docker-compose.yml) | [Single App Guide](deployments/caprover/README.md) | [Deployment + PVC](deployments/kubernetes/README.md#option-b-single-runner-deployment) |
| **Multi-Runner (Independent)** | [docker-compose.multi.yml](deployments/docker-compose/docker-compose.multi.yml) | [Multi-App Setup](deployments/caprover/README.md#option-b-independent-single-runner-apps) | [StatefulSet Cluster](deployments/kubernetes/README.md#option-a-scalable-cluster-statefulset) |
| **Multi-Runner + Shared Cache** | [Multi-Repo Cache Compose](deployments/docker-compose/multi-repo-cache/README.md) | [One-Click App Template](deployments/caprover/multi-repo-cache/README.md) | [Kustomize Manifests](deployments/kubernetes/multi-repo-cache/README.md) |

---

## 1. Quick Start (Manual Single Container)

To start a single runner container quickly, use `docker run`.

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

The runner configures itself, registers with GitHub, and begins listening for jobs.
Runner credentials persist in the `runner_data` volume. Container restarts do not require re-registration.

---

## 2. Using with Cache Server

This image supports an external GitHub Actions Cache Server (such as [falcondev-oss/github-actions-cache-server](https://github.com/falcondev-oss/github-actions-cache-server)).
The runner image includes a binary patch for `ACTIONS_RESULTS_URL` and bundles `zstd` for fast compression.

### How to Enable Cache

Set the `ACTIONS_RESULTS_URL` environment variable:

```bash
docker run -d \
  --name github-runner \
  --restart unless-stopped \
  -e RUNNER_URL="https://github.com/your-org/your-repo" \
  -e RUNNER_TOKEN="YOUR_REGISTRATION_TOKEN" \
  -e ACTIONS_RESULTS_URL="http://cache-server:3000/" \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v runner_data:/runner \
  bestony/self-hosted-runner:latest
```

When `ACTIONS_RESULTS_URL` is configured:
1. `actions/cache` workflow steps save and restore cache directly with your cache server.
2. Official auto-updates are disabled (`--disableupdate`) to prevent overwriting the internal cache patch.
3. If workflows execute container actions, ensure `ACTIONS_RESULTS_URL` uses an address reachable from the host (such as `http://host.docker.internal:3000/` or your server IP).

---

## 3. Docker Compose File

You can manage the runner and the cache server together with Docker Compose.

### `docker-compose.yml`

```yaml
services:
  runner:
    image: bestony/self-hosted-runner:latest
    container_name: github-runner
    restart: unless-stopped
    environment:
      - RUNNER_URL=${RUNNER_URL}
      - RUNNER_TOKEN=${RUNNER_TOKEN}
      - RUNNER_NAME=${RUNNER_NAME:-}
      - RUNNER_LABELS=${RUNNER_LABELS:-self-hosted,docker,linux}
      - RUNNER_WORKDIR=${RUNNER_WORKDIR:-/tmp/github-runner/work}
      - ACTIONS_RESULTS_URL=${ACTIONS_RESULTS_URL:-}
      - LOG_LEVEL=${LOG_LEVEL:-info}
    volumes:
      - runner_data:/runner
      - /var/run/docker.sock:/var/run/docker.sock
      - ${RUNNER_WORKDIR:-/tmp/github-runner/work}:${RUNNER_WORKDIR:-/tmp/github-runner/work}
    depends_on:
      cache-server:
        condition: service_started
        required: false

  cache-server:
    image: ghcr.io/falcondev-oss/github-actions-cache-server:9.8.0
    container_name: github-actions-cache-server
    restart: unless-stopped
    ports:
      - "3000:3000"
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

volumes:
  runner_data:
  cache_data:
```

### Usage Instructions

1. Create a `.env` file:
   ```bash
   cp .env.example .env
   ```
2. Configure `RUNNER_URL` and `RUNNER_TOKEN` in `.env`.
3. Start the services:
   ```bash
   # Start runner only
   docker compose up -d

   # Start runner with cache server
   docker compose --profile cache up -d
   ```
4. View runner logs:
   ```bash
   docker compose logs -f runner
   ```

---

## 4. More Information

For comprehensive documentation, refer to:
- [development.md](development.md): Architecture details, environment variable reference, DooD workspace setup, multi-platform image builds, Kubernetes / CapRover deployments, and CI/CD automation.
- [GitHub Repository](https://github.com/bestony/self-hosted-action-runner): Source code, release notes, and issue tracker.
