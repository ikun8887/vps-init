# VPS Init

轻量中文 VPS 初始化工具：**一行启动、一键优化、独立模块、重复安装、卸载恢复、当场显示结果**。

v0.3.0-beta.1 提供约 90 KB 的单文件 Bash 程序。ANSI 配色无需界面依赖，支持 `NO_COLOR=1`。运行模块使用 Linux 自带工具；缺少的管理工具可从发行版软件源安装。Docker JSON 配置模块单独需要已有的 Python 3。

## 一行启动

在 Linux VPS 的 root 终端执行，打开菜单：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ikun8887/vps-init/v0.3.0-beta.1/install.sh)
```

**直接一键优化，不再选择菜单：**

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ikun8887/vps-init/v0.3.0-beta.1/install.sh) auto
```

安装后输入 `vps-init` 随时打开菜单。重复执行安装命令会重装该固定版本工具，保留配置及备份；以后升级只需改用新版本安装地址。下载程序和 SHA256 校验表均来自本仓库固定发行版，校验可发现下载损坏，仍需信任仓库发布者。

最小镜像需先安装 Bash、curl、util-linux/flock、sha256sum。例如 Debian/Ubuntu：`apt-get update && apt-get install -y bash curl util-linux coreutils`；Alpine：`apk add bash curl util-linux coreutils`。安装器不会更换系统内核或额外软件源。

## 独立模块

不想执行整套优化，直接选择模块。以下命令在 root 下运行：

```bash
vps-init apply network --yes --install-tools           # TCP / UDP 缓冲、内核 BBR
vps-init apply logs --yes --install-tools              # 日志大小与保留周期
vps-init apply memory --yes --swap-mb 1024             # 无 swap 时创建 1 GiB
vps-init apply memory --yes --zram                    # 无现有 swap/zswap 时启用 zram
vps-init apply cpu --yes                              # 有接口时启用 performance
vps-init apply security --yes                         # 内核安全基线
vps-init apply disk --yes                             # TRIM 调度与磁盘检查
vps-init apply ssh --yes --install-tools --ssh-port 22222
vps-init apply firewall --yes --install-tools --allow tcp:80,443 --allow udp:443
vps-init apply fail2ban --yes --install-tools          # 软件源可提供时安装并配置
vps-init apply docker --yes                           # 已有 Docker 的日志轮转
vps-init apply time --yes --timezone Asia/Shanghai     # 时区及已有 NTP 服务
```

也可以把 `apply network --yes --install-tools` 接在一行安装命令后面，直接完成下载和该模块配置。防火墙模块不改 SSH 配置；SSH 模块会同步放行目标端口。未适配的能力会显示具体跳过原因。

## 运行时会看到什么

```text
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  VPS INIT · 初始化与优化控制台
  一键优化 · 独立模块 · 重复安装 · 一键卸载
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

── [1/8] 安装工具 ──
  ✓ 已处理
── [2/8] 基础维护 ──
  ✓ 已处理
...
========== VPS Init 运行结果 ==========
结果：配置流程已结束。
  日志轮转：已处理
  TCP/UDP/BBR：已处理
SSH 原端口：22
SSH 新端口：22222（已生效；原入口保留，无需确认命令）
SSH 当前配置端口：22222,22
目标 TCP 端口 22222：正在监听（公网连通性仍需登录验证）
TCP 当前拥塞算法：bbr
当前 swap：总量 1024 MiB，已用 0 MiB
```

以上是示意，真实端口、状态、跳过原因和耗时会在**当前会话结束前直接输出**。详细执行输出进入 `/var/lib/vps-init/<操作ID>/run.log`，不再把 apt 和 logrotate 调试信息刷满终端。结果同时保存在该目录的 `summary.txt`；失败会保留非零退出码并输出失败模块、末尾日志。菜单执行后按回车即可返回。

## SSH 与重复执行

- 默认自动选择 20000–39999 空闲端口；本机语法、监听及持久化检查通过后完成，并保留原 SSH 入口。**普通优化不需要另开 SSH 会话或执行确认命令。**
- 再次运行复用已管理端口，不反复随机；指定 `--ssh-port` 可以新增另一个目标端口。已有 swap 保留，不重建或清空。
- `--keep-ssh-port` 保留端口，仍可应用适用的防火墙；独立运行其他模块不会修改 SSH。
- 旧版遗留的待确认操作，会先通过真实备份和冲突检查恢复，再执行新的操作。人工改动造成冲突时会停止并指出文件，不会通过删标记冒充成功。
- 云安全组、NAT 和提供商防火墙需放行新端口。脚本显示“本机监听”不等于已验证公网可达。

需要**关闭旧端口或禁用原认证方式**时，使用可选严格模式：

```bash
vps-init apply ssh --yes --strict-ssh --ssh-port 22222
# 仅严格模式需要：从新端口登录后，执行摘要里给出的 confirm-ssh 命令。
```

严格模式有 5 分钟独立恢复任务。普通模式在完成本机检查后取消恢复任务；若中途失败，恢复任务保留。OpenRC 的 SSH 变更需要已启用的 atd；缺少时跳过并说明。公钥管理员向导也使用严格模式，确认真实公钥登录后才关闭密码/root 登录。

## 卸载 / 恢复

```bash
vps-init uninstall --yes                 # 按逆序恢复所有操作，再卸载命令
vps-init uninstall --yes --keep-config   # 只卸载程序，保留已完成的系统优化
vps-init rollback 操作ID                 # 恢复某次操作，例如单独安装的模块
```

默认卸载按实际运行顺序逆向恢复，包括重复优化和独立模块操作。遇到事后的人工修改会停止，保留工具方便处理；修复冲突后可重试。已恢复的操作会跳过。需要单独撤销某模块时，使用其独立运行摘要中的操作 ID；一键优化的备份作为整次操作恢复。

备份、系统软件包、新建用户和业务数据保留。软件包升级、已轮转日志不能撤销。交换空间不足时不会强行删除正在使用的 swap。安装目录为 `/usr/local/lib/vps-init`，快捷命令为 `/usr/local/bin/vps-init`；卸载只删除安装器管理的文件。

## 功能与适配范围

| 模块 | 实际处理 |
| --- | --- |
| CPU | 检测 CPUFreq 与现有调频管理器，可选 performance 并持久化；没有接口的 VPS 跳过 |
| 内存 | 无 swap 时创建 512–2048 MiB 自动交换文件，支持指定大小或 zram；检查磁盘空间和文件系统 |
| 日志 | journald 持久日志 128/256 MiB、运行时 32/64 MiB、14 天；logrotate 默认每周/4 份/16 MiB，应用自身规则优先 |
| TCP / UDP | 按 RAM 或带宽×RTT 提高缓冲上限，保留更大现值；不改 MTU、转发、IPv6 和业务重传策略 |
| BBR | 启用内核已有 `bbr`；可选后续设备默认 FQ，不覆盖当前 tc 队列 |
| 安全 | SYN cookies、硬链接/符号链接保护；保留 SELinux/AppArmor；公钥管理员及可选登录加固 |
| 防火墙 | 活动 UFW/firewalld，或无冲突时使用 nftables；保留现有服务、ICMP、DHCP 和已有管理规则 |
| SSH | 自动/指定端口、普通服务及适配的 socket 模式、SELinux 端口检测、可恢复变更 |
| 磁盘 | 空间/inode 检查、支持时启用 TRIM 定时器，不清空业务数据 |
| 可选 | 已有 NTP、时区/主机名、发行版安全更新、Fail2ban、Docker 日志 |

网络自适应示例：`vps-init apply network --yes --network-profile throughput --bandwidth-mbps 1000 --rtt-ms 100`。只读检查：`vps-init check`、`vps-init network`、`vps-init verify`。全部参数：`vps-init help`。

面向 Debian/Ubuntu、RHEL 系、Alpine、openSUSE/SLES，按 systemd/OpenRC 和内核实际能力判断；容器不接管宿主机网络、交换空间与 SSH。不宣称支持所有历史 Linux 版本，未知发行版只读。

**BBRv3 需要对应内核实现，不能靠几个 sysctl 参数安装。** 本工具不下载未知内核、不执行 kejilion、vps-setup、bbrv3-lite、VPS-Optimize 的远程脚本；仅参考功能及交互并自行实现。`bbr` 名称无法单独证明代际，TCP BBR 也不会直接控制 UDP/QUIC 拥塞算法。

研究依据：[官方资料](docs/SOURCES.md)、[参考项目审阅](docs/REFERENCE-REVIEW.md)。验证范围与限制：[VALIDATION](docs/VALIDATION.md)。构建：`python3 scripts/build-release.py dist`，产物仅一个 Bash 文件及校验表。许可证 MIT。
