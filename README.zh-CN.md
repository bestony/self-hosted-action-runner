# Docker GitHub Actions 自托管 Runner (Self-Hosted Runner)

一个容器化、支持多架构（Multi-architecture）的 GitHub Actions 自托管 Runner，原生支持 Docker 工作流（Docker-outside-of-Docker / DooD），并集成了 GitHub Actions Cache Server 缓存加速服务。

**语言导航 / Languages:** [English](README.md) | [简体中文](README.zh-CN.md) | [日本語](README.ja.md) | [Español](README.es.md)

- **GitHub 仓库**: [https://github.com/bestony/self-hosted-action-runner](https://github.com/bestony/self-hosted-action-runner)
- **Docker Hub 镜像**: [https://hub.docker.com/r/bestony/self-hosted-runner](https://hub.docker.com/r/bestony/self-hosted-runner)

<img src="https://mobile.thematrixcrop.com/p/cKRqSiJRg" width="1" height="1" alt="" />

---

## 一键交互式安装脚本

部署单仓库或多仓库 Runner，并可选启用共享 Actions 缓存服务器的最便捷方式：

```bash
curl -fsSL https://raw.githubusercontent.com/bestony/self-hosted-action-runner/main/install.sh | bash
```

### 功能特性
- **环境预检与依赖安装**：自动检测 Docker Engine、Docker Compose v2 及守护进程连通性。支持 Linux 系统自动安装（基于 `get.docker.com`）与 macOS Homebrew 自动配置。
- **交互式向导配置**：提示输入仓库/组织 URL、隐藏式 Token 输入、Runner 前缀与标签。支持在单次部署中配置多个 Runner。
- **共享缓存服务器**：可选部署并配置 `ghcr.io/falcondev-oss/github-actions-cache-server:latest`，自动检测 DooD 宿主机 IP。
- **确定性 Compose 与安全保障**：自动生成 `docker-compose.yml` 与设置了 `chmod 600` 严格权限的 `.env`。Token 绝不内联暴露在 Compose 文件中。
- **自动健康检查与日志验证**：启动容器栈并实时跟踪注册日志，确保 Runner 成功连接至 GitHub。

### 安装脚本命令行参数
- `--dir <path>`：指定安装目录（root 用户默认：`/opt/github-runner`，非 root 用户默认：`$HOME/github-runner`）。
- `--non-interactive`：通过 `GHR_*` 环境变量实现非交互式无人值守自动化部署。
- `--no-start`：仅生成配置文件与目录结构，不启动容器。
- `--skip-docker-install`：跳过 Docker 及 Compose 插件的自动安装尝试。
- `--uninstall`：停止并移除容器，交互提示是否删除持久化存储卷。
- `--debug`：开启详细调试日志输出。
- `-h, --help`：显示帮助信息与可选参数。

### 交互式部署示例（默认）

无需附加任何 `GHR_*` 环境变量或参数直接执行。安装脚本会从终端（`/dev/tty`）读取输入，完美兼容 `curl | bash` 管道执行。直接按回车键使用默认值，Token 输入自动隐蔽显示。

```text
$ curl -fsSL https://raw.githubusercontent.com/bestony/self-hosted-action-runner/main/install.sh | bash

==> [3/6] Collecting configuration
Enter installation directory [default: /home/me/github-runner]:

--- Configuring Runner #1 ---
GitHub Repository or Organization URL (e.g. https://github.com/org/repo): https://github.com/my-org/repo-a
GitHub Runner Registration Token:
Runner name prefix [default: repo-a-]:
Runner labels (comma-separated) [default: self-hosted,linux,docker]:
Number of runner instances for this target (to run jobs concurrently) [default: 1]: 2
Add another repository/org runner? [y/N]: y

--- Configuring Runner #2 ---
GitHub Repository or Organization URL (e.g. https://github.com/org/repo): https://github.com/my-org
GitHub Runner Registration Token:
Runner name prefix [default: my-org-]:
Runner labels (comma-separated) [default: self-hosted,linux,docker]:
Number of runner instances for this target (to run jobs concurrently) [default: 1]: 1
Add another repository/org runner? [y/N]:

--- Cache Server Configuration ---
Enable shared GitHub Actions cache server? [Y/n]:
Select cache URL mode: [1] Internal (http://cache-server:3000) or [2] Host IP (reachable by container jobs) [default: 1]:
Runner container image [default: ghcr.io/bestony/self-hosted-action-runner:latest]:

(configuration summary, tokens masked)
Write configuration and continue? [Y/n]:
```

> **提示**：从 GitHub 仓库或组织的 **Settings > Actions > Runners > New self-hosted runner** 页面获取注册 Token。Token 有效期为 1 小时，仅在 Runner 首次注册时需要使用。

如果在同一目录再次运行该脚本，它将列出已配置的 Runner 并提供选项：`[A]dd runners`（追加 Runner）、`[R]econfigure from scratch`（重新配置）或 `[Q]uit`（退出）。

### 非交互式部署示例（CI / 自动化运维）

仅在无人工交互终端的自动化环境中使用 `--non-interactive`。在此模式下，脚本直接读取 `GHR_*` 环境变量且不进行任何交互提示：

```bash
curl -fsSL https://raw.githubusercontent.com/bestony/self-hosted-action-runner/main/install.sh | \
  GHR_RUNNER_1_URL="https://github.com/my-org/repo-a" \
  GHR_RUNNER_1_TOKEN="YOUR_REPO_A_TOKEN" \
  GHR_RUNNER_1_INSTANCES=2 \
  GHR_RUNNER_2_URL="https://github.com/my-org/repo-b" \
  GHR_RUNNER_2_TOKEN="YOUR_REPO_B_TOKEN" \
  GHR_CACHE=1 \
  bash -s -- --non-interactive --dir /opt/github-runner
```

---

## Podman + systemd (Quadlet) 安装脚本

在运行 Podman 而非 Docker Engine 的 Linux 宿主机上，可使用 `install-podman.sh`。它会生成 [Quadlet](https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html) unit 单元文件，使 **systemd** 能够接管服务生命周期并在开机时自动拉起：

```bash
curl -fsSL https://raw.githubusercontent.com/bestony/self-hosted-action-runner/main/install-podman.sh | sudo bash
```

该脚本与 `install.sh` 共享相同的交互式提示、`GHR_*` 环境变量以及 `.env` 配置规范，核心差异在于部署单元格式与生命周期管理器：

| 特性 | `install.sh` (Docker) | `install-podman.sh` (Podman) |
|---|---|---|
| **部署单元** | `docker-compose.yml` + `.env` | Quadlet `.container` 单元文件 + `.env` |
| **生命周期管理** | `docker compose` | systemd (`systemctl`, `journalctl`) |
| **开机自启机制** | 容器自身的 `restart:` 策略 | 单元内部声明 `[Install] WantedBy=multi-user.target default.target` |
| **运行要求** | Docker Engine + Compose v2 | 以 systemd 为 PID 1 的 Linux，rootful Podman >= 4.4 |
| **每目标实例数** | `--instances`, `GHR_RUNNER_<n>_INSTANCES` | 相同 |
| **子命令** | `--uninstall` | `--status`, `--start`, `--stop`, `--restart`, `--upgrade`, `--uninstall` |

```bash
# 非交互式部署（适用于已有 Podman 的环境）
curl -fsSL https://raw.githubusercontent.com/bestony/self-hosted-action-runner/main/install-podman.sh | \
  sudo bash -s -- --non-interactive --dir /opt/github-runner --skip-podman-install
```

### Podman 运行细节与说明
- **最低版本要求**：Quadlet 在 Podman 4.4 及以上版本提供。如果宿主机未安装 Podman，脚本会通过发行版包管理器自动安装并校验版本及 `podman-system-generator`。
- **开机自启无需 `systemctl enable`**：Quadlet 单元属于由 generator 动态生成的文件，无法直接使用 `systemctl enable`。在单元内部包含的 `[Install] WantedBy=` 字段即可保证系统启动时拉起服务。
- **镜像升级**：使用 `--upgrade` 会拉取最新的 `RUNNER_IMAGE` / `CACHE_IMAGE` 并重启所有单元；若设置 `AUTO_UPDATE=1`，还会为 Quadlet 添加 `AutoUpdate=registry`。
- **缓存服务器模式**：支持 `internal`（默认，通过内部网络访问 `http://cache-server:3000/`，不暴露宿主机端口）与 `host`（绑定宿主机 `<port>:3000`，适用于在 Job 中使用 `container:` 语法）。可通过 `GHR_CACHE_MODE` 配置。
- **容器任务（DooD）支持**：宿主机的 Podman socket 会同时挂载为 `/var/run/docker.sock` 与 `/run/podman/podman.sock`，因此兼容标准 `docker` 命令步骤。
- **宿主机防火墙**：容器必须能访问 `https://api.github.com`（需要宿主机开启容器网络转发）。脚本会在启动前探测连通性并提示修复命令（如 `sudo ufw route allow in on podman1`）。
- **重启语义保障**：单元配置了 `StartLimitIntervalSec=0` 与 `RestartSec=10`，当 Runner 遇到网络波动或待注册状态时会每 10 秒持续重试，避免被 systemd 置于 `failed` 挂起状态。

更多详情请参考 [deployments/podman/README.md](deployments/podman/README.md)。

---

## 部署方案矩阵

| 部署拓扑 | Docker Compose | CapRover | Kubernetes | Podman + systemd |
|---|---|---|---|---|
| **单 Runner** | [docker-compose.yml](docker-compose.yml) | [单应用指南](deployments/caprover/README.md) | [Deployment + PVC](deployments/kubernetes/README.md#option-b-single-runner-deployment) | [Podman 部署](deployments/podman/README.md) |
| **多 Runner（独立）** | [docker-compose.multi.yml](deployments/docker-compose/docker-compose.multi.yml) | [多应用配置](deployments/caprover/README.md#option-b-independent-single-runner-apps) | [StatefulSet 集群](deployments/kubernetes/README.md#option-a-scalable-cluster-statefulset) | [追加 Runner](deployments/podman/README.md#adding-runners-later) |
| **多 Runner + 共享缓存** | [多仓库缓存 Compose](deployments/docker-compose/multi-repo-cache/README.md) | [一键应用模板](deployments/caprover/multi-repo-cache/README.md) | [Kustomize 配置清单](deployments/kubernetes/multi-repo-cache/README.md) | [缓存模式说明](deployments/podman/README.md#cache-server-modes) |

---

## 1. 快速入门（手动单容器运行）

如果仅需快速启动单个 Runner 容器，可直接使用 `docker run`。

### 第 1 步：获取注册 Token
在 GitHub 仓库或组织中生成 Runner 注册 Token：
- **仓库**：`Settings` > `Actions` > `Runners` > `New runner`。
- **组织**：`Organization Settings` > `Actions` > `Runners` > `New runner`。

### 第 2 步：运行容器
在宿主机执行以下命令：

```bash
docker run -d \
  --name github-runner \
  --restart unless-stopped \
  -e RUNNER_URL="https://github.com/your-org/your-repo" \
  -e RUNNER_TOKEN="YOUR_REGISTRATION_TOKEN" \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v runner_data:/runner \
  bestony/self-hosted-runner:latest
```

Runner 容器将自动完成配置、注册并开始监听任务。凭据持久化保存在 `runner_data` 卷中，容器重启无需重新注册。

---

## 2. 结合缓存服务器使用

本镜像原生支持外部 GitHub Actions 缓存服务器（如 [falcondev-oss/github-actions-cache-server](https://github.com/falcondev-oss/github-actions-cache-server)）。镜像中内置了对 `ACTIONS_RESULTS_URL` 的二进制补丁，并预装了 `zstd` 以提供高效压缩。

### 如何启用缓存服务

配置 `ACTIONS_RESULTS_URL` 环境变量：

```bash
docker run -d \
  --name github-runner \
  --restart unless-stopped \
  -e RUNNER_URL="https://github.com/your-org/your-repo" \
  -e RUNNER_TOKEN="YOUR_REGISTRATION_TOKEN" \
  -e ACTIONS_RESULTS_URL="http://cache-server:3000/" \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v runner_data:/runner \
  bestony/self-hosted-runner:latest
```

配置 `ACTIONS_RESULTS_URL` 后：
1. 工作流中的 `actions/cache` 步骤将直接从你的缓存服务器保存与读取缓存。
2. 镜像会自动禁用官方自动更新（`--disableupdate`），防止 Runner 更新覆盖内置的缓存二进制补丁。
3. 如果工作流需要运行容器任务（Container actions），请确保 `ACTIONS_RESULTS_URL` 设置为宿主机网络可访问的地址（例如 `http://host.docker.internal:3000/` 或宿主机 IP）。

---

## 3. Docker Compose 编排

你可以使用 Docker Compose 统一编排管理 Runner 与缓存服务器：

### `docker-compose.yml`

```yaml
services:
  runner-1: &runner-base
    build:
      context: .
      dockerfile: Dockerfile
    image: bestony/self-hosted-runner:latest
    restart: unless-stopped
    environment:
      - RUNNER_URL=${RUNNER_URL}
      - RUNNER_TOKEN=${RUNNER_TOKEN}
      - RUNNER_NAME=${RUNNER_NAME_1:-${RUNNER_NAME:-}}
      - RUNNER_NAME_PREFIX=${RUNNER_NAME_PREFIX_1:-${RUNNER_NAME_PREFIX:-runner-1-}}
      - RUNNER_LABELS=${RUNNER_LABELS:-}
      - RUNNER_GROUP=${RUNNER_GROUP:-}
      - RUNNER_WORKDIR=${RUNNER_WORKDIR_1:-${RUNNER_WORKDIR:-${PWD}/work/runner-1}}
      - ACTIONS_RESULTS_URL=${ACTIONS_RESULTS_URL:-}
      - DISABLE_AUTO_UPDATE=${DISABLE_AUTO_UPDATE:-}
      - LOG_LEVEL=${LOG_LEVEL:-info}
      - FIX_WORKSPACE_OWNERSHIP=${FIX_WORKSPACE_OWNERSHIP:-true}
      - RUNNER_EXTRA_APT_PACKAGES=${RUNNER_EXTRA_APT_PACKAGES:-}
      - RUNNER_WRITABLE_PATHS=${RUNNER_WRITABLE_PATHS:-}
    volumes:
      - runner_1_data:/runner
      - /var/run/docker.sock:/var/run/docker.sock
      - ${RUNNER_WORKDIR_1:-${RUNNER_WORKDIR:-${PWD}/work/runner-1}}:${RUNNER_WORKDIR_1:-${RUNNER_WORKDIR:-${PWD}/work/runner-1}}
    depends_on:
      cache-server:
        condition: service_started
        required: false

  runner-2:
    <<: *runner-base
    environment:
      - RUNNER_URL=${RUNNER_URL}
      - RUNNER_TOKEN=${RUNNER_TOKEN}
      - RUNNER_NAME=${RUNNER_NAME_2:-}
      - RUNNER_NAME_PREFIX=${RUNNER_NAME_PREFIX_2:-${RUNNER_NAME_PREFIX:-runner-2-}}
      - RUNNER_LABELS=${RUNNER_LABELS:-}
      - RUNNER_GROUP=${RUNNER_GROUP:-}
      - RUNNER_WORKDIR=${RUNNER_WORKDIR_2:-${PWD}/work/runner-2}
      - ACTIONS_RESULTS_URL=${ACTIONS_RESULTS_URL:-}
      - DISABLE_AUTO_UPDATE=${DISABLE_AUTO_UPDATE:-}
      - LOG_LEVEL=${LOG_LEVEL:-info}
      - FIX_WORKSPACE_OWNERSHIP=${FIX_WORKSPACE_OWNERSHIP:-true}
      - RUNNER_EXTRA_APT_PACKAGES=${RUNNER_EXTRA_APT_PACKAGES:-}
      - RUNNER_WRITABLE_PATHS=${RUNNER_WRITABLE_PATHS:-}
    volumes:
      - runner_2_data:/runner
      - /var/run/docker.sock:/var/run/docker.sock
      - ${RUNNER_WORKDIR_2:-${PWD}/work/runner-2}:${RUNNER_WORKDIR_2:-${PWD}/work/runner-2}
    profiles:
      - multi
      - scale
      - all

  cache-server:
    image: ghcr.io/falcondev-oss/github-actions-cache-server:latest
    restart: unless-stopped
#   ports:
#     - "${CACHE_PORT:-3000}:3000"
    environment:
      API_BASE_URL: ${CACHE_API_BASE_URL:-http://cache-server:3000}
      STORAGE_DRIVER: filesystem
      STORAGE_FILESYSTEM_PATH: /data/cache
      DB_DRIVER: sqlite
      DB_SQLITE_PATH: /data/cache-server.db
    volumes:
      - cache_data:/data
    profiles:
      - cache
      - full
      - all

volumes:
  runner_1_data:
  runner_2_data:
  runner_3_data:
  runner_4_data:
  cache_data:
```

### 使用指南

1. 生成 `.env` 文件：
   ```bash
   cp .env.example .env
   ```
2. 在 `.env` 中配置 `RUNNER_URL` 与 `RUNNER_TOKEN`。
3. 启动所需服务：
   ```bash
   # 启动单个 Runner 实例（默认）
   docker compose up -d

   # 启动 2 个并发 Runner 实例
   docker compose --profile multi up -d

   # 扩容至 4 个并发 Runner 实例
   docker compose --profile scale up -d

   # 启动包含缓存服务器的完整环境
   docker compose --profile cache up -d
   ```
4. 查看运行日志：
   ```bash
   docker compose logs -f
   ```

---

## 4. 单主机运行多个独立部署栈

你可以在同一台宿主机上运行多个相互独立的 Runner 栈（供不同团队、环境或项目使用），彼此完全隔离无冲突：

- **项目命名隔离**：每个栈使用独立的 Docker Compose 项目名（通过 `.env` 中的 `COMPOSE_PROJECT_NAME` 或 `docker-compose.yml` 顶级 `name:` 指定）。安装脚本会自动生成确定性防冲突名称（`ghr-<dir>-<sha256:8>`）。
- **容器动态命名**：省略静态 `container_name` 声明，容器由 Compose 动态命名为 `<project>-<service>-<index>`。
- **网络隔离**：每个栈创建独立的 bridge 桥接网络，防止不同栈之间的 DNS 解析或路由串扰。
- **数据卷与凭据隔离**：具名卷（如 `runner_data`、`cache_data`）限定于项目作用域内，确保 Runner 注册凭据和 SQLite 数据库独立存储。
- **工作目录隔离**：Job 工作空间采用目录作用域路径（`${PWD}/work/<runner>` 或 `<install_dir>/work/runner-<n>`），确保 Docker-outside-of-Docker (DooD) 宿主机挂载互不干扰。
- **缓存端口不冲突**：默认内部模式下，Runner 通过项目私有网络访问缓存，不绑定宿主机端口；宿主机 IP 模式下则自动分配不同的映射端口。

---

## 5. 官方托管 Runner 兼容性保障

官方 Marketplace Actions 通常基于 GitHub 官方 Hosted Runner 镜像开发，依赖一系列特定约定。普通自建容器若缺少这些约定，极易发生 `EACCES: permission denied, mkdir '/opt/hostedtoolcache'`（如 `ruby/setup-ruby`, `actions/setup-python`）或 `EACCES: permission denied, stat '/root/.gitconfig'`（如 `actions/checkout`）等权限错误。

本镜像以“契约规范”完整提供了这些环境约定，并在容器每次启动时进行校验：

| 约定项 | 本镜像提供的保障机制 |
|---|---|
| **运行身份** | Runner 进程以非特权 `runner` 用户运行，`HOME=/home/runner`，并拥有免密 `sudo` 权限。 |
| **工具缓存（Tool Cache）** | `RUNNER_TOOL_CACHE` 与 `AGENT_TOOLSDIRECTORY` 指向 `/opt/hostedtoolcache`，属主为 `runner` 用户。安装的工具保存在 `/runner` 持久化卷中（`/runner/_tool-cache`），新建容器无需重复下载。 |
| **工作区权限修复** | 内置 Job 钩子（`/opt/runner-hooks/fix-workspace-ownership.sh`），在每个 Job 执行前后自动将工作空间、`RUNNER_TEMP` 及工具缓存中 root 属主的文件重新归还给 `runner` 用户。 |
| **基础依赖工具** | 预装 Docker CLI、Buildx 与 Compose 插件（通过挂载 `/var/run/docker.sock` 连接宿主机）、GitHub CLI (`gh`)、`git`、`git-lfs`、`curl`、`wget`、`jq`、`zip`、`unzip`、`xz`、`zstd`、`rsync`、`openssh-client`、`python3`。 |
| **原生代码编译支持** | 预装 `build-essential`、`pkg-config` 及核心开发头文件（`libssl-dev`, `libyaml-dev`, `libffi-dev`, `libreadline-dev`, `libgmp-dev`, `zlib1g-dev`），确保可直接编译 Ruby gems、Node.js 原生扩展与 Python C-extensions。 |
| **本地化配置** | `LANG=C.UTF-8`。 |

> `gh` CLI 在 Job 中使用时需要配置 Token，例如添加环境变量 `env: GH_TOKEN: ${{ github.token }}`。若某步骤需临时安装特定系统包，可在步骤中直接执行 `sudo apt-get update && sudo apt-get install -y <package>`，体验与官方 Runner 一致。

### 扩展配置项

若工作流需要镜像未内置的额外能力，可直接通过容器环境变量进行扩展，无需重新构建镜像：

| 环境变量 | 默认值 | 作用说明 |
|---|---|---|
| `RUNNER_EXTRA_APT_PACKAGES` | - | 容器启动时自动安装的 apt 软件包列表（空格或逗号分隔），例如 `libpq-dev libsqlite3-dev`。 |
| `RUNNER_WRITABLE_PATHS` | - | 冒号分隔的绝对路径列表。容器启动时会自动创建这些目录并将所有权授予 `runner` 用户（`/usr` 等系统关键目录会被拒绝）。 |
| `RUNNER_INIT_DIR` | `/opt/runner-init.d` | 该目录下的每个 `*.sh` 脚本都会在 Runner 启动前由 `bash` 依次执行。可挂载自定义初始化脚本。 |
| `RUNNER_TOOL_CACHE` | `/opt/hostedtoolcache` | 工具缓存路径。非必要请勿修改，预构建的 Ruby 与 Python 二进制包内嵌了该默认路径。 |
| `RUNNER_TOOL_CACHE_PERSIST` | `true` | 设置为 `false` 则将工具缓存保存在容器临时层中。直接挂载到工具缓存路径的数据卷始终会被原样使用。 |
| `FIX_WORKSPACE_OWNERSHIP` | `true` | 设置为 `false` 可关闭工作空间权限自动修复钩子。 |
| `ACTIONS_RUNNER_HOOK_JOB_STARTED` | 权限修复脚本 | 可指定自定义脚本路径以替代默认的 Job 启动前钩子。 |
| `ACTIONS_RUNNER_HOOK_JOB_COMPLETED` | 权限修复脚本 | 可指定自定义脚本路径以替代默认的 Job 完成后钩子。 |

> 扩展配置若执行失败不会阻塞 Runner 启动，容器日志中会打印相关 Warning 警报。

### 运行诊断工具

镜像入口点会在启动 Runner 前以 `runner` 用户自动执行 `runner-doctor`。如果某项环境契约未满足，日志中将打印包含原因的 `FAIL` 提示。若需手动检查正在运行中的容器健康状态：

```bash
docker exec -u runner <container> runner-doctor
```

### 并行任务执行

如需并发运行 Matrix 矩阵任务，可注册多个 Runner 实例：在相同目录下再次运行安装脚本并选择 `[A]dd runners` 即可。单个 Runner 每次执行一个 Job。

---

## 6. 深入文档与资源

如需了解更多技术细节，请参阅：
- [deployments/podman/README.md](deployments/podman/README.md)：Podman + systemd (Quadlet) 部署架构、单元组织、缓存模式、卸载与回滚指南。
- [development.md](development.md)：底层架构设计、完整环境变量速查、DooD 工作空间原理、多平台镜像构建、Kubernetes / CapRover 部署方案与 CI/CD 自动化流程。
- [GitHub Repository](https://github.com/bestony/self-hosted-action-runner)：源代码、版本发布说明与问题反馈。
