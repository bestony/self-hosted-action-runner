# Proposal

## Why

现有安装器 `install.sh` 依赖 Docker Engine 与 Docker Compose。部分生产主机出于许可证、安全基线或发行版策略的原因只运行 Podman（daemonless、默认 rootless），这些主机上既没有 `docker compose`，也没有可托管的常驻守护进程，因此无法复用现有部署路径。需要一条以 Podman 为运行时、以 systemd（Quadlet 生成单元）负责开机自启与状态管理的一键安装路径，让同一 runner 镜像在 Podman 主机上获得与 Docker Compose 路径等价的部署、验证与卸载体验。

## What Changes

- 新增 `install-podman.sh`：以 system 级（root）Podman + systemd 为目标的一键安装器，交互式与 `--non-interactive`（`GHR_*` 环境变量）两种模式与 `install.sh` 对齐。
- 生成 Quadlet 单元文件（`*.container`）到 `/etc/containers/systemd/`，由 `podman-system-generator` 派生同名 `.service` 单元；开机自启用 `[Install] WantedBy=` 表达（Quadlet 生成单元无法 `systemctl enable`）。
- 生命周期子命令：`--status`、`--start`、`--stop`、`--restart`、`--upgrade`、`--uninstall`；控制面统一为 systemd（`systemctl` / `journalctl`），容器日志使用 journald 驱动。
- 多目标与多实例：每个 GitHub 仓库/组织可配置多个并发实例；每个实例拥有独立的 Quadlet 单元、命名卷（`/runner`）与工作目录（`work/runner-N`），目录在容器内外保持同一绝对路径以满足 DooD 挂载约束。
- 缓存服务集成：`internal` 模式（默认）为整套 stack 创建启用 DNS 的 Podman 网络，runner 通过 `cache-server` 别名访问缓存；`host` 模式将缓存端口发布到宿主机，供 `container:` 形式的嵌套容器作业访问。
- 运行环境对接：默认挂载 `/run/podman/podman.sock` 到容器的 `/var/run/docker.sock`（Docker 兼容面）与 `/run/podman/podman.sock`（Podman 远程 CLI），并在单元中声明对 `podman.socket` 的依赖。
- 配置记录：`${INSTALL_DIR}/.env`（权限 600）为唯一权威配置；每个服务的 env 文件由 `.env` 派生（权限 600），单元文件中不内联 token；重复执行安装器可追加 runner（`GHR_MODE=add`）或整体重配。
- 安装后验证：等待 systemd 单元进入 active，按注册日志判定 runner 注册结果（Listening for Jobs / 401 / 404），失败实例停止以避免重启风暴，并输出含 systemd 与 podman 管理命令的最终状态表。
- 测试与 CI：新增 `tests/podman_install_test.sh`（在无真实 Podman 的环境中验证文件生成、权限、单元内容、缓存模式语义、生命周期指令映射、注册判定与卸载行为），将 `install-podman.sh` 与新测试纳入 lint 工作流的 ShellCheck 列表，并新增执行该测试套件的步骤。
- 文档：README 新增 Podman 章节，新增 `deployments/podman/README.md` 运维手册。

## Capabilities

### New Capabilities

- `runner-systemd-deployment`: Podman 运行时下的一键安装、Quadlet 单元生成、systemd 生命周期与状态管理、缓存服务集成、卸载与清理行为。

### Modified Capabilities

- 无。现有 `runner-container`、`runner-lifecycle`、`runner-deployments` 三条能力的要求不发生变化：本变更新增运行时路径，不修改镜像内部行为，也不修改既有 Compose/CapRover/Kubernetes 参考部署的要求。

## Impact

- 新增文件：`install-podman.sh`、`tests/podman_install_test.sh`、`deployments/podman/README.md`。
- 修改文件：`README.md`（Podman 章节）、`.github/workflows/lint.yml`（ShellCheck 与测试）。
- 目标主机影响：需要 systemd（PID 1）与 Podman ≥ 4.4；安装会写入 `/etc/containers/systemd/`、启用 `podman.socket`、创建 Podman 网络与命名卷，并在 `${INSTALL_DIR}/work/` 下创建作业工作区。
- 运行时依赖：镜像不变（`ghcr.io/bestony/self-hosted-action-runner`），无新增语言级依赖；仅依赖 Podman、systemd 与基础工具（`curl`、`grep`、`awk`）。
- 安全影响：Podman API socket 挂载使工作流具备宿主机 root 等价能力（与 Docker DooD 路径同级）；默认 `SecurityLabelDisable=true` 以允许 socket 与工作区 bind mount，可用 `GHR_SELINUX=1` 退回带标签模式。
- 已知限制（在文档中明示）：Podman API 仅提供 Docker API v1.40 兼容层，`docker compose` 风格的嵌套容器编排不受支持，工作流内应使用 `podman`（或对镜像操作可用的 `docker` 子集）；`container:` 作业需要 `host` 模式的缓存地址。
