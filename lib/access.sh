#!/usr/bin/env bash
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
    cp "$BASE"/lib/*.sh "$TX/tool/lib/"
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
    [[ $INIT == systemd ]] || { skip 'OpenRC 访问控制暂未具备经过验证的独立恢复机制，保留 SSH/防火墙'; return; }
    if ! has sshd || ! has ss; then skip '缺少 sshd 或 ss'; return; fi
    [[ -f /etc/ssh/sshd_config ]] || { skip '未找到 OpenSSH 配置'; return; }
    sshd -t
    local service=sshd
    if systemctl is-active --quiet ssh.service; then service=ssh
    elif ! systemctl is-active --quiet sshd.service; then skip 'SSH 服务未运行，不启动新的远程访问服务'; return; fi
    local socket=''
    if systemctl is-active --quiet ssh.socket; then socket=ssh.socket
    elif systemctl is-active --quiet sshd.socket; then socket=sshd.socket; fi
    if [[ -n $socket && $(systemctl show "$service.service" -p KillMode --value) != process ]]; then
        skip 'socket 模式下服务 KillMode 非 process，无法保证保留现有 SSH 会话'; return
    fi
    firewall_detect
    [[ $FW != unknown && $FW != none ]] || { skip '已有自定义防火墙或无支持的工具，不接管 SSH/防火墙'; return; }
    if [[ $FW == nft ]]; then
        if [[ -f /etc/nftables.conf ]] && grep -qvE '^[[:space:]]*(#.*)?$|^[[:space:]]*flush ruleset[[:space:]]*$' /etc/nftables.conf; then
            skip '发现已有持久化 nftables 配置，不覆盖其开机策略'; return
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
        if [[ $SSH_PORT != auto && $SSH_PORT != "$target" ]]; then die '已有管理端口；请先回滚之前的端口事务'; fi
        say "保留本工具已管理端口 $target"
        skip '访问配置已管理，本次不重建防火墙或重新随机端口'
        return
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
      awk 'BEGIN {matchblock=0} /^[[:space:]]*[Mm][Aa][Tt][Cc][Hh][[:space:]]/ {matchblock=1} !matchblock && /^[[:space:]]*[Pp][Oo][Rr][Tt][[:space:]]/ {next} {print}' /etc/ssh/sshd_config
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
    [[ -n $(ss -H -ltn "sport = :$target") ]] || die '新端口未监听，将由恢复任务还原'
    say "[待确认] 请在 5 分钟内从新端口 $target 重新 SSH 登录，然后执行："
    say "sudo bash $BASE/vps-init.sh confirm-ssh $TXID"
    say '云安全组/NAT 未放行时保留当前会话；超时恢复整个配置事务。'
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
            printf '%s dport { %s } accept\n' "$proto" "$list"
        done
        printf '}\n}\n'
    } > "$TX/nft.new"
    nft --check -f "$TX/nft.new"
    nft -f "$TX/nft.new"
    nft list table inet vps_init > "$TX/nft.after"
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
    cmp -s /etc/ssh/sshd_config "$TX/after/etc/ssh/sshd_config" || die 'SSH 配置在事务后变化，拒绝覆盖'
    { printf 'Port %s\n' "$target"
      awk 'BEGIN {matchblock=0} /^[[:space:]]*[Mm][Aa][Tt][Cc][Hh][[:space:]]/ {matchblock=1} !matchblock && /^[[:space:]]*[Pp][Oo][Rr][Tt][[:space:]]/ {next} {print}' /etc/ssh/sshd_config
    } > "$TX/sshd.confirm"
    sshd -t -f "$TX/sshd.confirm"
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
    [[ -n $(ss -H -ltn "sport = :$target") ]] || die '新端口监听异常'
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
        write_file /etc/systemd/system/vps-init-firewall.service <<'EOF'
[Unit]
Description=VPS Init firewall
After=network-pre.target
Before=network.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/nft -f /etc/nftables-vps-init.conf
[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable vps-init-firewall.service
        touch "$TX/nft.service"
    elif [[ $FW == firewalld && -f $TX/firewalld.added ]]; then
        local proto
        while IFS=$'\t' read -r proto p; do firewall-cmd --permanent --add-port="$p/$proto"; done < "$TX/firewalld.added"
        say '既有防火墙旧端口规则保留；SSH 已停止在旧端口监听。'
    fi
    write_file /etc/ssh/vps-init-port <<< "$target"
    stop_recovery
    touch "$TX/access.confirmed"
    say "SSH 新端口 $target 已确认。"
}
rollback_access() {
    local fw='' p proto service
    [[ ! -f $TX/firewall.kind ]] || fw=$(cat "$TX/firewall.kind")
    case $fw in
        nft)
            if nft list table inet vps_init >/dev/null 2>&1; then nft delete table inet vps_init; fi
            [[ ! -f $TX/nft.before ]] || nft -f "$TX/nft.before"
            ;;
        ufw) ufw reload;;
        firewalld)
            if [[ -f $TX/firewalld.added ]]; then
                while IFS=$'\t' read -r proto p; do
                    firewall-cmd --remove-port="$p/$proto"
                    if [[ -f $TX/access.confirmed ]]; then firewall-cmd --permanent --remove-port="$p/$proto"; fi
                done < "$TX/firewalld.added"
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
