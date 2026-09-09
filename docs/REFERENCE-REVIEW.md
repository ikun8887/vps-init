# 参考项目复核与本工具的实现选择

查阅日期：2026-09-09。第三方源码只下载到审阅目录作为文本读取，没有运行用户给出的远程执行命令，也没有将这些项目的脚本或二进制加入发行包。以下是初始化、网络及界面相关路径的定向复核，不是对这些大项目的全仓安全认证。

| 参考项目与固定提交 | 已读重点 | 采用的设计 |
| --- | --- | --- |
| [kejilion/sh](https://github.com/kejilion/sh/tree/298f6f23751e36726660d73b5c0c83aef1b404f4) | `kejilion.sh` 菜单/调用入口、`network-optimize.sh` 的检测和参数分档 | 中文分组菜单、状态概览、分步反馈；不引入外部应用市场或其远程执行链 |
| [yahuisme/vps-setup](https://github.com/yahuisme/vps-setup/tree/3c632678c6db241a7efcc35cf4a5cc6283268280) | `install.sh`：软件包、时间同步、BBR、swap、DNS、SSH、结束摘要 | 前置检查、可选时间同步、明确结束结果；继续保留已有 swap 与解析器，避免统一替换 |
| [ike-sh/bbrv3-lite](https://github.com/ike-sh/bbrv3-lite/tree/669ecb214b4aa96fae71550e1ea4f89915455032) | `install-alias.sh`、README、`src/sysctl.sh` 的档位/兼容判断、`src/kernel.sh` 的安装边界 | 带宽时延积、内存预算、BBR 变体保护、把代际证明与算法名称分开；不引入其安装器、测速器或内核仓库 |
| [Chunlion/VPS-Optimize](https://github.com/Chunlion/VPS-Optimize/tree/79f2f44c12800ae8cdbf71b207b14c60384ab0f1) | `system_init.sh` 实际加载的 `system_core.sh`、`kernel_tuning.sh` 的 BBR/RTT 模型与外部调用、`ui.sh` | 一键入口与自定义入口并存、计划及结果可见、网络输入注明来源；不引入节点面板、分流服务或外部加速脚本 |

## 重写后的功能

- 交互终端无参数进入菜单；自动化无参数仍只读预览，CLI 原命令保持可用。
- 菜单包含一键优化、自定义优化、公钥管理员、系统检查、BBR/网络检查、计划、验证、事务摘要、SSH 确认和回滚。
- 终端采用青色分区、步骤编号和状态配色；`NO_COLOR` 或 `--no-color` 禁用颜色。日志及摘要不保存 ANSI 配色。
- 网络保守/均衡档使用按内存分级的缓冲目标；throughput 使用人工输入的带宽和主要业务 RTT 计算两个带宽时延积，受内存预算和固定上限约束。保持更大的既有值、TCP 最小/初始值和既有队列树。
- 可选 `--default-fq` 仅设置后续创建队列的默认值，明确不把它报告成当前网卡已经使用 FQ。
- 已运行 `bbr2`、`bbrplus` 等变体时默认跳过网络接管；显式 `--keep-bbr` 保留算法并允许缓冲调整。
- 可选 `--enable-ntp` 使用系统已提供的时间同步服务，记录原状态供回滚。
- 所有配置流程结束均显示 SSH 新旧端口、监听情况、实际拥塞算法、swap、备份及下一步；失败不打印全成功，退出码不被摘要覆盖。

## BBRv3 与安全边界

BBRv3 是内核 TCP 拥塞控制实现，不能通过扩大几个 sysctl 缓冲值把 BBRv1 升级成 BBRv3。标准实现通常同样注册为 `bbr`，单看该名称不足以证明代际。[Google BBR v3 源码](https://github.com/google/bbr/tree/v3)、[BBRv3 Lite 的代际说明](https://github.com/ike-sh/bbrv3-lite/blob/669ecb214b4aa96fae71550e1ea4f89915455032/README.md) 是本次判断依据。

本工具支持使用当前可信内核提供的标准 BBR，包括其实际为 v3 的环境；没有实现第三方内核下载、切换引导或自动重启。需要特定 v3 内核时，应先按内核发行方维护流程核验来源、架构、Secure Boot 与救援方式，再运行本工具检查/调优。这里没有把“兼容标准 bbr”写成“已验证 BBRv3”。

不默认运行公网测速，不把虚拟网卡标称速度当作套餐带宽，不自动改 DNS/IPv6/默认路由，不统一放大 conntrack/文件句柄/初始窗口，也不为优化关闭防火墙、SELinux 或 AppArmor。缓冲上限是每个 socket 的可用上界，不能替代总内存/连接数控制。参数语义以 [Linux 网络 sysctl](https://docs.kernel.org/networking/ip-sysctl.html) 与 [默认 qdisc 文档](https://www.kernel.org/doc/html/latest/admin-guide/sysctl/net.html) 为准。

第三方代码可读、有校验值或没有混淆，都不足以证明整个供应链绝对安全。本次发行仍只包含本工具自行实现并测试的代码，不为参考项目或其下游脚本作“没有后门”的担保。
