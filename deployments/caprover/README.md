# Deploying GitHub Actions Runner on CapRover

This guide provides step-by-step instructions to deploy the GitHub Actions self-hosted runner as a persistent app on CapRover PaaS.

---

## 1. Create App in CapRover

1. Log in to your CapRover dashboard.
2. Go to **Apps** > **Create A New App**.
3. Name your app (e.g. `github-runner-01`).
4. **Important**: Check **Has Persistent Data** before creating the app.

---

## 2. Configure Persistent Storage

The runner requires persistent storage for `/runner` to save registration tokens and prevent re-registration on restart.

1. Navigate to your app's **App Configs** tab.
2. Scroll to **Persistent Directories**.
3. Add a new directory mapping:
   - **Path in App**: `/runner`
   - **Label**: `runner-data` (or leave default generated volume)
4. Click **Save & Restart**.

---

## 3. Configure Environment Variables

Under the **Environmental Variables** section in **App Configs**, add:

| Key | Example Value | Description |
|---|---|---|
| `RUNNER_URL` | `https://github.com/my-org/my-repo` | Repository or Organization URL |
| `RUNNER_TOKEN` | `A1234567890ABCDEF` | Registration Token from GitHub Settings |
| `RUNNER_NAME` | `caprover-runner-01` | Optional custom runner name |
| `RUNNER_LABELS` | `caprover,docker,self-hosted` | Optional custom runner labels |
| `ACTIONS_RESULTS_URL` | `http://cache-server:3000/` | Optional external cache server endpoint |

Click **Save & Restart**.

---

## 4. Mount Docker Socket (DooD for Docker Actions)

To allow GitHub Actions workflows to run `docker build` or container actions (`uses: docker://...`), mount the host Docker socket:

1. In **App Configs**, scroll down to **Service Update Override**.
2. Add a bind mount for `/var/run/docker.sock`:
   ```json
   {
     "TaskTemplate": {
       "ContainerSpec": {
         "Mounts": [
           {
             "Type": "bind",
             "Source": "/var/run/docker.sock",
             "Target": "/var/run/docker.sock"
           }
         ]
       }
     }
   }
   ```
3. Click **Update Service**.

> [!WARNING]
> **DooD Workspace Path Parity for Container Actions**:
> When workflows use container actions (`uses: docker://...`) or `container:` job definitions, the host Docker daemon creates containers and attempts to mount the runner's workspace from the host filesystem. If the workspace resides only inside a container-isolated volume, the host path does not exist and container jobs will see an empty directory.
> To support container actions:
> 1. Set environment variable `RUNNER_WORKDIR=/tmp/github-runner/work` in App Configs.
> 2. Add an identical bind mount in Service Update Override:
>    ```json
>    {
>      "Type": "bind",
>      "Source": "/tmp/github-runner/work",
>      "Target": "/tmp/github-runner/work"
>    }
>    ```
> 3. Note that `--work` is permanently recorded in `.runner` during initial registration; changing `RUNNER_WORKDIR` requires deleting `.runner` and re-registering.

---

## 5. Deploy the Runner App

You can deploy the app using either CapRover CLI or Tarball upload:

### Method A: Deploy using CapRover CLI
From the root of this repository:
```bash
# Copy captain-definition to repository root if deploying whole repo
cp deployments/caprover/captain-definition ./captain-definition

# Deploy using CapRover CLI
caprover deploy --appName github-runner-01
```

### Method B: Deploy using Pre-built Image
If using an image built to GHCR / Docker Hub:
1. In the app's **Deployment** tab, scroll to **Method 6: Deploy via ImageName**.
2. Enter your image name (e.g. `ghcr.io/your-org/github-runner:latest`).
3. Click **Deploy**.

---

## 6. Multi-Runner Deployment on CapRover

To run multiple runners in CapRover:

### Option A: Multi-Runner with Shared Cache (One-Click App Template)
For multi-repository or multi-organization setups sharing an Actions Cache Server and DooD workspace isolation, use the dedicated one-click template:
- [Multi-Repository Runner & Cache Server Guide](./multi-repo-cache/README.md)
- [One-Click App Template](./multi-repo-cache/one-click-app.yml)

### Option B: Independent Single-Runner Apps
Alternatively, create separate CapRover apps (`runner-org`, `runner-repo-frontend`, `runner-repo-backend`):
1. Create each app with **Has Persistent Data** enabled.
2. Each app maintains its own independent persistent `/runner` directory, environment variables, and registration token.
3. Multiple runner apps can coexist safely on the same CapRover server.

