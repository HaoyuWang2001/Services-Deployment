#!/usr/bin/env bash
# Mooncake Store 启动脚本模板（需在 Master 之后手动启动）
set -euo pipefail

echo "[$(date '+%F %T')] starting mooncake-store on $(hostname)"
echo "MASTER_ADDR=${MASTER_ADDR:-192.168.1.11:2379}"

# TODO: 替换为真实命令，例如：
#   exec /opt/mooncake/bin/mooncake-store --master "${MASTER_ADDR}"
exec tail -f /dev/null
