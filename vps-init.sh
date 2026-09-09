#!/usr/bin/env bash
# VPS 初始化入口；发行版提供可独立运行的单文件。
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
VPS Init 0.3.0-beta.1
用法：sudo bash vps-init.sh <命令> [选项]
  check                  只读环境检查
  menu                   中文交互菜单（交互终端无参数时默认）
  network                网络、BBR/BBRv3 能力与调优计划检查（只读）
  plan                   一键优化预览（默认）
  optimize               一键优化：适配当前能力，备份后应用全部基础模块
  auto                   直接一键：自动依赖、CPU、已有 NTP、Docker 日志，执行后显示结果
  apply <模块>           单独安装/重复应用：logs memory cpu network security disk ssh firewall docker fail2ban time
  uninstall              按逆序恢复所有配置并卸载工具；保留备份和软件包
  uninstall --keep-config 只卸载工具，保留系统优化配置
  verify                 检查当前实际状态
  confirm-ssh <事务ID>    从新端口登录后确认并关闭旧 SSH 入口
  rollback <事务ID>       恢复指定事务管理的配置及可恢复运行状态
选项：
  --yes                  无交互执行；普通优化直接完成
  --strict-ssh           可选：新连接验证后关闭旧入口；仅此模式需要确认
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
    if [[ $command == auto ]]; then
        command=optimize YES=1 INSTALL=1 CPU_PERFORMANCE=1 ENABLE_NTP=1 DOCKER_LOG=1
    fi
    if [[ $command == rollback || $command == confirm-ssh ]]; then
        tx=${1:-}; [[ $# == 0 ]] || shift
    fi
    if [[ $command == apply ]]; then
        SELECTED_MODULE=${1:-}; [[ $# == 0 ]] || shift
        case $SELECTED_MODULE in logs|memory|cpu|network|security|disk|ssh|firewall|docker|fail2ban|time) :;; *) die '模块：logs memory cpu network security disk ssh firewall docker fail2ban time';; esac
        command=optimize
        case $SELECTED_MODULE in cpu) CPU_PERFORMANCE=1;; docker) DOCKER_LOG=1;; fail2ban) FAIL2BAN=1;; time) ENABLE_NTP=1;; esac
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
        uninstall) uninstall_tool;;
        optimize)
            require_root
            ui_banner
            say "即将执行：${SELECTED_MODULE:-all}；完成后直接显示结果。"
            if (( ! YES )); then
                local answer
                read -r -p '输入 yes 应用以上计划：' answer
                [[ $answer == yes ]] || die '已取消'
            fi
            RUN_STARTED=$SECONDS
            begin_transaction
            printf '%s\n' "$SELECTED_MODULE" > "$TX/module"
            RUN_ACTION=optimize
            trap 'finish_output "$?"' EXIT
            trap 'on_error "$?" "$LINENO"' ERR
            trap 'die "执行被中断；请查看事务并运行 rollback"' INT TERM
            MODULE_TOTAL=1
            [[ $SELECTED_MODULE != all ]] || MODULE_TOTAL=$((7+CPU_PERFORMANCE+DOCKER_LOG+FAIL2BAN))
            MODULE_TOTAL=$((MODULE_TOTAL+INSTALL))
            run_module 安装工具 "$INSTALL" install_tools
            require_commands
            apply_modules
            ;;
        rollback|confirm-ssh)
            require_root; require_commands; acquire_lock; load_transaction "$tx"
            RUN_ACTION=$command
            trap 'finish_output "$?"' EXIT
            if [[ $command == rollback ]]; then rollback; else confirm_ssh; fi;;
        *) usage; die "未知命令：$command";;
    esac
}
apply_modules() {
    case $SELECTED_MODULE in
        all)
            run_module 基础维护 1 basic_init
            run_module 日志轮转 1 configure_logs
            run_module 内存与交换空间 1 configure_memory
            run_module CPU调频 "$CPU_PERFORMANCE" configure_cpu
            run_module TCP/UDP/BBR 1 configure_network
            run_module 内核安全 1 configure_security
            run_module 磁盘维护 1 configure_storage
            run_module Docker日志 "$DOCKER_LOG" configure_docker
            run_module SSH与防火墙 1 configure_access
            run_module Fail2ban "$FAIL2BAN" configure_fail2ban;;
        logs) run_module 日志轮转 1 configure_logs;;
        memory) run_module 内存与交换空间 1 configure_memory;;
        cpu) run_module CPU调频 1 configure_cpu;;
        network) run_module TCP/UDP/BBR 1 configure_network;;
        security) run_module 内核安全 1 configure_security;;
        disk) run_module 磁盘维护 1 configure_storage;;
        ssh) run_module SSH与防火墙 1 configure_access;;
        firewall) run_module 防火墙 1 configure_firewall;;
        docker) run_module Docker日志 1 configure_docker;;
        fail2ban) run_module Fail2ban 1 configure_fail2ban;;
        time) run_module 时间同步 1 basic_init;;
    esac
}
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
