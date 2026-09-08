#!/usr/bin/env bash
install_tools() {
    (( INSTALL )) || { skip '未选择安装工具；使用已有命令'; return; }
    case $DIST in
        debian|ubuntu) apt-get update; DEBIAN_FRONTEND=noninteractive apt-get install -y util-linux procps iproute2 logrotate openssh-server nftables;;
        rocky|almalinux|rhel|fedora) dnf install -y util-linux procps-ng iproute logrotate openssh-server nftables;;
        alpine) apk add util-linux procps iproute2 logrotate openssh nftables;;
        opensuse*|sles) zypper --non-interactive install util-linux procps iproute2 logrotate openssh nftables;;
    esac
}
basic_init() {
    if [[ -n $HOSTNAME_NEW ]]; then
        if has hostnamectl && [[ $INIT == systemd ]]; then
            hostnamectl --static > "$TX/hostname.before"
            hostnamectl set-hostname "$HOSTNAME_NEW"
        else skip '主机名修改需要 hostnamectl'; fi
    fi
    if [[ -n $TIMEZONE_NEW ]]; then
        if has timedatectl && [[ $INIT == systemd ]] && [[ -f /usr/share/zoneinfo/$TIMEZONE_NEW ]]; then
            timedatectl show -p Timezone --value > "$TX/timezone.before"
            timedatectl set-timezone "$TIMEZONE_NEW"
        else skip '时区未安装或 timedatectl 不可用'; fi
    fi
    if [[ $INIT == systemd ]] && has timedatectl; then
        say '时间同步状态：'; timedatectl show -p NTPSynchronized -p NTP || true
    fi
    if (( UPDATES )); then
        case $DIST in
            rocky|almalinux|rhel|fedora) dnf upgrade --security -y;;
            opensuse*|sles) zypper --non-interactive patch --category security;;
            debian|ubuntu)
                if has unattended-upgrade; then unattended-upgrade; else skip '请先配置并安装 unattended-upgrades；不以全量升级冒充安全更新'; fi;;
            *) skip '该发行版没有本工具支持的安全更新筛选，请使用发行版维护流程';;
        esac
    fi
}
configure_logs() {
    local budget=128 runtime=32 free_mb
    free_mb=$(df -Pm /var | awk 'NR==2 {print $4}')
    (( RAM_MB >= 2048 )) && runtime=64
    (( free_mb >= 10240 )) && budget=256
    if [[ $INIT == systemd ]]; then
        write_file /etc/systemd/journald.conf.d/60-vps-init.conf <<EOF
[Journal]
SystemMaxUse=${budget}M
SystemKeepFree=256M
RuntimeMaxUse=${runtime}M
MaxRetentionSec=14day
Compress=yes
EOF
        touch "$TX/logs.changed"
        systemctl restart systemd-journald
    else skip '非 systemd：journald 配置不适用'; fi
    if has logrotate; then
        if [[ -f /etc/logrotate.conf ]]; then
            # 在 include 之前补充默认上限，应用自己的块内设置仍有优先权。
            awk '
                /^# BEGIN VPS-INIT DEFAULTS$/ {managed=1;next}
                /^# END VPS-INIT DEFAULTS$/ {managed=0;next}
                managed {next}
                !added && /^[[:space:]]*include[[:space:]]/ {
                    print "# BEGIN VPS-INIT DEFAULTS\nweekly\nrotate 4\nmaxsize 16M\ncompress\n# END VPS-INIT DEFAULTS"
                    added=1
                }
                {print}
            ' /etc/logrotate.conf > "$TX/logrotate.new"
            write_file /etc/logrotate.conf < "$TX/logrotate.new"
        fi
        # 不添加覆盖所有日志的通配符规则，避免与发行版规则重复。
        write_file /etc/logrotate.d/vps-init <<'EOF'
/var/lib/vps-init/*/run.log {
    weekly
    maxsize 1M
    rotate 4
    compress
    missingok
    notifempty
    create 0600 root root
}
EOF
        logrotate -d /etc/logrotate.conf
        say '已验证 logrotate 配置；系统/应用日志沿用各自规则，请检查是否都具备轮转。'
    else skip 'logrotate 不存在，可使用 --install-tools'; fi
}
configure_memory() {
    (( ! LIMITED )) || { skip '容器环境不修改宿主机交换空间'; return; }
    (( ! NO_SWAP )) || { skip '用户保留 swap 配置'; return; }
    if [[ $(awk 'END {print NR}' /proc/swaps) -gt 1 ]]; then skip '已有 swap，保留其容量和策略'; return; fi
    if (( ZRAM )); then configure_zram; return; fi
    local size=$SWAP_MB free_mb fs
    if [[ $size == auto ]]; then
        size=$RAM_MB
        (( size >= 512 )) || size=512
        (( size <= 2048 )) || size=2048
    fi
    fs=$(stat -f -c %T /var/lib)
    case $fs in ext2/ext3|xfs) :;; *) skip "文件系统 $fs 未验证交换文件创建；不猜测 Btrfs/CoW 设置"; return;; esac
    free_mb=$(df -Pm /var/lib | awk 'NR==2 {print $4}')
    (( free_mb > size + 512 && size < free_mb / 2 )) || { skip '空闲空间不足以安全创建 swap'; return; }
    [[ ! -e /var/lib/vps-init.swap && ! -L /var/lib/vps-init.swap ]] || { skip '交换文件路径已存在'; return; }
    printf '%s\n' /var/lib/vps-init.swap > "$TX/swap.created"
    dd if=/dev/zero of=/var/lib/vps-init.swap bs=1M count="$size" status=none
    chmod 600 /var/lib/vps-init.swap
    mkswap /var/lib/vps-init.swap
    swapon /var/lib/vps-init.swap
    { cat /etc/fstab; printf '\n/var/lib/vps-init.swap none swap sw 0 0\n'; } > "$TX/fstab.new"
    write_file /etc/fstab < "$TX/fstab.new"
    say "已创建 ${size} MiB swap；保留内核 swappiness 默认策略。"
}
configure_zram() {
    if ! has modprobe || ! has zramctl; then skip 'zram 需要 modprobe 与 zramctl'; return; fi
    [[ ! -e /sys/block/zram0 ]] || { skip '已存在 zram 设备，避免接管其他管理器'; return; }
    if [[ -r /sys/module/zswap/parameters/enabled ]] && [[ $(cat /sys/module/zswap/parameters/enabled) == Y ]]; then
        skip 'zswap 已启用，避免叠加压缩'; return
    fi
    modprobe zram num_devices=1 || { skip '内核不支持加载 zram'; return; }
    local size=$((RAM_MB/2))
    (( size <= 2048 )) || size=2048
    (( size >= 32 )) || { skip '可用内存过小'; return; }
    write_file /usr/local/sbin/vps-init-zram <<EOF
#!/bin/sh
set -eu
case "\${1:-start}" in
start)
    modprobe zram num_devices=1
    [ "\$(cat /sys/block/zram0/disksize)" = 0 ] || exit 1
    zramctl /dev/zram0 --size ${size}M
    mkswap /dev/zram0
    swapon -p 100 /dev/zram0
    ;;
stop)
    if grep -q '^/dev/zram0[[:space:]]' /proc/swaps; then swapoff /dev/zram0; fi
    if [ -e /sys/block/zram0 ]; then zramctl --reset /dev/zram0; fi
    ;;
esac
EOF
    chmod 700 /usr/local/sbin/vps-init-zram
    touch "$TX/zram.created"
    if [[ $INIT == systemd ]]; then
        write_file /etc/systemd/system/vps-init-zram.service <<'EOF'
[Unit]
Description=VPS Init zram swap
After=systemd-modules-load.service
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/vps-init-zram start
ExecStop=/usr/local/sbin/vps-init-zram stop
[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable --now vps-init-zram.service
    else
        write_file /etc/init.d/vps-init-zram <<'EOF'
#!/sbin/openrc-run
description="VPS Init zram swap"
start() { /usr/local/sbin/vps-init-zram start; }
stop() { /usr/local/sbin/vps-init-zram stop; }
EOF
        chmod 755 /etc/init.d/vps-init-zram
        rc-update add vps-init-zram default
        rc-service vps-init-zram start
    fi
}
configure_cpu() {
    (( CPU_PERFORMANCE )) || { skip 'CPU 保留调度策略；可显式使用 --cpu-performance'; return; }
    (( ! LIMITED )) || { skip '容器无 CPU 调频管理权限'; return; }
    if [[ $INIT == systemd ]]; then
        if systemctl is-active --quiet tuned || systemctl is-active --quiet power-profiles-daemon; then
            skip '已有调频管理服务，避免竞争'; return
        fi
    fi
    local p count=0
    for p in /sys/devices/system/cpu/cpufreq/policy*/scaling_governor; do
        [[ -f $p && -w $p ]] || continue
        grep -qw performance "${p%/*}/scaling_available_governors" || continue
        printf '%s\t%s\n' "$p" "$(cat "$p")" >> "$TX/sysfs.before"
        printf 'performance\n' > "$p"
        count=$((count+1))
    done
    if (( ! count )); then skip 'VPS 未提供可写的 CPUFreq 接口'; return; fi
    if [[ ! -f /usr/local/sbin/vps-init-cpu ]]; then touch "$TX/cpu.created"; fi
    write_file /usr/local/sbin/vps-init-cpu <<'EOF'
#!/bin/sh
set -eu
for path in /sys/devices/system/cpu/cpufreq/policy*/scaling_governor; do
    [ -w "$path" ] || continue
    grep -qw performance "${path%/*}/scaling_available_governors" || continue
    printf 'performance\n' > "$path"
done
EOF
    chmod 700 /usr/local/sbin/vps-init-cpu
    if [[ $INIT == systemd ]]; then
        write_file /etc/systemd/system/vps-init-cpu.service <<'EOF'
[Unit]
Description=VPS Init CPU governor
After=systemd-modules-load.service
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/vps-init-cpu
[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable vps-init-cpu.service
    else
        write_file /etc/init.d/vps-init-cpu <<'EOF'
#!/sbin/openrc-run
description="VPS Init CPU governor"
start() { /usr/local/sbin/vps-init-cpu; }
EOF
        chmod 755 /etc/init.d/vps-init-cpu
        rc-update add vps-init-cpu default
    fi
    say 'CPU performance 已应用，并添加开机配置。'
}
configure_network() {
    (( ! LIMITED )) || { skip '容器不修改宿主机网络参数'; return; }
    SYSCTL_TEMP="$TX/sysctl.new"
    : > "$SYSCTL_TEMP"
    local max=4194304
    (( RAM_MB < 1024 )) || max=8388608
    (( RAM_MB < 4096 )) || max=16777216
    # 只提高上限；不降低机器已有的更大缓冲，不抬高每连接初始分配。
    local key old
    for key in net.core.rmem_max net.core.wmem_max; do
        old=$(sysctl -n "$key" 2>/dev/null || printf 0)
        if (( old < max )); then set_sysctl "$key" "$max"; fi
    done
    set_sysctl net.ipv4.tcp_moderate_rcvbuf 1
    for key in net.ipv4.tcp_rmem net.ipv4.tcp_wmem; do
        local low normal high
        IFS=$' \t' read -r low normal high <<< "$(sysctl -n "$key")"
        if (( high < max )); then set_sysctl "$key" "$low $normal $max"; fi
    done
    if has modprobe; then modprobe tcp_bbr 2>/dev/null || true; fi
    if sysctl -n net.ipv4.tcp_available_congestion_control | grep -qw bbr; then
        set_sysctl net.ipv4.tcp_congestion_control bbr
        say '已启用内核提供的 bbr；不据此猜测 BBR 版本。'
    else skip '当前内核无 BBR；不下载替换内核'; fi
    # 不替换当前 tc 层级：可能存在提供商限速、VPN 或用户队列。
    say '保留现有 qdisc、MTU、TCP 重传、UDP 超时及转发配置。'
    local managed=/etc/sysctl.d/60-vps-init-network.conf
    if [[ -s $SYSCTL_TEMP ]]; then
        # 合并此前本工具管理的参数，保证第二次运行不丢失持久化配置。
        if [[ -f $managed ]]; then
            awk -F= 'NR==FNR {k=$1;gsub(/[ \t]/,"",k);seen[k]=1;next} {k=$1;gsub(/[ \t]/,"",k);if(!seen[k]) print}' "$SYSCTL_TEMP" "$managed" > "$TX/sysctl.merge"
            cat "$SYSCTL_TEMP" >> "$TX/sysctl.merge"
            write_file "$managed" < "$TX/sysctl.merge"
        else write_file "$managed" < "$SYSCTL_TEMP"; fi
    fi
    if has nstat; then say '当前网络异常计数（累计值）：'; nstat -az UdpInErrors UdpRcvbufErrors TcpRetransSegs; fi
}
configure_security() {
    (( ! LIMITED )) || { skip '容器保留内核安全策略'; return; }
    SYSCTL_TEMP="$TX/security.new"
    : > "$SYSCTL_TEMP"
    set_sysctl fs.protected_hardlinks 1
    set_sysctl fs.protected_symlinks 1
    set_sysctl net.ipv4.tcp_syncookies 1
    # 不强制 rp_filter、禁转发或关闭 IPv6，以兼容 VPN/多网卡。
    write_file /etc/sysctl.d/60-vps-init-security.conf < "$SYSCTL_TEMP"
    if has getenforce; then say "SELinux：$(getenforce)，保留现状"; fi
    if has aa-status; then
        if aa-status --enabled; then say 'AppArmor 已启用'; else say 'AppArmor 未启用'; fi
    fi
    say '保留现有 SSH 认证方式；仅改端口不等于密钥认证加固。'
}
configure_storage() {
    if [[ $INIT == systemd ]] && has fstrim && has lsblk && lsblk -D -n -o DISC-MAX | grep -qvE '^ *0B? *$'; then
        if systemctl cat fstrim.timer >/dev/null 2>&1; then
            systemctl is-enabled fstrim.timer > "$TX/fstrim.before" 2>/dev/null || true
            systemctl is-active fstrim.timer > "$TX/fstrim.active" 2>/dev/null || true
            systemctl enable --now fstrim.timer
        else skip '系统未提供 fstrim.timer'; fi
    else skip '未检测到可用 TRIM 调度；不修改文件系统挂载选项'; fi
    say '磁盘检查：'; df -h / /var; df -i / /var
    say '不自动删除应用数据、历史安全日志、软件包或内核。'
}
configure_docker() {
    (( DOCKER_LOG )) || return 0
    if ! has docker || ! has python3; then skip 'Docker 日志配置需要 docker 和 python3'; return; fi
    backup /etc/docker/daemon.json
    python3 - "$TX/docker.new" <<'PY'
import json, os, sys
path = '/etc/docker/daemon.json'
with open(path, encoding='utf-8') if os.path.exists(path) else open('/dev/null') as f:
    raw = f.read()
data = json.loads(raw) if raw.strip() else {}
if not isinstance(data, dict):
    raise SystemExit('daemon.json 必须是 JSON 对象')
driver = data.get('log-driver', 'json-file')
if driver not in ('json-file', 'local'):
    raise SystemExit('已有第三方日志驱动，拒绝覆盖')
data.setdefault('log-driver', driver)
opts = data.setdefault('log-opts', {})
opts.setdefault('max-size', '10m')
opts.setdefault('max-file', '3')
with open(sys.argv[1], 'w', encoding='utf-8') as f:
    json.dump(data, f, indent=2)
    f.write('\n')
PY
    has dockerd || { skip '缺少 dockerd，无法验证配置'; return; }
    dockerd --validate --config-file "$TX/docker.new"
    write_file /etc/docker/daemon.json < "$TX/docker.new"
    say '[待生效] Docker 配置已校验；维护窗口重启 Docker 后，新建容器采用默认日志限制。'
}

configure_fail2ban() {
    (( FAIL2BAN )) || return 0
    if ! has fail2ban-client || ! has sshd; then skip 'Fail2ban 未安装，请先通过系统软件源安装'; return; fi
    [[ $INIT == systemd ]] || { skip 'Fail2ban 当前只配置 systemd 后端'; return; }
    local ports remote=''
    ports=$(sshd -T | awk '$1=="port" {printf "%s%s",sep,$2;sep=","}')
    [[ -n $ports ]] || die 'Fail2ban 无法读取 SSH 端口'
    remote=${SSH_CONNECTION:-}; remote=${remote%% *}
    [[ $remote =~ ^[0-9a-fA-F:.]+$ ]] || remote=''
    systemctl is-active fail2ban > "$TX/fail2ban.active" || true
    write_file /etc/fail2ban/jail.d/60-vps-init.local <<EOF
[sshd]
enabled = true
backend = systemd
port = $ports
maxretry = 5
findtime = 10m
bantime = 1h
ignoreip = 127.0.0.1/8 ::1 $remote
EOF
    fail2ban-client -t
    systemctl restart fail2ban
    fail2ban-client status sshd
}
