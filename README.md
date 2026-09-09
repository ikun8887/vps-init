# VPS Init

中文 Linux VPS 初始化工具：**一键优化、自动 SSH 端口、配置备份与回滚**。核心逻辑自行实现，不下载执行第三方脚本。

当前版本 **v0.2.0-beta.1**。已通过静态检查、10 种发行版容器基础检查，以及 Ubuntu 临时虚拟机的真实 SSH、UFW、swap 和 nftables 测试。它不是“所有 Linux 版本均已认证”的承诺；具体能力及未验证环境见下文。

## 下载与一键优化

完整源码解压后运行 `sudo bash vps-init.sh` 可进入中文菜单，选择 **1** 一键优化；选择 **2** 自定义网络/SSH/swap，选择 **3** 配置公钥管理员。菜单也提供只读检查、历史结果、确认与回滚。无交互终端时不弹菜单，避免阻塞自动化任务。禁用配色：`sudo bash vps-init.sh menu --no-color`，或设置 `NO_COLOR=1`。

在 VPS 上下载完整发行包（入口依赖同目录的 `lib/`），先核对校验值：

```bash
curl -fLO https://github.com/ikun8887/vps-init/releases/download/v0.2.0-beta.1/vps-init-v0.2.0-beta.1.tar.gz
curl -fLO https://github.com/ikun8887/vps-init/releases/download/v0.2.0-beta.1/SHA256SUMS
sha256sum -c SHA256SUMS
tar -xzf vps-init-v0.2.0-beta.1.tar.gz
cd vps-init-v0.2.0-beta.1

bash vps-init.sh check
bash vps-init.sh plan
sudo bash vps-init.sh optimize --install-tools
```

`optimize` 显示计划后输入 `yes` 即执行基础模块；默认在 20000–39999 中选择空闲 SSH 端口。已是 root 时可去掉 `sudo`。校验文件用于发现下载损坏，仍需信任仓库账号及所选版本。

需要无人值守执行配置时：

```bash
sudo bash vps-init.sh optimize --yes --install-tools --ssh-port 22222 --allow tcp:80,443 --allow udp:443
```

**SSH 新连接确认不能由 `--yes` 跳过。** 请预先准备云控制台，并放行目标端口的云安全组/NAT。脚本只能修改 VPS 内部配置。自动随机端口会在输出中显示，未确认则在恢复期限到达后尝试回滚整个事务。

保持现有 SSH 端口且不创建 swap：

```bash
sudo bash vps-init.sh optimize --yes --keep-ssh-port --no-swap
```

`--keep-ssh-port` 仍会处理适用的防火墙，并可能要求访问确认；它不是“跳过访问模块”。

## 功能与默认行为

运行结束会集中输出结果摘要，并写入 `/var/lib/vps-init/<事务ID>/summary.txt`。例如：

```text
========== VPS Init 运行结果 ==========
结果：配置流程已结束；SSH 仍待新连接确认。
事务 ID：20260909T000000Z-1234
  日志轮转：已处理
  CPU调频：未启用
SSH 原端口：22
SSH 目标端口：22222（待确认；旧入口暂时保留）
SSH 当前配置端口：22222,22
目标 TCP 端口 22222：正在监听（公网连通性仍需登录验证）
本次防火墙后端：ufw
TCP 当前拥塞算法：bbr
```

实际摘要还包含跳过原因、swap 状态、备份位置、新连接示例、确认及回滚命令。端口和状态以实际执行为准；未迁移、执行失败、确认成功、已经回滚会分别显示，失败仍返回非零退出码。确认及回滚后会更新同一份摘要。操作前的参数/权限检查失败或无法创建事务时，只有错误提示，不会虚构事务结果。

| 模块 | 一键默认行为 | 可选项及边界 |
| --- | --- | --- |
| 检测 | 发行版、内核、架构、systemd/OpenRC、虚拟化、cgroup 内存上限、磁盘/inode、监听端口 | 未知发行版仅允许只读命令 |
| CPU | 检查 CPU 数量与负载，保留原调频策略 | `--cpu-performance` 在真实可写 CPUFreq 接口上生效并持久化，避开已有调频服务；多数 VPS 无该接口 |
| 内存 | 已有 swap 则保留；无 swap 时按 RAM 创建 512–2048 MiB 交换文件 | `--swap-mb 1024`、`--no-swap`、`--zram`；检查空间及文件系统，不叠加已有 swap/zswap |
| 日志 | journald 持久日志 128/256 MiB、运行时 32/64 MiB、14 天；logrotate 默认每周、4 份、16 MiB 大小阈值 | 应用块内设置优先；大小阈值在轮转任务运行时检查，不是实时磁盘硬配额 |
| 事务日志 | 每次运行保存约 1 MiB，终端继续输出 | 历史配置备份不自动清理，需自行管理空间 |
| TCP/UDP | 按内存提高缓冲上限至 4/8/16 MiB，保留更大现值和 TCP 初始分配 | 不改 MTU、重传次数、UDP 超时、转发或 IPv6；应用仍需使用相应缓冲 |
| BBR | 检测并启用内核提供的 `bbr` | 不更换内核、不承诺 BBR 版本，保留既有 qdisc；不直接控制 QUIC 拥塞算法 |
| 磁盘 | 容量/inode 检查；系统支持时启用 fstrim.timer | 不删除业务数据、不更改挂载选项 |
| 内核安全 | 硬链接/符号链接保护、SYN cookies | 保留 SELinux/AppArmor；不关闭安全模块 |
| SSH | 自动选端口、新旧入口过渡、语法/有效配置/监听检查、独立恢复任务 | 支持普通服务及可识别的 socket 绑定；SELinux 端口迁移需要 semanage |
| 防火墙 | 使用活动 UFW/firewalld；无冲突时创建独立 nftables 表 | nft 默认拒绝新入站，保留当前监听服务、ICMP/IPv6 邻居发现和 DHCP；不接管自定义规则或 Docker 网络 |
| 管理员 | 默认保留现有认证 | 可导入自己的公钥、创建可信管理员、验证后关闭密码/root 登录 |
| Fail2ban | 默认不改 | `--fail2ban` 配置已安装服务及实际 SSH 端口，systemd 后端 |
| Docker 日志 | 默认不改 | `--docker-log-limit` 校验并补充新容器默认轮转；维护窗口重启 Docker 后新建容器生效 |
| 基础维护 | 显示时间同步状态 | 可设置主机名、时区、执行发行版支持的安全更新 |

CPU/网络参数并不保证每个业务更快。BBR 作用于 TCP；UDP 缓冲优化不能突破带宽、路由、内核和应用限制。每个跳过项都会说明原因，不能把“命令结束”理解为所有模块均已修改。

## 公钥管理员与登录加固

先将你自己的**公钥**上传到 VPS，例如 `/root/my-key.pub`，不要上传私钥：

```bash
sudo bash vps-init.sh optimize --install-tools --ssh-port 22222 \
  --admin-user vpsadmin --public-key /root/my-key.pub \
  --disable-password-login --disable-root-login
```

指定账号不存在时会创建；现有同名账号也会被授予 **完整免密码 sudo**，因此必须是你信任的管理员账号。公钥保存在 root 管理的 `/etc/ssh/vps-init-authorized-keys/`。

使用刚提供公钥对应的私钥，以新管理员从新端口登录：

```bash
ssh -i ~/.ssh/id_ed25519 -p 22222 vpsadmin@你的服务器IP
sudo --preserve-env=SSH_CONNECTION,SSH_USER_AUTH bash /实际解压路径/vps-init.sh confirm-ssh 实际事务ID
```

关闭密码/root 登录前，工具拒绝原主配置及其 Include 中的既有 `Match` 条件，以及无法安全解析的复杂 Include 路径。此类配置需要人工整合，不能仅凭当前会话抽样验证就宣称全局禁用成功。普通端口迁移不受这项额外限制。

## 确认与恢复

从新端口重新登录后，在 5 分钟恢复期限内执行终端给出的命令。未启用公钥管理员功能时：

```bash
sudo --preserve-env=SSH_CONNECTION bash /实际解压路径/vps-init.sh confirm-ssh 实际事务ID
sudo bash /实际解压路径/vps-init.sh verify
```

确认后停止旧 SSH 监听。为避免误删既有规则，UFW/firewalld 旧放行规则及 nftables 保留的既有服务规则可能留下；这不代表旧端口仍有 SSH 服务。

```bash
sudo bash /实际解压路径/vps-init.sh rollback 实际事务ID
```

状态与备份位于 `/var/lib/vps-init/<事务ID>/`，仅 root 可读。恢复代码复制在事务内；systemd 使用独立 timer/service，OpenRC 使用已运行并启用的 atd。缺少可靠恢复机制就跳过访问迁移。

回滚会先检查配置是否被人工修改，冲突时拒绝覆盖。swapoff 内存不足、系统损坏、服务失败也可能阻止完整回滚，需保留现有会话或使用控制台。软件包升级、已轮转日志及外部云配置不能撤销；新建管理员账号/家目录保留，但撤回本事务管理的公钥和 sudo 配置。不要删除等待确认的事务目录。多个事务应按从新到旧的顺序回滚。

重复运行会保留已有 swap 和已确认 SSH 端口；已有访问事务待确认时拒绝启动下一次优化。`plan` 是模块级预览，尚不提供逐文件差异；`verify` 检查已管理 sysctl 和 SSH 状态，不替代公网连通及重启测试。

## 可选命令

```bash
# BBR / BBRv3 内核能力、当前队列与网络参数：只读，不测速
bash vps-init.sh network

# 小内存保守档
sudo bash vps-init.sh optimize --network-profile conservative

# 按人工带宽和主要业务 RTT 计算缓冲目标
sudo bash vps-init.sh optimize --network-profile throughput --bandwidth-mbps 1000 --rtt-ms 150

# 明确保留当前拥塞算法；不把第三方 BBR 变体静默切换成 bbr
sudo bash vps-init.sh optimize --keep-bbr

# 仅改变后续队列默认 FQ；当前 tc 树不变
sudo bash vps-init.sh optimize --default-fq

# 使用已经安装且可由 timedatectl 管理的时间同步服务
sudo bash vps-init.sh optimize --enable-ntp
```

档位 `balanced` 为默认，基础目标按 RAM 为 4/8/16 MiB；`conservative` 为该目标的一半；`throughput` 为 `Mbps × RTT毫秒 × 250` 字节。三档目标均受 `max(1 MiB, min(RAM/32, 128 MiB))` 预算限制，已有更大值不降低。throughput 必须提供两项输入，它们不是测速结果，也不代表所有业务路径的实际带宽/RTT。

**BBRv3 需要内核本身支持，本工具不安装第三方内核。** 当前可信内核若提供标准 `bbr` 接口即可使用，但不能仅凭名称证明 v3。新的菜单与网络逻辑参考了四个项目，实际采用范围见 [参考项目复核](docs/REFERENCE-REVIEW.md)。

```bash
sudo bash vps-init.sh optimize --swap-mb 1024
sudo bash vps-init.sh optimize --zram
sudo bash vps-init.sh optimize --cpu-performance
sudo bash vps-init.sh optimize --docker-log-limit
sudo bash vps-init.sh optimize --fail2ban
sudo bash vps-init.sh optimize --security-updates
sudo bash vps-init.sh optimize --hostname my-vps --timezone Asia/Tokyo
bash vps-init.sh help
```

`--install-tools` 通过已配置的发行版软件源安装管理工具，不改源、不关闭签名验证。它不能引导缺失的 Bash/flock，也不会安装可选的 sudo、Fail2ban、Python、Docker、atd 或 semanage。最小系统应先使用发行版包管理器准备 Bash 4+、coreutils、util-linux、procps、iproute2 和 diffutils；Alpine 尤其需要额外安装 Bash/coreutils。

安全更新：RHEL 系使用 `dnf upgrade --security`，SUSE 使用安全 patch；Debian/Ubuntu 需要预先配置 unattended-upgrades。主机名/时区变更需要 systemd 对应工具。脚本不会自动重启机器。

## 兼容与验证

| 环境 | 已验证内容 |
| --- | --- |
| Debian 12/13、Ubuntu 22.04/24.04/26.04 | 容器中的基础命令、参数和事务文件测试、只读检测 |
| AlmaLinux 8/9/10、Alpine 3.24、openSUSE Leap 16 | 同上；容器共享宿主内核，不证明内核/服务兼容 |
| Ubuntu 22.04/24.04 临时 VM | 一键执行，实际 SSH 新连接确认、旧端口关闭、UFW、手动及超时恢复 |
| Ubuntu 24.04 socket 模式 | 实际端口迁移和恢复，保留原会话 |
| Ubuntu 24.04 公钥管理员 | 公钥登录、sudo 确认、root 禁用、恢复旧登录 |
| Ubuntu 24.04 swap/nftables | 真实交换文件、幂等与回滚；隔离网络命名空间内真实 nft 内核规则 |

Rocky/RHEL/Fedora/SLES 有适配分支，但未分别完成实机验收。ARM、OpenRC 访问迁移、CPUFreq、zram、firewalld、SELinux 迁移、Docker/Fail2ban 及整机重启仍需相应环境验证。测试版不承诺 EOL 系统可安全维护。LXC/OpenVZ/容器会跳过宿主交换空间、内核调优及访问控制；未知系统只读退出。

测试和证据见 [验证记录](docs/VALIDATION.md)、[GitHub Actions](https://github.com/ikun8887/vps-init/actions)。

## 安全与来源

代码不含预置密码/私钥/公钥、遥测、混淆或远程脚本执行。包管理器仍依赖你配置的软件源。发布前进行了源码审查并修复条件 SSH 认证覆盖问题；这些工作不能构成“绝对无漏洞/无后门”保证。

参考 NodeSeek 及 Linux、OpenSSH、systemd、发行版等官方资料，采用范围与链接见 [资料来源](docs/SOURCES.md)。核心脚本未引用帖子中的第三方一键执行代码。使用 MIT 许可证。
