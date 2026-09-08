# 资料与采用边界

查阅日期：2026-09-09。以下资料用于理解接口和约束，不代表已逐行审计其整个项目。

| 来源 | 用途 |
| --- | --- |
| [Linux IP Sysctl](https://kernel.org/doc/html/latest/networking/ip-sysctl.html) | TCP 自动调节、缓冲单位、UDP 参数、拥塞控制 |
| [Linux VM Sysctl](https://kernel.org/doc/html/latest/admin-guide/sysctl/vm.html) | swappiness 的适用条件；不统一套用固定值 |
| [CPUFreq](https://www.kernel.org/doc/html/latest/admin-guide/pm/cpufreq.html) | 检查实际调频接口及 governor |
| [网络多核处理](https://docs.kernel.org/networking/scaling.html) | RSS/RPS/XPS 需按队列和负载判断 |
| [zram](https://cdn.kernel.org/doc/html/latest/admin-guide/blockdev/zram.html) | 压缩交换设备的创建和复位 |
| [zswap](https://www.kernel.org/doc/html/latest/admin-guide/mm/zswap.html) | 压缩缓存与磁盘交换的关系 |
| [Google BBR quick start](https://github.com/google/bbr/blob/master/Documentation/bbr-quick-start.md) | BBR 与内核能力、pacing 的关系 |
| [Google BBR v3](https://github.com/google/bbr/blob/v3/README.md) | 不把参数名 bbr 直接等同于特定版本 |
| [OpenSSH sshd](https://man.openbsd.org/sshd.8) | 语法检查与有效配置检查 |
| [OpenSSH sshd_config](https://man.openbsd.org/sshd_config) | Port、Include、Match 及认证选项 |
| [Ubuntu OpenSSH](https://ubuntu.com/server/docs/how-to/security/openssh-server/) | 发行版 SSH 服务配置差异 |
| [Red Hat 网络安全](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html-single/securing_networks/securing_networks) | SELinux SSH 端口标签及 firewalld |
| [journald 配置](https://www.freedesktop.org/software/systemd/man/252/journald.conf.html) | 空间上限、预留空间、压缩和保留期 |
| [logrotate](https://github.com/logrotate/logrotate) | 定时轮转与大小检查 |
| [Docker 日志](https://docs.docker.com/engine/logging/configure/) | 默认日志配置及新容器生效边界 |
| [Docker 防火墙](https://docs.docker.com/engine/network/packet-filtering-firewalls/) | 容器发布端口与主机防火墙交互 |
| [nftables 手册](https://netfilter.org/projects/nftables/manpage.html) | 规则检查与应用 |
| [nftables 原子更新](https://wiki.nftables.org/wiki-nftables/index.php/Atomic_rule_replacement) | 独立表更新，避免清空全局规则 |
| [systemd-run](https://manpages.ubuntu.com/manpages/jammy/man1/systemd-run.1.html) | 独立于 SSH 的恢复任务设计参考 |
| [Fail2ban](https://github.com/fail2ban/fail2ban) | 登录封禁功能及配置参考 |
| [Debian 发布](https://www.debian.org/releases/) | 维护版本范围 |
| [Ubuntu 生命周期](https://ubuntu.com/about/release-cycle) | 维护版本范围 |
| [Alpine 发布](https://alpinelinux.org/releases/) | 维护版本范围 |

用户提供的 [NodeSeek 帖子《【保姆级】VPS 拿到手后必做的初始化配置脚本v2》](https://www.nodeseek.com/post-724033-1) 已通过浏览器读取正文；此前网页检索工具访问失败。

采用其基础设置、交换空间、日志、BBR、SSH 与登录防护的功能分类，并作以下调整：

- 以运行时内核能力确认 BBR，不仅判断版本号；不直接追加重复 sysctl。
- SSH 端口采用双入口、有效配置检查和独立恢复机制，处理 socket activation。
- Fail2ban 读取当前 SSH 端口，避免改端口后封禁规则仍针对默认端口。
- 日志使用独立配置片段，保留原配置备份；不立即删除历史日志。
- zram/swap 自行实现，不运行文章引用的浮动分支脚本。

帖子还介绍 WARP、Docker 安装及外部跑分/解锁工具。这些会改变路由、安装业务环境或向外部服务发送测试流量，未作为初始化优化的默认动作，也未对这些外部项目作无后门保证。当前工具不引用或运行其代码。

[OpenSSH 认证信息回归测试](https://github.com/openssh/openssh-portable/blob/master/regress/authinfo.sh) 用于核对 `ExposeAuthInfo` / `SSH_USER_AUTH` 的公钥登录验证方法。
