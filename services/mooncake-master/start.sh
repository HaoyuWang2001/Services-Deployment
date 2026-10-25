#!/usr/bin/env bash
# Mooncake Master 启动脚本模板
# 说明：
#   1. 工作目录即 service.json 中声明的 workspace，本脚本与配置文件已下发到该目录
#   2. 标准输出/标准错误由管理端重定向到 logs/<启动时间>/<master.log>，脚本内无需处理日志
#   3. variables（含启动时覆盖值）以环境变量注入，如 MASTER_PORT
#   4. 请将最后的占位命令替换为真实启动命令，保持 exec 形式以便 PID 管理
set -euo pipefail

echo "[$(date '+%F %T')] starting mooncake-master on $(hostname)"
echo "MASTER_PORT=${MASTER_PORT:-2379}"

# TODO: 替换为真实命令，例如：
#   exec /opt/mooncake/bin/mooncake-master --port "${MASTER_PORT}"
exec tail -f /dev/null
