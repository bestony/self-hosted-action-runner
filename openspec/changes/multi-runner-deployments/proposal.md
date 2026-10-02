# Proposal

## Why

While the GitHub Actions runner Docker image provides the core runtime and entrypoint automation, production users need standardized deployment references across different target orchestrators—specifically Docker Compose, CapRover PaaS, and Kubernetes. Furthermore, teams often need to run multiple runner instances on a single Docker host or cluster, serving different GitHub Organizations and Repositories simultaneously without file conflicts, volume collisions, or naming clashes on GitHub.

## What Changes

- Introduce reference deployment configurations for **Docker Compose**:
  - Multi-runner compose profile demonstrating concurrent execution of multiple runner containers targeting different Orgs and Repositories on a single host.
  - Per-instance volume isolation (`runner_data_org1`, `runner_data_repo2`) and dedicated environment files.
- Introduce reference deployment configuration for **CapRover**:
  - `captain-definition` file and CapRover template configuration for deploying self-hosted runners via CapRover web UI / CLI.
  - Guidelines on persistent directories, environment variable mapping, and Docker-in-Docker / socket support in CapRover.
- Introduce production reference manifests for **Kubernetes**:
  - Complete Kubernetes manifests: `Deployment` (or `StatefulSet`), `Secret`, `ConfigMap`, and `PersistentVolumeClaim` (PVC).
  - Multi-instance and multi-tenant isolation patterns (separate namespaces or labeled deployments per Org/Repo).
- Enhance runner naming conventions in `entrypoint.sh` to support optional name prefixes (`RUNNER_NAME_PREFIX`) for automated unique naming when spinning up multiple runners across instances.

## Capabilities

### New Capabilities

- `runner-deployments`: Reference deployment configurations and multi-runner architecture manifests for Docker Compose, CapRover, and Kubernetes, enabling single-host multi-Org/Repo execution and isolated volume management.

### Modified Capabilities

- `runner-lifecycle`: Add support for runner name prefixing (`RUNNER_NAME_PREFIX`) to facilitate automated, collision-free naming in multi-runner and scaled deployments.

## Impact

- Repository files: Adds `deployments/docker-compose/`, `deployments/caprover/`, `deployments/kubernetes/`, and enhances `entrypoint.sh`.
- Runtime dependencies: None; provides orchestration YAMLs and configuration templates.
- Operational impact: Users can deploy runners into CapRover or Kubernetes clusters within minutes, and run multiple runners concurrently on a single host with guaranteed storage and credential isolation.
