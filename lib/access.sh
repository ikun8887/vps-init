#!/usr/bin/env bash
assert_simple_auth_policy() {
    # 全局禁用无法靠抽样 sshd -T 证明。只接受无既有 Match 的配置树。
    # Include 仅解析简单路径语法；复杂引用明确拒绝，不猜测 OpenSSH 的解析结果。
    local file=$1 depth=${2:-0} line keyword rest pattern child
    local -a patterns=() children=()
    (( depth < 16 )) || die 'SSH Include 层级过深或循环，不能自动加固'
    [[ -f $file && -r $file ]] || die "SSH 配置不可读取：$file"
    while IFS= read -r line || [[ -n $line ]]; do
        line=${line%%#*}
        [[ $line =~ ^[[:space:]]*$ ]] && continue
        [[ $line =~ ^[[:space:]]*([[:alpha:]]+)[[:space:]]*=?[[:space:]]*(.*)$ ]] || die "不能安全解析 SSH 配置行：$file"
        keyword=${BASH_REMATCH[1],,}; rest=${BASH_REMATCH[2]}
        case $keyword in
            match) die "检测到既有 Match 条件：$file；请人工整合全局登录禁用策略";;
            include)
                IFS=$' \t' read -r -a patterns <<< "$rest"
                (( ${#patterns[@]} )) || die 'SSH Include 缺少路径'
                for pattern in "${patterns[@]}"; do
                    [[ $pattern =~ ^[a-zA-Z0-9_./*?+-]+$ ]] || die "不自动解析复杂 SSH Include 路径：$file"
                    [[ $pattern == /* ]] || pattern="/etc/ssh/$pattern"
                    mapfile -t children < <(compgen -G "$pattern" || true)
                    for child in "${children[@]}"; do assert_simple_auth_policy "$child" "$((depth+1))"; done
                done
                ;;
        esac
    done < "$file"
}

firewall_detect() {
    FW=none
    if has firewall-cmd && firewall-cmd --state >/dev/null 2>&1; then FW=firewalld
    elif has ufw && ufw status | grep -q '^Status: active'; then FW=ufw
    elif has nft; then
        local rules
        rules=$(nft list tables) || { FW=unknown; return; }
        if [[ -z $rules || $rules == 'table inet vps_init' ]]; then FW=nft
        else FW=unknown; fi
    fi
}
configure_firewall() {
    (( ! LIMITED )) || { skip '受限容器不接管防火墙'; return; }
    firewall_detect
    [[ $FW != none && $FW != unknown ]] || { skip '未找到可安全管理的防火墙后端'; return; }
    if [[ $FW == nft ]]; then
        if [[ $INIT == systemd ]] && { systemctl is-enabled --quiet nftables.service || systemctl is-active --quiet nftables.service; }; then skip '已有 nftables 服务，不接管'; return; fi
        if [[ $INIT == openrc ]] && rc-service nftables status >/dev/null 2>&1; then skip '已有 nftables 服务，不接管'; return; fi
        if has iptables-save && iptables-save | grep -q '^-A'; then skip '已有 iptables 规则，不接管'; return; fi
        if has docker && docker info >/dev/null 2>&1; then skip 'Docker 正在管理网络，不接管'; return; fi
        if nft list table inet vps_init > "$TX/nft.before" 2>/dev/null; then :; else rm -f "$TX/nft.before"; fi
    fi
    local p proto item list
    local -a ports=() ssh_ports=()
    has sshd && mapfile -t ssh_ports < <(sshd -T | awk '$1=="port" {print $2}')
    printf '%s\n' "$FW" > "$TX/firewall.kind"
    if [[ $FW == nft ]]; then
        build_nft "${ssh_ports[@]}"
    else
        if [[ $FW == ufw ]]; then for p in /etc/ufw/user.rules /etc/ufw/user6.rules; do backup "$p"; done; fi
        for p in "${ssh_ports[@]}"; do firewall_open tcp "$p"; done
        for item in "${ALLOW[@]}"; do
            proto=${item%%:*}; list=${item#*:}; IFS=, read -r -a ports <<< "$list"
            for p in "${ports[@]}"; do firewall_open "$proto" "$p"; done
        done
        if [[ $FW == ufw ]]; then for p in /etc/ufw/user.rules /etc/ufw/user6.rules; do cp -p "$p" "$TX/after$p"; done; fi
    fi
    persist_access
    say '防火墙已处理，未修改 SSH 配置。'
}
wait_listener() {
    local port=$1 attempt
    for ((attempt=0; attempt<50; attempt++)); do
        if [[ -n $(ss -H -ltn "sport = :$port") ]]; then return 0; fi
        sleep 0.1
    done
    return 1
}
firewall_open() {
    local proto=$1 port=$2
    case $FW in
        firewalld)
            if ! firewall-cmd --query-port="$port/$proto" >/dev/null; then
                firewall-cmd --add-port="$port/$proto"
                printf '%s\t%s\n' "$proto" "$port" >> "$TX/firewalld.added"
            fi
            # 临时规则在确认后才持久化，避免未经验证的入口永久暴露。
            ;;
        ufw)
            # UFW 对规则编号和现有多种语法的逆操作易误删，备份其配置做回滚。
            ufw allow "$port/$proto" comment 'vps-init'
            ;;
    esac
}
prepare_recovery() {
    # 恢复任务独立于 SSH 会话；复制当前工具，避免用户移动源码后无法回滚。
    mkdir -p "$TX/tool/lib"
    cp "$BASE/vps-init.sh" "$TX/tool/"
    if [[ -d $BASE/lib ]]; then cp "$BASE"/lib/*.sh "$TX/tool/lib/"; fi
    if [[ $INIT == openrc ]]; then
        local result job
        result=$(printf '/bin/bash %s/tool/vps-init.sh rollback %s >>%s/recovery.log 2>&1\n' "$TX" "$TXID" "$TX" | env -i PATH="$PATH" HOME=/root LC_ALL=C at now + 5 minutes 2>&1) || die 'at 恢复任务创建失败'
        job=$(printf '%s\n' "$result" | awk '$1=="job" {print $2}')
        [[ $job =~ ^[0-9]+$ ]] || die '无法确认 at 恢复任务 ID'
        printf '%s\n' "$job" > "$TX/at.job"
        atq | awk '{print $1}' | grep -Fxq "$job" || die 'at 恢复任务不在队列'
        touch "$TX/access.pending"
        return
    fi
    local unit="vps-init-recovery-$TXID"
    cat > "/etc/systemd/system/$unit.service" <<EOF
[Unit]
Description=Restore unconfirmed VPS Init SSH change
[Service]
Type=oneshot
ExecStart=/bin/bash $TX/tool/vps-init.sh rollback $TXID
EOF
    cat > "/etc/systemd/system/$unit.timer" <<EOF
[Unit]
Description=VPS Init access recovery deadline
[Timer]
OnActiveSec=5min
AccuracySec=1s
Unit=$unit.service
[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    systemctl enable --now "$unit.timer"
    systemctl is-active --quiet "$unit.timer" || die '恢复定时器启动失败'
    touch "$TX/access.pending"
}
stop_recovery() {
    if [[ -f $TX/at.job ]]; then
        local job
        job=$(cat "$TX/at.job")
        [[ $job =~ ^[0-9]+$ ]] || die 'at 任务记录无效'
        if atq | awk '{print $1}' | grep -Fxq "$job"; then atrm "$job"; fi
        rm -f "$TX/access.pending"
        return
    fi
    local unit="vps-init-recovery-$TXID"
    if [[ -f /etc/systemd/system/$unit.timer ]]; then
        systemctl disable --now "$unit.timer"
        rm -f "/etc/systemd/system/$unit.timer" "/etc/systemd/system/$unit.service"
        systemctl daemon-reload
    fi
    rm -f "$TX/access.pending"
}
configure_access() {
    (( ! LIMITED )) || { skip '受限容器不接管 SSH 或防火墙'; return; }
    if [[ $INIT == openrc ]]; then
        if ! has at || ! has atq || ! has atrm || ! rc-service atd status >/dev/null 2>&1; then
            skip 'OpenRC 访问迁移需要已运行的 atd 和 at 工具作为独立恢复机制'; return
        fi
        rc-update show default | grep -qE '^[[:space:]]*atd[[:space:]]' || { skip 'atd 未在默认运行级别启用，不能保证重启后恢复'; return; }
    fi
    if ! has sshd || ! has ss; then skip '缺少 sshd 或 ss'; return; fi
    [[ -f /etc/ssh/sshd_config ]] || { skip '未找到 OpenSSH 配置'; return; }
    sshd -t
    if (( DISABLE_PASSWORD || DISABLE_ROOT )); then assert_simple_auth_policy /etc/ssh/sshd_config; fi
    local service=sshd
    local socket=''
    if [[ $INIT == systemd ]]; then
        if systemctl is-active --quiet ssh.service; then service=ssh
        elif ! systemctl is-active --quiet sshd.service; then skip 'SSH 服务未运行，不启动新的远程访问服务'; return; fi
        if systemctl is-active --quiet ssh.socket; then socket=ssh.socket
        elif systemctl is-active --quiet sshd.socket; then socket=sshd.socket; fi
    elif ! rc-service sshd status >/dev/null 2>&1; then skip 'sshd 未运行'; return; fi
    if [[ -n $socket && $(systemctl show "$service.service" -p KillMode --value) != process ]]; then
        skip 'socket 模式下服务 KillMode 非 process，无法保证保留现有 SSH 会话'; return
    fi
    firewall_detect
    [[ $FW != unknown && $FW != none ]] || { skip '已有自定义防火墙或无支持的工具，不接管 SSH/防火墙'; return; }
    if [[ $FW == nft ]]; then
        if [[ $INIT == systemd ]]; then
            if systemctl is-enabled --quiet nftables.service || systemctl is-active --quiet nftables.service; then
                skip '已有启用的 nftables 服务，不叠加开机规则管理器'; return
            fi
        elif rc-service nftables status >/dev/null 2>&1; then
            skip '已有 nftables 服务，不叠加规则管理器'; return
        fi
        if has iptables-save && iptables-save | grep -q '^-A'; then skip '检测到 iptables 规则，不创建冲突的 nftables 策略'; return; fi
        if has docker && docker info >/dev/null 2>&1; then skip '检测到 Docker，由现有容器防火墙策略管理'; return; fi
    fi
    local -a old_ports=()
    mapfile -t old_ports < <(sshd -T | awk '$1=="port" {print $2}')
    (( ${#old_ports[@]} )) || die '未能识别 SSH 端口'
    local p target=$SSH_PORT
    if (( KEEP_SSH )); then target=${old_ports[0]}
    elif [[ -f /etc/ssh/vps-init-port ]]; then
        target=$(cat /etc/ssh/vps-init-port)
        port_valid "$target" || die '已管理 SSH 端口记录损坏'
        if [[ $SSH_PORT != auto && $SSH_PORT != "$target" ]]; then target=$SSH_PORT
        elif [[ -z $ADMIN_USER ]] && (( ! STRICT_SSH && ${#ALLOW[@]} == 0 )) &&
            printf '%s\n' "${old_ports[@]}" | grep -Fxq "$target" && wait_listener "$target"; then
            skip '访问配置已管理，本次不重建防火墙或重新随机端口'
            return
        fi
    elif [[ $target == auto ]]; then
        local tries=0
        while :; do
            target=$((20000 + RANDOM % 20000))
            [[ -z $(ss -H -ltn "sport = :$target") ]] && break
            tries=$((tries+1)); (( tries < 100 )) || die '找不到空闲端口'
        done
    fi
    port_valid "$target" || die '无效目标端口'
    if [[ -n $(ss -H -ltn "sport = :$target") ]]; then
        local found=0
        for p in "${old_ports[@]}"; do [[ $p != "$target" ]] || found=1; done
        (( found )) || die "目标端口 $target 已被占用"
    fi
    if has getenforce && [[ $(getenforce) != Disabled ]]; then
        if ! has semanage; then skip 'SELinux 生效但缺少 semanage，保留现有端口'; return; fi
        if ! semanage port -l | awk '$1=="ssh_port_t" {for(i=3;i<=NF;i++) print $i}' | tr -d ',' | grep -Fxq "$target"; then
            semanage port -a -t ssh_port_t -p tcp "$target"
            printf '%s\n' "$target" > "$TX/selinux.added"
        fi
    fi
    printf '%s\n' "$FW" > "$TX/firewall.kind"
    printf '%s\n' "$service" > "$TX/ssh.service"
    printf '%s\n' "$target" > "$TX/ssh.target"
    printf '%s\n' "${old_ports[@]}" > "$TX/ssh.oldports"
    if [[ -n $socket ]]; then
        prepare_socket "$socket" "$target" || { skip 'socket 绑定含不支持的地址形式，保留 SSH'; return; }
        printf '%s\n' "$socket" > "$TX/ssh.socket"
    fi
    if [[ $FW == ufw ]]; then
        for p in /etc/ufw/user.rules /etc/ufw/user6.rules; do backup "$p"; done
    elif [[ $FW == nft ]]; then
        if nft list table inet vps_init > "$TX/nft.before" 2>/dev/null; then :; else rm -f "$TX/nft.before"; fi
    fi
    prepare_recovery
    if [[ -n $ADMIN_USER ]]; then prepare_identity; fi
    if [[ $FW == nft ]]; then
        build_nft "$target" "${old_ports[@]}"
    else
        for p in "$target" "${old_ports[@]}"; do firewall_open tcp "$p"; done
        local item proto list
        local -a ports
        for item in "${ALLOW[@]}"; do
            proto=${item%%:*}; list=${item#*:}; IFS=, read -r -a ports <<< "$list"
            for p in "${ports[@]}"; do firewall_open "$proto" "$p"; done
        done
        if [[ $FW == ufw ]]; then
            for p in /etc/ufw/user.rules /etc/ufw/user6.rules; do cp -p "$p" "$TX/after$p"; done
        fi
    fi
    # Port 为可重复项。先剔除全局 Port，再在首个 Match 之前加入过渡端口。
    # 不尝试重写第三方 Include 里的 Port；确认阶段用 sshd -T 检测残留。
    { printf 'Port %s\n' "$target"; for p in "${old_ports[@]}"; do [[ $p == "$target" ]] || printf 'Port %s\n' "$p"; done
      if [[ -n $ADMIN_USER ]]; then printf 'ExposeAuthInfo yes\n'; fi
      awk 'BEGIN {matchblock=0} /^[[:space:]]*[Mm][Aa][Tt][Cc][Hh][[:space:]]/ {matchblock=1} !matchblock && /^[[:space:]]*[Pp][Oo][Rr][Tt][[:space:]]/ {next} {print}' /etc/ssh/sshd_config
      if [[ -n $ADMIN_USER ]] && ! grep -Fxq "# VPS-INIT USER $ADMIN_USER" /etc/ssh/sshd_config; then
          printf '\n# VPS-INIT USER %s\nMatch User %s\n    PubkeyAuthentication yes\n    AuthorizedKeysFile /etc/ssh/vps-init-authorized-keys/%%u .ssh/authorized_keys .ssh/authorized_keys2\n' "$ADMIN_USER" "$ADMIN_USER"
      fi
    } > "$TX/sshd.new"
    sshd -t -f "$TX/sshd.new"
    write_file /etc/ssh/sshd_config < "$TX/sshd.new"
    if [[ -n $socket ]]; then
        write_file "/etc/systemd/system/$socket.d/90-vps-init.conf" < "$TX/socket.transition"
        systemctl daemon-reload
        systemctl stop "$service.service"
        systemctl restart "$socket"
        systemctl start "$service.service"
    else service_reload "$service"; fi
    wait_listener "$target" || die '新端口未监听，将由恢复任务还原'
    if (( ! STRICT_SSH )); then
        # 默认保留所有旧入口；仅在语法、监听和持久化成功后取消恢复任务。
        for p in "${old_ports[@]}"; do wait_listener "$p" || die '旧 SSH 入口未监听，保留恢复任务'; done
        persist_access
        write_file /etc/ssh/vps-init-port <<< "$target"
        touch "$TX/access.ready"
        stop_recovery
        say "SSH $target 已生效，旧入口保留；本次已完成。"
        return
    fi
    say "[待确认] 请在 5 分钟内从新端口 $target 重新 SSH 登录，然后执行："
    say "sudo bash $BASE/vps-init.sh confirm-ssh $TXID"
    say '云安全组/NAT 未放行时保留当前会话；超时恢复整个配置事务。'
    if [[ -n $ADMIN_USER ]]; then
        say "请以 $ADMIN_USER 使用刚提供的公钥登录，并用 sudo --preserve-env=SSH_CONNECTION,SSH_USER_AUTH 执行确认。"
    fi
}
persist_access() {
    if [[ $FW == nft ]]; then
        nft list table inet vps_init > "$TX/nft.after"
        write_file /etc/nftables-vps-init.conf < "$TX/nft.after"
        install_firewall_persistence
    elif [[ $FW == firewalld && -f $TX/firewalld.added ]]; then
        local proto p
        while IFS=$'\t' read -r proto p; do
            if ! firewall-cmd --permanent --query-port="$p/$proto" >/dev/null; then
                printf '%s\t%s\n' "$proto" "$p" >> "$TX/firewalld.permanent-added"
                firewall-cmd --permanent --add-port="$p/$proto"
            fi
        done < "$TX/firewalld.added"
    fi
}
prepare_identity() {
    if ! has ssh-keygen || ! has visudo || ! has getent; then die '公钥管理员需要 ssh-keygen、sudo/visudo 与 getent'; fi
    visudo -c
    [[ $(stat -c %s "$PUBLIC_KEY") -le 16384 ]] || die '公钥文件过大'
    [[ $(awk 'NF {n++} END {print n+0}' "$PUBLIC_KEY") == 1 ]] || die '仅接受一个公钥'
    grep -qE '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)) [A-Za-z0-9+/]+={0,3}([[:space:]].*)?$' "$PUBLIC_KEY" || die '需要 OpenSSH 公钥，不能提供私钥或 authorized_keys 选项'
    ssh-keygen -l -f "$PUBLIC_KEY" >/dev/null
    awk 'NF {print $1 " " $2}' "$PUBLIC_KEY" > "$TX/identity.key"
    printf '%s\n' "$ADMIN_USER" > "$TX/identity.user"
    printf '%s\n' "$DISABLE_PASSWORD" > "$TX/identity.disable-password"
    printf '%s\n' "$DISABLE_ROOT" > "$TX/identity.disable-root"
    if ! getent passwd "$ADMIN_USER" >/dev/null; then
        if has useradd; then useradd -m -s /bin/bash -p '*' "$ADMIN_USER"
        else adduser -D -s /bin/bash "$ADMIN_USER"; printf '%s:*\n' "$ADMIN_USER" | chpasswd -e; fi
        printf '%s\n' "$ADMIN_USER" > "$TX/user.created"
    fi
    [[ $(id -u "$ADMIN_USER") != 0 ]] || die '管理员不能是 UID 0 的别名'
    # 公钥由 root 管理，避免沿用户可写 home 目录进行特权文件写入。
    local keyfile="/etc/ssh/vps-init-authorized-keys/$ADMIN_USER"
    mkdir -p /etc/ssh/vps-init-authorized-keys
    [[ ! -L /etc/ssh/vps-init-authorized-keys ]] || die '公钥目录不可为符号链接'
    [[ $(stat -c %u /etc/ssh/vps-init-authorized-keys) == 0 ]] || die '公钥目录必须属于 root'
    [[ ! -L $keyfile ]] || die '公钥文件不可为符号链接'
    chmod 755 /etc/ssh/vps-init-authorized-keys
    if [[ -f $keyfile ]]; then cat "$keyfile" > "$TX/keys.new"; else : > "$TX/keys.new"; fi
    if ! grep -Fxq "$(cat "$TX/identity.key")" "$TX/keys.new"; then cat "$TX/identity.key" >> "$TX/keys.new"; fi
    write_file "$keyfile" < "$TX/keys.new"
    chmod 644 "$keyfile"
    printf '%s ALL=(ALL:ALL) NOPASSWD: ALL\n' "$ADMIN_USER" > "$TX/sudo.new"
    visudo -cf "$TX/sudo.new"
    write_file "/etc/sudoers.d/60-vps-init-$ADMIN_USER" < "$TX/sudo.new"
    chmod 440 "/etc/sudoers.d/60-vps-init-$ADMIN_USER"
    visudo -c
}
prepare_socket() {
    local socket=$1 target=$2 address kind listen
    local -a fields
    listen=$(systemctl show "$socket" -p Listen --value)
    IFS=' ' read -r -a fields <<< "$listen"
    (( ${#fields[@]} > 0 && ${#fields[@]} % 2 == 0 )) || return 1
    printf '[Socket]\nListenStream=\n' > "$TX/socket.transition"
    printf '[Socket]\nListenStream=\n' > "$TX/socket.confirm"
    local i new
    for ((i=0; i<${#fields[@]}; i+=2)); do
        address=${fields[i]}; kind=${fields[i+1]}
        [[ $kind == '(Stream)' ]] || return 1
        [[ $address =~ ^(\[[0-9a-fA-F:.%_-]+\]|[0-9.]+):[0-9]+$ ]] || return 1
        new="${address%:*}:$target"
        printf 'ListenStream=%s\n' "$address" >> "$TX/socket.transition"
        if [[ $address != "$new" ]]; then printf 'ListenStream=%s\n' "$new" >> "$TX/socket.transition"; fi
        printf 'ListenStream=%s\n' "$new" >> "$TX/socket.confirm"
    done
}
socket_port_only() {
    local socket=$1 target=$2 binding
    local -a bindings
    IFS=' ' read -r -a bindings <<< "$(systemctl show "$socket" -p Listen --value)"
    (( ${#bindings[@]} )) || return 1
    for binding in "${bindings[@]}"; do
        [[ $binding == '(Stream)' || ${binding##*:} == "$target" ]] || return 1
    done
}
build_nft() {
    local -a ports=("$@")
    local p item proto list
    if nft list table inet vps_init > "$TX/nft.current" 2>/dev/null; then
        : > "$TX/nft.new"
        for p in "${ports[@]}"; do nft_append_port tcp "$p"; done
        for item in "${ALLOW[@]}"; do
            proto=${item%%:*}; list=${item#*:}
            local -a extra=()
            IFS=, read -r -a extra <<< "$list"
            for p in "${extra[@]}"; do nft_append_port "$proto" "$p"; done
        done
        nft --check -f "$TX/nft.new"
        nft -f "$TX/nft.new"
        nft list table inet vps_init > "$TX/nft.after"
        return
    fi
    {
        if nft list table inet vps_init >/dev/null 2>&1; then printf 'delete table inet vps_init\n'; fi
        printf 'table inet vps_init {\n chain input {\n type filter hook input priority 0; policy drop;\n'
        printf 'iifname "lo" accept\nct state established,related accept\n'
        printf 'meta l4proto { icmp, ipv6-icmp } accept\n'
        # DHCP 客户端续租；不默认禁止出站或转发。
        printf 'udp sport 67 udp dport 68 accept\nudp sport 547 udp dport 546 accept\n'
        for p in "${ports[@]}"; do printf 'tcp dport %s accept\n' "$p"; done
        # 保留现有服务入口，新增默认拒绝策略不应切断已经部署的业务。
        local endpoint
        while IFS=' ' read -r proto endpoint; do
            p=${endpoint##*:}
            port_valid "$p" || continue
            printf '%s dport %s accept comment "existing-service"\n' "$proto" "$p"
        done < <(ss -H -lntu | awk '$1=="tcp" || $1=="udp" {print $1 " " $5}')
        for item in "${ALLOW[@]}"; do
            proto=${item%%:*}; list=${item#*:}
            local -a extra=()
            IFS=, read -r -a extra <<< "$list"
            for p in "${extra[@]}"; do printf '%s dport %s accept\n' "$proto" "$p"; done
        done
        printf '}\n}\n'
    } > "$TX/nft.new"
    nft --check -f "$TX/nft.new"
    nft -f "$TX/nft.new"
    nft list table inet vps_init > "$TX/nft.after"
}
nft_append_port() {
    local proto=$1 p=$2
    port_valid "$p" || die '无效防火墙端口'
    if ! grep -Eq "(^|[[:space:]])$proto dport $p accept([[:space:];]|$)" "$TX/nft.current" "$TX/nft.new"; then
        printf 'add rule inet vps_init input %s dport %s accept\n' "$proto" "$p" >> "$TX/nft.new"
    fi
}
confirm_ssh() {
    [[ -f $TX/access.pending ]] || die '该事务无待确认 SSH 变更'
    local target service local_port
    target=$(cat "$TX/ssh.target")
    service=$(cat "$TX/ssh.service")
    # SSH_CONNECTION 由 sshd 提供；sudo 可能过滤，不能因此跳过新连接检查。
    local_port=${SSH_CONNECTION:-}
    local_port=${local_port##* }
    [[ -n ${SSH_CONNECTION:-} && $local_port == "$target" ]] || die '请从新端口登录，并使用 sudo --preserve-env=SSH_CONNECTION 执行确认'
    if [[ -f $TX/identity.user ]]; then
        local admin expected
        admin=$(cat "$TX/identity.user")
        [[ ${SUDO_USER:-} == "$admin" ]] || die '请用新管理员账号登录并通过 sudo 确认'
        [[ -n ${SSH_USER_AUTH:-} && -f $SSH_USER_AUTH ]] || die '缺少 SSH_USER_AUTH，请保留该环境变量'
        expected=$(cat "$TX/identity.key")
        grep -Fq "publickey $expected" "$SSH_USER_AUTH" || die '本次会话未使用指定公钥认证'
    fi
    cmp -s /etc/ssh/sshd_config "$TX/after/etc/ssh/sshd_config" || die 'SSH 配置在事务后变化，拒绝覆盖'
    if [[ -f $TX/identity.user ]] && { [[ $(cat "$TX/identity.disable-password") == 1 ]] || [[ $(cat "$TX/identity.disable-root") == 1 ]]; }; then
        # 主配置与本事务生成内容一致；重新检查原主配置引用的当前 Include，
        # 避免等待确认期间增加条件认证。工具自己添加的 Match 仅设置公钥路径。
        assert_simple_auth_policy "$TX/files/etc/ssh/sshd_config"
    fi
    { printf 'Port %s\n' "$target"
      if [[ -f $TX/identity.disable-password && $(cat "$TX/identity.disable-password") == 1 ]]; then printf 'PasswordAuthentication no\nKbdInteractiveAuthentication no\n'; fi
      if [[ -f $TX/identity.disable-root && $(cat "$TX/identity.disable-root") == 1 ]]; then printf 'PermitRootLogin no\n'; fi
      awk 'BEGIN {matchblock=0} /^[[:space:]]*[Mm][Aa][Tt][Cc][Hh][[:space:]]/ {matchblock=1} !matchblock && /^[[:space:]]*[Pp][Oo][Rr][Tt][[:space:]]/ {next} {print}' /etc/ssh/sshd_config
    } > "$TX/sshd.confirm"
    sshd -t -f "$TX/sshd.confirm"
    if [[ -f $TX/identity.user ]]; then
        local addr=${SSH_CONNECTION%% *}
        sshd -T -f "$TX/sshd.confirm" -C "user=$admin,host=$(hostname),addr=$addr" > "$TX/identity.effective"
        grep -q '^pubkeyauthentication yes$' "$TX/identity.effective" || die 'Match 配置禁用了新管理员公钥登录'
        if [[ $(cat "$TX/identity.disable-password") == 1 ]]; then
            grep -q '^passwordauthentication no$' "$TX/identity.effective" || die 'Match 配置仍允许管理员密码登录'
            grep -q '^kbdinteractiveauthentication no$' "$TX/identity.effective" || die 'Match 配置仍允许交互式登录'
            grep -qE '^authenticationmethods (any|publickey)$' "$TX/identity.effective" || die '现有多因素认证策略不能直接关闭密码，请人工整合'
        fi
        if [[ $(cat "$TX/identity.disable-root") == 1 ]]; then
            # 完整读取配置，避免 grep -q 提前退出使 pipefail 将 SIGPIPE 当成验证失败。
            sshd -T -f "$TX/sshd.confirm" -C "user=root,host=$(hostname),addr=$addr" > "$TX/root.effective"
            grep -q '^permitrootlogin no$' "$TX/root.effective" || die 'Match 配置仍允许此来源的 root 登录'
        fi
    fi
    local p
    while read -r p; do [[ $p == "$target" ]] || die "Include 中仍有端口 $p，请人工整理后再迁移"; done < <(sshd -T -f "$TX/sshd.confirm" | awk '$1=="port" {print $2}')
    write_file /etc/ssh/sshd_config < "$TX/sshd.confirm"
    if [[ -f $TX/ssh.socket ]]; then
        local socket
        socket=$(cat "$TX/ssh.socket")
        write_file "/etc/systemd/system/$socket.d/90-vps-init.conf" < "$TX/socket.confirm"
        systemctl daemon-reload
        systemctl stop "$service.service"
        systemctl restart "$socket"
        systemctl start "$service.service"
        socket_port_only "$socket" "$target" || die 'socket 实际绑定仍含旧端口，保留恢复任务'
    else service_reload "$service"; fi
    wait_listener "$target" || die '新端口监听异常'
    FW=$(cat "$TX/firewall.kind")
    if [[ $FW == nft ]]; then
        # 只删除本次额外保留的旧 SSH accept；其余业务端口保持原规则。
        local rules
        rules=$(nft list table inet vps_init)
        while read -r p; do
            [[ $p == "$target" ]] && continue
            rules=$(printf '%s\n' "$rules" | sed "/^[[:space:]]*tcp dport $p accept$/d")
        done < "$TX/ssh.oldports"
        printf 'delete table inet vps_init\n%s\n' "$rules" > "$TX/nft.confirm"
        nft --check -f "$TX/nft.confirm"
        nft -f "$TX/nft.confirm"
        nft list table inet vps_init > "$TX/nft.after"
        write_file /etc/nftables-vps-init.conf < "$TX/nft.after"
        install_firewall_persistence
    elif [[ $FW == firewalld && -f $TX/firewalld.added ]]; then
        local proto
        while IFS=$'\t' read -r proto p; do
            if ! firewall-cmd --permanent --query-port="$p/$proto" >/dev/null; then
                printf '%s\t%s\n' "$proto" "$p" >> "$TX/firewalld.permanent-added"
                firewall-cmd --permanent --add-port="$p/$proto"
            fi
        done < "$TX/firewalld.added"
        say '既有防火墙旧端口规则保留；SSH 已停止在旧端口监听。'
    fi
    write_file /etc/ssh/vps-init-port <<< "$target"
    stop_recovery
    touch "$TX/access.confirmed"
    say "SSH 新端口 $target 已确认。"
}
install_firewall_persistence() {
    write_file /usr/local/sbin/vps-init-firewall <<'EOF'
#!/bin/sh
set -eu
PATH=/usr/sbin:/usr/bin:/sbin:/bin
if [ "${1:-start}" = stop ]; then
    if nft list table inet vps_init >/dev/null 2>&1; then nft delete table inet vps_init; fi
    exit 0
fi
tmp=$(mktemp /run/vps-init-nft.XXXXXX)
trap 'rm -f "$tmp"' EXIT
if nft list table inet vps_init >/dev/null 2>&1; then printf 'delete table inet vps_init\n' >> "$tmp"; fi
cat /etc/nftables-vps-init.conf >> "$tmp"
nft --check -f "$tmp"
nft -f "$tmp"
EOF
    chmod 700 /usr/local/sbin/vps-init-firewall
    if [[ $INIT == systemd ]]; then
        [[ -f /etc/systemd/system/vps-init-firewall.service ]] || touch "$TX/nft.service"
        write_file /etc/systemd/system/vps-init-firewall.service <<'EOF'
[Unit]
Description=VPS Init firewall
After=network-pre.target
Before=network.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/vps-init-firewall start
ExecStop=/usr/local/sbin/vps-init-firewall stop
[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable vps-init-firewall.service
    else
        [[ -f /etc/init.d/vps-init-firewall ]] || touch "$TX/nft.service"
        write_file /etc/init.d/vps-init-firewall <<'EOF'
#!/sbin/openrc-run
description="VPS Init firewall"
depend() { need localmount; before net; }
start() { /usr/local/sbin/vps-init-firewall start; }
stop() { /usr/local/sbin/vps-init-firewall stop; }
EOF
        chmod 755 /etc/init.d/vps-init-firewall
        rc-update add vps-init-firewall default
    fi
}
rollback_access() {
    local fw='' p proto service
    [[ ! -f $TX/firewall.kind ]] || fw=$(cat "$TX/firewall.kind")
    case $fw in
        nft)
            {
                if nft list table inet vps_init >/dev/null 2>&1; then printf 'delete table inet vps_init\n'; fi
                if [[ -f $TX/nft.before ]]; then cat "$TX/nft.before"; fi
            } > "$TX/nft.restore"
            nft --check -f "$TX/nft.restore"
            nft -f "$TX/nft.restore"
            ;;
        ufw) ufw reload;;
        firewalld)
            if [[ -f $TX/firewalld.added ]]; then
                while IFS=$'\t' read -r proto p; do
                    firewall-cmd --remove-port="$p/$proto"
                done < "$TX/firewalld.added"
            fi
            if [[ -f $TX/firewalld.permanent-added ]]; then
                while IFS=$'\t' read -r proto p; do firewall-cmd --permanent --remove-port="$p/$proto"; done < "$TX/firewalld.permanent-added"
            fi;;
    esac
    if [[ -f $TX/ssh.service ]]; then
        service=$(cat "$TX/ssh.service")
        sshd -t
        if [[ -f $TX/ssh.socket ]]; then
            systemctl daemon-reload
            systemctl stop "$service.service"
            systemctl restart "$(cat "$TX/ssh.socket")"
            systemctl start "$service.service"
        else service_reload "$service"; fi
    fi
    if [[ -f $TX/selinux.added ]]; then semanage port -d -t ssh_port_t -p tcp "$(cat "$TX/selinux.added")"; fi
    if [[ -f $TX/access.pending || -f $TX/access.confirmed ]]; then stop_recovery; fi
}
