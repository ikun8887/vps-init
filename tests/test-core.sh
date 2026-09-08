#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
source "$ROOT/vps-init.sh"
WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT
passed=0
ok() { passed=$((passed+1)); printf 'ok %s - %s\n' "$passed" "$1"; }

for p in 1 22 65535 00022; do port_valid "$p" || exit 1; done
for p in 0 65536 -1 '22;id' abc ''; do if port_valid "$p"; then exit 1; fi; done
ok '端口范围与注入拒绝'

for arg in 'tcp:22,443' 'udp:53'; do (validate_allow "$arg"); done
for arg in 'tcp:0' 'udp:65536' 'tcp:22;id' 'icmp:22' 'tcp:22,'; do
    if (validate_allow "$arg") >/dev/null 2>&1; then exit 1; fi
done
ok '防火墙输入校验'

if (parse_options --swap-mb 0) >/dev/null 2>&1; then exit 1; fi
if (parse_options --hostname 'host;id') >/dev/null 2>&1; then exit 1; fi
if (parse_options --timezone '../../etc/passwd') >/dev/null 2>&1; then exit 1; fi
if (parse_options --zram --no-swap) >/dev/null 2>&1; then exit 1; fi
ok '危险和冲突参数拒绝'

TX="$WORK/tx"
mkdir -p "$TX/files" "$TX/after"
: > "$TX/manifest"; : > "$TX/sysctl.before"; : > "$TX/sysfs.before"
target="$WORK/config"
printf 'original\n' > "$target"
write_file "$target" <<< first
write_file "$target" <<< second
[[ $(cat "$TX/files$target") == original ]]
[[ $(wc -l < "$TX/manifest") -eq 1 ]]
[[ $(cat "$target") == second ]]
ok '多次写入保留最初备份且不重复清单'

ln -s "$target" "$WORK/link"
if [[ -L $WORK/link ]]; then
    if (write_file "$WORK/link" <<< unsafe) >/dev/null 2>&1; then exit 1; fi
    [[ $(cat "$target") == second ]]
    ok '拒绝符号链接覆盖'
else
    printf 'SKIP: 当前文件系统未创建真实符号链接，需在 Linux 重测\n'
fi

printf 'manual change\n' > "$target"
INIT=unknown
rollback_access() { :; }
if (rollback) >/dev/null 2>&1; then exit 1; fi
[[ $(cat "$target") == 'manual change' ]]
ok '回滚拒绝覆盖事务后的人工修改'

cp "$TX/after$target" "$target"
new="$WORK/new-config"
write_file "$new" <<< new
rollback
[[ $(cat "$target") == original && ! -e $new ]]
ok '恢复原文件并删除事务新建配置'

if (load_transaction '../../etc') >/dev/null 2>&1; then exit 1; fi
ok '事务路径遍历拒绝'

parse_options --yes --ssh-port 22222 --allow tcp:80,443 --swap-mb 512
[[ $YES == 1 && $SSH_PORT == 22222 && $SWAP_MB == 512 && ${ALLOW[0]} == tcp:80,443 ]]
ok '一键命令参数解析'
printf '%s checks passed\n' "$passed"
