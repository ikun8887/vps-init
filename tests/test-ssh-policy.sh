#!/usr/bin/env bash
# 只使用临时配置调用真实 sshd -T，不更改/重载本机服务。
set -Eeuo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
source "$ROOT/vps-init.sh"
WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT
sshd -t
cat > "$WORK/main" <<'EOF'
PasswordAuthentication no
PermitRootLogin no
Match User legacy
    PasswordAuthentication yes
EOF
sshd -T -f "$WORK/main" -C user=legacy,host=localhost,addr=192.0.2.1 > "$WORK/effective"
grep -q '^passwordauthentication yes$' "$WORK/effective"
if (assert_simple_auth_policy "$WORK/main"); then exit 1; fi
cat > "$WORK/child" <<'EOF'
Match Address 192.0.2.0/24
    PermitRootLogin yes
EOF
printf 'PermitRootLogin no\nInclude %s/child\n' "$WORK" > "$WORK/main"
sshd -T -f "$WORK/main" -C user=root,host=localhost,addr=192.0.2.1 > "$WORK/effective"
grep -q '^permitrootlogin yes$' "$WORK/effective"
if (assert_simple_auth_policy "$WORK/main"); then exit 1; fi
printf 'PasswordAuthentication no\n' > "$WORK/child"
assert_simple_auth_policy "$WORK/main"
printf 'PASS: 真实 sshd 验证其他用户/来源的 Match 覆盖；加固前置检查全部拒绝。\n'
