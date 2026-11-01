# Tasks

## 1. Core Entrypoint Naming Enhancements

- [x] 1.1 Update `entrypoint.sh` to support `RUNNER_NAME_PREFIX`, automatically combining the prefix with container hostname when `RUNNER_NAME` is not explicitly provided. Verify name resolution logic with unit tests or bash execution test.

## 2. Multi-Runner Docker Compose Deployments

- [x] 2.1 Create `deployments/docker-compose/docker-compose.multi.yml` defining multiple runner services (e.g. `runner-org` and `runner-repo`) with isolated persistent volumes (`runner_org_data`, `runner_repo_data`), resource limits, and environment bindings. Verify with `docker compose -f deployments/docker-compose/docker-compose.multi.yml config`.
- [x] 2.2 Create `deployments/docker-compose/.env.multi.example` detailing per-instance configuration variables (`ORG_RUNNER_URL`, `ORG_RUNNER_TOKEN`, `REPO_RUNNER_URL`, `REPO_RUNNER_TOKEN`).
- [x] 2.3 Create `deployments/docker-compose/README.md` documenting multi-tenant deployment, volume isolation, and running multiple runners on a single Docker host.

## 3. CapRover Deployment Integration

- [x] 3.1 Create `deployments/caprover/captain-definition` defining the deployment schema and Dockerfile reference for CapRover.
- [x] 3.2 Create `deployments/caprover/README.md` detailing the step-by-step procedure to deploy runners in CapRover, configure persistent directory mappings for `/runner`, configure environment variables, and mount `/var/run/docker.sock`.

## 4. Kubernetes Manifests and Multi-Instance Topology

- [x] 4.1 Create `deployments/kubernetes/secret.example.yaml` and `deployments/kubernetes/configmap.yaml` templates for runner registration secrets and environment configuration.
- [x] 4.2 Create `deployments/kubernetes/pvc.yaml` and `deployments/kubernetes/deployment.yaml` declaring independent runner deployments with dedicated persistent volume mounts. Verify manifest formatting.
- [x] 4.3 Create `deployments/kubernetes/statefulset.yaml` using `volumeClaimTemplates` for multi-replica scalable runner clusters with automated per-replica volume allocation. Verify manifest formatting.
- [x] 4.4 Create `deployments/kubernetes/README.md` documenting multi-tenant isolation patterns (separate namespaces or deployments), RBAC/security contexts, and persistent volume requirements.
