# Multi-Runner Docker Compose Deployments

This configuration enables running multiple GitHub Actions self-hosted runner containers concurrently on a single Docker host, serving different GitHub Organizations or Repositories.

---

## Architecture & Storage Isolation

When running multiple runners on the same machine:
- **Dedicated Volumes**: Each runner container **must** have its own isolated volume (e.g. `runner_org_data` and `runner_repo_data`) mounted to `/runner`. Sharing a single volume between multiple runner instances will cause credential corruption, lock file conflicts, and registration crashes.
- **Dedicated Registration**: Each runner registers independently with GitHub using its specific `RUNNER_URL` and `RUNNER_TOKEN`.
- **Automated Collision-Free Naming**: By configuring `RUNNER_NAME_PREFIX` (such as `org-runner-` and `repo-runner-`), each runner receives a unique name based on the prefix and the container hostname (e.g. `org-runner-github-runner-org`), preventing naming collisions on GitHub.
- **Host Docker Socket**: Both runners mount `/var/run/docker.sock` to enable Docker-in-Docker / Docker-outside-of-Docker workflow execution.
- **Resource Limits**: Configured CPU and Memory limits (e.g. `cpus: '2.0'`, `memory: 4096M`) prevent a single heavy CI job from starving other runners on the host.

---

## Quick Start

### 1. Configure Environment

Copy `.env.multi.example` to `.env`:

```bash
cp .env.multi.example .env
```

Edit `.env` with your organization and repository runner tokens:

```env
ORG_RUNNER_URL=https://github.com/my-org
ORG_RUNNER_TOKEN=AAABBBCCCDDDEEEFFF111222333
ORG_RUNNER_NAME_PREFIX=org-runner-

REPO_RUNNER_URL=https://github.com/my-org/my-project
REPO_RUNNER_TOKEN=GGGHHHIIIJJJKKKLLL444555666
REPO_RUNNER_NAME_PREFIX=repo-runner-
```

### 2. Launch the Runners

```bash
docker compose -f docker-compose.multi.yml up -d
```

### 3. Verify Status

```bash
# Check running containers
docker compose -f docker-compose.multi.yml ps

# View logs for both runners
docker compose -f docker-compose.multi.yml logs -f
```

---

## Security Considerations

- **Shared Host Socket**: Because both runners share access to the host's `/var/run/docker.sock`, containers created by one runner can see the Docker daemon state. Only co-locate runners that belong to the same security boundary (e.g. trusted internal repositories or teams).
- **Disk Pruning**: High job volume may fill Docker build caches. Set up a periodic host cron job to clean unused resources:
  ```bash
  docker system prune -af --filter "until=168h"
  ```
