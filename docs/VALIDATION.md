# 验证记录

日期：2026-09-09。只将实际执行的检查列为证据，版本支持范围见 README。

## 已完成基线

提交 `4bf1b2d6f3e16a366afdc0541ca7691dc5431181` 的 GitHub Actions：

- [静态检查](https://github.com/ikun8887/vps-init/actions/runs/34279159571)：Bash 语法、ShellCheck、Linux 参数/文件恢复测试、只读检测通过。
- [真实临时 VM 集成](https://github.com/ikun8887/vps-init/actions/runs/34279159435)：Ubuntu 普通 SSH 服务及 socket、新公钥管理员、确认/旧端口关闭/回滚/独立超时恢复、真实 swap 和隔离 nftables 通过。
- [10 种发行版容器基础检查](https://github.com/ikun8887/vps-init/actions/runs/34279159423)：全部通过。容器检查不等于对应系统内核或服务已通过验证。

## 发布前源码审查与修复

对上述提交加当时未提交的恢复改动进行了完整 16 文件静态审查，包含独立基线和架构检查。发现 1 项中等严重性问题：全局 SSH 登录禁用只验证当前账号/来源，其他 Match 条件可能继续允许密码或 root 登录。

修复采用保守前置检查：主配置及递归 Include 中存在既有 Match，或 Include 语法不能安全解析时，拒绝自动执行全局禁用；确认时重新检查引用配置。`tests/test-ssh-policy.sh` 使用真实 sshd 展示其他用户及来源的覆盖，并检查修复将其拒绝。不会用“没有发现后门”替代漏洞修复或环境测试。

同时改进配置回滚的原子写入和失败重试，优先恢复 SSH；nft 恢复在一个事务中完成，firewalld 只撤销本事务新增的永久放行规则。

## 可复现命令

```bash
find . -name '*.sh' -print0 | xargs -0 -n1 bash -n
shellcheck -x vps-init.sh tests/*.sh
bash tests/test-core.sh
sudo bash tests/test-ssh-policy.sh
```

前三项无需 root；最后一项需要可用 OpenSSH 主机密钥/运行目录，只读取本机配置并在临时文件上执行 sshd 检查，不更改服务。

`tests/integration-*.sh` 会修改整台测试机，只允许明确标记的 GitHub 托管一次性 VM。不要在生产 VPS 手动运行。Windows 本地测试会跳过真实符号链接用例，Linux CI 覆盖该用例。

## 未证实范围

尚未验证整机重启、ARM、真实 OpenRC、CPUFreq、zram、firewalld/SELinux 迁移、Docker/Fail2ban 各版本以及公网性能收益。没有提供统一 EOL 支持或任意旧内核保证。源码审查不包含发行版包、软件源或第三方参考项目的全量审计。
