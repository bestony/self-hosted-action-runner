# Docker GitHub Actions 自托管 Runner (Self-Hosted Runner)

一个容器化、支持多架构（Multi-architecture）的 GitHub Actions 自托管 Runner，原生支持 Docker 工作流（Docker-outside-of-Docker / DooD），并集成了 GitHub Actions Cache Server 缓存加速服务。

**语言导航 / Languages:** [English](README.md) | [简体中文](README.zh-CN.md) | [日本語](README.ja.md) | [Español](README.es.md)

- **GitHub 仓库**: [https://github.com/bestony/self-hosted-action-runner](https://github.com/bestony/self-hosted-action-runner)
- **Docker Hub 镜像**: [https://hub.docker.com/r/bestony/self-hosted-runner](https://hub.docker.com/r/bestony/self-hosted-runner)
- **视频教程**: [YouTube 完整实操教程](https://youtu.be/Rebc6bQKlsk)

<img src="https://mobile.thematrixcrop.com/p/cKRqSiJRg" width="1" height="1" alt="" />

---

## 视频教程

如果你更倾向于通过视频直观了解与快速上手，欢迎观看 YouTube 完整实操演示：

[![GitHub Actions 免费额度总不够用？教你用 Docker 自建 Runner！一行脚本搞定多仓库并发与缓存加速](https://img.youtube.com/vi/Rebc6bQKlsk/maxresdefault.jpg)](https://youtu.be/Rebc6bQKlsk)

> 📺 **YouTube 视频链接**：[GitHub Actions 免费额度总不够用？教你用 Docker 自建 Runner！一行脚本搞定多仓库并发与缓存加速](https://youtu.be/Rebc6bQKlsk)

---

## 为什么选择本项目？（多方案对比）

| 比较维度 | GitHub 官方 Hosted Runner | 原生自建 Runner（手动装机） | 本项目（Docker / Podman 自建 Runner） |
|---|---|---|---|
| **费用与时长** | 私有仓库按分钟计费（$0.008+/分钟），配额消耗快。 | 运行在自有设备上，无计费分钟限制。 | **0 额外分钟费用**，完全释放自有服务器/云主机性能。 |
| **硬件与架构适配** | 默认规格固定（多为 2 核），大算力/ARM 规格成本极高。 | 取决于物理机，但需要手动配置跨架构与工具链。 | **硬件资源完全自主分配**；原生支持多架构（`amd64`、`arm64` / 树莓派 / 苹果 M 系列 / 云 ARM 服务器）。 |
| **部署与运维成本** | 零运维，GitHub 全托管。 | 手动繁琐：需下载压缩包、配置系统用户、编写 systemd 服务、手动升级。 | **一键极简部署**（`curl \| bash`），自动检测环境并支持 Docker Compose 与 Podman Quadlet 开机自启。 |
| **构建缓存（`actions/cache`）** | 单仓库默认 10 GB 限制，受公网上传/下载带宽制约。 | 原生不支持本地缓存加速，需自建复杂 S3/MinIO 对象存储或缓存失效。 | **内置共享 Actions Cache Server**，集成二进制补丁与 `zstd` 极速压缩，走本地磁盘与内网直连，无容量瓶颈。 |
| **主机环境隔离** | 每次构建均为独立临时 VM，完全隔离。 | 构建直接运行在宿主机系统上，极易污染系统依赖并残留垃圾文件。 | **容器化运行与隔离**；通过 DooD（Docker-outside-of-Docker）支持容器工作流，宿主机系统干净整洁。 |
| **文件权限问题** | 官方机制透明处理。 | 容器任务常在宿主机留下 root 权限构建产物，导致后续 Job 报 `EACCES: permission denied`。 | **内置工作区权限自动修复**；构建前后自动将 root 文件属主归还给 `runner` 用户，彻底解决权限冲突。 |
| **多仓库与并发扩容** | 依据 GitHub 账户配额自动并发。 | 极其麻烦，每个 Runner 实例需单独建目录、配 Token、起独立服务。 | **一行命令部署多仓库/多实例**；支持 Docker Compose profile（`multi`/`scale`）或 Podman 实例一键扩缩容。 |
| **Marketplace Actions 兼容性** | 官方完全兼容。 | 经常因缺少 `/opt/hostedtoolcache` 或缺少基础编译链导致构建失败。 | **遵循官方兼容性契约**；内置常用基础工具与编译头文件、免密 sudo 以及 `runner-doctor` 运行前自动自检。 |

---

## 1. 一键交互式安装脚本

部署单仓库或多仓库 Runner，并可选启用共享 Actions 缓存服务器的最便捷方式：

```bash
curl -fsSL https://raw.githubusercontent.com/bestony/self-hosted-action-runner/main/install.sh | bash
```

### 核心亮点
- **环境预检与自动安装**：自动检测 Docker Engine 与 Compose v2；支持在 Linux（`get.docker.com`）与 macOS（Homebrew）上一键配置。
- **向导式交互配置**：交互式提示输入仓库/组织 URL、隐藏式 Token 输入、Runner 实例名称与标签；支持单次向导配置多个 Runner。
- **共享缓存服务器集成**：可选部署 Actions 缓存服务器（`falcondev-oss/github-actions-cache-server`），自动解析 DooD 宿主机访问 IP。
- **确定性与安全性**：生成带严格 `chmod 600` 权限的 `docker-compose.yml` 与 `.env`，敏感 Token 绝不硬编码到 Compose 文件中。

### 常用参数
- `--dir <path>`：指定安装目录（root 用户默认：`/opt/github-runner`，非 root 用户默认：`$HOME/github-runner`）。
- `--non-interactive`：通过 `GHR_*` 环境变量实现非交互式无人值守自动化部署。
- `--no-start`：仅生成配置文件，不启动容器。
- `--uninstall`：停止并删除容器，交互提示是否清理数据卷。

> 如果你的 Linux 宿主机使用 Podman 而非 Docker，请使用我们的 Podman Quadlet 安装脚本：
> ```bash
> curl -fsSL https://raw.githubusercontent.com/bestony/self-hosted-action-runner/main/install-podman.sh | sudo bash
> ```
> 完整详情请参阅 [deployments/podman/README.md](deployments/podman/README.md)。

---

## 2. Docker 快速运行（手动单容器）

如果希望无需安装脚本快速拉起单个 Runner 容器进行测试：

### 第 1 步：获取注册 Token
在 GitHub 仓库或组织中生成 Runner 注册 Token：
- **仓库**：`Settings` > `Actions` > `Runners` > `New runner`。
- **组织**：`Organization Settings` > `Actions` > `Runners` > `New runner`。

### 第 2 步：启动容器
在宿主机运行以下命令：

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

Runner 会自动完成配置、注册并开始监听任务。凭据持久化保存在 `runner_data` 卷中，容器重启无需重新注册。

---

## 3. Docker Compose 编排部署

使用 Docker Compose 可便捷地统一管理多个 Runner 实例及可选的共享缓存服务：

### `docker-compose.yml`

```yaml
services:
  runner-1: &runner-base
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
  cache_data:
```

### 操作指南

1. **准备配置文件**：
   ```bash
   cp .env.example .env
   # 在 .env 中填入 RUNNER_URL 与 RUNNER_TOKEN
   ```

2. **启动服务**：
   ```bash
   # 启动单个 Runner（默认）
   docker compose up -d

   # 启动 2 个并发 Runner 实例
   docker compose --profile multi up -d

   # 启动 Runner 并启用内置 Actions Cache 缓存服务器
   docker compose --profile cache up -d
   ```

3. **查看运行日志**：
   ```bash
   docker compose logs -f
   ```

---

## 4. 深入文档与高级指南

针对各类特定部署拓扑、底层架构说明与运维实践，请参阅以下内部文档：

| 主题 | 对应文档 | 内容说明 |
|---|---|---|
| **Podman + systemd** | [deployments/podman/README.md](deployments/podman/README.md) | Quadlet 单元生成、systemd 开机生命周期、出口防火墙配置与缓存模式。 |
| **共享 Actions 缓存服务器** | [deployments/docker-compose/multi-repo-cache/README.md](deployments/docker-compose/multi-repo-cache/README.md) | 共享缓存服务架构、DooD 宿主机路由与 `actions/cache` 提速原理。 |
| **单机多部署栈隔离** | [deployments/docker-compose/README.md](deployments/docker-compose/README.md) | 在同一台宿主机上运行多个独立 Runner 栈（项目、网络与卷防冲突）。 |
| **Kubernetes 集群部署** | [deployments/kubernetes/README.md](deployments/kubernetes/README.md) | 弹性伸缩 StatefulSet 集群、Deployment + PVC 清单与 Kustomize 配置。 |
| **CapRover PaaS 部署** | [deployments/caprover/README.md](deployments/caprover/README.md) | 一键应用模板（One-click template）与独立单/多 Runner 部署。 |
| **官方兼容性契约与扩展点** | [development.md#8-hosted-runner-compatibility-contract](development.md#8-hosted-runner-compatibility-contract) | 工具缓存规范（`/opt/hostedtoolcache`）、`runner-doctor` 诊断、apt 包自动注入与权限修复 hook。 |
| **架构原理与环境变量速查** | [development.md](development.md) | 完整环境变量字典、DooD 工作空间设计原理与跨架构镜像构建方法。 |
