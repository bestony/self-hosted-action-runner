# Spec Delta

## Purpose

定义在 Podman 运行时下以 Quadlet 单元配合 systemd 部署、启动与运维 GitHub Actions self-hosted runner stack 的行为契约，覆盖一键安装、单元生成、缓存集成、状态验证与卸载清理。

## ADDED Requirements

### Requirement: Podman 一键安装入口

安装器 SHALL 提供单一入口脚本，在支持 systemd 的 Linux 主机上完成 Podman 环境检查、配置收集、文件生成与 stack 启动，并在整个过程中以 systemd 作为唯一控制面。

#### Scenario: 交互式安装

- **WHEN** 用户在终端直接运行安装脚本且未提供非交互参数
- **THEN** 脚本依次提示安装目录、GitHub 仓库/组织 URL、隐藏输入的注册 token、名称前缀、标签、实例数量与缓存配置，并在写入前打印含 token 掩码的配置摘要请求确认

#### Scenario: 非交互式安装

- **WHEN** 用户以 `--non-interactive` 运行并设置 `GHR_RUNNER_<n>_URL` 与 `GHR_RUNNER_<n>_TOKEN` 等环境变量
- **THEN** 脚本不读取终端输入，按环境变量完成配置，并在缺少 runner 配置时以退出码 1 失败

#### Scenario: 仅生成文件不启动

- **WHEN** 用户以 `--no-start` 运行
- **THEN** 脚本完成配置写入、单元安装与 `systemctl daemon-reload`，不拉取镜像、不创建网络、不启动任何单元，并输出后续启动与查看状态的命令

#### Scenario: Podman 缺失或版本过低

- **WHEN** 主机未安装 Podman，或已安装的 Podman 版本低于 Quadlet 所需的 4.4
- **THEN** 脚本在 Linux 上按发行版包管理器尝试安装（除非指定 `--skip-podman-install`），安装后仍低于门槛或无法安装时以退出码 1 失败并给出可执行的补救说明

#### Scenario: 环境不满足前置条件

- **WHEN** 主机不是 Linux、PID 1 不是 systemd，或以非 root 身份运行且未获得 sudo 权限、也未覆盖 Quadlet 输出目录
- **THEN** 脚本在任何文件写入前以非零退出码失败，并指明缺失的前置条件

### Requirement: Quadlet 单元生成

安装器 SHALL 为每个 runner 实例与缓存服务生成一个 Quadlet `.container` 单元文件，使 `podman-system-generator` 能够派生对应的 systemd service 单元。

#### Scenario: 每个实例生成独立单元

- **WHEN** 安装器完成文件生成
- **THEN** Quadlet 输出目录中每个 runner 实例各有一个 `.container` 文件，内容包含镜像引用、环境变量文件路径、`/runner` 数据卷、作业工作区绑定挂载与日志驱动设置

#### Scenario: 单元文件不包含注册 token

- **WHEN** 安装器写入 `.container` 单元文件
- **THEN** 单元文件仅引用权限为 600 的环境变量文件，注册 token 不出现在任何单元文件中

#### Scenario: 开机自启由单元文件表达

- **WHEN** 生成的单元包含 `[Install]` 小节
- **THEN** 该小节使用 `WantedBy=`（而非 `systemctl enable`）声明开机自启，且脚本不调用 `systemctl enable` 作用于生成单元

#### Scenario: 单元可被生成器解析

- **WHEN** 安装器执行 `systemctl daemon-reload`
- **THEN** 每个已生成的 `.container` 文件被 `podman-system-generator` 解析为同名 service 单元，解析失败时脚本输出 `systemd-analyze verify` 等诊断命令并退出非零

### Requirement: 每项目资源隔离

安装器 SHALL 依据安装目录派生确定性的项目前缀，并把它用于单元名、容器名、命名卷与 Podman 网络，使同一主机上的多个 stack 互不冲突。

#### Scenario: 同一主机运行多套 stack

- **WHEN** 两个安装目录的 basename 相同但绝对路径不同
- **THEN** 两者派生出不同的项目前缀，因此单元名、容器名、命名卷与网络名各不相同，可同时启动

#### Scenario: 重复安装保持幂等

- **WHEN** 用户在已有配置的安装目录重跑安装器并选择追加实例
- **THEN** 既有实例的单元、环境文件与工作区保持不变，仅新增实例对应的文件，且 `.env` 中的实例计数被更新

### Requirement: systemd 生命周期管理

安装器 SHALL 提供以 systemd 为控制面的生命周期子命令，覆盖启动、停止、重启、状态查看与镜像升级。

#### Scenario: 查看状态

- **WHEN** 用户以 `--status` 运行
- **THEN** 脚本输出每个单元的 `systemctl` 激活状态、对应容器的运行与健康状态，以及 runner 注册状态摘要

#### Scenario: 停止与启动整套 stack

- **WHEN** 用户以 `--stop` 或 `--start` 运行
- **THEN** 脚本对 stack 内所有单元执行对应的 systemctl 操作，并在结束后输出最终状态表

#### Scenario: 升级镜像

- **WHEN** 用户以 `--upgrade` 运行
- **THEN** 脚本拉取配置中记录的镜像并按单元重启服务，使运行中的容器切换到新镜像

#### Scenario: 日志可经由 systemd 读取

- **WHEN** 用户按脚本输出的提示查看日志
- **THEN** 容器输出既可通过 `journalctl -u <unit>` 读取，也可通过 podman 日志命令读取

### Requirement: 安装后状态验证

安装器 SHALL 在启动 stack 后等待并判定每个 runner 的注册结果，并对失败实例采取停止动作。

#### Scenario: 注册成功

- **WHEN** runner 容器日志在等待窗口内出现 `Listening for Jobs`
- **THEN** 脚本把该实例标记为成功，并在最终状态表中显示目标 URL 与对应的 GitHub 设置页地址

#### Scenario: 注册凭据无效

- **WHEN** runner 容器日志在等待窗口内出现 `Http response code: 404` 或 `Http response code: 401`
- **THEN** 脚本把该实例标记为失败、停止对应 systemd 单元以避免重启风暴，打印排查与修复命令，并在结束时以退出码 1 报告失败实例数

#### Scenario: 等待窗口内未得出结论

- **WHEN** 等待窗口结束时仍未观察到注册成功或失败标志
- **THEN** 脚本以警告标记该实例，保留单元继续运行，并输出日志查看命令

### Requirement: 缓存服务集成

安装器 SHALL 支持为 stack 部署 GitHub Actions cache server，并支持内部网络与宿主机地址两种可达性模式。

#### Scenario: 内部模式部署

- **WHEN** 缓存启用且模式为 internal（默认）
- **THEN** 安装器创建启用 DNS 的 Podman 网络，缓存容器以 `cache-server` 别名加入该网络，runner 环境中的 `ACTIONS_RESULTS_URL` 指向该别名，且不发布任何宿主机端口

#### Scenario: 宿主机模式部署

- **WHEN** 缓存启用且模式为 host
- **THEN** 缓存容器把配置端口发布到宿主机，runner 环境中的 `ACTIONS_RESULTS_URL` 使用宿主可解析地址，使 `container:` 形式的嵌套容器作业也能访问缓存

#### Scenario: 禁用缓存

- **WHEN** 缓存被禁用
- **THEN** 安装器不生成缓存单元、不创建缓存网络与数据卷，且不向 runner 环境注入 `ACTIONS_RESULTS_URL`

#### Scenario: 内部地址不可达时的提示

- **WHEN** 缓存启用且为内部模式，但启动后从 runner 容器内无法访问缓存地址
- **THEN** 脚本输出警告并提示切换到 host 模式或检查网络 DNS 的处置建议

### Requirement: 容器运行时对接

安装器 SHALL 把宿主机的 Podman API socket 暴露给 runner 与嵌套容器工作流使用，并保持作业工作区路径在容器内外一致。

#### Scenario: 暴露 Podman API socket

- **WHEN** 主机存在 Podman API socket 且未显式禁用
- **THEN** 单元把该 socket 同时挂载到容器的 `/var/run/docker.sock` 与容器内 Podman 默认 socket 路径，并声明对 `podman.socket` 单元的依赖

#### Scenario: 显式禁用 socket 挂载

- **WHEN** 用户把 socket 配置置空
- **THEN** 生成单元不包含 socket 挂载与 `podman.socket` 依赖，runner 仍可正常注册与执行不需要容器的工作流

#### Scenario: 工作区路径一致性

- **WHEN** 安装器生成工作区绑定挂载
- **THEN** 容器内的作业工作区绝对路径与宿主机路径相同，使嵌套容器通过 Podman API 挂载宿主目录时路径有效

#### Scenario: SELinux 标签策略

- **WHEN** 主机启用 SELinux，或以 `GHR_SELINUX=1` 要求保留标签分离
- **THEN** 默认生成的单元设置 `SecurityLabelDisable=true`（因为挂载的 socket 无法重标记），而在显式要求保留标签时单元不作该设置并给作业工作区挂载添加 `:z` 重标记选项

### Requirement: 配置记录与派生

安装器 SHALL 把 `.env` 作为唯一权威配置记录，并由它派生每个服务使用的环境变量文件与单元文件。

#### Scenario: 权威配置文件权限

- **WHEN** 安装器写入 `${INSTALL_DIR}/.env`
- **THEN** 文件权限为 600，包含项目名、镜像、缓存设置、实例计数与每个实例的 URL、token、前缀、标签、工作区

#### Scenario: 派生环境变量文件

- **WHEN** 安装器为某个 runner 实例或缓存服务生成环境变量文件
- **THEN** 该文件仅含 `KEY=VALUE` 行、权限为 600，并按 `.env` 中的值填充运行时变量（含缓存地址与透传的运行时可调参数）

#### Scenario: 恢复既有配置

- **WHEN** 安装目录已存在 `.env` 且用户选择追加实例或查看状态
- **THEN** 脚本从该文件读取既有实例配置，不要求用户重新输入已配置实例的 token

### Requirement: 卸载与清理

安装器 SHALL 支持卸载 stack，并在删除持久数据前要求显式确认。

#### Scenario: 卸载并移除单元

- **WHEN** 用户以 `--uninstall` 运行
- **THEN** 脚本停止 stack 内单元、按项目前缀删除对应 Quadlet 单元文件与容器、重新加载 systemd 配置，并保留 `${INSTALL_DIR}/.env` 以便追溯

#### Scenario: 卸载不影响其他 stack

- **WHEN** Quadlet 输出目录中还存在其他前缀的单元文件
- **THEN** 卸载只删除本项目前缀的单元文件，其他文件保持不变

#### Scenario: 可选删除持久数据

- **WHEN** 同一命令中用户确认删除持久数据（或以 `GHR_UNINSTALL_VOLUMES=yes`/`GHR_UNINSTALL_WORKDIR=yes` 显式授权）
- **THEN** 脚本额外删除命名卷与作业工作区目录；未确认时保留这些数据并说明其位置

#### Scenario: 非交互式卸载

- **WHEN** 用户以 `--non-interactive --uninstall` 运行
- **THEN** 脚本不提问即执行卸载，但仍保留持久数据，除非对应的 `GHR_UNINSTALL_*` 变量被显式设为 `yes`

### Requirement: 输入校验与退出码语义

安装器 SHALL 在写入任何文件前校验输入，并以稳定退出码区分成功、一般错误与参数错误。

#### Scenario: 非法目标 URL

- **WHEN** 提供的 GitHub URL 既不是仓库也不是组织地址
- **THEN** 脚本打印期望格式并以退出码 1 结束，且不创建任何单元文件

#### Scenario: 不安全的安装目录

- **WHEN** 安装目录包含空格、冒号或 systemd 说明符 `%`
- **THEN** 脚本拒绝该路径并说明其会破坏容器绑定挂载或 systemd 单元语义

#### Scenario: 并发执行保护

- **WHEN** 同一安装目录中存在未清除的安装锁
- **THEN** 脚本拒绝执行并输出锁信息，待锁释放后重试可成功且锁在退出时被清理

#### Scenario: 帮助与未知参数

- **WHEN** 用户传入 `--help` 或未知参数
- **THEN** `--help` 输出用法并以退出码 0 结束，未知参数输出用法并以退出码 2 结束
