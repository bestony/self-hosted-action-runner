# Deploying GitHub Actions Runner on Kubernetes

Production reference manifests for deploying GitHub Actions self-hosted runners on Kubernetes clusters using standard declarative resources.

---

## Architecture Overview

```
                      +---------------------------------------+
                      | Kubernetes Cluster                    |
                      |                                       |
                      |  [Secret: runner-token]               |
                      |  [ConfigMap: runner-config]           |
                      |                 │                     |
                      |                 ▼                     |
                      |  +─────────────────────────+          |
                      |  | Runner Pod (runner-0)   |          |
                      |  |                         |          |
                      |  | Mounts:                 |          |
                      |  |   /runner ──────────────┼──► [PVC] |
                      |  |   /var/run/docker.sock ─┼──► Host  |
                      |  +─────────────────────────+          |
                      +---------------------------------------+
```

### Storage Isolation
GitHub Actions runner maintains active state in `.runner`, credentials in `.credentials`, and active jobs in `_work/`.
- **Never share a single PVC between multiple runner pods.**
- For a single runner: use `deployment.yaml` + `pvc.yaml`.
- For multi-replica runner clusters: use `statefulset.yaml`. The `volumeClaimTemplates` automatically dynamically provisions an isolated PersistentVolume for each replica (`runner-data-runner-0`, `runner-data-runner-1`).

---

## Deployment Options

### Option A: Scalable Cluster (`StatefulSet`)

Recommended for running multiple identical runner replicas:

1. Create secret from your registration token:
   ```bash
   kubectl create secret generic github-runner-secret \
     --from-literal=RUNNER_TOKEN="YOUR_GITHUB_TOKEN"
   ```

2. Apply ConfigMap and StatefulSet:
   ```bash
   kubectl apply -f configmap.yaml
   kubectl apply -f statefulset.yaml
   ```

3. Scale replicas dynamically:
   ```bash
   kubectl scale statefulset github-runner-cluster --replicas=3
   ```
   Each pod (`github-runner-cluster-0`, `github-runner-cluster-1`, etc.) automatically registers with a unique name prefixed by `RUNNER_NAME_PREFIX`.

> [!NOTE]
> **Registration Token Expiration**: The registration token in `github-runner-secret` expires after approximately 1 hour. It is only required during the initial registration of each runner replica. Once registered, credentials persist in the replica's PVC. When scaling up additional replicas at a later time, you must update `github-runner-secret` with a newly generated registration token from GitHub Settings before scaling.

---

### Option B: Single Runner (`Deployment`)

1. Create secret:
   ```bash
   kubectl apply -f secret.example.yaml # (Edit with your real token)
   ```

2. Apply configuration and deployment:
   ```bash
   kubectl apply -f configmap.yaml
   kubectl apply -f pvc.yaml
   kubectl apply -f deployment.yaml
   ```

---

## Multi-Tenant Isolation Patterns

### Pattern 1: Namespace Isolation
Deploy runners for different teams or organizations into dedicated Kubernetes namespaces:
```bash
# Team Alpha
kubectl create namespace runner-alpha
kubectl apply -f secret.yaml -n runner-alpha
kubectl apply -f deployment.yaml -n runner-alpha

# Team Beta
kubectl create namespace runner-beta
kubectl apply -f secret.yaml -n runner-beta
kubectl apply -f deployment.yaml -n runner-beta
```

### Pattern 2: Dedicated Worker Nodes
For workloads requiring root Docker daemon access, isolate runner pods to specific tainted nodes:
```yaml
nodeSelector:
  workload: ci-runners
tolerations:
  - key: "ci-runners"
    operator: "Exists"
    effect: "NoSchedule"
```

---

## Security Context & Docker Socket Access

- The runner pod mounts the host's `/var/run/docker.sock` via `hostPath`.
- The runner entrypoint dynamically discovers the socket's GID on startup and assigns the non-root runner user (`UID 1001`) to that group.
- If your cluster uses Pod Security Standards (PSS) or Kyverno/OPA Gatekeeper, ensure hostPath volume permissions are allowed for the runner namespace.

---

## DooD and Container Jobs Path Parity

When workflow jobs run container steps (`container:` or `uses: docker://...`) via the mounted Docker socket, the host node's Docker daemon bind-mounts workspace paths from the host node filesystem. If `RUNNER_WORKDIR` points to a path only present in the runner pod's PVC, the host daemon will mount an empty directory on the node.

To resolve this when running container actions on Kubernetes:
- Configure `RUNNER_WORKDIR` (e.g. `/tmp/github-runner/work`) in your pod environment or ConfigMap.
- Mount a `hostPath` volume into the pod at the **identical** path:
  ```yaml
  volumeMounts:
    - name: runner-work
      mountPath: /tmp/github-runner/work
  volumes:
    - name: runner-work
      hostPath:
        path: /tmp/github-runner/work
        type: DirectoryOrCreate
  ```
- **Important**: `--work` is fixed in `.runner` during initial registration. Changing `RUNNER_WORKDIR` requires deleting the existing runner registration.

