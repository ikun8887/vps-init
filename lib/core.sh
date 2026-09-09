#!/usr/bin/env bash
YES=0 KEEP_SSH=0 SSH_PORT=auto SWAP_MB=auto NO_SWAP=0 INSTALL=0 UPDATES=0
CPU_PERFORMANCE=0 ZRAM=0 DOCKER_LOG=0 HOSTNAME_NEW='' TIMEZONE_NEW=''
FAIL2BAN=0
NETWORK_PROFILE=balanced BANDWIDTH_MBPS=0 RTT_MS=0 KEEP_BBR=0 DEFAULT_FQ=0 ENABLE_NTP=0
NO_COLOR_OPTION=0 MODULE_INDEX=0 RUN_STARTED=-1
STRICT_SSH=0 MODULE_TOTAL=0 LOG_FD='' LOG_PID='' CONSOLE_SAVED=0
ADMIN_USER='' PUBLIC_KEY='' DISABLE_PASSWORD=0 DISABLE_ROOT=0
STATE=/var/lib/vps-init
SELECTED_MODULE=all KEEP_CONFIG=0
declare -a ALLOW=()
CURRENT_MODULE='' MODULE_SKIP_COUNT=0 RUN_ACTION=''
say() { printf '%s\n' "$*"; }
skip() {
    say "[跳过] $*"
    if [[ -n $CURRENT_MODULE ]]; then
        MODULE_SKIP_COUNT=$((MODULE_SKIP_COUNT+1))
        printf '%s：%s\n' "$CURRENT_MODULE" "$*" >> "$TX/skipped.txt"
    fi
}
run_module() {
    local label=$1 enabled=$2
    shift 2
    if (( ! enabled )); then return; fi
    MODULE_INDEX=$((MODULE_INDEX+1))
    ui_section "[$MODULE_INDEX/$MODULE_TOTAL] $label"
    CURRENT_MODULE=$label MODULE_SKIP_COUNT=0
    start_module_log
    # 不放入 if/|| 条件，避免 Bash 关闭被调用函数内部的 errexit。
    "$@" >&"$LOG_FD" 2>&1
    close_module_log
    local status=已处理
    (( ! MODULE_SKIP_COUNT )) || status='已处理（有跳过项）'
    printf '%s\t%s\n' "$label" "$status" >> "$TX/results.tsv"
    ui_line '32' "  ✓ $status"
    CURRENT_MODULE=''
}
start_module_log() {
    local used=0
    if (( ! CONSOLE_SAVED )); then exec 3>&1 4>&2; CONSOLE_SAVED=1; fi
    [[ ! -f $TX/run.log ]] || used=$(wc -c < "$TX/run.log")
    # 只收集当前模块输出。显式等待写入完成，避免会话结束时摘要丢失。
    exec {LOG_FD}> >(exec 9>&-; awk -v used="$used" -v logfile="$TX/run.log" '
        { if (used < 1048576) {
            text=$0 ORS; gsub(/\033\[[0-9;]*m/, "", text)
            text=substr(text,1,1048576-used); printf "%s",text >> logfile
            used+=length(text); fflush(logfile)
        }}')
    LOG_PID=$!
}
close_module_log() {
    if [[ -n $LOG_FD ]]; then exec {LOG_FD}>&-; LOG_FD=''; fi
    if [[ -n $LOG_PID ]]; then wait "$LOG_PID"; LOG_PID=''; fi
}
render_summary() {
    local code=$1 label status target='' old='' current='' user_name
    say ''; say '========== VPS Init 运行结果 =========='
    if (( RUN_STARTED >= 0 )); then say "运行耗时：$((SECONDS-RUN_STARTED)) 秒"; fi
    if (( code )); then say "结果：执行失败（退出码 $code），未完成的步骤不可视为成功。"
    elif [[ -f $TX/rolled-back ]]; then say '结果：事务已回滚。'
    elif [[ -f $TX/access.pending ]]; then say '结果：配置流程已结束；可选的 SSH 严格加固仍待新连接确认。'
    elif [[ $RUN_ACTION == confirm-ssh ]]; then say '结果：SSH 新入口已确认。'
    else say '结果：配置流程已结束。'; fi
    say "事务 ID：$TXID"
    if [[ $RUN_ACTION == optimize ]]; then
        if [[ -f $TX/results.tsv ]]; then
            while IFS=$'\t' read -r label status; do say "  $label：$status"; done < "$TX/results.tsv"
        fi
        [[ -z $CURRENT_MODULE ]] || say "  $CURRENT_MODULE：失败或中断"
        if [[ -s $TX/skipped.txt ]]; then say '跳过原因：'; cat "$TX/skipped.txt"; fi
    fi
    [[ ! -f $TX/ssh.target ]] || target=$(cat "$TX/ssh.target")
    [[ ! -f $TX/ssh.oldports ]] || old=$(awk '{printf "%s%s",sep,$0;sep=","}' "$TX/ssh.oldports")
    [[ -z $old ]] || say "SSH 原端口：$old"
    if [[ -f $TX/access.pending ]]; then
        say "SSH 目标端口：$target（待确认；旧入口暂时保留）"
    elif [[ -f $TX/rolled-back && -n $target ]]; then
        say "SSH 本次目标端口：$target（已回滚，以当前配置为准）"
    elif [[ -f $TX/access.ready ]]; then say "SSH 新端口：$target（已生效；原入口保留，无需确认命令）"
    elif [[ -f $TX/access.confirmed ]]; then say "SSH 已确认端口：$target"
    else say 'SSH：本次未完成新的端口迁移，保留现有配置。'; fi
    if has sshd; then
        if current=$(sshd -T 2>/dev/null); then
            current=$(printf '%s\n' "$current" | awk '$1=="port" {printf "%s%s",sep,$2;sep=","}')
            say "SSH 当前配置端口：${current:-未能读取}"
        else say 'SSH 当前配置端口：读取失败，请检查 sshd 配置。'; fi
    else say 'SSH 当前配置端口：未安装 sshd，无法读取。'; fi
    if [[ -n $target ]] && port_valid "$target" && has ss; then
        if current=$(ss -H -ltn "sport = :$target" 2>/dev/null); then
            if [[ -n $current ]]; then say "目标 TCP 端口 $target：正在监听（公网连通性仍需登录验证）"
            else say "目标 TCP 端口 $target：未监听"; fi
        else say '目标端口监听状态：无法读取'; fi
    fi
    if [[ -f $TX/firewall.kind ]]; then say "本次防火墙后端：$(cat "$TX/firewall.kind")"; fi
    if has sysctl && current=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null); then
        say "TCP 当前拥塞算法：$current"
        [[ $current != bbr ]] || say 'BBR 代际：内核未提供通用代际证明，不能仅凭 bbr 名称认定 v3。'
    fi
    [[ ! -f $TX/network.profile ]] || say "网络调优计划：$(cat "$TX/network.profile")"
    if [[ -r /proc/swaps ]]; then
        current=$(awk 'NR>1 {total+=$3;used+=$4} END {printf "总量 %.0f MiB，已用 %.0f MiB",total/1024,used/1024}' /proc/swaps)
        say "当前 swap：$current"
    fi
    if [[ -f $TX/manifest ]]; then say "本事务备份配置数：$(awk 'END {print NR+0}' "$TX/manifest")"; fi
    if [[ -f $TX/access.pending ]]; then
        user_name=${SUDO_USER:-root}
        [[ ! -f $TX/identity.user ]] || user_name=$(cat "$TX/identity.user")
        say "新连接示例：ssh -p $target $user_name@你的服务器IP"
        say '确认命令（在新端口的新会话中执行）：'
        if [[ -f $TX/identity.user ]]; then
            printf 'sudo --preserve-env=SSH_CONNECTION,SSH_USER_AUTH bash %q confirm-ssh %q\n' "$BASE/vps-init.sh" "$TXID"
        else printf 'sudo --preserve-env=SSH_CONNECTION bash %q confirm-ssh %q\n' "$BASE/vps-init.sh" "$TXID"; fi
        say '恢复任务从访问迁移开始计时 5 分钟，剩余时间可能不足 5 分钟；请立即验证。'
        say '请保留原会话，并在云安全组/NAT 中放行目标端口。'
    fi
    say "备份和日志：$TX"
    say "结果文件：$TX/summary.txt"
    if (( code )) && [[ -s $TX/run.log ]]; then say '最后的执行记录：'; tail -n 12 "$TX/run.log"; fi
    if [[ ! -f $TX/rolled-back ]]; then
        printf '回滚命令：sudo bash %q rollback %q\n' "$BASE/vps-init.sh" "$TXID"
    fi
    say '======================================'
}
finish_output() {
    local code=$1
    trap - ERR EXIT
    set +e
    if (( CONSOLE_SAVED )); then exec 1>&3 2>&4; fi
    close_module_log
    # 摘要独立保存，即使 run.log 已达容量上限仍可查看；保留原执行退出码。
    if UI_COLOR=0 render_summary "$code" > "$TX/summary.txt"; then ui_show_summary "$TX/summary.txt"
    else say "[错误] 无法完整保存运行摘要：$TX/summary.txt" >&2; fi
    exit "$code"
}
die() { say "[错误] $*" >&2; exit 1; }
has() { command -v "$1" >/dev/null 2>&1; }
uint() { [[ $1 =~ ^[0-9]+$ && ${#1} -le 8 ]]; }
port_valid() { uint "$1" && (( 10#$1 >= 1 && 10#$1 <= 65535 )); }
parse_options() {
    while (( $# )); do
        case $1 in
            --yes) YES=1;;
            --keep-ssh-port) KEEP_SSH=1;;
            --no-swap) NO_SWAP=1;;
            --install-tools) INSTALL=1;;
            --security-updates) UPDATES=1;;
            --cpu-performance) CPU_PERFORMANCE=1;;
            --zram) ZRAM=1;;
            --docker-log-limit) DOCKER_LOG=1;;
            --fail2ban) FAIL2BAN=1;;
            --keep-bbr) KEEP_BBR=1;;
            --default-fq) DEFAULT_FQ=1;;
            --enable-ntp) ENABLE_NTP=1;;
            --no-color) NO_COLOR_OPTION=1;;
            --strict-ssh) STRICT_SSH=1;;
            --keep-config) KEEP_CONFIG=1;;
            --disable-password-login) DISABLE_PASSWORD=1;;
            --disable-root-login) DISABLE_ROOT=1;;
            --ssh-port|--swap-mb|--allow|--hostname|--timezone|--admin-user|--public-key|--network-profile|--bandwidth-mbps|--rtt-ms)
                [[ $# -ge 2 ]] || die "$1 缺少参数"
                case $1 in
                    --ssh-port)
                        if [[ $2 == auto ]]; then SSH_PORT=auto
                        else port_valid "$2" || die '无效 SSH 端口'; SSH_PORT=$((10#$2)); fi;;
                    --swap-mb)
                        uint "$2" || die 'swap 必须是整数'
                        (( 10#$2 >= 64 && 10#$2 <= 65536 )) || die 'swap 范围为 64–65536 MiB'
                        SWAP_MB=$((10#$2));;
                    --allow) validate_allow "$2"; ALLOW+=("$2");;
                    --hostname) [[ $2 =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]{0,61}[a-zA-Z0-9])?$ ]] || die '无效主机名'; HOSTNAME_NEW=$2;;
                    --timezone) [[ $2 =~ ^[a-zA-Z0-9_+-]+(/[a-zA-Z0-9_+-]+)*$ ]] || die '无效时区'; TIMEZONE_NEW=$2;;
                    --admin-user) [[ $2 =~ ^[a-z_][a-z0-9_-]{0,30}$ && $2 != root ]] || die '需要非 root 的合法管理员用户名'; ADMIN_USER=$2;;
                    --public-key) PUBLIC_KEY=$2;;
                    --network-profile)
                        case $2 in conservative|balanced|throughput) NETWORK_PROFILE=$2;; *) die '网络档位：conservative/balanced/throughput';; esac;;
                    --bandwidth-mbps) if ! uint "$2" || (( 10#$2 < 1 || 10#$2 > 100000 )); then die '带宽范围 1–100000 Mbps'; fi; BANDWIDTH_MBPS=$((10#$2));;
                    --rtt-ms) if ! uint "$2" || (( 10#$2 < 1 || 10#$2 > 2000 )); then die 'RTT 范围 1–2000 ms'; fi; RTT_MS=$((10#$2));;
                esac
                shift;;
            *) die "未知选项：$1";;
        esac
        shift
    done
    (( ! ZRAM || ! NO_SWAP )) || die '--zram 与 --no-swap 冲突'
    if [[ $NETWORK_PROFILE == throughput ]]; then
        (( BANDWIDTH_MBPS > 0 && RTT_MS > 0 )) || die 'throughput 需要 --bandwidth-mbps 和 --rtt-ms'
    else (( BANDWIDTH_MBPS == 0 && RTT_MS == 0 )) || die '带宽/RTT 参数仅用于 throughput 档位'; fi
    if [[ -n $ADMIN_USER || -n $PUBLIC_KEY ]] || (( DISABLE_PASSWORD || DISABLE_ROOT )); then
        [[ -n $ADMIN_USER && -n $PUBLIC_KEY ]] || die '登录加固需要同时提供 --admin-user 与 --public-key'
        [[ -f $PUBLIC_KEY && -r $PUBLIC_KEY ]] || die '公钥文件不可读取'
        STRICT_SSH=1
    fi
}
validate_allow() {
    local proto=${1%%:*} list=${1#*:} p
    [[ $1 == *:* && ( $proto == tcp || $proto == udp ) && $list =~ ^[0-9]+(,[0-9]+)*$ ]] || die '端口格式：tcp:80,443 或 udp:443'
    local -a ports
    IFS=, read -r -a ports <<< "$list"
    for p in "${ports[@]}"; do port_valid "$p" || die "无效端口：$p"; done
}
detect() {
    [[ $(uname -s) == Linux ]] || die '仅支持 Linux；不会修改当前系统'
    DIST=unknown VERSION=unknown
    if [[ -r /etc/os-release ]]; then
        # os-release 是操作系统拥有的配置；不执行用户提供的配置文件。
        DIST=$(sed -n 's/^ID=//p' /etc/os-release | tr -d '\"')
        VERSION=$(sed -n 's/^VERSION_ID=//p' /etc/os-release | tr -d '\"')
    fi
    INIT=unknown
    [[ ! -d /run/systemd/system ]] || INIT=systemd
    if [[ $INIT == unknown ]] && has rc-service; then INIT=openrc; fi
    VIRT=unknown
    if has systemd-detect-virt; then VIRT=$(systemd-detect-virt 2>/dev/null || true); fi
    RAM_MB=$(awk '/MemTotal:/ {print int($2/1024)}' /proc/meminfo)
    local cap='' path
    for path in /sys/fs/cgroup/memory.max /sys/fs/cgroup/memory/memory.limit_in_bytes; do
        if [[ -r $path ]]; then
            cap=$(cat "$path")
            if [[ $cap =~ ^[0-9]+$ && ${#cap} -lt 16 ]] && (( cap / 1048576 < RAM_MB )); then RAM_MB=$((cap/1048576)); fi
        fi
    done
    LIMITED=0
    case "$VIRT" in lxc*|openvz|docker|podman|systemd-nspawn|wsl) LIMITED=1;; esac
    [[ ! -e /.dockerenv && ! -e /run/.containerenv ]] || LIMITED=1
    SUPPORTED=1
    case "$DIST" in debian|ubuntu|rocky|almalinux|rhel|fedora|alpine|opensuse*|sles) :;; *) SUPPORTED=0;; esac
}
require_root() {
    (( EUID == 0 )) || die '修改操作需要 root 权限'
    (( SUPPORTED )) || die "发行版 $DIST 未适配，仅允许 check/plan/verify"
    [[ $INIT != unknown ]] || die '未识别服务管理器，仅允许只读检查'
}
require_commands() {
    local needed
    for needed in awk cat cmp cp date df getconf grep mktemp mv mkdir sed stat sysctl tr chmod chown; do
        has "$needed" || die "缺少必需命令 $needed；请先通过发行版软件源安装，尚未应用优化配置"
    done
}
acquire_lock() {
    has flock || die '需要 util-linux 的 flock；请先通过系统软件源安装'
    [[ ! -L $STATE ]] || die '状态目录不可为符号链接'
    mkdir -p "$STATE"
    [[ $(stat -c %u "$STATE") == 0 ]] || die '状态目录必须属于 root'
    chmod 700 "$STATE"
    exec 9>"$STATE/lock"
    flock -n 9 || die '另一个初始化或恢复操作正在运行'
}
begin_transaction() {
    acquire_lock
    recover_pending
    TXID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
    TX="$STATE/$TXID"
    mkdir -m 700 "$TX" "$TX/files" "$TX/after"
    : > "$TX/manifest"
    : > "$TX/sysctl.before"
    : > "$TX/sysfs.before"
    printf '%s\n' "$TXID" >> "$STATE/history"
}
recover_pending() {
    local pending
    for pending in "$STATE"/*/access.pending; do
        [[ -f $pending ]] || continue
        load_transaction "$(basename "${pending%/*}")"
        say "[修复] 恢复上次未完成的 SSH 操作 $TXID，然后继续本次执行。"
        # 使用真实回滚和冲突检查，不删除状态标记来假装恢复成功。
        rollback
    done
}
transaction_order() {
    local directory
    # 旧版无顺序文件；新版按持锁时追加的真实执行顺序恢复，避免同秒 PID 排序失真。
    {
        for directory in "$STATE"/*; do
            [[ -d $directory && ! -L $directory && -f $directory/manifest ]] || continue
            if [[ ! -f $STATE/history ]] || ! grep -Fxq "${directory##*/}" "$STATE/history"; then
                printf '%s\n' "${directory##*/}"
            fi
        done
        [[ ! -f $STATE/history ]] || cat "$STATE/history"
    } | awk '!seen[$0]++ {ids[++n]=$0} END {for(i=n;i>0;i--) print ids[i]}'
}
uninstall_tool() {
    require_root; require_commands; acquire_lock
    if (( ! YES )); then
        local answer
        read -r -p '恢复优化配置并卸载工具（备份保留）？输入 yes：' answer
        [[ $answer == yes ]] || die '已取消'
    fi
    local id count=0
    if (( KEEP_CONFIG )); then
        # 未完成的访问操作不可遗留给已卸载的入口。
        recover_pending
    else
        while IFS= read -r id; do
            load_transaction "$id"
            [[ ! -f $TX/rolled-back ]] || continue
            say "[恢复] $id"
            rollback
            count=$((count+1))
        done < <(transaction_order)
    fi
    # 只删除本工具安装器拥有的三个文件；不递归删除目录或第三方文件。
    if [[ -f /usr/local/lib/vps-init/.managed && ! -L /usr/local/lib/vps-init ]]; then
        if [[ -f /usr/local/bin/vps-init && ! -L /usr/local/bin/vps-init ]] && grep -Fxq '# VPS-INIT LAUNCHER' /usr/local/bin/vps-init; then rm /usr/local/bin/vps-init; fi
        rm -f /usr/local/lib/vps-init/vps-init.sh /usr/local/lib/vps-init/.managed
        rmdir /usr/local/lib/vps-init 2>/dev/null || say '安装目录含其他文件，已保留。'
    fi
    say "卸载完成：恢复 $count 次操作；备份保留在 $STATE。软件包、用户及业务数据保留。"
    if has sshd; then sshd -T | awk '$1=="port" {print "当前 SSH 端口：" $2}'; fi
}
load_transaction() {
    [[ $1 =~ ^[0-9]{8}T[0-9]{6}Z-[0-9]+$ ]] || die '无效事务 ID'
    TXID=$1 TX="$STATE/$1"
    [[ -d $TX && ! -L $TX && -f $TX/manifest ]] || die '事务不存在'
}
backup() {
    local target=$1
    [[ $target == /* && $target != *$'\t'* && $target != *$'\n'* ]] || die '无效备份路径'
    [[ ! -L $target ]] || die "拒绝覆盖符号链接：$target"
    if grep -Fxq "$target" "$TX/manifest"; then return; fi
    mkdir -p "$TX/files$(dirname "$target")" "$TX/after$(dirname "$target")"
    if [[ -e $target ]]; then
        [[ -f $target ]] || die "目标不是普通文件：$target"
        cp -p -- "$target" "$TX/files$target"
    fi
    printf '%s\n' "$target" >> "$TX/manifest"
}
write_file() {
    local target=$1 tmp
    backup "$target"
    mkdir -p "$(dirname "$target")"
    tmp=$(mktemp "$(dirname "$target")/.vps-init.XXXXXX")
    cat > "$tmp"
    if [[ -f $target ]]; then
        chmod "$(stat -c %a "$target")" "$tmp"
        chown "$(stat -c %u:%g "$target")" "$tmp"
    else chmod 600 "$tmp"; fi
    mv -f -- "$tmp" "$target"
    if has restorecon; then restorecon "$target"; fi
    cp -p -- "$target" "$TX/after$target"
}
set_sysctl() {
    local key=$1 value=$2 old
    if [[ ! -e /proc/sys/${key//./\/} ]]; then skip "内核无 $key"; return; fi
    old=$(sysctl -n "$key")
    printf '%s\t%s\n' "$key" "$old" >> "$TX/sysctl.before"
    if sysctl -q -w "$key=$value"; then
        printf '%s = %s\n' "$key" "$value" >> "$SYSCTL_TEMP"
    else
        printf '%s\n' "$key" >> "$TX/sysctl.failed"
        skip "无权设置 $key，未持久化"
    fi
}
service_reload() {
    local service=$1
    if [[ $INIT == systemd ]]; then systemctl reload "$service"; else rc-service "$service" reload; fi
}
report() {
    say "系统：$DIST $VERSION | 内核：$(uname -r) | 架构：$(uname -m)"
    say "服务管理：$INIT | 虚拟化：$VIRT | 可见内存上限：${RAM_MB} MiB"
    say 'CPU / 负载：'; getconf _NPROCESSORS_ONLN; cat /proc/loadavg
    say '磁盘容量 / inode：'; df -h /; df -i /
    say '交换空间：'; cat /proc/swaps
    say 'TCP 拥塞算法：'; sysctl net.ipv4.tcp_congestion_control net.ipv4.tcp_available_congestion_control 2>/dev/null || true
    if has ss; then say '监听端口：'; ss -lntu; fi
    if has tc; then say '当前队列：'; tc qdisc show; fi
    if has journalctl && [[ $INIT == systemd ]]; then journalctl --disk-usage || true; fi
    say 'SSH 生效配置需 root 执行 verify 才能完整检查。'
    if (( EUID == 0 )) && has sshd; then sshd -t && sshd -T | awk '$1 ~ /^(port|permitrootlogin|passwordauthentication|pubkeyauthentication)$/'; fi
}
show_plan() {
    say "检测：$DIST $VERSION；内核 $(uname -r)；$INIT；内存 ${RAM_MB} MiB；受限环境=$LIMITED。"
    say '一键计划：日志轮转、内存/swap、TCP/UDP/BBR、安全基线、磁盘维护、SSH/防火墙。'
    say "SSH：$SSH_PORT（保留现端口=$KEEP_SSH）；swap：$SWAP_MB MiB（禁用=$NO_SWAP；zram=$ZRAM）。"
    say "安装工具=$INSTALL；安全更新=$UPDATES；CPU performance=$CPU_PERFORMANCE；Docker 日志=$DOCKER_LOG。"
    say "网络档位=$NETWORK_PROFILE；缓冲目标=$(network_buffer_target) 字节；保留拥塞算法=$KEEP_BBR；默认 FQ=$DEFAULT_FQ。"
    (( ! DEFAULT_FQ )) || say '默认 FQ 只影响之后创建队列的设备；不会替换现有 tc 队列树。'
    say "启用已安装的时间同步服务=$ENABLE_NTP。"
    say '适用模块才执行；已有服务/转发/防火墙冲突会跳过并说明；不会自动重启机器。'
    say '普通模式：新端口生效后保留旧入口，直接完成；云安全组/NAT 需放行新端口。'
    if [[ -n $ADMIN_USER ]]; then say "登录加固：管理员 $ADMIN_USER，配置公钥和免密码 sudo；新公钥登录确认后才关闭指定认证方式。"; fi
}
verify_managed() {
    local file key wanted actual failed=0 pending
    for file in /etc/sysctl.d/60-vps-init-network.conf /etc/sysctl.d/60-vps-init-security.conf; do
        [[ -f $file ]] || continue
        while IFS='=' read -r key wanted; do
            key=$(printf '%s' "$key" | tr -d ' \t')
            [[ -n $key && $key != \#* ]] || continue
            [[ $key =~ ^[a-z0-9_.]+$ ]] || { say "[异常] 无效管理参数 $key"; failed=1; continue; }
            wanted=$(printf '%s\n' "$wanted" | awk '{$1=$1;print}')
            actual=$(sysctl -n "$key" 2>/dev/null | awk '{$1=$1;print}') || { say "[失败] 无法读取 $key"; failed=1; continue; }
            if [[ $actual == "$wanted" ]]; then say "[生效] $key=$actual"
            else say "[不一致] $key 期望 $wanted，实际 $actual"; failed=1; fi
        done < "$file"
    done
    if (( EUID == 0 )); then
        for pending in "$STATE"/*/access.pending; do
            [[ ! -f $pending ]] || { say "[待确认] ${pending%/*}"; failed=1; }
        done
        if [[ -f /etc/ssh/vps-init-port ]]; then
            wanted=$(cat /etc/ssh/vps-init-port)
            actual=$(sshd -T | awk '$1=="port" {print $2}')
            grep -Fxq "$wanted" <<< "$actual" || { say '[不一致] SSH 配置中缺少管理端口'; failed=1; }
            [[ -n $(ss -H -ltn "sport = :$wanted") ]] || { say '[失败] 已确认端口未监听'; failed=1; }
        fi
    else say '[未验证] 非 root 无法完整检查访问配置及事务状态'; fi
    if (( failed )); then return 1; fi
    say '可读取的已管理参数检查通过；重启、外部连通性和性能收益需要独立验证。'
}
on_error() {
    local code=$1 line=$2
    trap - ERR
    say "[失败] 第 $line 行，退出码 $code；未声称全部完成。" >&2
    say "请检查 $TX/run.log；恢复：sudo bash $BASE/vps-init.sh rollback $TXID" >&2
    exit "$code"
}
rollback() {
    [[ ! -e $TX/rolled-back ]] || die '事务已经回滚'
    local target key value conflict=0 tmp
    # 先检查所有文件，避免发现后续人工修改时已恢复了一半。
    while IFS= read -r target; do
        if [[ -e $TX/after$target ]] && ! cmp -s "$target" "$TX/after$target"; then
            # 允许恢复过程重试，也允许管理员已自行恢复到原始内容。
            if [[ -e $TX/files$target ]] && cmp -s "$target" "$TX/files$target"; then continue; fi
            if [[ ! -e $TX/files$target && ! -e $target && ! -L $target ]]; then continue; fi
            say "[冲突] $target 已在事务后变化，拒绝覆盖"; conflict=1
        fi
    done < "$TX/manifest"
    (( ! conflict )) || die '请先处理配置冲突'
    if [[ -f $TX/nft.after ]]; then
        if nft list table inet vps_init > "$TX/nft.current" 2>/dev/null; then
            if ! cmp -s "$TX/nft.current" "$TX/nft.after" && ! cmp -s "$TX/nft.current" "$TX/nft.before"; then die '防火墙在事务后变化，拒绝覆盖'; fi
        elif [[ -f $TX/nft.before ]]; then die '原有防火墙表已被外部删除，拒绝覆盖'; fi
    fi
    if [[ -f $TX/zram.created ]]; then
        /usr/local/sbin/vps-init-zram stop
        if [[ $INIT == systemd ]]; then systemctl disable --now vps-init-zram.service
        else rc-service vps-init-zram stop; rc-update del vps-init-zram default; fi
    fi
    if [[ -f $TX/cpu.created ]]; then
        if [[ $INIT == systemd ]]; then systemctl disable --now vps-init-cpu.service
        else rc-service vps-init-cpu stop; rc-update del vps-init-cpu default; fi
    fi
    if [[ -f $TX/nft.service ]]; then
        if [[ $INIT == systemd ]]; then systemctl disable vps-init-firewall.service
        else rc-update del vps-init-firewall default; fi
    fi
    if [[ -f $TX/swap.created ]]; then
        local swapfile; swapfile=$(cat "$TX/swap.created")
        if grep -Fq "$swapfile " /proc/swaps || grep -Fq "$swapfile" /proc/swaps; then swapoff "$swapfile" || die '内存不足，无法安全 swapoff；未删除交换文件'; fi
        rm -f -- "$swapfile"
    fi
    while IFS= read -r target; do
        if [[ -e $TX/files$target ]]; then
            tmp=$(mktemp "$(dirname "$target")/.vps-init-restore.XXXXXX")
            cp -p -- "$TX/files$target" "$tmp"
            mv -f -- "$tmp" "$target"
            if has restorecon; then restorecon "$target"; fi
        else rm -f -- "$target"; fi
    done < "$TX/manifest"
    # 优先恢复访问入口；后续非访问参数失败不应阻挡 SSH 恢复。
    rollback_access
    while IFS=$'\t' read -r key value; do
        [[ -n $key ]] || continue
        if [[ -f $TX/sysctl.failed ]] && grep -Fxq "$key" "$TX/sysctl.failed"; then continue; fi
        sysctl -q -w "$key=$value"
    done < "$TX/sysctl.before"
    while IFS=$'\t' read -r key value; do [[ -z $key ]] || printf '%s\n' "$value" > "$key"; done < "$TX/sysfs.before"
    if [[ $INIT == systemd ]]; then
        systemctl daemon-reload
        [[ ! -f $TX/logs.changed ]] || systemctl restart systemd-journald
        [[ ! -f $TX/hostname.before ]] || hostnamectl set-hostname "$(cat "$TX/hostname.before")"
        [[ ! -f $TX/timezone.before ]] || timedatectl set-timezone "$(cat "$TX/timezone.before")"
        [[ ! -f $TX/ntp.before ]] || timedatectl set-ntp "$(cat "$TX/ntp.before")"
        if [[ -f $TX/fstrim.before && $(cat "$TX/fstrim.before") == disabled ]]; then systemctl disable fstrim.timer; fi
        if [[ -f $TX/fstrim.active && $(cat "$TX/fstrim.active") != active ]]; then systemctl stop fstrim.timer; fi
        if [[ -f $TX/fail2ban.active ]]; then
            if [[ $(cat "$TX/fail2ban.active") == active ]]; then systemctl restart fail2ban
            else systemctl stop fail2ban; fi
        fi
    fi
    touch "$TX/rolled-back"
    [[ ! -f $TX/user.created ]] || say "新建账号 $(cat "$TX/user.created") 及其目录保留；本事务的公钥和 sudo 配置已恢复。"
    say '配置回滚完成；软件包更新、已轮转日志和外部状态不支持撤销。'
}
