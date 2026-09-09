#!/usr/bin/env bash
# 仅使用 Bash/ANSI；无终端或设置 NO_COLOR 时输出可重定向的纯文本。
UI_COLOR=0
ui_init() {
    UI_COLOR=0
    if [[ -t 1 && ${TERM:-dumb} != dumb && -z ${NO_COLOR+x} ]] && (( ! NO_COLOR_OPTION )); then UI_COLOR=1; fi
}
ui_line() {
    local color=$1 text=$2
    if (( UI_COLOR )); then printf '\033[%sm%s\033[0m\n' "$color" "$text"
    else printf '%s\n' "$text"; fi
}
ui_section() { say ''; ui_line '1;36' "── $* ──"; }
ui_banner() {
    say ''
    ui_line '1;36' '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
    ui_line '1;37' '  VPS INIT  ·  初始化与优化控制台'
    ui_line '36' '  一键优化 · 独立模块 · 重复安装 · 一键卸载'
    ui_line '1;36' '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
    say "  $DIST $VERSION  |  $INIT  |  ${RAM_MB} MiB  |  $VIRT"
}
ui_show_summary() {
    local line
    while IFS= read -r line || [[ -n $line ]]; do
        case $line in
            *失败*|*中断*) ui_line '1;31' "$line";;
            *待确认*|*跳过*|*未监听*) ui_line '1;33' "$line";;
            =*|结果：*|SSH*端口：*) ui_line '1;36' "$line";;
            sudo*|新连接示例：*|回滚命令：*) ui_line '1;32' "$line";;
            *) say "$line";;
        esac
    done < "$1"
}
ui_menu_body() {
    ui_banner
    ui_section '一键配置'
    ui_line '1;32' '  1  一键优化（均衡档 / 自动 SSH 端口 / 安装基础工具）'
    say '  2  自定义优化（网络档位、SSH、swap 和可选模块）'
    say '  3  公钥管理员向导'
    ui_section '检查与预览'
    say '  4  系统只读检查             5  网络 / BBRv3 能力检查'
    say '  6  一键优化预览             7  检查已应用配置'
    ui_section '独立安装 / 优化'
    say ' 12  日志限额与轮转          13  内存 / swap'
    say ' 14  CPU 调频               15  TCP / UDP / BBR'
    say ' 16  内核安全               17  磁盘维护'
    say ' 18  SSH 自动端口           19  防火墙端口放行'
    say ' 20  Docker 日志限制        21  Fail2ban 防暴力登录'
    say ' 22  时间同步'
    ui_section '记录与维护'
    say '  8  事务记录及结果           9  确认 SSH 新入口'
    say ' 10  回滚指定事务            11  查看全部命令参数'
    ui_line '33' ' 23  卸载并恢复配置          24  只卸载工具 / 保留优化'
    ui_line '36' '  0  退出'
    say ''; say '普通优化当场显示结果；新旧 SSH 入口均保留，不需另开会话确认。'
}
ui_pause() { local answer; read -r -p '按回车返回菜单…' answer || return 0; }
ui_exec() {
    local -a color_args=()
    (( ! NO_COLOR_OPTION )) || color_args+=(--no-color)
    # 子进程自己启用严格错误处理；菜单保留，执行失败也能查看结果并返回。
    local code
    set +e
    bash "$BASE/vps-init.sh" "$@" "${color_args[@]}"
    code=$?
    set -e
    (( ! code )) || ui_line '31' "本次操作退出码：$code"
    ui_pause
}
ui_custom() {
    local value choice
    local -a args=(optimize --install-tools) choices=()
    ui_section '自定义一键优化'
    read -r -p 'SSH 目标端口 [auto]，输入 keep 保留现端口：' value || return
    case ${value:-auto} in keep) args+=(--keep-ssh-port);; *) args+=(--ssh-port "${value:-auto}");; esac
    read -r -p '网络档位：1 保守 / 2 均衡 / 3 带宽时延自适应 [2]：' value || return
    case ${value:-2} in
        1) args+=(--network-profile conservative);;
        2) args+=(--network-profile balanced);;
        3)
            args+=(--network-profile throughput)
            read -r -p '带宽 Mbps（按实际套餐/实测填写）：' value || return
            args+=(--bandwidth-mbps "$value")
            read -r -p '主要业务连接 RTT 毫秒：' value || return
            args+=(--rtt-ms "$value");;
        *) say '无效档位，尚未修改系统。'; return;;
    esac
    read -r -p 'swap：自动=auto / 保持不动=keep / 压缩=zram / 指定 MiB [auto]：' value || return
    case ${value:-auto} in auto) :;; keep) args+=(--no-swap);; zram) args+=(--zram);; *) args+=(--swap-mb "$value");; esac
    say '可选：1 CPU performance；2 已安装的 Fail2ban；3 Docker 日志；4 已安装的 NTP；5 默认 FQ'
    read -r -p '输入需要启用的编号，以逗号分隔；直接回车全部保留：' value || return
    if [[ -n $value ]]; then
        [[ $value =~ ^[1-5](,[1-5])*$ ]] || { say '无效选择，尚未修改系统。'; return; }
        IFS=, read -r -a choices <<< "$value"
        for choice in "${choices[@]}"; do
            case $choice in 1) args+=(--cpu-performance);; 2) args+=(--fail2ban);; 3) args+=(--docker-log-limit);; 4) args+=(--enable-ntp);; 5) args+=(--default-fq);; esac
        done
    fi
    ui_exec "${args[@]}"
}
ui_identity() {
    local user_name key answer
    local -a args=(optimize --install-tools)
    ui_section '公钥管理员'
    say '指定账号将获得完整免密码 sudo，请使用你信任的账号。只提供公钥文件，不提供私钥。'
    read -r -p '管理员用户名（留空返回）：' user_name || return
    [[ -n $user_name ]] || return 0
    read -r -p '本机公钥文件完整路径：' key || return
    args+=(--admin-user "$user_name" --public-key "$key")
    read -r -p '新公钥登录验证后关闭密码和 root 登录？[y/N]：' answer || return
    case $answer in y|Y) args+=(--disable-password-login --disable-root-login);; ''|n|N) :;; *) say '无效选择，尚未修改系统。'; return;; esac
    ui_exec "${args[@]}"
}
ui_transactions() {
    local directory id status count=0
    ui_section '事务记录'
    [[ -r $STATE && -x $STATE ]] || { say '无可读取记录；已有记录需 root 权限。'; return; }
    for directory in "$STATE"/*; do
        [[ -d $directory && ! -L $directory && -f $directory/manifest ]] || continue
        id=${directory##*/}
        [[ $id =~ ^[0-9]{8}T[0-9]{6}Z-[0-9]+$ ]] || continue
        status=未确认访问或无访问变更
        if [[ -f $directory/rolled-back ]]; then status=已回滚
        elif [[ -f $directory/access.pending ]]; then status=SSH待确认
        elif [[ -f $directory/access.confirmed ]]; then status=SSH已确认; fi
        say "$id  $status"
        count=$((count+1))
    done
    (( count )) || say '暂无事务记录。'
}
ui_menu() {
    [[ -t 0 && -t 1 ]] || die '菜单需要交互终端；自动化请使用 plan/optimize 等 CLI 命令'
    local choice tx module value
    while :; do
        [[ -f $BASE/vps-init.sh ]] || return 0
        ui_menu_body
        read -r -p '选择操作 [0]：' choice || return 0
        case ${choice:-0} in
            1) ui_exec optimize --yes --install-tools --cpu-performance --enable-ntp --docker-log-limit;;
            2) ui_custom;;
            3) ui_identity;;
            4) report; ui_pause;;
            5) network_status; ui_pause;;
            6) show_plan; ui_pause;;
            7) if verify_managed; then :; else say '存在未确认或不一致项目，请查看上方结果。'; fi; ui_pause;;
            8)
                ui_transactions
                read -r -p '输入事务 ID 查看摘要，留空返回：' tx || return 0
                if [[ -n $tx ]]; then
                    if [[ $tx =~ ^[0-9]{8}T[0-9]{6}Z-[0-9]+$ && -f $STATE/$tx/summary.txt && ! -L $STATE/$tx ]]; then ui_show_summary "$STATE/$tx/summary.txt"
                    else say '事务 ID 无效或摘要不可读取。'; fi
                    ui_pause
                fi;;
            9|10)
                ui_transactions
                read -r -p '请输入事务 ID（留空返回）：' tx || return 0
                [[ -n $tx ]] || continue
                if [[ $choice == 9 ]]; then ui_exec confirm-ssh "$tx"
                else
                    read -r -p '确认回滚此事务？输入 yes 执行：' choice || return 0
                    [[ $choice != yes ]] || ui_exec rollback "$tx"
                fi;;
            11) usage; ui_pause;;
            12|13|14|15|16|17|18|19|20|21|22)
                case $choice in 12) module=logs;; 13) module=memory;; 14) module=cpu;; 15) module=network;; 16) module=security;; 17) module=disk;; 18) module=ssh;; 19) module=firewall;; 20) module=docker;; 21) module=fail2ban;; 22) module='time';; esac
                if [[ $module == firewall ]]; then
                    read -r -p '放行端口（如 tcp:80,443 或 udp:443，回车仅保留现有服务）：' value || return 0
                    if [[ -n $value ]]; then ui_exec apply firewall --yes --install-tools --allow "$value"
                    else ui_exec apply firewall --yes --install-tools; fi
                elif [[ $module == ssh ]]; then
                    read -r -p '新端口 [auto，首次自动选择 / 已安装则复用]：' value || return 0
                    ui_exec apply ssh --yes --install-tools --ssh-port "${value:-auto}"
                else ui_exec apply "$module" --yes --install-tools; fi;;
            23) ui_exec uninstall;;
            24) ui_exec uninstall --keep-config;;
            0|q|Q) return 0;;
            *) ui_line '33' '请输入菜单中的编号。';;
        esac
    done
}
