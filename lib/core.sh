#!/usr/bin/env bash
YES=0 KEEP_SSH=0 SSH_PORT=auto SWAP_MB=auto NO_SWAP=0 INSTALL=0 UPDATES=0
CPU_PERFORMANCE=0 ZRAM=0 DOCKER_LOG=0 HOSTNAME_NEW='' TIMEZONE_NEW=''
STATE=/var/lib/vps-init
declare -a ALLOW=()
say() { printf '%s\n' "$*"; }
skip() { say "[跳过] $*"; }
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
            --ssh-port|--swap-mb|--allow|--hostname|--timezone)
                [[ $# -ge 2 ]] || die "$1 缺少参数"
                case $1 in
                    --ssh-port) SSH_PORT=$2; [[ $2 == auto ]] || port_valid "$2" || die '无效 SSH 端口';;
                    --swap-mb) uint "$2" && (( 10#$2 >= 64 && 10#$2 <= 65536 )) || die 'swap 范围为 64–65536 MiB'; SWAP_MB=$((10#$2));;
                    --allow) validate_allow "$2"; ALLOW+=("$2");;
                    --hostname) [[ $2 =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]{0,61}[a-zA-Z0-9])?$ ]] || die '无效主机名'; HOSTNAME_NEW=$2;;
                    --timezone) [[ $2 =~ ^[a-zA-Z0-9_+-]+(/[a-zA-Z0-9_+-]+)*$ ]] || die '无效时区'; TIMEZONE_NEW=$2;;
                esac
                shift;;
            *) die "未知选项：$1";;
        esac
        shift
    done
    (( ! ZRAM || ! NO_SWAP )) || die '--zram 与 --no-swap 冲突'
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
    local pending
    for pending in "$STATE"/*/access.pending; do
        [[ ! -f $pending ]] || die '已有 SSH 事务等待确认或恢复，请先完成该事务'
    done
    TXID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
    TX="$STATE/$TXID"
    mkdir -m 700 "$TX" "$TX/files" "$TX/after"
    : > "$TX/manifest"
    : > "$TX/sysctl.before"
    : > "$TX/sysfs.before"
    exec > >(tee -a "$TX/run.log") 2>&1
    say "事务 $TXID"
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
    chmod 600 "$tmp"
    mv -f -- "$tmp" "$target"
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
    say '一键计划：日志轮转、内存/swap、TCP/UDP/BBR、安全基线、磁盘维护、SSH/防火墙。'
    say "SSH：$SSH_PORT（保留现端口=$KEEP_SSH）；swap：$SWAP_MB MiB（禁用=$NO_SWAP；zram=$ZRAM）。"
    say "安装工具=$INSTALL；安全更新=$UPDATES；CPU performance=$CPU_PERFORMANCE；Docker 日志=$DOCKER_LOG。"
    say '适用模块才执行；已有服务/转发/防火墙冲突会跳过并说明；不会自动重启机器。'
    say 'SSH 变更需从新端口重新登录确认；云安全组和 NAT 映射需由你放行。'
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
    local target key value conflict=0
    # 先检查所有文件，避免发现后续人工修改时已恢复了一半。
    while IFS= read -r target; do
        if [[ -e $TX/after$target ]] && ! cmp -s "$target" "$TX/after$target"; then
            say "[冲突] $target 已在事务后变化，拒绝覆盖"; conflict=1
        fi
    done < "$TX/manifest"
    (( ! conflict )) || die '请先处理配置冲突'
    if [[ -f $TX/nft.after ]]; then
        nft list table inet vps_init > "$TX/nft.current" || die '防火墙状态与事务不一致'
        cmp -s "$TX/nft.current" "$TX/nft.after" || die '防火墙在事务后变化，拒绝覆盖'
    fi
    if [[ -f $TX/zram.created ]]; then
        if [[ $INIT == systemd ]]; then systemctl disable --now vps-init-zram.service
        else rc-service vps-init-zram stop; rc-update del vps-init-zram default; fi
    fi
    if [[ -f $TX/nft.service ]]; then systemctl disable vps-init-firewall.service; fi
    if [[ -f $TX/swap.created ]]; then
        local swapfile; swapfile=$(cat "$TX/swap.created")
        if grep -Fq "$swapfile " /proc/swaps || grep -Fq "$swapfile" /proc/swaps; then swapoff "$swapfile" || die '内存不足，无法安全 swapoff；未删除交换文件'; fi
        rm -f -- "$swapfile"
    fi
    while IFS= read -r target; do
        if [[ -e $TX/files$target ]]; then cp -p -- "$TX/files$target" "$target"; else rm -f -- "$target"; fi
    done < "$TX/manifest"
    while IFS=$'\t' read -r key value; do [[ -z $key ]] || sysctl -q -w "$key=$value"; done < "$TX/sysctl.before"
    while IFS=$'\t' read -r key value; do [[ -z $key ]] || printf '%s\n' "$value" > "$key"; done < "$TX/sysfs.before"
    rollback_access
    if [[ $INIT == systemd ]]; then
        systemctl daemon-reload
        [[ ! -f $TX/logs.changed ]] || systemctl restart systemd-journald
        [[ ! -f $TX/hostname.before ]] || hostnamectl set-hostname "$(cat "$TX/hostname.before")"
        [[ ! -f $TX/timezone.before ]] || timedatectl set-timezone "$(cat "$TX/timezone.before")"
        if [[ -f $TX/fstrim.before && $(cat "$TX/fstrim.before") == disabled ]]; then systemctl disable --now fstrim.timer; fi
    fi
    touch "$TX/rolled-back"
    say '配置回滚完成；软件包更新、已轮转日志和外部状态不支持撤销。'
}
