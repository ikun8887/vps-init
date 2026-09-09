#!/usr/bin/env bash
# VPS Init 官方安装器：只下载固定版本发行资产，不执行其他项目代码。
set -Eeuo pipefail
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH LC_ALL=C
umask 077
VERSION=v0.3.0-beta.1
URL="https://github.com/ikun8887/vps-init/releases/download/$VERSION"
DEST=/usr/local/lib/vps-init
[[ $(uname -s) == Linux && $EUID == 0 ]] || { printf '请在 Linux VPS 上以 root 运行。\n' >&2; exit 1; }
for tool in curl sha256sum flock mktemp; do command -v "$tool" >/dev/null || { printf '缺少依赖：%s，请用系统包管理器安装。\n' "$tool" >&2; exit 1; }; done
[[ ! -L /var/lib/vps-init && ! -L $DEST && ! -L /usr/local/bin/vps-init ]] || { printf '拒绝覆盖符号链接。\n' >&2; exit 1; }
mkdir -p /var/lib/vps-init /usr/local/lib /usr/local/bin
[[ $(stat -c %u /var/lib/vps-init) == 0 ]] || exit 1
chmod 700 /var/lib/vps-init
exec 9>/var/lib/vps-init/lock
flock -n 9 || { printf '另一个 VPS Init 操作正在运行。\n' >&2; exit 1; }
if [[ -e $DEST && ! -f $DEST/.managed ]]; then printf '安装目录不是本工具创建，拒绝覆盖。\n' >&2; exit 1; fi
if [[ -e /usr/local/bin/vps-init ]] && ! grep -Fxq '# VPS-INIT LAUNCHER' /usr/local/bin/vps-init; then printf '已有同名命令，拒绝覆盖。\n' >&2; exit 1; fi
STAGE=$(mktemp -d /usr/local/lib/.vps-init-install.XXXXXX)
trap 'rm -f "$STAGE/vps-init.sh" "$STAGE/SHA256SUMS" "$STAGE/launcher"; rmdir "$STAGE"' EXIT
printf '下载 VPS Init %s…\n' "$VERSION"
curl --proto '=https' --tlsv1.2 -fLsS --connect-timeout 15 --max-time 180 --retry 2 "$URL/vps-init.sh" -o "$STAGE/vps-init.sh"
curl --proto '=https' --tlsv1.2 -fLsS --connect-timeout 15 --max-time 60 --retry 2 "$URL/SHA256SUMS" -o "$STAGE/SHA256SUMS"
expected=$(awk '$2=="vps-init.sh" && length($1)==64 {print $1}' "$STAGE/SHA256SUMS")
[[ $expected =~ ^[a-f0-9]{64}$ ]] || { printf '发行校验文件无效。\n' >&2; exit 1; }
actual=$(sha256sum "$STAGE/vps-init.sh"); actual=${actual%% *}
[[ $actual == "$expected" ]] || { printf '下载内容校验失败，原版本保持不变。\n' >&2; exit 1; }
bash -n "$STAGE/vps-init.sh"
mkdir -p "$DEST"
chmod 755 "$DEST"
chmod 755 "$STAGE/vps-init.sh"
mv -f "$STAGE/vps-init.sh" "$DEST/vps-init.sh"
printf 'VPS-INIT MANAGED INSTALL\n' > "$DEST/.managed"
cat > "$STAGE/launcher" <<'EOF'
#!/usr/bin/env bash
# VPS-INIT LAUNCHER
exec /bin/bash /usr/local/lib/vps-init/vps-init.sh "$@"
EOF
chmod 755 "$STAGE/launcher"
mv -f "$STAGE/launcher" /usr/local/bin/vps-init
printf '安装完成。以后输入 vps-init 即可打开菜单；重复运行本命令可重装工具。\n'
rm -f "$STAGE/SHA256SUMS"
rmdir "$STAGE"
trap - EXIT
exec 9>&-
if [[ $# == 0 ]]; then set -- menu; fi
if [[ $1 == menu && ! -t 0 ]]; then
    [[ -r /dev/tty ]] || { printf '无交互终端，请指定 optimize --yes 或 apply network --yes。\n' >&2; exit 1; }
    exec </dev/tty
fi
exec /bin/bash "$DEST/vps-init.sh" "$@"
