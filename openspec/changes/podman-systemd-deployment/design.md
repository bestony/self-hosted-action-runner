# Design

## Context

现有部署路径见 `openspec/specs/runner-deployments/spec.md`：Docker Compose / CapRover / Kubernetes 三种编排，均以 Docker 为运行时，`install.sh` 负责生成 `docker-compose.yml` 与 `.env` 并调用 `docker compose up`。镜像 `entrypoint.sh` 的既有契约（`RUNNER_URL` / `RUNNER_TOKEN` / `RUNNER_NAME_PREFIX` / `RUNNER_LABELS` / `RUNNER_WORKDIR` / `ACTIONS_RESULTS_URL` / `FIX_WORKSPACE_OWNERSHIP` / `RUNNER_EXTRA_APT_PACKAGES` 等）是本次实现的输入，不修改镜像行为。动机见 `proposal.md`，行为要求见 `specs/runner-systemd-deployment/spec.md`。

与本设计相关的既有约束：

- DooD 工作区约束：容器内作业工作区路径必须与宿主机路径一致，否则嵌套容器通过容器 API 挂载宿主目录时路径无效（`docker-compose.yml` 与 `install.sh` 已采用该约定）。
- `entrypoint.sh` 会自动读取 `/var/run/docker.sock` 的 gid 并把 runner 用户加入同 gid 组，因此 socket 权限无需在单元侧特殊处理。
- 目标主机形态通常是长期在线的服务器（systemd 为 PID 1、root 可用），而非开发机。

## Goals / Non-Goals

**Goals:**

- 在 Podman ≥ 4.4 且 systemd 可用的 Linux 主机上，用一条命令完成 stack 部署，且部署结果由 systemd 托管（开机自启、状态查询、日志、重启、升级）。
- 与 `install.sh` 在配置语义（`GHR_*` 变量、`.env` 键名、缓存地址语义）上对齐，使同一套配置知识与运维习惯可以复用。
- 安装后可自证：脚本等待并判定 runner 注册结果，失败实例被停止而不是无限重启。
- 无需真实 Podman 即可在 CI 中验证文件生成、权限、单元内容、模式语义与卸载行为。

**Non-Goals:**

- 不支持 rootless（`systemctl --user`）与 `podman machine`（macOS/Windows）：本变更为 system 级 rootful 部署（非目标，可在后续变更中单独引入）。
- 不替换或改写 Docker Compose 路径，不修改镜像与 `entrypoint.sh`。
- 不提供 Kubernetes/CapRover 侧的新能力，也不引入 `podman-compose`。
- 不实现 `docker compose` 风格的工作流内嵌套编排（Podman API 兼容面限制，见 Decisions）。

## Decisions

### 1. 用 Quadlet 而不是 `podman generate systemd` 或 `podman-compose`

Quadlet 是 Podman 官方当前的 systemd 集成方式（4.4 起提供 `podman-system-generator`），单元文件是声明式的、可被 systemd 生成器校验，且未来的 `podman generate systemd` 已被官方标记为不推荐使用。`podman-compose` 属于第三方实现，不提供 systemd 生命周期语义（开机自启、`journalctl -u` 归属、依赖排序），与本变更"由 systemd 管理启动与状态"的目标不符。

### 2. 单元输出到 `/etc/containers/systemd/`，安装目录不保留副本

Quadlet 的 rootful 搜索路径固定为 `/run/containers/systemd/`、`/etc/containers/systemd/`、`/usr/share/containers/systemd/`。安装目录中只保留权威配置 `.env` 与派生产物（每服务 env 文件、工作区、日志、`README.txt`），单元文件仅写入 `/etc/containers/systemd/`。备选方案是在 `${INSTALL_DIR}/quadlet/` 保留一份并复制过去，但两份拷贝会随时间漂移，容易出现"改了安装目录里的单元却未生效"的隐性故障。为便于测试与自定义搜索路径，输出目录可通过 `GHR_QUADLET_DIR` 覆盖。

### 3. 开机自启用 `[Install] WantedBy=`，不用 `systemctl enable`

Quadlet 生成的单元对 systemd 而言是生成单元（transient），`systemctl enable` 对其无效；官方方式是生成器读取单元文件的 `[Install]` 小节。因此脚本只做 `daemon-reload` + `systemctl start`，脚本输出的文档命令也不会建议 `systemctl enable`。

### 4. 资源命名以项目前缀隔离

项目名沿用 `install.sh` 的确定性算法（`ghr-<目录名>-<sha256 前 8 位>`），并作为单元名、容器名（`ContainerName=`）、命名卷（`<project>-runner-N-data`、`<project>-cache-data`）与网络名（`<project>-net`）的前缀。这样同名 basename 的不同目录不会互相覆盖，卸载时也能按前缀精确删除本项目文件，不误删他人手工放入的 Quadlet 文件。

### 5. 缓存可达性：默认专用网络 + `cache-server` 别名，可选宿主机端口

Podman 默认网络的 `dns_enabled` 为 `false`，容器名在默认网络上不可解析，因此 internal 模式必须使用自建网络：脚本创建 `<project>-net`，缓存容器以 `Network=<project>-net:alias=cache-server` 加入，runner 通过 `http://cache-server:3000` 访问，不向宿主机发布端口。自建网络带 DNS 这一点已在 Podman 4.9.3 上实测：默认 `podman` 网络的 `dns_enabled` 为 `false`，`podman network create` 创建的网络为 `true`（该版本只有 `--disable-dns` 开关，没有反向的 `--dns-enabled`），因此无需额外开关，Quadlet 自愈用的 `ExecStartPre=-podman network create` 重建出的网络同样保有 DNS。别名没有使用 Quadlet 的 `NetworkAlias=` 键，因为该键自 Podman 5.2 才存在，而 `--network` 的 `alias=` 选项在 4.4 已可用，用它才能保住既定的版本门槛。备选方案是 Quadlet `.network` 单元，但该单元类型需要 Podman ≥ 4.7，会把门槛抬高并排除更多发行版。为在网络被误删后自愈，两个角色的单元都带一条 `ExecStartPre=-podman network create ...`（失败可忽略，故用 `-` 前缀）；安装器还会检查 `podman info` 报告的网络后端，在非 netavark 后端上提示别名可能无法解析（CNI 需要 dnsname 插件）。

host 模式则发布 `<port>:3000` 并把宿主机可解析地址写入 `ACTIONS_RESULTS_URL`，用于工作流里使用 `container:` 的嵌套容器作业（嵌套容器不在 stack 网络上，无法解析 `cache-server`）。这与 `install.sh` 的 `host` 模式语义一致，风险与限制在同处说明。

### 6. 配置模型：`.env` 权威，每服务 env 文件派生

Quadlet 的 `EnvironmentFile=` 只能整文件注入，无法按实例做变量改名，所以安装器由 `.env` 派生 `${INSTALL_DIR}/env/<project>-runner-N.env` 与 `<project>-cache.env`（仅 `KEY=VALUE` 行、权限 600），单元只引用这些文件。单元文件因此不含 token（与 `install.sh` 的"token 不内联到 compose 文件"约定同源），`.env` 仍可被解析以便追加实例或查看状态，解析使用 `grep`/`cut` 而不是 `source`，避免执行配置内容。缓存服务的清理阈值（`CACHE_CLEANUP_OLDER_THAN_DAYS`、`CACHE_FILESYSTEM_MAX_USAGE_PERCENT`）同样先记录到 `.env` 再派生，避免"改了派生文件、下次重新生成被覆盖"。

### 7. DooD 兼容面：挂载 Podman API socket 到两个路径

宿主机的 `/run/podman/podman.sock` 被同时挂载到容器的 `/var/run/docker.sock`（既有镜像与工作流习惯的 Docker 兼容面）与容器内 Podman 默认 socket 路径（使容器内安装 `podman` CLI 后可直接使用，`CONTAINER_HOST` 无需额外配置）。单元声明 `Wants=podman.socket` + `After=podman.socket`，由 systemd 保证 socket 先就绪，避免 `-v` 在源缺失时静默创建目录这一经典坑。

Podman API 的 Docker 兼容层对应 Docker API v1.40，因此：镜像构建与容器运行建议走 `podman` CLI（通过 socket 远程执行），`docker` CLI 的镜像/容器子集可用，而 `docker compose` 风格的嵌套编排不受支持。该限制写入 README 与 `deployments/podman/README.md`，避免使用者按 Docker 心智模型预期。

### 8. 安全基线：默认关闭 SELinux 标签分离，可显式打开

mount 一个 unix socket 无法通过 `:z`/`:Z` 重标记，在 SELinux enforcing 的主机上会失败，因此默认 `SecurityLabelDisable=true`（`--security-opt label=disable`）。用户可用 `GHR_SELINUX=1` 关闭该行为（适用于 AppArmor 或无 SELinux 主机），此时单元的作业工作区绑定挂载会附带 `:z` 重标记选项。socket 挂载本身等价于把宿主机 root 能力交给工作流，这与 Docker DooD 路径同级；`GHR_PODMAN_SOCKET=` 置空可完全关闭该能力。

### 9. 日志与可观测性：journald 驱动

单元显式设置 `LogDriver=journald`，使 `journalctl -u <unit>` 成为一等公民的排障入口，同时保留 podman 侧日志命令。安装后的等待与判定逻辑优先读 `journalctl -u`，失败时回退到 podman 日志命令，避免单一通道差异导致误判。缓存服务额外配置 `HealthCmd`，使 `podman ps`/状态表能显示健康状态。

### 10. 可测试性：不依赖真实 Podman 与 systemd

脚本支持 `--no-start`（仅生成文件）、`GHR_QUADLET_DIR`（单元输出目录）、`GHR_UNSAFE_SKIP_PLATFORM_CHECKS=1` 或 `GHR_ALLOW_NON_ROOT=1`（跳过 Linux/PID1/root 检查，且该模式下不再通过 `sudo` 提权，避免绕过 stub）、`GHR_PROMPT_STDIN=1`（强制提示从标准输入读取，使交互式流程也能被脚本化驱动），使 `tests/podman_install_test.sh` 可以在普通用户下用 stub 的 `podman`/`systemctl`/`journalctl` 验证：`.env` 与派生 env 文件的内容与权限、单元文件关键指令与"不含 token"、internal/host 缓存模式差异、`--no-start` 与 `--upgrade`/`--status`/`--stop`/`--restart` 的指令映射、注册成功与 404 失败两条分支、SELinux 开关、卸载时按前缀删除单元与数据保留策略、参数与路径校验的退出码。测试套件在主机存在 `podman-system-generator` 时额外执行一次 `--dryrun` 解析，把"单元能被 Quadlet 接受"纳入 CI；真实端到端启动验证（实际注册与开机自启）仍列为需要 root 与 systemd 的后续人工步骤。

### 11. 生命周期子命令与卸载语义

除安装外，脚本提供 `--status`/`--start`/`--stop`/`--restart`/`--upgrade`/`--uninstall`。它们统一通过解析 `.env` 还原 stack 形态（不依赖任何本地状态文件），因此可以在任意时刻对同一安装目录重复执行。`--uninstall` 只删除本项目前缀的单元文件与容器，保留 `.env`（它是唯一能解释"曾部署了什么"的记录），命名卷与作业工作区默认保留，只有交互确认或 `GHR_UNINSTALL_VOLUMES=yes`/`GHR_UNINSTALL_WORKDIR=yes` 才删除——这与"数据删除必须是一次显式决策"的取舍一致；删除工作区前还会跳过空路径与 `/`，避免手工编辑过的 `.env` 触发误删。

### 12. 配置优先级：环境变量 > `.env` > 内置默认值

`GHR_*` 环境变量在显式设置时覆盖 `.env` 中的同名记录（如 `GHR_QUADLET_DIR`、`GHR_IMAGE`、`GHR_CACHE_*`、`GHR_SELINUX`、`GHR_AUTO_UPDATE`），未设置时才使用 `.env` 的值，最后回落到内置默认值。这样"重复执行安装器应用 `.env`"与"用一次性环境变量做临时覆盖（例如灰度升级镜像）"两种用法都成立，且 `.env` 始终记录生效后的结果。

## Risks / Trade-offs

- [Podman < 4.4（Debian 12 为 4.3、Ubuntu 22.04 为 3.4）导致 Quadlet 不可用] → 安装前检查版本与生成器文件，失败时给出发行版对应的升级路径（backports 或上游仓库）并退出，不做"降级到 `podman generate systemd`"的隐式回退。
- [专用网络被 `podman network prune` 删除导致单元启动失败] → 单元自带 `ExecStartPre=-podman network create` 自愈，安装器在启动前也会创建网络。副作用：网络已存在时每次启动都会打印一行 `Error: network name <net> already used: network already exists`，由 `-` 前缀忽略，属预期噪声，已写入运维手册避免误判。
- [宿主机防火墙丢弃容器转发的流量] → 首次真实部署在同时装有 ufw、Docker 与 Tailscale 的 Debian 13 主机上复现：Podman 5.4.2 的 netavark 把放行规则写入 nftables（`table inet netavark` 的 `FORWARD` 链，`priority filter`），而 ufw 的 `DEFAULT_FORWARD_POLICY=DROP` 位于 iptables 的 `FORWARD` 链（同一 hook 同一优先级）；iptables 先执行，容器子网（`10.89.0.0/24`）的包被全部丢弃，DNS 仍可解析（由宿主回答）而 TCP 静默挂死。表现为 runner 连续重启、每次注册请求挂满 100 秒后超时，安装器却因日志子串误判报告"注册成功"。处理：安装器启动前用探针容器验证 DNS 与 `https://api.github.com` 可达（区分两类成因并给出 `ufw route allow in/out on <bridge>` 命令），运维手册新增宿主机前置条件章节；`GHR_SKIP_EGRESS_CHECK=yes` 为显式逃生口。修复转发后在同一台主机复检时又暴露了判据本身的问题：该出口 IP 的匿名 API 额度已被耗尽，GitHub 对 `https://api.github.com/` 返回 `403`，而探针原先用 `curl -f`（非 2xx 即失败），会把"网络完全正常但匿名请求被限流"误判为转发被丢弃并阻断安装。因此判据改为"是否收到 HTTP 响应"：状态码为数字即视为可达，`000`/无响应才算断网，非 2xx 时在输出里说明是匿名限流；runner 用自身 token 鉴权、额度独立，不受匿名限流影响。
- [systemd 的启动速率限制把快速失败的单元停在 `failed`] → Docker 的 `restart: always` 永不放弃，而 systemd 默认"10 秒内 5 次启动"即停止并按 `Restart=always` 的默认 `RestartSec=100ms` 形成热循环。真实主机（systemd 257）实测：默认配置 11 秒后 `NRestarts=5` 且 `failed`；加 `StartLimitIntervalSec=0` 后 11 秒内 `NRestarts=9` 且仍在 `running`。因此生成的单元固定带 `StartLimitIntervalSec=0`（`[Unit]`）与 `RestartSec=10`（`[Service]`），并在 Podman 4.9.3 与 5.4.2 的生成器上确认两键被接受且出现在生成结果中（更早的 Quadlet 若不支持会在安装时被 `verify_generated_units` 拦下，不会静默降级）。
- [socket 挂载导致工作流拥有宿主机 root 等价能力] → 文档明示风险与 `GHR_PODMAN_SOCKET=` 关闭方式；默认沿用 Docker DooD 的信任边界，不新增授权。
- [SELinux enforcing 主机上标签行为差异] → 默认 `SecurityLabelDisable=true`，并在文档中说明 `GHR_SELINUX=1` 的适用条件。
- [`ExecStartPre` 里的 `podman network create` 与 systemd 单元同时启动时的竞态] → 创建冲突由 `-` 前缀忽略，先成功者创建网络，随后容器启动。
- [Podman API 兼容面（v1.40）与工作流预期不符] → 在 README、运维手册与 `--help` 中明示支持的子集与推荐的 `podman` CLI 用法。
- [安装目录中的 `.env` 与 `/etc/containers/systemd/` 单元漂移] → 单元文件头部写入生成来源与重新生成命令；重复执行安装器即重新生成两者。
- [host 模式把缓存端口暴露到宿主网络] → 与 `install.sh` 行为一致，安装输出中提示仅在内网或配合防火墙使用。
- [注册判定依赖日志解析] → 判定只依据"能证明 runner 在线"的证据（`Listening for Jobs`），失败标志锚定到 `runner-registration` 端点以避免把运行期其他端点的 404 误报为安装失败；同一日志窗口内以最新一条有效状态为准，昨日的成功不会覆盖今日的失败。代价是"凭据存在但从未上线"只能给警告而非硬失败（可能只是日志尚未落盘），此时脚本明确说明未观察到上线。

## Migration Plan

1. 在 Podman 主机上执行 `install-podman.sh`（交互式或 `--non-interactive`），脚本完成 Podman/systemd 检查、文件生成、`daemon-reload` 与启动验证。
2. 从 Docker 路径迁移：在同一主机保留原 `docker compose` stack，先以新的安装目录部署 Podman stack，确认 runner 在 GitHub 上注册并接单后，再 `docker compose down` 旧 stack（两套 stack 的项目前缀不同，可并存）。
3. 回滚：`install-podman.sh --dir <dir> --uninstall` 停止并删除单元（保留 `.env` 与数据卷），必要时再执行 `docker compose up -d` 恢复旧路径；数据卷只有在显式确认时才会删除。
4. 升级镜像：`--upgrade` 拉取镜像并重启单元；如启用 `GHR_AUTO_UPDATE=1`，单元带 `AutoUpdate=registry` 并由 `podman-auto-update.timer` 完成定期更新。

## Open Questions

- `podman-auto-update.timer` 是否应从 opt-in 改为默认启用：涉及升级节奏与回滚习惯的策略选择，可在后续变更中决定，不影响本次的单元生成与生命周期接口。
- 是否需要独立的 `--sync-quadlet`（只重新生成并安装单元、不触碰容器）子命令：当前可用"重复执行安装器"覆盖该场景，等出现明确需求再引入。
