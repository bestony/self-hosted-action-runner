# Deploying Multi-Repository GitHub Runners with Shared Cache on Kubernetes

This directory provides declarative Kustomize manifests to deploy multiple GitHub Actions self-hosted runners alongside a shared Actions Cache Server in a Kubernetes cluster.

---

## Architecture Overview

```
                      ┌───────────────────────────────────────────────┐
                      │          Kubernetes (github-runners)          │
                      │                                               │
                      │   ┌──────────────────────────────────────┐    │
                      │   │  cache-server (Deployment, 1 replica)│    │
                      │   │  Service: cache-server:3000          │    │
                      │   │  PVC: cache-server-data (20Gi)       │    │
                      │   └──────────────────▲───────────────────┘    │
                      │                      │                        │
                      │          ACTIONS_RESULTS_URL                  │
                      │                      │                        │
                      │          ┌───────────┴───────────┐            │
                      │          │                       │            │
                      │   ┌──────┴─────────┐      ┌──────┴─────────┐  │
                      │   │ runner-repo-a  │      │ runner-repo-b  │  │
                      │   │ (StatefulSet)  │      │ (StatefulSet)  │  │
                      │   │ PVC: runner-a  │      │ PVC: runner-b  │  │
                      │   └──────┬─────────┘      └──────┬─────────┘  │
                      │          │                       │            │
                      │          └───────────┬───────────┘            │
                      │                      ▼                        │
                      │             /var/run/docker.sock              │
                      │             (Node Docker Daemon)              │
                      └───────────────────────────────────────────────┘
```

- **Namespace**: `github-runners` isolates the CI workload.
- **Cache Server**: Singleton Deployment with `strategy: Recreate` mounted to a 20Gi ReadWriteOnce PersistentVolumeClaim. Exposes port 3000 via a ClusterIP Service.
- **Workspace Parity**: `hostPath` bind mounts scoped by namespace and StatefulSet (`/var/lib/github-runner/<namespace>-<statefulset>`) to guarantee host path parity for Docker-outside-of-Docker (DooD) without multi-instance collisions.

---

## Prerequisites and Node Requirements

> [!WARNING]
> **Docker Daemon Required on Nodes (DooD)**:
> This runner image executes Docker workflows by mounting `/var/run/docker.sock` from the host node. The Kubernetes worker nodes **must** run Docker Engine (`dockerd`). Clusters running purely containerd or CRI-O runtimes cannot use `/var/run/docker.sock`.
>
> If you run a containerd cluster without Docker daemon, consider running the cache server separately via its official Helm chart:
> [falcondev-oss/github-actions-cache-server Kubernetes Chart](https://github.com/falcondev-oss/github-actions-cache-server/tree/master/install/kubernetes).

---

## Deployment Steps

### 1. Configure Registration Tokens

Before applying manifests, edit the placeholder tokens in `runner-repo-a.yaml` and `runner-repo-b.yaml`, or create the secrets manually:

```bash
# Obtain runner tokens from GitHub:
# Repository > Settings > Actions > Runners > New self-hosted runner

# Update runner-repo-a secret:
kubectl create secret generic runner-repo-a-secret \
  --namespace github-runners \
  --from-literal=RUNNER_TOKEN="YOUR_REPO_A_TOKEN" \
  --dry-run=client -o yaml > runner-repo-a-secret.override.yaml

# Update runner-repo-b secret:
kubectl create secret generic runner-repo-b-secret \
  --namespace github-runners \
  --from-literal=RUNNER_TOKEN="YOUR_REPO_B_TOKEN" \
  --dry-run=client -o yaml > runner-repo-b-secret.override.yaml
```

### 2. Apply Manifests with Kustomize

Apply the entire stack using `kubectl`:

```bash
kubectl apply -k .
```

### 3. Verify Pods and Services

```bash
# Check running pods
kubectl get pods -n github-runners

# Check cache server logs
kubectl logs -n github-runners deployment/cache-server

# Check runner logs
kubectl logs -n github-runners statefulset/runner-repo-a
kubectl logs -n github-runners statefulset/runner-repo-b
```

---

## Important Networking Caveat for `container:` Jobs

In this configuration:
- In-cluster runner steps reach the cache server using Kubernetes DNS:
  `http://cache-server:3000/`
- If your workflow defines `container:` jobs or Docker service containers, the runner asks the **node Docker daemon** to run the container.
- These host Docker containers run on the host's bridge network and do **not** use the Kubernetes cluster CoreDNS. They cannot resolve `.cluster.local` names.
- **Solution for Container Jobs**: Change `cache-server` Service type to `NodePort` or `LoadBalancer`, and point `ACTIONS_RESULTS_URL` and `API_BASE_URL` to the node IP and NodePort (for example, `http://192.168.1.50:32000`).

---

## How to Add Another Repository Runner

To add a runner for Repository C (`runner-repo-c`):

1. **Create `runner-repo-c.yaml`**:
   Duplicate `runner-repo-a.yaml` and update:
   - ConfigMap name: `runner-repo-c-config`
   - Secret name: `runner-repo-c-secret`
   - Service name: `runner-repo-c`
   - StatefulSet name: `runner-repo-c`
   - Labels and app selectors: `runner-repo-c`
   - `RUNNER_URL`: Target GitHub repository URL
   - `RUNNER_NAME_PREFIX`: `repo-c-`
   - `RUNNER_WORKDIR` and volume mount: `/var/lib/github-runner/github-runners-runner-repo-c`

2. **Register in `kustomization.yaml`**:
   Add `- runner-repo-c.yaml` to the `resources` list.

3. **Apply**:
   ```bash
   kubectl apply -k .
   ```
