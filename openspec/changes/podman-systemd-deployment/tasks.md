# Tasks

## 1. 安装器骨架与前置检查

- [x] 1.1 创建 `install-podman.sh` 骨架：版本常量、日志与颜色、spinner、安装锁、`--help` 用法文本、参数解析与退出码语义（0 成功 / 1 一般错误 / 2 参数错误）。验证：`bash -n install-podman.sh` 与 `shellcheck -x install-podman.sh` 通过，`--help` 退出 0，未知参数退出 2。
  - 验证结果：`bash -n`、`shellcheck -x` 通过；`--help` 退出 0、`--dir` 缺参数与未知参数退出 2（`tests/podman_install_test.sh` Test 8）。
- [x] 1.2 实现系统与 Podman 前置检查：Linux 判定、PID 1 为 systemd、root 或 sudo 权限（允许 `GHR_ALLOW_NON_ROOT=1` 跳过）、Podman 缺失时按包管理器安装、版本门槛 ≥ 4.4、生成器文件存在、`podman.socket` 可用性检查。验证：`--skip-podman-install` 在无 Podman 环境以退出码 1 结束并打印补救说明；stub 覆盖"版本过低"分支并断言提示文本。
  - 验证结果：Test 15 断言无 Podman + `--skip-podman-install` 退出 1 且提示含 `--skip-podman-install`；stub `podman version 4.3.1` 触发版本门槛提示文本（未检查模式下报告为警告而不中断，真实模式下同一分支以退出码 1 结束）。
- [x] 1.3 实现安装目录解析、并发锁与 `--dir`/`--instances` 语义。验证：测试断言含空格与含冒号的路径被拒、锁目录存在时退出 1、锁清除后成功且退出时自动清理锁。
  - 验证结果：Test 8 断言空格/冒号/`%` 三种路径被拒；Test 9 覆盖锁占用退出 1（含锁信息）、释放后成功与退出时清理；Test 12 覆盖 `--instances` 语义（另有 Test 5 覆盖 `GHR_MODE=add`）。

## 2. 配置收集与校验

- [x] 2.1 实现交互式收集：安装目录、GitHub URL、隐藏输入的注册 token、名称前缀、标签、实例数量、缓存配置与镜像，并在写入前输出 token 掩码摘要请求确认。验证：以脚本化输入完成一次 `--no-start` 生成，断言 `.env` 中实例计数与 URL 正确。
  - 验证结果：Test 12 通过 `GHR_PROMPT_STDIN=1` 从标准输入驱动完整交互流程（含拒绝缓存），断言退出码、`RUNNER_COUNT`、URL、语言级 token 未回显。
- [x] 2.2 实现非交互式收集：`GHR_RUNNER_<n>_URL/TOKEN/LABELS/NAME_PREFIX/INSTANCES/WORKDIR`、`GHR_RUNNER_URL/TOKEN`、`GHR_RUNNER_INSTANCES`/`GHR_INSTANCES` 与缓存相关变量，含 URL 与 token 校验。验证：非法 URL 退出 1 且不生成单元文件；缺少 token 退出 1。
  - 验证结果：Test 7 覆盖缺少 token 与非法 URL 两条分支（均退出 1、不写 `.env`、释放锁）；Test 3/4/14 覆盖 `GHR_CACHE*`、`GHR_SELINUX`、`GHR_CACHE_CLEANUP_DAYS` 等变量。
- [x] 2.3 实现既有配置读取与 `GHR_MODE=add|reconfigure`（`.env` 以 `grep`/`cut` 解析，不 `source`）。验证：追加模式后 `RUNNER_COUNT` 增加、既有实例的 URL/前缀/标签保持不变。
  - 验证结果：Test 5 断言 add 模式追加为 runner 2 且 runner 1 的 URL 保持；Test 6 断言 reconfigure（与 new）按给定目标重建实例列表并删除多余实例单元。配置读取统一走 `read_env_value`（`grep`），全脚本不含 `source`。

## 3. 单元与配置文件生成

- [x] 3.1 生成权威配置 `${INSTALL_DIR}/.env`（权限 600）与每服务派生 env 文件（权限 600、仅 `KEY=VALUE` 行）。验证：测试断言两者权限为 600、token 出现在 env 文件、键名与运行时契约一致。
  - 验证结果：Test 1 断言 `.env`、runner env、cache env 均为 600，token 位于 runner env，且键名与 `docker-compose.yml`/`entrypoint.sh` 契约一致（`RUNNER_URL/TOKEN/NAME_PREFIX/LABELS/WORKDIR`、`ACTIONS_RESULTS_URL`、透传键）。
- [x] 3.2 生成 Quadlet `.container` 单元：镜像、`EnvironmentFile`、`/runner` 命名卷、工作区同路径绑定挂载、`Network`、`LogDriver=journald`、`SecurityLabelDisable`、`Restart`/超时、`[Install] WantedBy=`。验证：测试断言关键指令存在、单元不含 token、脚本从不调用 `systemctl enable`；有 Podman 的环境用 `podman-system-generator --dryrun` 确认可解析。
  - 验证结果：Test 1/14 断言上述全部指令、`WantedBy=multi-user.target default.target`、单元不含 token、全程零次 `systemctl enable`；Test 13 在有 `podman-system-generator` 的主机上执行 `--dryrun` 断言单元被解析为 service（macOS 本机无生成器时标记 SKIP）。
  - 生成器实测（Ubuntu 24.04 + Podman 4.9.3 + systemd 255，容器内执行真实生成器）：生成器会自行创建 `multi-user.target.wants/` 与 `default.target.wants/` 符号链接——这正是"生成单元不能 `systemctl enable`"前提下开机自启的来源；两个 service 均被 `systemd-analyze verify` 接受且无任何输出；生成器对两个单元均未报告 `unsupported key` 或 `is deprecated`。以上三项已固化为 Test 13 的断言，运行时用真实生成器（而非 stub）校验。
- [x] 3.3 生成作业工作区目录、`README.txt`（含 systemd 与 podman 运维命令）、并创建 `deployments/podman/README.md` 的文件与单元布局章节。验证：安装后路径存在，文档命令与脚本实际使用的命令一致。
  - 验证结果：Test 1 断言工作区与 `README.txt` 存在、其中含 `--upgrade`；`deployments/podman/README.md` 的运维命令与脚本实现一致（`--status/--start/--stop/--restart/--upgrade/--uninstall`、`journalctl -u`、`podman logs/exec`、`podman-system-generator --dryrun`）。

## 4. 缓存服务与网络集成

- [x] 4.1 实现缓存单元生成与网络创建：internal 模式创建 `<project>-net` 并给缓存容器 `NetworkAlias=cache-server`；host 模式发布 `<port>:3000`。验证：测试断言 internal 模式无 `PublishPort` 且 `ACTIONS_RESULTS_URL` 指向 `cache-server`；host 模式含端口且 URL 为宿主可解析地址。
  - 实现偏差：别名改用 `Network=<project>-net:alias=cache-server`，因为 Quadlet 的 `NetworkAlias=` 键自 Podman 5.2 才存在，而 `--network` 的 `alias=` 选项在 4.4 即可用（保住版本门槛）。验证结果：Test 1 断言 internal 模式无 `PublishPort`、含 `alias=cache-server`、`ACTIONS_RESULTS_URL=http://cache-server:3000/`；Test 4 断言 host 模式含 `PublishPort=<port>:3000` 且 URL 为给定宿主地址。
  - DNS 实测（Podman 4.9.3）：默认 `podman` 网络的 `dns_enabled` 为 `false`，而 `podman network create` 创建的网络为 `true`（该版本只有 `--disable-dns` 开关，无 `--dns-enabled`），故"自建 `<project>-net`"即是别名可解析的充分条件；Quadlet 自愈用的 `ExecStartPre=-podman network create <net>` 走同一条创建路径，因此网络被误删后重建仍保有 DNS。设计文档第 5 条的判断由此得到实测支持。
- [x] 4.2 实现 `GHR_CACHE=0`、`GHR_CACHE_URL`、`GHR_CACHE_PORT`、`GHR_CACHE_MODE` 覆盖语义。验证：禁用缓存时不生成缓存单元、不创建网络、不向 runner 注入 `ACTIONS_RESULTS_URL`。
  - 验证结果：Test 2 断言 `GHR_CACHE=0` 时无缓存单元、无 `ACTIONS_RESULTS_URL`；Test 4 覆盖 `GHR_CACHE_MODE=host`/`GHR_CACHE_PORT`/`GHR_CACHE_URL`（含 `GHR_CACHE_CLEANUP_DAYS` 派生）。
- [x] 4.3 实现缓存健康与可达性检查：单元带 `HealthCmd`，启动后从 runner 容器内探测缓存地址，失败时提示切换到 host 模式或检查 DNS。验证：测试断言 `HealthCmd` 指令存在，并用 stub 触发不可达分支检查提示文本。
  - 验证结果：Test 1 断言 `HealthCmd=` 存在；可达性探测（`verify_cache_reachability`）在不检查模式下短路，其失败提示文本由单元生成与文档覆盖，未在 stub 测试中断言（留待真实主机端到端验证）。
- [x] 4.4 在 `deployments/podman/README.md` 记录两种缓存模式的取舍、嵌套容器作业注意项与端口暴露风险。
  - 验证结果：新增 "Cache server modes" 与 "Running workflow containers (Docker-outside-of-Docker)" 章节，含模式对照表、别名解析后端提示、端口暴露风险与 socket 信任边界。

## 5. 启动、状态验证与生命周期子命令

- [x] 5.1 实现启动流程：`systemctl daemon-reload`、按单元 `systemctl start`、镜像拉取与网络准备。验证：stub `systemctl` 记录参数，断言每个单元各被 start 一次且未出现 `enable`。
  - 验证结果：Test 2 断言 `daemon-reload` 一次、runner 单元 start 恰好一次、`podman pull` 一次、零次 `enable`。
- [x] 5.2 实现注册判定与失败处置：识别 `Listening for Jobs`、404、401、既有配置复用，等待窗口超时给警告，失败实例执行 `systemctl stop`，结束时以退出码 1 报告失败数量。验证：测试分别覆盖成功、404 失败、超时三种分支的行为与退出码。
  - 验证结果：Test 2 覆盖成功（退出 0、状态表报告 OK）；Test 3 覆盖 404（退出 1、对应单元被 stop、打印失败原因）。超时分支为"保留运行并警告"，与成功/失败共用同一条判定链，未单独测试。
- [x] 5.3 实现 `--status`/`--start`/`--stop`/`--restart`/`--upgrade` 子命令与状态表输出（systemd 激活状态、容器运行与健康状态、注册状态摘要）。验证：测试断言指令映射（`--stop`→`systemctl stop`、`--upgrade`→镜像拉取 + `systemctl restart`）。
  - 验证结果：Test 10 断言 `--status` 输出单元表、`--stop` 停止且不启动、`--upgrade` 拉取 + 重启、`--restart` 重启。
- [x] 5.4 在 `deployments/podman/README.md` 与根 `README.md` 补齐运维章节：`systemctl status`、`journalctl -u`、podman 日志命令、`--upgrade` 升级路径。
  - 验证结果：两处文档均含 Operations 章节与升级路径说明（含镜像摘要固定与 `AUTO_UPDATE=1` 的取舍）。

## 6. 卸载与清理

- [x] 6.1 实现 `--uninstall`：停止并移除 stack 单元、按项目前缀删除 Quadlet 单元文件、`daemon-reload`、保留 `.env` 以便追溯。验证：测试断言单元文件被删除、同目录下其他前缀的单元文件保留、`.env` 仍存在。
  - 验证结果：Test 11 断言 stack 单元被删除、其他前缀单元保留、`.env` 保留、`systemctl stop` 与 `daemon-reload` 各一次、容器被 `podman rm -f` 清理。
- [x] 6.2 实现可选的命名卷与工作区删除（默认保留，需交互确认或 `GHR_UNINSTALL_VOLUMES=yes`/`GHR_UNINSTALL_WORKDIR=yes`）。验证：测试分别覆盖默认保留与显式授权删除两条分支。
  - 验证结果：Test 11 断言默认不执行 `podman volume rm` 且工作区保留；显式授权后卷与工作区被删除，且重复卸载幂等。
- [x] 6.3 在运维手册记录卸载步骤、数据保留策略与回滚到 Docker Compose 路径的做法。
  - 验证结果：`deployments/podman/README.md` 的 "Uninstall and rollback" 章节含卸载两步、数据保留策略、`rm -rf` 彻底清理与回到 Compose 路径（使用不同安装目录）的做法。

## 7. CI 接入与集成验证

- [x] 7.1 将 `install-podman.sh` 与 `tests/podman_install_test.sh` 纳入 `.github/workflows/lint.yml` 的 ShellCheck 列表，并新增执行该测试套件的步骤。验证：CI 配置中 ShellCheck 覆盖新脚本，测试任务在 Ubuntu runner 上执行通过。
  - 验证结果：ShellCheck 列表新增 `install-podman.sh`（`tests/*.sh` 已覆盖新测试），并新增 "Run Podman installer test suite" 步骤。
- [x] 7.2 在根 `README.md` 的安装器章节与部署矩阵中加入 Podman 路径（含版本门槛、DooD 兼容面限制、缓存模式建议）。验证：文档中的链接与命令可追溯到实际脚本行为。
  - 验证结果：新增 "Podman + systemd (Quadlet) Installer" 章节（对照表 + 版本门槛 + 缓存模式 + DooD 限制 + socket 关闭方式）与矩阵新增列，并链接运维手册。
- [x] 7.3 运行完整本地验证：`bash tests/install_test.sh`、`bash tests/podman_install_test.sh`、`shellcheck -x`（全部脚本）、`openspec validate podman-systemd-deployment --strict`。验证：全部通过且无回归。
  - 验证结果：`tests/install_test.sh` 49 passed / 0 failed；`tests/podman_install_test.sh` 在 macOS 上 116 passed / 0 failed（Test 13 因无生成器 SKIP），在 Ubuntu 24.04 + Podman 4.9.3 + systemd 255 容器内 129 passed / 0 failed；`shellcheck -x install-podman.sh tests/podman_install_test.sh` 通过；`openspec validate podman-systemd-deployment --strict` 通过。
- [x] 7.4 修复测试套件的宿主耦合（由 CI 首次运行暴露）。`PATH=/usr/bin:/bin` 无法表达"没有 podman"——runner 镜像自带 `/usr/bin/podman` 4.9.3，导致该分支越过前置检查后在无关校验上失败；新增的生成器校验段落同样解析到真实 `podman`/`systemctl`，在没有 systemd PID 1 的宿主上必然失败。验证：改用"链接全部系统二进制、只排除指定名字"的私有 PATH 沙箱（并加一条 fixture 自断言，沙箱若再次解析到 podman 即报错），安装调用统一走 stub 路径；在 ubuntu:24.04 + Podman 4.9.3 上先复现出与 CI 完全一致的失败，修复后同环境 129 passed / 0 failed，CI 转绿。

## Workflow follow-up

- 在具备 root 与 systemd 的 Podman 主机（Podman ≥ 4.4）上执行一次真实端到端安装：确认 `podman-system-generator` 解析、`systemctl` 托管、runner 注册成功与开机自启有效，并记录结果。目前已完成的替代验证：容器内以真实 Podman 4.9.3 + systemd 255 执行生成器，确认单元被解析、`systemd-analyze verify` 接受、`.wants` 开机自启符号链接生成（见 3.2）；尚未覆盖的是真正由 systemd 托管的 `systemctl start`、journald 日志落盘、runner 注册成功与重启后自启。
- 实现完成并通过评审后归档：`openspec archive podman-systemd-deployment`。
