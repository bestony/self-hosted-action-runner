# Spec Delta

## Purpose

Provides production reference deployment configurations and multi-runner isolation architectures across Docker Compose, CapRover, and Kubernetes.

## ADDED Requirements

### Requirement: Multi-Runner Docker Compose Orchestration
The deployment configurations SHALL provide Docker Compose templates demonstrating concurrent execution of multiple runner containers targeting different organizations or repositories on a single host.

#### Scenario: Multi-runner docker compose execution
- **WHEN** `docker compose up -d` is invoked with multiple runner service definitions targeting different `RUNNER_URL` values
- **THEN** each runner container starts, registers independently with isolated volumes, and runs concurrently without interference

#### Scenario: Per-instance volume isolation
- **WHEN** multiple runner services are defined in Docker Compose
- **THEN** each service mounts a distinct named volume or host directory for `/runner`, preserving independent credentials and workspaces

### Requirement: CapRover Deployment Integration
The deployment configurations SHALL provide a CapRover deployment reference (`captain-definition` and application configuration templates) allowing users to deploy persistent runners via CapRover.

#### Scenario: CapRover container deployment
- **WHEN** the runner image and captain-definition are deployed to a CapRover instance
- **THEN** CapRover provisions the runner container with persistent directory mapping to `/runner` and environment variables for registration

#### Scenario: CapRover multi-app runner deployment
- **WHEN** a user creates multiple CapRover apps targeting different repositories
- **THEN** each CapRover app runs an independent runner container with its own persistent storage and registration token

### Requirement: Kubernetes Deployment Reference
The deployment configurations SHALL provide Kubernetes manifests (`Deployment`, `StatefulSet`, `Secret`, `ConfigMap`, and `PersistentVolumeClaim`) for production cluster deployments.

#### Scenario: Deploying runner on Kubernetes
- **WHEN** the Kubernetes manifests are applied to a cluster
- **THEN** runner pods schedule successfully, mount dedicated PVCs at `/runner`, register with GitHub, and process workflow jobs

#### Scenario: Multi-target Kubernetes deployments
- **WHEN** multiple runner deployments are created targeting different repositories or organizations
- **THEN** each deployment operates independently with separate Secrets and isolated persistent volume claims
