# Tasks

## 1. Container Image Infrastructure

- [x] 1.1 Create `.dockerignore` to exclude local files, git metadata, and OpenSpec artifacts from container build context. Verify `.dockerignore` contains all non-build files.
- [x] 1.2 Implement multi-architecture `Dockerfile` based on Ubuntu LTS supporting `linux/amd64` and `linux/arm64` via `TARGETARCH`, installing runtime dependencies (`curl`, `tar`, `git`, `jq`, `zstd`, `libicu`, `ca-certificates`), Docker CLI tools (`docker-ce-cli`, `docker-buildx-plugin`), downloading architecture-matched runner packages into `/opt/runner-dist`, and applying the `Runner.Worker.dll` binary patch for `ACTIONS_RESULTS_URL` retention. Verify Dockerfile syntax and build target definition.

## 2. Runner Lifecycle and Entrypoint

- [x] 2.1 Implement `entrypoint.sh` script to handle volume hydration from `/opt/runner-dist` to `/runner` if empty. Verify script syntax with `bash -n entrypoint.sh`.
- [x] 2.2 Implement registration logic in `entrypoint.sh`: support both repository-level and organization-level URLs via `RUNNER_URL`, check for existing `/runner/.runner`, execute `./config.sh --unattended` with `--replace`, and pass `--disableupdate` when `ACTIONS_RESULTS_URL` is set or `DISABLE_AUTO_UPDATE=true`. Verify registration argument construction.
- [x] 2.3 Implement cache server environment normalization in `entrypoint.sh`: validate `ACTIONS_RESULTS_URL` (if provided) and enforce a trailing slash before exporting to runner environment. Verify normalization logic.
- [x] 2.4 Implement Docker socket GID detection and dynamic group assignment in `entrypoint.sh` so the unprivileged runner user can execute `docker` commands without `sudo` when `/var/run/docker.sock` is mounted. Verify group creation and assignment logic.
- [x] 2.5 Implement signal trapping (`SIGTERM`, `SIGINT`) in `entrypoint.sh` to forward shutdown signals to `./run.sh` and ensure graceful container termination.
- [x] 2.6 Set appropriate executable permissions on `entrypoint.sh` and ensure unprivileged `runner` user ownership over the `/runner` directory.

## 3. Orchestration and Compose Deployment

- [x] 3.1 Create `docker-compose.yml` declaring runner service with persistent volume mounted at `/runner`, host Docker socket mount `/var/run/docker.sock`, restart policy `unless-stopped`, environment variable bindings, and an optional companion `cache-server` service based on `ghcr.io/falcondev-oss/github-actions-cache-server`. Verify compose structure with `docker compose config`.
- [x] 3.2 Create `.env.example` template detailing required variables (`RUNNER_URL`, `RUNNER_TOKEN`) with examples for both repository and organization targets, optional runner variables (`RUNNER_NAME`, `RUNNER_LABELS`), and cache configuration (`ACTIONS_RESULTS_URL`).

## 4. Documentation and Integration Verification

- [x] 4.1 Create `README.md` documenting prerequisites, Docker Buildx multi-arch build commands, repository vs organization registration, Docker-in-Docker / socket workflow execution, GHA Cache Server setup and update policy, and restart persistence verification steps.
- [x] 4.2 Validate container build using Docker locally, verify help output or dry-run execution, and confirm configuration files exist as expected.
