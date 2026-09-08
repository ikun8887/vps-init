#!/usr/bin/env bash
set -Eeuo pipefail
[[ ${GITHUB_ACTIONS:-} == true && ${RUNNER_ENVIRONMENT:-} == github-hosted && ${VPS_INIT_DISPOSABLE_VM:-} == 1 && $EUID == 0 ]] || exit 1
ROOT=$(cd "$(dirname "$0")/.." && pwd)
if [[ ${1:-} != child ]]; then
    NS="vps-init-test-$$"
    ip netns add "$NS"
    trap 'ip netns delete "$NS"' EXIT
    ip netns exec "$NS" bash "$ROOT/tests/integration-nft.sh" child
    exit
fi
source "$ROOT/vps-init.sh"
TX=$(mktemp -d)
trap 'rm -rf -- "$TX"' EXIT
ALLOW=('tcp:80,443' 'udp:443')
nft add table inet unrelated
build_nft 22221 22220
nft list table inet vps_init > "$TX/before"
grep -q 'policy drop;' "$TX/before"
grep -q 'tcp dport 22221 accept' "$TX/before"
grep -q 'ipv6-icmp' "$TX/before"
build_nft 22221 22220
nft list table inet vps_init > "$TX/second"
cmp "$TX/before" "$TX/second"
nft list table inet unrelated >/dev/null
cp "$TX/before" "$TX/nft.before"
build_nft 33333
printf 'nft\n' > "$TX/firewall.kind"
rollback_access
nft list table inet vps_init > "$TX/restored"
cmp "$TX/before" "$TX/restored"
nft list table inet unrelated >/dev/null
printf 'PASS: nftables 内核规则检查、幂等更新、回滚及其他表保留。\n'
