# Design

## Context

See [proposal.md](proposal.md) for motivation.
This change provides reference deployment templates and operational architectures for deploying GitHub self-hosted runners across three major environments: Docker Compose (multi-instance/multi-target), CapRover PaaS, and Kubernetes. It addresses the architectural requirements of running multiple runner instances on a single Docker host or cluster concurrently, serving different GitHub Organizations and Repositories safely without interference.

## Goals / Non-Goals

**Goals:**
- Provide a clean, organized `deployments/` directory structure containing battle-tested deployment manifests:
  - `deployments/docker-compose/`: Multi-runner compose configurations with isolated volumes and distinct environment variables per runner.
  - `deployments/caprover/`: `captain-definition` and step-by-step app deployment guides for CapRover.
  - `deployments/kubernetes/`: Declarative manifests (`Deployment`, `StatefulSet`, `Secret`, `ConfigMap`, `PVC`) supporting single and multi-instance topologies.
- Guarantee full state and credential isolation: ensure each runner instance has dedicated persistent storage for its `/runner` directory.
- Avoid runner naming collisions on GitHub when running multiple runners on a single host by introducing `RUNNER_NAME_PREFIX`.
- Document resource management (CPU/memory caps) and Docker socket sharing considerations across multi-runner hosts.

**Non-Goals:**
- Writing a custom Kubernetes Operator: This design provides standard, cloud-native Kubernetes manifests suitable for standard clusters, without requiring complex operator installations.
- Automated token rotation APIs: Tokens are provided via environment variables, secrets, or .env files following standard orchestration practices.

## Decisions

### 1. Directory Structure Organization
- **Choice**: Place all orchestrator-specific configurations under `deployments/`:
  - `deployments/docker-compose/docker-compose.multi.yml`
  - `deployments/docker-compose/.env.multi.example`
  - `deployments/caprover/captain-definition`
  - `deployments/caprover/README.md`
  - `deployments/kubernetes/deployment.yaml`
  - `deployments/kubernetes/statefulset.yaml`
  - `deployments/kubernetes/secret.example.yaml`
  - `deployments/kubernetes/pvc.yaml`
  - `deployments/kubernetes/README.md`
- **Rationale**: Keeps the root directory minimal and clean for image building while providing dedicated, easily discoverable configuration templates for each deployment platform.

### 2. Multi-Runner Storage Isolation Pattern
- **Choice**:
  - In **Docker Compose**: Define distinct named volumes per service (e.g., `runner_data_org1` and `runner_data_repo1`). Each container mounts its own volume to `/runner`.
  - In **CapRover**: Each runner instance runs as an independent CapRover App, configuring its own persistent directory mapping to `/runner` in the App Config UI.
  - In **Kubernetes**: Use dedicated `PersistentVolumeClaim`s per deployment, or a `StatefulSet` with `volumeClaimTemplates` where each replica receives a stable, dedicated PVC (e.g. `runner-data-runner-0`, `runner-data-runner-1`).
- **Rationale**: The GitHub Actions runner runtime creates locks, state files, and session keys inside `.runner` and `.credentials`. Sharing a single storage volume across multiple runners causes immediate state corruption and registration failure.

### 3. Automated Collision-Free Naming with `RUNNER_NAME_PREFIX`
- **Choice**: Update `entrypoint.sh` with the following resolution:
  - If `RUNNER_NAME` is explicitly specified → use `RUNNER_NAME`.
  - Else if `RUNNER_NAME_PREFIX` is set → `${RUNNER_NAME_PREFIX}${HOSTNAME}`.
  - Else → `${HOSTNAME}`.
- **Rationale**: When scaling replicas in Compose or Kubernetes, containers share identical environment configurations. Having a prefix like `RUNNER_NAME_PREFIX=prod-org1-` automatically combines with container hostnames (`prod-org1-abc12345`), preventing runner name collisions on GitHub.

### 4. CapRover Integration Architecture
- **Choice**:
  - Provide a `captain-definition` specifying the Dockerfile path or pre-built image.
  - Document mounting `/var/run/docker.sock` in CapRover App Config > Service Update for Docker-in-Docker / DooD capabilities.
  - Document persistent volume binding to `/runner` in CapRover Persistent Directories tab.

### 5. Kubernetes Architecture: Deployment vs StatefulSet
- **Choice**:
  - Provide both `Deployment` (for single-target or fixed-token deployments) and `StatefulSet` (for multi-replica deployments with automated dedicated volume provisioning).
  - Use Kubernetes `Secret` for `RUNNER_TOKEN` and ConfigMap for `RUNNER_URL` and `RUNNER_LABELS`.
  - Provide resource limits (`resources.requests` and `resources.limits`) to ensure fair scheduling on worker nodes.

## Risks / Trade-offs

- **[Risk] Docker Daemon Saturation on Shared Host**: Running multiple runners on one host that simultaneously trigger intensive `docker build` jobs may exhaust disk space or CPU.
  - *Mitigation*: Configure Docker Compose `cpus` / `mem_limit` and Kubernetes resource constraints. Include guidance on periodic Docker disk pruning.
- **[Risk] Host Docker Socket Security in Shared Runner Environments**: When multiple organizations share a single Docker host socket, jobs from Org A could technically inspect host containers from Org B.
  - *Mitigation*: Clearly highlight this tenancy boundary in the documentation: runners sharing a Docker socket should belong to the same security trust boundary (e.g., internal company teams, not untrusted external users).
