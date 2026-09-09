#!/usr/bin/env bash
set -Eeuo pipefail
[[ ${GITHUB_ACTIONS:-} == true && ${RUNNER_ENVIRONMENT:-} == github-hosted && ${VPS_INIT_DISPOSABLE_VM:-} == 1 && $EUID == 0 ]] || exit 1
ROOT=$(cd "$(dirname "$0")/.." && pwd)
source "$ROOT/vps-init.sh"
detect
require_root
require_commands
WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT
keys=(net.core.rmem_max net.core.wmem_max net.ipv4.tcp_rmem net.ipv4.tcp_wmem net.ipv4.tcp_moderate_rcvbuf net.ipv4.tcp_congestion_control net.core.default_qdisc)
sysctl "${keys[@]}" > "$WORK/before"
tc qdisc show > "$WORK/qdisc.before"
NETWORK_PROFILE=throughput BANDWIDTH_MBPS=1000 RTT_MS=100 KEEP_BBR=1 DEFAULT_FQ=1
begin_transaction
configure_network
verify_managed
[[ $(sysctl -n net.core.default_qdisc) == fq ]]
tc qdisc show > "$WORK/qdisc.after"
cmp "$WORK/qdisc.before" "$WORK/qdisc.after"
rollback
sysctl "${keys[@]}" > "$WORK/after"
cmp "$WORK/before" "$WORK/after"
printf 'PASS: 自适应参数和默认 FQ 生效，既有 tc 树保留，回滚恢复全部原始 sysctl。\n'
