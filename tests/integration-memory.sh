#!/usr/bin/env bash
set -Eeuo pipefail
[[ ${GITHUB_ACTIONS:-} == true && ${RUNNER_ENVIRONMENT:-} == github-hosted && ${VPS_INIT_DISPOSABLE_VM:-} == 1 && $EUID == 0 ]] || exit 1
ROOT=$(cd "$(dirname "$0")/.." && pwd)
source "$ROOT/vps-init.sh"
detect
require_root
require_commands
# 临时 VM 镜像有预置但未使用的 swap；仅在没有换出页时停用作测试基线。
[[ $(awk 'NR>1 {sum+=$4} END {print sum+0}' /proc/swaps) == 0 ]] || { echo '临时 VM swap 正在使用，停止该测试'; exit 1; }
swapoff -a
SWAP_MB=64
begin_transaction
configure_memory
[[ -f $TX/swap.created && -f /var/lib/vps-init.swap ]]
awk '$1=="/var/lib/vps-init.swap" {found=1} END {exit !found}' /proc/swaps
[[ $(stat -c %a /var/lib/vps-init.swap) == 600 ]]
[[ $(stat -c %s /var/lib/vps-init.swap) == 67108864 ]]
configure_memory
[[ $(grep -c '^/var/lib/vps-init.swap ' /etc/fstab) == 1 ]]
rollback
[[ ! -e /var/lib/vps-init.swap ]]
if grep -q '^/var/lib/vps-init.swap ' /etc/fstab; then exit 1; fi
printf 'PASS: 真实交换文件创建、权限、重复执行与回滚。\n'
