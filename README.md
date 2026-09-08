# VPS Init

中文 Linux VPS 初始化工具，提供一键优化、只读预览、事务备份及恢复。

**当前为开发预览版，尚未完成真实 VPS、SSH 迁移、重启和跨发行版验收。请先在可恢复的测试机验证，不应直接用于唯一访问入口的生产服务器。**

## 一键使用

下载仓库的完整源码包并解压。不要只下载入口脚本，它需要同目录下的 `lib/`。

```bash
# 只读检查和预览
bash vps-init.sh check
bash vps-init.sh plan

# 一键优化：显示计划后输入 yes
sudo bash vps-init.sh optimize

# 自动执行，指定 SSH 新端口，并放行网站端口
sudo bash vps-init.sh optimize --yes --ssh-port 22222 --allow tcp:80,443

# 自动执行但保持 SSH 端口，且不创建交换空间
sudo bash vps-init.sh optimize --yes --keep-ssh-port --no-swap
```

`optimize` 是一键入口，默认覆盖全部基础模块。已有 swap、缺少内核权限、现存防火墙冲突等情形会输出跳过原因。**执行结束不代表所有模块都修改成功，也不代表性能必然提升。**

## 当前功能

| 模块 | 当前实现 |
| --- | --- |
| 环境检测 | Linux、发行版、初始化系统、虚拟化、内存/cgroup 限额、磁盘、监听端口 |
| 日志 | journald 持久/内存空间限制、保留期、压缩；logrotate 配置验证 |
| 内存 | 无 swap 时按资源创建磁盘 swap；可选 zram；保护空间不足及已有 swap |
| CPU | CPUFreq 支持时可选 performance；当前只在本次启动生效 |
| TCP/UDP | 分内存等级提高缓冲上限、保留 TCP 自动调节、显示丢包/重传计数 |
| BBR | 检测并启用内核提供的 `bbr`，不替换内核，不猜测 BBR 版本 |
| 内核安全 | 硬链接/符号链接保护、SYN cookies；保留 SELinux/AppArmor 状态 |
| 磁盘 | 空间/inode 检查、受支持的系统 fstrim 定时器 |
| SSH | systemd 普通服务模式下新旧端口过渡、独立恢复定时器、实际连接确认 |
| 防火墙 | 适配活动 firewalld/UFW；无冲突时管理独立 nftables 表，保留现有监听服务 |
| Docker | 可选配置新容器默认日志轮转；不自动重启 Docker |
| 事务 | 配置备份、运行日志、重复写入保留原备份、回滚冲突检测 |

BBR 的 sysctl 作用于 TCP，不会直接改变 QUIC 应用的拥塞控制；UDP 缓冲调整也要求应用正确使用 socket 缓冲设置。

## 可选项

```bash
sudo bash vps-init.sh optimize --install-tools          # 使用现有发行版软件源
sudo bash vps-init.sh optimize --swap-mb 1024           # 无 swap 时创建 1 GiB
sudo bash vps-init.sh optimize --zram                   # 无 swap 且无 zswap 时使用 zram
sudo bash vps-init.sh optimize --cpu-performance        # 需要真实可写 CPUFreq 接口
sudo bash vps-init.sh optimize --docker-log-limit       # 需要 python3 和 dockerd
sudo bash vps-init.sh optimize --security-updates       # 受支持的系统安全更新流程
sudo bash vps-init.sh optimize --hostname my-vps --timezone Asia/Tokyo
bash vps-init.sh help
```

依赖 Bash 4+、GNU/coreutils 风格的基础工具、util-linux（含 flock）、procps 和 iproute2。Alpine 最小镜像需要提前准备 Bash 和这些工具。`--install-tools` 不修改软件源、不关闭签名校验；它也不能引导缺失的 Bash/flock。

## SSH 迁移与恢复

1. 先确认云厂商控制台可用，并放行目标端口的云安全组/NAT 映射。使用自动随机端口时，在脚本显示端口后操作。
2. 脚本保留新旧监听端口，并设置 5 分钟恢复期限。
3. 从新端口重新登录，执行输出的确认命令，例如：

```bash
sudo --preserve-env=SSH_CONNECTION bash vps-init.sh confirm-ssh 20260909T000000Z-1234
```

上面是事务 ID 示例，请使用实际输出。`SSH_CONNECTION` 会用于检查新会话的服务端口；root 本来就能伪造环境，因此这不是对 root 的安全认证边界。

确认后 SSH 关闭旧监听；UFW/firewalld 的既有放行规则可能仍保留，不代表旧端口仍有 SSH 服务。nftables 保留的既有业务规则也不会被当作 SSH 专属规则删除。

未确认则恢复整个配置事务。修改配置后发现人工变更，回滚会拒绝覆盖，需要通过保留会话或控制台处理。恢复定时器也不能对机器宕机、磁盘损坏和云安全组误改提供保证。

```bash
sudo bash vps-init.sh verify
sudo bash vps-init.sh rollback <实际事务ID>
```

备份和运行日志在 `/var/lib/vps-init/<事务ID>/`，仅 root 可读。请管理历史备份空间；当前不自动清除备份。软件包升级和已轮转日志无法回滚。不要删除尚在等待 SSH 确认的事务目录。

## 兼容和待完成事项

已编写 Debian/Ubuntu、Rocky/AlmaLinux/RHEL/Fedora、Alpine、openSUSE/SLES 的工具安装适配。**适配代码存在不代表该系统已经通过测试。**

- 当前未通过真实虚拟机运行及重启验证，正式支持矩阵尚未建立。
- SSH socket activation 和 OpenRC 的安全访问迁移当前明确跳过，后续需要实现和验证。
- 密钥导入、管理员账号创建、禁止密码/root 登录、Fail2ban 尚未实现。
- 应用日志轮转审计、备份保留策略、CPU 持久化、细化网络场景和性能基准尚待补齐。
- 当前 `plan` 为模块级预览，逐文件/逐参数差异预览尚待补齐。
- 容器默认跳过交换空间、内核调优及访问控制；宿主机限制不能通过脚本绕过。
- 不承诺对 EOL 系统提供安全维护；当前版本检测尚未实现维护期策略。

## 测试

```bash
find . -name '*.sh' -print0 | xargs -0 -n1 bash -n
shellcheck -x vps-init.sh lib/*.sh tests/*.sh
bash tests/test-core.sh
```

测试不需要 root，只在临时目录操作。静态检查和临时文件测试不能替代 SSH、防火墙、swap、内核与重启集成测试。

## 安全与来源

核心代码自行实现，无运行时远程脚本执行、预置公钥/密码、遥测或隐藏下载。不能以此保证“绝对无漏洞或后门”；需要对每个发布版本审计并记录验证证据。

技术依据、参考帖状态见 [资料来源](docs/SOURCES.md)。
