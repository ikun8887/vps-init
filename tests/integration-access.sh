#!/usr/bin/env bash
# 仅用于 GitHub 临时虚拟机，会修改该临时机的 SSH、UFW 和系统优化配置。
set -Eeuo pipefail
[[ ${GITHUB_ACTIONS:-} == true && ${RUNNER_ENVIRONMENT:-} == github-hosted && ${VPS_INIT_DISPOSABLE_VM:-} == 1 ]] || {
    printf '此测试只能在明确授权的 GitHub 托管临时 VM 中执行。\n' >&2
    exit 1
}
[[ $EUID == 0 ]] || exit 1
# GitHub runner 镜像的 sudoers 文件可能为 0644；测试基线先满足 visudo 的权限检查。
if [[ -f /etc/sudoers.d/runner ]]; then chmod 440 /etc/sudoers.d/runner; fi
ROOT=$(cd "$(dirname "$0")/.." && pwd)
MODE=${1:-service}
IDENTITY=${2:-plain}
TMP=$(mktemp -d)
trap 'rm -rf -- "$TMP"' EXIT
ssh-keygen -q -t ed25519 -N '' -f "$TMP/key"
mkdir -p /root/.ssh
chmod 700 /root/.ssh
cat "$TMP/key.pub" >> /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
cat > /etc/ssh/sshd_config <<'EOF'
Port 22220
ListenAddress 127.0.0.1
PermitRootLogin prohibit-password
PasswordAuthentication no
PubkeyAuthentication yes
UsePAM yes
Subsystem sftp internal-sftp
EOF
mkdir -p /run/sshd
sshd -t
if systemctl cat ssh.socket >/dev/null 2>&1; then systemctl stop ssh.socket; fi
systemctl stop ssh.service
if [[ $MODE == socket ]]; then
    mkdir -p /etc/systemd/system/ssh.socket.d
    cat > /etc/systemd/system/ssh.socket.d/10-integration.conf <<'EOF'
[Socket]
ListenStream=
ListenStream=127.0.0.1:22220
EOF
    systemctl daemon-reload
    systemctl start ssh.socket
else
    # Ubuntu 24 的发行版 drop-in 会拉起 socket，显式构造独立服务测试场景。
    mkdir -p /etc/systemd/system/ssh.service.d
    cat > /etc/systemd/system/ssh.service.d/99-integration.conf <<'EOF'
[Unit]
Requires=
Wants=
[Service]
Type=simple
ExecStart=
ExecStart=/usr/sbin/sshd -D -e
ExecReload=
ExecReload=/bin/kill -HUP $MAINPID
KillMode=process
EOF
    systemctl daemon-reload
    systemctl start ssh.service
fi
ufw allow 22220/tcp
ufw --force enable
SSH=(ssh -i "$TMP/key" -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o "UserKnownHostsFile=$TMP/known_hosts")
for ((i=0; i<50; i++)); do
    [[ -z $(ss -H -ltn 'sport = :22220') ]] || break
    sleep 0.1
done
"${SSH[@]}" -p 22220 root@127.0.0.1 true
# 从旧会话运行一键优化，验证服务重载/重启不会杀死该会话。
extra=''
if [[ $IDENTITY == identity ]]; then
    extra="--admin-user vpscheck --public-key '$TMP/key.pub' --disable-password-login --disable-root-login"
fi
"${SSH[@]}" -p 22220 root@127.0.0.1 "bash '$ROOT/vps-init.sh' optimize --yes --no-swap --ssh-port 22221 $extra"
pending=(/var/lib/vps-init/*/access.pending)
[[ ${#pending[@]} == 1 && -f ${pending[0]} ]]
tx=${pending[0]%/access.pending}; tx=${tx##*/}
grep -Fq 'SSH 原端口：22220' "/var/lib/vps-init/$tx/summary.txt"
grep -Fq 'SSH 目标端口：22221（待确认' "/var/lib/vps-init/$tx/summary.txt"
grep -Fq '目标 TCP 端口 22221：正在监听' "/var/lib/vps-init/$tx/summary.txt"
login=root prefix=''
if [[ $IDENTITY == identity ]]; then login=vpscheck; prefix='sudo --preserve-env=SSH_CONNECTION,SSH_USER_AUTH'; fi
"${SSH[@]}" -p 22221 "$login@127.0.0.1" "$prefix bash '$ROOT/vps-init.sh' confirm-ssh '$tx'"
grep -Fq 'SSH 已确认端口：22221' "/var/lib/vps-init/$tx/summary.txt"
"${SSH[@]}" -p 22221 "$login@127.0.0.1" "$prefix bash '$ROOT/vps-init.sh' verify"
if [[ $IDENTITY == identity ]] && "${SSH[@]}" -p 22221 root@127.0.0.1 true; then
    printf '加固后 root 仍可登录\n' >&2
    exit 1
fi
if "${SSH[@]}" -p 22220 root@127.0.0.1 true; then
    printf '旧 SSH 端口确认后仍可登录\n' >&2
    exit 1
fi
"${SSH[@]}" -p 22221 "$login@127.0.0.1" "$prefix bash '$ROOT/vps-init.sh' rollback '$tx'"
"${SSH[@]}" -p 22220 root@127.0.0.1 true
[[ ! -e /etc/ssh/vps-init-port && -f /var/lib/vps-init/$tx/rolled-back ]]
grep -Fq '结果：事务已回滚' "/var/lib/vps-init/$tx/summary.txt"
printf 'PASS: %s 一键执行、新连接确认、旧端口关闭和恢复旧登录。\n' "$MODE"
if [[ $IDENTITY == plain ]]; then
    # 第二个事务不确认新入口，缩短测试计时，实际调用独立恢复服务。
    "${SSH[@]}" -p 22220 root@127.0.0.1 "bash '$ROOT/vps-init.sh' optimize --yes --no-swap --ssh-port 22221"
    pending=(/var/lib/vps-init/*/access.pending)
    [[ ${#pending[@]} == 1 && -f ${pending[0]} ]]
    tx=${pending[0]%/access.pending}; tx=${tx##*/}
    unit="vps-init-recovery-$tx"
    systemctl stop "$unit.timer"
    sed -i 's/OnActiveSec=5min/OnActiveSec=3s/' "/etc/systemd/system/$unit.timer"
    systemctl daemon-reload
    systemctl start "$unit.timer"
    for ((i=0; i<30; i++)); do
        [[ ! -f /var/lib/vps-init/$tx/rolled-back ]] || break
        sleep 1
    done
    [[ -f /var/lib/vps-init/$tx/rolled-back ]]
    "${SSH[@]}" -p 22220 root@127.0.0.1 true
    printf 'PASS: 无需原 SSH 会话或人工干预的定时恢复。\n'
fi
