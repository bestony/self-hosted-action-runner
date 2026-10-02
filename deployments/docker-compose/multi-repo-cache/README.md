# Multi-Repository GitHub Runners with Shared Cache Server

This deployment runs multiple GitHub Actions self-hosted runner containers alongside a shared GitHub Actions Cache Server on a single Docker host.

---

## Architecture Overview

```
                      ┌────────────────────────────────────────┐
                      │              Docker Host               │
                      │                                        │
                      │  ┌──────────────────────────────────┐  │
                      │  │   github-actions-cache-server    │  │
                      │  │   (falcondev-oss/cache-server)   │  │
                      │  └─────────────────▲────────────────┘  │
                      │                    │                   │
                      │          ACTIONS_RESULTS_URL           │
                      │         (internal or host IP)          │
                      │                    │                   │
                      │         ┌──────────┴──────────┐        │
                      │         │                     │        │
                      │  ┌──────┴───────┐      ┌──────┴───────┐│
                      │  │ runner-repo-a│      │ runner-repo-b││
                      │  │ (Volume A)   │      │ (Volume B)   ││
                      │  └──────┬───────┘      └──────┬───────┘│
                      │         │                     │        │
                      │         └──────────┬──────────┘        │
                      │                    ▼                   │
                      │          /var/run/docker.sock          │
                      │         (Host Docker Daemon)           │
                      └────────────────────────────────────────┘
```

### Key Principles

1. **Dedicated Runner State**: Each runner container maintains its own isolated persistent volume (`runner_a_data`, `runner_b_data`) for credentials and state. Do not share runner volumes.
2. **Dedicated Workspace Directories**: Each runner binds its own dedicated host directory (`REPO_A_WORKDIR`, `REPO_B_WORKDIR`). For Docker-outside-of-Docker (DooD), the host path must match the container path exactly.
3. **Shared Cache Server**: A single cache server instance is shared across all runners. Cache entries are isolated by repository inside the GitHub Actions OIDC runtime token.
4. **Trust Boundary**: Runners sharing the host Docker daemon share the same security boundary. Only co-locate repositories that trust each other.

---

## Quick Start

### 1. Prepare Environment File

Copy `.env.example` to `.env`:

```bash
cp .env.example .env
```

### 2. Configure Runner Tokens and URLs

Edit `.env` and configure:
- `REPO_A_URL` and `REPO_A_TOKEN`: Registration URL and token for the first repository.
- `REPO_B_URL` and `REPO_B_TOKEN`: Registration URL and token for the second repository.
- Registration tokens are obtained from GitHub:
  - Repository: `Settings` > `Actions` > `Runners` > `New self-hosted runner`
  - Organization: `Organization Settings` > `Actions` > `Runners` > `New runner`

> [!NOTE]
> Registration tokens expire after one hour. Tokens are only needed for the initial registration. Once registered, credentials persist in the dedicated volume.

### 3. Start the Stack

```bash
docker compose up -d
```

### 4. Verify Runner Status

```bash
# Check container status and health
docker compose ps

# View runner logs
docker compose logs -f runner-repo-a runner-repo-b
```

---

## Important Networking Caveat for `container:` Jobs

Normal workflow steps run inside the runner container and communicate with the cache server using Docker internal DNS:

```env
CACHE_URL=http://cache-server:3000
```

However, if your workflows run jobs inside Docker containers via `container:` or use Docker service containers:
- The runner asks the **host Docker daemon** to create the job container.
- The job container attaches to the default bridge network, **not** the Compose project network.
- The job container cannot resolve the internal DNS name `cache-server`.

**Solution for Container Jobs**:
Set `CACHE_URL` in `.env` to a host-reachable IP address or hostname and published port:

```env
CACHE_PORT=3000
CACHE_URL=http://192.168.1.100:3000
```

Both the cache server (`API_BASE_URL`) and the runners (`ACTIONS_RESULTS_URL`) will use this address.

---

## How to Add a Third Repository

To add another repository runner (for example, `runner-repo-c`):

1. **Add environment variables** to `.env`:
   ```env
   REPO_C_URL=https://github.com/my-org/repo-c
   REPO_C_TOKEN=YOUR_REPO_C_TOKEN
   REPO_C_NAME_PREFIX=repo-c-
   REPO_C_LABELS=self-hosted,linux,docker
   REPO_C_WORKDIR=/tmp/github-runner/repo-c-work
   ```

2. **Add service block** to `docker-compose.yml`:
   ```yaml
     runner-repo-c:
       <<: *runner-common
       container_name: github-runner-repo-c
       environment:
         - RUNNER_URL=${REPO_C_URL}
         - RUNNER_TOKEN=${REPO_C_TOKEN}
         - RUNNER_NAME=${REPO_C_NAME:-}
         - RUNNER_NAME_PREFIX=${REPO_C_NAME_PREFIX:-repo-c-}
         - RUNNER_LABELS=${REPO_C_LABELS:-self-hosted,linux,docker}
         - RUNNER_GROUP=${REPO_C_GROUP:-}
         - RUNNER_WORKDIR=${REPO_C_WORKDIR:-/tmp/github-runner/repo-c-work}
         - ACTIONS_RESULTS_URL=${CACHE_URL:-http://cache-server:3000}/
         - DISABLE_AUTO_UPDATE=${DISABLE_AUTO_UPDATE:-}
         - LOG_LEVEL=${LOG_LEVEL:-info}
       volumes:
         - runner_c_data:/runner
         - /var/run/docker.sock:/var/run/docker.sock
         - ${REPO_C_WORKDIR:-/tmp/github-runner/repo-c-work}:${REPO_C_WORKDIR:-/tmp/github-runner/repo-c-work}
   ```

3. **Add volume entry** under `volumes:` in `docker-compose.yml`:
   ```yaml
   volumes:
     cache_data:
     runner_a_data:
     runner_b_data:
     runner_c_data:
   ```

4. **Apply changes**:
   ```bash
   docker compose up -d
   ```

---

## Upgrades and Maintenance

### Update Images

To update all images to the latest versions:

```bash
docker compose pull
docker compose up -d
```

### Stop Services

```bash
docker compose down
```

### Clean Up Storage

To remove stopped containers and persistent volumes (deletes runner credentials):

```bash
docker compose down -v
```
