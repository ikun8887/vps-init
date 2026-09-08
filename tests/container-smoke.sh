#!/bin/sh
# 在一次性、工作区只读挂载的容器中准备发行版工具。
set -eu
[ -f /.dockerenv ] || { echo '仅供一次性容器使用' >&2; exit 1; }
if command -v apt-get >/dev/null; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y bash coreutils util-linux procps iproute2 diffutils
elif command -v dnf >/dev/null; then
    # Alma 官方镜像已有 coreutils-single，不为测试替换它。
    dnf install -y bash util-linux procps-ng iproute diffutils
elif command -v apk >/dev/null; then
    apk add bash coreutils util-linux procps iproute2 diffutils
elif command -v zypper >/dev/null; then
    zypper --non-interactive install bash coreutils util-linux procps iproute2 diffutils
else
    echo '未识别容器包管理器' >&2
    exit 1
fi
bash tests/test-core.sh
bash vps-init.sh check
