#!/usr/bin/env bash
# VPS 初始化入口；下载完整发行包后运行，禁止在线拼接执行代码。
set -Eeuo pipefail
IFS=$'\n\t'
umask 077
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH
export LC_ALL=C
BASE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$BASE/lib/core.sh"
source "$BASE/lib/modules.sh"
source "$BASE/lib/access.sh"
source "$BASE/lib/ui.sh"

usage() {
    cat <<'EOF'
VPS Init 0.2.0-beta.1
用法：sudo bash vps-init.sh <命令> [选项]
  check                  只读环境检查
  menu                   中文交互菜单（交互终端无参数时默认）
  network                网络、BBR/BBRv3 能力与调优计划检查（只读）
  plan                   一键优化预览（默认）
  optimize               一键优化：适配当前能力，备份后应用全部基础模块
  verify                 检查当前实际状态
  confirm-ssh <事务ID>    从新端口登录后确认并关闭旧 SSH 入口
  rollback <事务ID>       恢复指定事务管理的配置及可恢复运行状态
选项：
  --yes                  无交互执行；不绕过 SSH 新连接确认
  --ssh-port auto|数字    一键优化默认 auto；指定目标 SSH 端口
  --keep-ssh-port         保留现有 SSH 端口
  --allow tcp:80,443      放行额外端口，可多次指定 tcp/udp
  --swap-mb 数字          无 swap 时创建指定 MiB 的交换文件（默认自动）
  --no-swap               不创建 swap
  --install-tools        从当前发行版软件源安装所需管理工具
  --security-updates      执行系统提供的安全更新（不自动重启）
  --cpu-performance      有 CPUFreq 接口时选择 performance
  --zram                 使用 zram 替代自动磁盘 swap（需要内核支持）
  --docker-log-limit      配置 Docker 新容器默认日志轮转（不重启 Docker）
  --fail2ban              为已安装的 Fail2ban 配置 SSH 登录失败封禁
  --admin-user 用户名     配置非 root 公钥管理员（不存在则创建，授予免密码 sudo）
  --public-key 文件       与 --admin-user 配合，提供你自己的单个公钥
  --disable-password-login  新管理员通过公钥验证后，关闭全局密码/交互式认证
  --disable-root-login    新管理员通过公钥验证后，关闭全局 root 登录
  --hostname 名称         设置主机名（需 hostnamectl）
  --timezone 时区         设置时区（需 timedatectl）
  --network-profile 档位  conservative / balanced（默认）/ throughput
  --bandwidth-mbps 数字   throughput 档位的人工带宽输入：1–100000 Mbps
  --rtt-ms 数字           throughput 档位的业务 RTT：1–2000 ms
  --keep-bbr              保留当前拥塞算法，只调整网络缓冲
  --default-fq            仅设置后续队列默认 fq，不替换当前 tc 树
  --enable-ntp            启用 timedatectl 可管理的已安装时间同步服务
  --no-color              禁用终端配色，也支持 NO_COLOR 环境变量
EOF
}

main() {
    local command=${1:-} tx=''
    if [[ -z $command ]]; then
        if [[ -t 0 && -t 1 ]]; then command=menu; else command=plan; fi
    fi
    [[ $# == 0 ]] || shift
    if [[ $command == rollback || $command == confirm-ssh ]]; then
        tx=${1:-}; [[ $# == 0 ]] || shift
    fi
    case "$command" in help|--help|-h) usage; return;; esac
    parse_options "$@"
    ui_init
    detect
    case "$command" in
        menu) ui_menu;;
        network) network_status;;
        check|plan) report; [[ $command != plan ]] || show_plan;;
        verify) report; verify_managed;;
        optimize)
            require_root
            ui_banner
            show_plan
            if (( ! YES )); then
                local answer
                read -r -p '输入 yes 应用以上计划：' answer
                [[ $answer == yes ]] || die '已取消'
            fi
            RUN_STARTED=$SECONDS
            begin_transaction
            RUN_ACTION=optimize
            trap 'finish_output "$?"' EXIT
            trap 'on_error "$?" "$LINENO"' ERR
            trap 'die "执行被中断；请查看事务并运行 rollback"' INT TERM
            run_module 安装工具 "$INSTALL" install_tools
            require_commands
            run_module 基础维护 1 basic_init
            run_module 日志轮转 1 configure_logs
            run_module 内存与交换空间 1 configure_memory
            run_module CPU调频 "$CPU_PERFORMANCE" configure_cpu
            run_module TCP/UDP/BBR 1 configure_network
            run_module 内核安全 1 configure_security
            run_module 磁盘维护 1 configure_storage
            run_module Docker日志 "$DOCKER_LOG" configure_docker
            run_module SSH与防火墙 1 configure_access
            run_module Fail2ban "$FAIL2BAN" configure_fail2ban
            report
            ;;
        rollback|confirm-ssh)
            require_root; require_commands; acquire_lock; load_transaction "$tx"
            RUN_ACTION=$command
            trap 'finish_output "$?"' EXIT
            if [[ $command == rollback ]]; then rollback; else confirm_ssh; fi;;
        *) usage; die "未知命令：$command";;
    esac
}
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
