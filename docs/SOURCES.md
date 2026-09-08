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
| [Fail2ban](https://github.com/fail2ban/fail2ban) | 待实现的登录封禁功能参考 |
| [Debian 发布](https://www.debian.org/releases/) | 维护版本范围 |
| [Ubuntu 生命周期](https://ubuntu.com/about/release-cycle) | 维护版本范围 |
| [Alpine 发布](https://alpinelinux.org/releases/) | 维护版本范围 |

用户提供的 [NodeSeek 帖子](https://www.nodeseek.com/post-724033-1) 多次读取失败，搜索未取得正文。未将其内容作为已核对依据，也没有执行该帖可能引用的脚本。后续仍需补充核对。
