#!/usr/bin/env bash
# 在临时 VM 中使用本次构建资产替代下载，真实执行安装、重装、校验失败和卸载。
set -Eeuo pipefail
[[ ${GITHUB_ACTIONS:-} == true && ${RUNNER_ENVIRONMENT:-} == github-hosted && ${VPS_INIT_DISPOSABLE_VM:-} == 1 && $EUID == 0 ]] || exit 1
ROOT=$(cd "$(dirname "$0")/.." && pwd)
FIXTURE=$(mktemp -d)
export FIXTURE
trap 'rm -rf -- "$FIXTURE"' EXIT
python3 "$ROOT/scripts/build-release.py" "$FIXTURE"
# shellcheck disable=SC2329,SC2317
curl() {
    local url='' destination=''
    while (( $# )); do
        case $1 in https://*) url=$1;; -o) shift; destination=$1;; esac
        shift
    done
    cp "$FIXTURE/${url##*/}" "$destination"
}
export -f curl
bash "$ROOT/install.sh" help
cmp "$FIXTURE/vps-init.sh" /usr/local/lib/vps-init/vps-init.sh
vps-init help | grep -F '0.3.0-beta.1'
bash "$ROOT/install.sh" help
cp /usr/local/lib/vps-init/vps-init.sh "$FIXTURE/before"
printf '# corrupted\n' >> "$FIXTURE/vps-init.sh"
if bash "$ROOT/install.sh" help; then exit 1; fi
cmp "$FIXTURE/before" /usr/local/lib/vps-init/vps-init.sh
vps-init uninstall --yes
[[ ! -e /usr/local/bin/vps-init && ! -e /usr/local/lib/vps-init/vps-init.sh ]]
printf 'PASS: 单文件安装、重复安装、损坏下载拒绝、卸载快捷入口。\n'
