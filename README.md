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
- **Shared Cache Server**: Optionally deploys and configures `ghcr.io/falcondev-oss/github-actions-cache-server:latest` with automatic DooD host IP detection.
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

### Interactive Example (Default)

Run the command without any `GHR_*` variables or flags. The installer reads your answers from the terminal (`/dev/tty`), so this works through `curl | bash`. Press Enter to accept a default value. The token input is hidden.

```text
$ curl -fsSL https://raw.githubusercontent.com/bestony/self-hosted-action-runner/main/install.sh | bash

==> [3/6] Collecting configuration
Enter installation directory [default: /home/me/github-runner]:

--- Configuring Runner #1 ---
GitHub Repository or Organization URL (e.g. https://github.com/org/repo): https://github.com/my-org/repo-a
GitHub Runner Registration Token:
Runner name prefix [default: repo-a-]:
Runner labels (comma-separated) [default: self-hosted,linux,docker]:
Number of runner instances for this target (to run jobs concurrently) [default: 1]: 2
Add another repository/org runner? [y/N]: y

--- Configuring Runner #2 ---
GitHub Repository or Organization URL (e.g. https://github.com/org/repo): https://github.com/my-org
GitHub Runner Registration Token:
Runner name prefix [default: my-org-]:
Runner labels (comma-separated) [default: self-hosted,linux,docker]:
Number of runner instances for this target (to run jobs concurrently) [default: 1]: 1
Add another repository/org runner? [y/N]:

--- Cache Server Configuration ---
Enable shared GitHub Actions cache server? [Y/n]:
Select cache URL mode: [1] Internal (http://cache-server:3000) or [2] Host IP (reachable by container jobs) [default: 1]:
Runner container image [default: ghcr.io/bestony/self-hosted-action-runner:latest]:

(configuration summary, tokens masked)
Write configuration and continue? [Y/n]:
```

Get a registration token from **Settings > Actions > Runners > New self-hosted runner** of the repository or organization. The token expires after 1 hour, but the runner needs it only for the first registration.

If you run the installer again with the same directory, it shows the configured runners and asks you to choose `[A]dd runners`, `[R]econfigure from scratch` or `[Q]uit`.

### Non-Interactive Example (CI / Automation)

Use `--non-interactive` only when no person is at the terminal. In this mode the installer reads the `GHR_*` variables and does not ask questions. Without `--non-interactive`, the installer asks for all values and ignores the `GHR_*` variables (only `GHR_DEBUG=1` applies in both modes).

```bash
curl -fsSL https://raw.githubusercontent.com/bestony/self-hosted-action-runner/main/install.sh | \
  GHR_RUNNER_1_URL="https://github.com/my-org/repo-a" \
  GHR_RUNNER_1_TOKEN="YOUR_REPO_A_TOKEN" \
  GHR_RUNNER_1_INSTANCES=2 \
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
  runner-1: &runner-base
    build:
      context: .
      dockerfile: Dockerfile
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
      - RUNNER_EXTRA_APT_PACKAGES=${RUNNER_EXTRA_APT_PACKAGES:-}
      - RUNNER_WRITABLE_PATHS=${RUNNER_WRITABLE_PATHS:-}
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
      - RUNNER_EXTRA_APT_PACKAGES=${RUNNER_EXTRA_APT_PACKAGES:-}
      - RUNNER_WRITABLE_PATHS=${RUNNER_WRITABLE_PATHS:-}
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
#   ports:
#     - "${CACHE_PORT:-3000}:3000"
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
  runner_3_data:
  runner_4_data:
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
   # Start single runner instance (default)
   docker compose up -d

   # Start 2 concurrent runner instances
   docker compose --profile multi up -d

   # Scale to 4 concurrent runner instances
   docker compose --profile scale up -d

   # Start runner with cache server
   docker compose --profile cache up -d
   ```
4. View runner logs:
   ```bash
   docker compose logs -f
   ```

---

## 4. Running Multiple Independent Stacks on One Host

You can run multiple independent runner stacks on the same host machine (for different teams, environments, or projects) without collisions:

- **Project Names**: Each stack uses a unique Docker Compose project name (via `COMPOSE_PROJECT_NAME` in `.env` or top-level `name:` in `docker-compose.yml`). The installer automatically generates deterministic, collision-free project names (`ghr-<dir>-<sha256:8>`).
- **Container Names**: Static `container_name` attributes are omitted. Containers are dynamically named `<project>-<service>-<index>` by Compose.
- **Network Isolation**: Each stack creates an isolated bridge network, preventing DNS or routing cross-talk.
- **Volume & Credential Isolation**: Named volumes (e.g. `runner_data`, `cache_data`) are scoped per project, ensuring runner credentials and SQLite databases never conflict.
- **Workspace Parity**: Job workspaces use directory-scoped paths (`${PWD}/work/<runner>` or `<install_dir>/work/runner-<n>`), ensuring Docker-outside-of-Docker (DooD) host mounts do not collide.
- **Cache Ports**: In default internal mode, runners reach cache services over the internal project network without binding any host ports. In host-IP mode, distinct host ports are published.

---

## 5. Hosted-Runner Compatibility

Marketplace actions are written for the GitHub-hosted runner images. They rely on conventions that a bare self-hosted container does not have. A missing convention causes errors such as `EACCES: permission denied, mkdir '/opt/hostedtoolcache'` (`ruby/setup-ruby`, `actions/setup-python`) or `EACCES: permission denied, stat '/root/.gitconfig'` (`actions/checkout`).

The image supplies these conventions as a contract. The container examines the contract at each start.

| Convention | What the image supplies |
|---|---|
| Runner identity | The runner process runs as the unprivileged `runner` user with `HOME=/home/runner` and passwordless `sudo`. |
| Tool cache | `RUNNER_TOOL_CACHE` and `AGENT_TOOLSDIRECTORY` are `/opt/hostedtoolcache`. The `runner` user owns the directory. Installed tools are kept in the `/runner` volume (`/runner/_tool-cache`), so a new container does not download them again. |
| Workspace ownership | A job hook (`/opt/runner-hooks/fix-workspace-ownership.sh`) gives root-owned files in the job workspace, `RUNNER_TEMP` and the tool cache back to the `runner` user before and after each job. |
| Baseline tools | Docker CLI with the Buildx and Compose plugins (through `/var/run/docker.sock`), GitHub CLI (`gh`), `git`, `git-lfs`, `curl`, `wget`, `jq`, `zip`, `unzip`, `xz`, `zstd`, `rsync`, `openssh-client`, `python3`. |
| Native builds | `build-essential`, `pkg-config` and the headers `libssl-dev`, `libyaml-dev`, `libffi-dev`, `libreadline-dev`, `libgmp-dev`, `zlib1g-dev`. Ruby gems, Node.js addons and Python wheels with native code can be compiled. |
| Locale | `LANG=C.UTF-8`. |

`gh` needs a token in the job, for example `env: GH_TOKEN: ${{ github.token }}`. To install a system package in one workflow only, use `sudo apt-get update && sudo apt-get install -y <package>` in a step, as on a hosted runner.

### Extension Points

If a workflow needs something that the image does not supply, change the container configuration. An image rebuild is not necessary.

| Variable | Default | Description |
|---|---|---|
| `RUNNER_EXTRA_APT_PACKAGES` | - | apt packages to install when the container starts (separated by spaces or commas), for example `libpq-dev libsqlite3-dev`. |
| `RUNNER_WRITABLE_PATHS` | - | Colon-separated absolute paths. The container creates each directory and gives it to the `runner` user. System directories such as `/usr` are refused. |
| `RUNNER_INIT_DIR` | `/opt/runner-init.d` | Each `*.sh` file in this directory runs with `bash` before the runner starts. Mount your scripts into this directory. |
| `RUNNER_TOOL_CACHE` | `/opt/hostedtoolcache` | Tool cache path. Do not change it unless it is necessary: prebuilt Ruby and Python binaries embed the default path. |
| `RUNNER_TOOL_CACHE_PERSIST` | `true` | Set to `false` to keep the tool cache in the container filesystem. A volume that you mount at the tool cache path is always used as-is. |
| `FIX_WORKSPACE_OWNERSHIP` | `true` | Set to `false` to disable the ownership hook. |
| `ACTIONS_RUNNER_HOOK_JOB_STARTED` | ownership hook | Set your own script to replace the job-started hook. |
| `ACTIONS_RUNNER_HOOK_JOB_COMPLETED` | ownership hook | Set your own script to replace the job-completed hook. |

A problem in an extension point does not stop the runner. The container log shows a warning.

### Diagnostics

The entrypoint runs `runner-doctor` as the `runner` user before the runner starts. If a convention is not satisfied, the container log shows a `FAIL` line with the cause. To get the full report from a container that is in operation:

```bash
docker exec -u runner <container> runner-doctor
```

### Parallel Jobs

To run matrix jobs in parallel, register more than one runner: run the installer again in the same directory and choose `[A]dd runners`. One runner executes one job at a time.

---

## 6. More Information

For comprehensive documentation, refer to:
- [development.md](development.md): Architecture details, environment variable reference, DooD workspace setup, multi-platform image builds, Kubernetes / CapRover deployments, and CI/CD automation.
- [GitHub Repository](https://github.com/bestony/self-hosted-action-runner): Source code, release notes, and issue tracker.
