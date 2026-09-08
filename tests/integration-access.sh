#!/usr/bin/env bash
# 仅用于 GitHub 临时虚拟机，会修改该临时机的 SSH、UFW 和系统优化配置。
set -Eeuo pipefail
[[ ${GITHUB_ACTIONS:-} == true && ${RUNNER_ENVIRONMENT:-} == github-hosted && ${VPS_INIT_DISPOSABLE_VM:-} == 1 ]] || {
    printf '此测试只能在明确授权的 GitHub 托管临时 VM 中执行。\n' >&2
    exit 1
}
[[ $EUID == 0 ]] || exit 1
ROOT=$(cd "$(dirname "$0")/.." && pwd)
MODE=${1:-service}
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
else systemctl start ssh.service; fi
ufw allow 22220/tcp
ufw --force enable
SSH=(ssh -i "$TMP/key" -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o "UserKnownHostsFile=$TMP/known_hosts")
"${SSH[@]}" -p 22220 root@127.0.0.1 true
# 从旧会话运行一键优化，验证服务重载/重启不会杀死该会话。
"${SSH[@]}" -p 22220 root@127.0.0.1 "bash '$ROOT/vps-init.sh' optimize --yes --no-swap --ssh-port 22221"
pending=(/var/lib/vps-init/*/access.pending)
[[ ${#pending[@]} == 1 && -f ${pending[0]} ]]
tx=${pending[0]%/access.pending}; tx=${tx##*/}
"${SSH[@]}" -p 22221 root@127.0.0.1 "bash '$ROOT/vps-init.sh' confirm-ssh '$tx'"
"${SSH[@]}" -p 22221 root@127.0.0.1 "bash '$ROOT/vps-init.sh' verify"
if "${SSH[@]}" -p 22220 root@127.0.0.1 true; then
    printf '旧 SSH 端口确认后仍可登录\n' >&2
    exit 1
fi
"${SSH[@]}" -p 22221 root@127.0.0.1 "bash '$ROOT/vps-init.sh' rollback '$tx'"
"${SSH[@]}" -p 22220 root@127.0.0.1 true
[[ ! -e /etc/ssh/vps-init-port && -f /var/lib/vps-init/$tx/rolled-back ]]
printf 'PASS: %s 一键执行、新连接确认、旧端口关闭和恢复旧登录。\n' "$MODE"
