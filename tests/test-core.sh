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
rm "$TX/rolled-back"
rollback
[[ $(cat "$target") == original && ! -e $new ]]
ok '文件已恢复但事务未标记完成时可安全重试'

if (load_transaction '../../etc') >/dev/null 2>&1; then exit 1; fi
ok '事务路径遍历拒绝'

parse_options --yes --ssh-port 22222 --allow tcp:80,443 --swap-mb 512
[[ $YES == 1 && $SSH_PORT == 22222 && $SWAP_MB == 512 && ${ALLOW[0]} == tcp:80,443 ]]
ok '一键命令参数解析'

# 使用真实地址格式检查生成逻辑，不启动本机服务。
systemctl() { printf '%s\n' '0.0.0.0:22 (Stream) [::]:22 (Stream)'; }
prepare_socket ssh.socket 22222
grep -Fxq 'ListenStream=0.0.0.0:22' "$TX/socket.transition"
grep -Fxq 'ListenStream=[::]:22' "$TX/socket.transition"
grep -Fxq 'ListenStream=0.0.0.0:22222' "$TX/socket.confirm"
grep -Fxq 'ListenStream=[::]:22222' "$TX/socket.confirm"
if socket_port_only ssh.socket 22222; then exit 1; fi
systemctl() { printf '%s\n' '0.0.0.0:22222 (Stream) [::]:22222 (Stream)'; }
socket_port_only ssh.socket 22222
systemctl() { printf '%s\n' '/run/ssh.socket (Stream)'; }
if prepare_socket ssh.socket 22222; then exit 1; fi
unset -f systemctl
ok 'socket 双栈绑定保留、旧端口残留和 Unix socket 拒绝'

policy="$WORK/sshd-policy"
printf 'PasswordAuthentication yes\n' > "$policy"
assert_simple_auth_policy "$policy"
printf 'Match User legacy\n PasswordAuthentication yes\n' >> "$policy"
if (assert_simple_auth_policy "$policy") >/dev/null 2>&1; then exit 1; fi
printf 'Include %s/child-policy\n' "$WORK" > "$policy"
printf 'mAtCh=Address 192.0.2.0/24\n PermitRootLogin yes\n' > "$WORK/child-policy"
if (assert_simple_auth_policy "$policy") >/dev/null 2>&1; then exit 1; fi
printf 'PasswordAuthentication yes\n' > "$WORK/child-policy"
assert_simple_auth_policy "$policy"
printf '\"Match\" User legacy\n' > "$WORK/child-policy"
if (assert_simple_auth_policy "$policy") >/dev/null 2>&1; then exit 1; fi
printf 'Include %s/sshd-policy\n' "$WORK" > "$WORK/child-policy"
if (assert_simple_auth_policy "$policy") >/dev/null 2>&1; then exit 1; fi
ok '全局加固拒绝 Match、递归 Include 覆盖和循环'

TX="$WORK/summary-tx" TXID=20260909T000000Z-1234 RUN_ACTION=optimize
mkdir "$TX"
# shellcheck disable=SC2329,SC2317 # run_module 按参数间接调用，兼容不同 ShellCheck 版本
test_skipped_module() { skip '没有可写接口'; }
run_module CPU 1 test_skipped_module
run_module Docker 0 test_skipped_module
printf '22222\n' > "$TX/ssh.target"
printf '22\n' > "$TX/ssh.oldports"
touch "$TX/access.pending"
sshd() { printf 'port 22\nport 22222\n'; }
ss() { printf 'LISTEN\n'; }
render_summary 0 > "$WORK/summary"
grep -Fq 'SSH 目标端口：22222（待确认' "$WORK/summary"
grep -Fq 'SSH 原端口：22' "$WORK/summary"
grep -Fq 'SSH 当前配置端口：22,22222' "$WORK/summary"
grep -Fq 'CPU：已处理（有跳过项）' "$WORK/summary"
if grep -Fq 'Docker：' "$WORK/summary"; then exit 1; fi
grep -Fq -- '--preserve-env=SSH_CONNECTION bash' "$WORK/summary"
printf 'vpsadmin\n' > "$TX/identity.user"
render_summary 0 > "$WORK/summary"
grep -Fq -- '--preserve-env=SSH_CONNECTION,SSH_USER_AUTH bash' "$WORK/summary"
rm "$TX/access.pending"
touch "$TX/rolled-back"
render_summary 0 > "$WORK/summary"
grep -Fq '结果：事务已回滚' "$WORK/summary"
if grep -Fq '确认命令' "$WORK/summary"; then exit 1; fi
unset -f sshd ss test_skipped_module
ok '结束摘要显示端口、跳过项、公钥确认及回滚状态'

# 在独立 Bash 中验证包装器不屏蔽失败，且 EXIT 摘要保留原退出码。
if bash -s -- "$ROOT" "$WORK" > "$WORK/failure-output" 2>&1 <<'EOF'
source "$1/vps-init.sh"
TX="$2/failure-tx" TXID=20260909T000000Z-5678 RUN_ACTION=optimize
mkdir "$TX"
trap 'finish_output "$?"' EXIT
failing_module() { false; touch "$TX/incorrectly-continued"; }
run_module 失败模块 1 failing_module
EOF
then exit 1
else [[ $? == 1 ]]; fi
[[ ! -e $WORK/failure-tx/incorrectly-continued ]]
grep -Fq '执行失败（退出码 1）' "$WORK/failure-tx/summary.txt"
grep -Fq '失败模块：失败或中断' "$WORK/failure-tx/summary.txt"
ok '失败模块立即终止并保存失败摘要，退出码保持不变'

RAM_MB=256 NETWORK_PROFILE=balanced
[[ $(network_buffer_target) == 4194304 ]]
NETWORK_PROFILE=conservative
[[ $(network_buffer_target) == 2097152 ]]
NETWORK_PROFILE=throughput BANDWIDTH_MBPS=1000 RTT_MS=100 RAM_MB=4096
[[ $(network_buffer_target) == 25000000 ]]
RAM_MB=256
[[ $(network_buffer_target) == 8388608 ]]
RAM_MB=65536 BANDWIDTH_MBPS=100000 RTT_MS=2000
[[ $(network_buffer_target) == 134217728 ]]
if (parse_options --bandwidth-mbps '100;id') >/dev/null 2>&1; then exit 1; fi
if (parse_options --rtt-ms 2001) >/dev/null 2>&1; then exit 1; fi
if (BANDWIDTH_MBPS=0; parse_options --network-profile throughput) >/dev/null 2>&1; then exit 1; fi
NETWORK_PROFILE=balanced BANDWIDTH_MBPS=0 RTT_MS=0
ok '网络档位、BDP 单位、内存预算、溢出边界及输入拒绝'

DIST=ubuntu VERSION=24.04 INIT=systemd VIRT=kvm UI_COLOR=0
ui_menu_body > "$WORK/menu"
grep -Fq '一键优化' "$WORK/menu"
grep -Fq '公钥管理员向导' "$WORK/menu"
grep -Fq '事务记录及结果' "$WORK/menu"
if grep -q $'\033' "$WORK/menu"; then exit 1; fi
if (ui_menu </dev/null) > "$WORK/menu-error" 2>&1; then exit 1; fi
grep -Fq '菜单需要交互终端' "$WORK/menu-error"
ok '中文菜单纯文本降级及非交互调用拒绝'

mkdir -p "$WORK/order/20260909T000000Z-10" "$WORK/order/20260909T000000Z-2"
touch "$WORK/order/20260909T000000Z-10/manifest" "$WORK/order/20260909T000000Z-2/manifest"
printf '20260909T000000Z-10\n20260909T000000Z-2\n' > "$WORK/order/history"
STATE="$WORK/order"
[[ $(transaction_order | head -n 1) == 20260909T000000Z-2 ]]
ok '卸载按真实执行顺序反向恢复，不用 PID 推测先后'

# 真实临时文件模拟用户遗留的事务，执行已有回滚；只替代外部服务操作。
TXID=20260909T000000Z-3 TX="$STATE/20260909T000000Z-3"
mkdir -p "$TX/files" "$TX/after"
: > "$TX/manifest"; : > "$TX/sysctl.before"; : > "$TX/sysfs.before"
target="$WORK/legacy-config"
printf 'before\n' > "$target"
write_file "$target" <<< incomplete
touch "$TX/access.pending"
INIT=unknown
rollback_access() { rm -f "$TX/access.pending"; }
recover_pending
[[ $(cat "$target") == before && -f $TX/rolled-back && ! -e $TX/access.pending ]]
recover_pending
ok '旧版未完成事务自动恢复且可重复运行'

TX="$WORK/quiet" TXID=20260909T000000Z-4
mkdir "$TX"
# shellcheck disable=SC2329,SC2317
noisy_module() { for ((i=0;i<2000;i++)); do printf 'logrotate debug line %s\n' "$i"; done; }
run_module 日志轮转 1 noisy_module > "$WORK/quiet-console"
[[ $(wc -l < "$WORK/quiet-console") -lt 8 ]]
grep -Fq 'logrotate debug line 1999' "$TX/run.log"
ok '模块输出进入日志并等待写完，终端不会被调试信息刷屏'
printf '%s checks passed\n' "$passed"
