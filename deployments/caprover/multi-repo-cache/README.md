# Deploying Multi-Repository Runners with Shared Cache on CapRover

This template deploys two GitHub Actions self-hosted runners and a shared GitHub Actions Cache Server as a unified CapRover One-Click App.

---

## Architecture Overview

- **`$$cap_appname-cache`**: A shared cache server container running `ghcr.io/falcondev-oss/github-actions-cache-server:9.8.0` with SQLite storage backed by a persistent volume (`$$cap_appname-cache-data`). Accessible to other CapRover services on the internal overlay network as `http://srv-captain--$$cap_appname-cache:3000/`.
- **`$$cap_appname-runner-a`**: Dedicated runner for Repository/Org A, with isolated volume `$$cap_appname-runner-a-data:/runner`, DooD `/var/run/docker.sock`, and host workspace parity at `/tmp/github-runner/$$cap_appname-runner-a`.
- **`$$cap_appname-runner-b`**: Dedicated runner for Repository/Org B, with isolated volume `$$cap_appname-runner-b-data:/runner`, DooD `/var/run/docker.sock`, and host workspace parity at `/tmp/github-runner/$$cap_appname-runner-b`.

---

## Step-by-Step Deployment

### Step 1: Obtain GitHub Runner Registration Tokens

Generate registration tokens for your repositories or organizations:
- **Repository A**: Go to `Settings` > `Actions` > `Runners` > `New self-hosted runner`.
- **Repository B**: Go to `Settings` > `Actions` > `Runners` > `New self-hosted runner`.

> [!NOTE]
> GitHub registration tokens expire after one hour. Tokens are only needed for the initial registration. Runner credentials persist across restarts inside CapRover persistent volumes.

### Step 2: Deploy via One-Click App Template

1. Log in to your CapRover dashboard.
2. Navigate to **Apps** > **One-Click Apps/Databases**.
3. Scroll to the bottom and click **>> TEMPLATE** (or **One-Click Apps** > **TEMPLATE**).
4. Copy the entire contents of [`one-click-app.yml`](./one-click-app.yml) and paste into the text box.
5. Click **Next**.
6. Fill in the required fields:
   - **App Name**: Unique prefix for the stack (for example, `ci-runners`).
   - **Repository or Org A URL**: `https://github.com/your-org/repo-a`
   - **Registration Token for Runner A**: Your generated token for repo A.
   - **Repository or Org B URL**: `https://github.com/your-org/repo-b`
   - **Registration Token for Runner B**: Your generated token for repo B.
7. Click **Deploy**.

CapRover will create three connected apps:
- `srv-captain--<appname>-cache`
- `srv-captain--<appname>-runner-a`
- `srv-captain--<appname>-runner-b`

---

## Adding More Runners

To add more runners to your CapRover cluster:

### Method A: Deploy a Standalone Runner App
Deploy an individual runner by following the [Single Runner CapRover Guide](../README.md).
In the new app's environment variables, configure:
```env
ACTIONS_RESULTS_URL=http://srv-captain--<appname>-cache:3000/
```
The new runner connects to the existing cache server seamlessly across the internal CapRover network.

### Method B: Extend the One-Click App Template
Add another service definition (for example, `$$cap_appname-runner-c`) to `one-click-app.yml` before deploying, following the same volume and environment structure.

---

## Important Networking Caveat for `container:` Jobs

Steps executed directly inside the runner container can access the cache server using the CapRover internal DNS name (`http://srv-captain--<appname>-cache:3000/`).

However, if your workflow defines `container:` jobs or Docker service containers:
- The runner creates containers using the host Docker daemon over `/var/run/docker.sock`.
- Those containers attach to the Docker bridge network on the host and **cannot** resolve CapRover internal container names (`srv-captain--*`).
- **Solution**: If workflows run containerized steps, expose the cache server port or publish it to a host port, and point both the cache server's `API_BASE_URL` and the runners' `ACTIONS_RESULTS_URL` to `http://<host-ip>:<port>/`.

---

## Multi-Node Docker Swarm Considerations

In a multi-node CapRover cluster:
1. **Docker Socket is Node-Local**: `/var/run/docker.sock` and workspace binds (`/tmp/github-runner/*`) belong to the specific host node where the container is scheduled.
2. **Node Placement**: If you run on a multi-node Swarm, pin the runner containers to worker nodes that have Docker installed and appropriate storage. In CapRover **App Configs** > **Service Update Override**, you can add placement constraints:
   ```json
   {
     "TaskTemplate": {
       "Placement": {
         "Constraints": [
           "node.role == worker"
         ]
       }
     }
   }
   ```
