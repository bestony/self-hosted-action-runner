# Development & Advanced Operations Guide

This guide provides technical specifications, architectural details, deployment instructions, and build steps for the Docker GitHub Actions Self-Hosted Runner.

- **GitHub Repository**: [https://github.com/bestony/self-hosted-action-runner](https://github.com/bestony/self-hosted-action-runner)
- **Docker Hub Repository**: [https://hub.docker.com/r/bestony/self-hosted-runner](https://hub.docker.com/r/bestony/self-hosted-runner)

---

## 1. Architecture Overview

The runner container provides a secure, automated environment for GitHub Actions workflows.

Key architectural components:
- **Base System**: Ubuntu 24.04 LTS minimal runtime with Git, cURL, `zstd`, `jq`, and Docker CLI tools.
- **Unprivileged User**: Workflows run under the non-root `runner` user (`uid=1000`).
- **Dynamic Group Adaptation**: `entrypoint.sh` inspects the GID of `/var/run/docker.sock` at startup and creates or adjusts a container group so the `runner` user accesses Docker without `sudo`.
- **Signal Handling**: Traps `SIGTERM` and `SIGINT` signals to gracefully stop active jobs before container termination.
- **Cache Server Support**: A binary patch on `Runner.Worker.dll` redirects cache endpoints from internal services to custom endpoints specified by `ACTIONS_RESULTS_URL`.

---

## 2. Configuration Reference

Configure the runner through environment variables. You can store these variables in a `.env` file.

| Variable | Required | Default | Description |
|---|---|---|---|
| `RUNNER_URL` | **Yes** | - | Target URL for registration. Accepts repository URLs (`https://github.com/org/repo`) or organization URLs (`https://github.com/org`). |
| `RUNNER_TOKEN` | **Yes** | - | Registration token generated from GitHub Actions settings. |
| `RUNNER_NAME` | No | Container hostname | Unique name for the runner in the GitHub web interface. |
| `RUNNER_NAME_PREFIX` | No | - | Prefix added to container hostname when `RUNNER_NAME` is not set (e.g. `ci-runner-`). |
| `RUNNER_WORKDIR` | No | `/tmp/github-runner/work` | Working directory for job workspaces. For DooD, host path must match container path. |
| `RUNNER_LABELS` | No | - | Comma-separated custom labels (e.g. `gpu,docker,self-hosted`). |
| `RUNNER_GROUP` | No | `Default` | Runner group for organization-level registration. |
| `ACTIONS_RESULTS_URL` | No | - | External cache server URL (e.g. `http://cache-server:3000/`). Trailing slash is added automatically. |
| `DISABLE_AUTO_UPDATE` | No | `false` | Disables runner self-updates. Automatically enabled when `ACTIONS_RESULTS_URL` is set. |
| `LOG_LEVEL` | No | `info` | Output verbosity: `debug`, `info`, `warn`, or `error`. |

---

## 3. Docker-outside-of-Docker (DooD) Execution

The container uses Docker-outside-of-Docker (DooD) to execute container operations through the host Docker daemon.

### Host Socket Mount
Mount the host Docker socket into the container:
```text
-v /var/run/docker.sock:/var/run/docker.sock
```

### Path Matching Requirement for Container Actions
When a workflow job specifies `container:` or `uses: docker://...`:
1. The runner calls the host Docker daemon to create the job container.
2. The host daemon mounts the workspace folder into the job container.
3. Because the host daemon runs on the host filesystem, the workspace path must exist at the **identical absolute path** on both the host and the runner container.

Example volume configuration:
```yaml
volumes:
  - runner_data:/runner
  - /var/run/docker.sock:/var/run/docker.sock
  - /tmp/github-runner/work:/tmp/github-runner/work
```

> [!WARNING]
> Initial runner registration permanently writes the `--work` path into `/runner/.runner`. If you change `RUNNER_WORKDIR`, delete the `/runner/.runner` configuration file and re-register the runner.

---

## 4. State Persistence and Verification

The container stores runner configuration and credentials in `/runner`:
- `.runner`: Contains registration status, runner ID, and work directory settings.
- `.credentials`: Contains authentication tokens for GitHub communication.

### Verification Procedure
1. Start the container:
   ```bash
   docker compose up -d
   ```
2. Verify initial registration in the logs:
   ```text
   No existing runner configuration detected. Performing initial registration...
   ```
3. Restart the container:
   ```bash
   docker compose restart runner
   ```
4. Verify that registration was skipped in the logs:
   ```text
   Existing runner configuration detected (.runner file present). Skipping registration.
   ```

---

## 5. Local Multi-Architecture Image Builds

Build multi-architecture images locally with Docker Buildx:

```bash
# Create and activate a Buildx builder instance
docker buildx create --use --name multiarch-builder

# Build and push images for linux/amd64 and linux/arm64
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  --build-arg RUNNER_VERSION=2.337.0 \
  -t bestony/self-hosted-runner:latest \
  --push \
  .
```

---

## 6. Advanced Deployments

Pre-configured deployment templates are available in the repository:

### Multi-Runner Docker Compose
For running multiple runner instances on a single host with isolated data volumes:
- Path: [deployments/docker-compose/](file:///Users/bestony/code/docker/self-hosted-runner/deployments/docker-compose/)
- Configuration: [deployments/docker-compose/docker-compose.multi.yml](file:///Users/bestony/code/docker/self-hosted-runner/deployments/docker-compose/docker-compose.multi.yml)
- Documentation: [deployments/docker-compose/README.md](file:///Users/bestony/code/docker/self-hosted-runner/deployments/docker-compose/README.md)

### Kubernetes Deployment
For orchestrating runners in Kubernetes clusters using StatefulSets or Deployments with PersistentVolumeClaims:
- Path: [deployments/kubernetes/](file:///Users/bestony/code/docker/self-hosted-runner/deployments/kubernetes/)
- StatefulSet: [deployments/kubernetes/statefulset.yaml](file:///Users/bestony/code/docker/self-hosted-runner/deployments/kubernetes/statefulset.yaml)
- Deployment: [deployments/kubernetes/deployment.yaml](file:///Users/bestony/code/docker/self-hosted-runner/deployments/kubernetes/deployment.yaml)
- Documentation: [deployments/kubernetes/README.md](file:///Users/bestony/code/docker/self-hosted-runner/deployments/kubernetes/README.md)

### CapRover Deployment
For deploying the runner on CapRover PaaS:
- Path: [deployments/caprover/](file:///Users/bestony/code/docker/self-hosted-runner/deployments/caprover/)
- Definition: [deployments/caprover/captain-definition](file:///Users/bestony/code/docker/self-hosted-runner/deployments/caprover/captain-definition)
- Documentation: [deployments/caprover/README.md](file:///Users/bestony/code/docker/self-hosted-runner/deployments/caprover/README.md)

---

## 7. CI/CD & Registry Automation

This repository maintains two automated GitHub Actions workflows:

1. **Upstream Release Tracker** ([.github/workflows/check-upstream-runner.yml](file:///Users/bestony/code/docker/self-hosted-runner/.github/workflows/check-upstream-runner.yml)):
   - Runs on schedule (every 6 hours) or manual dispatch.
   - Polls `actions/runner` for new stable releases.
   - Creates a Git tag and GitHub Release when a new version is detected.
2. **Container Build and Publish** ([.github/workflows/docker-publish.yml](file:///Users/bestony/code/docker/self-hosted-runner/.github/workflows/docker-publish.yml)):
   - Triggers on version tags (`v*`) or manual dispatch.
   - Compiles multi-platform images (`linux/amd64`, `linux/arm64`).
   - Publishes images to GitHub Container Registry (`ghcr.io`) and Docker Hub (`docker.io`).
   - Synchronizes repository documentation to Docker Hub Overview.
3. **Docker Hub Overview Sync** ([.github/workflows/dockerhub-description.yml](file:///Users/bestony/code/docker/self-hosted-runner/.github/workflows/dockerhub-description.yml)):
   - Triggers on push to `main` when `README.md` changes.
   - Pushes updated documentation directly to Docker Hub description.
