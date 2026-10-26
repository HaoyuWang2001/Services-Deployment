#!/usr/bin/env bash
# 服务启动脚本模板
# 说明：
#   1. 运行时工作目录为 service.json 中的 workspace，本目录文件已全部下发到该目录
#   2. 标准输出/错误由管理端重定向到 logs/<启动时间>/<日志文件名>，脚本内无需处理日志
#   3. variables（含启动时覆盖值）以环境变量注入，例如 ${EXAMPLE_VAR}
#   4. 请将最后的占位命令替换为真实启动命令，保持 exec 形式以便 PID 管理
set -euo pipefail

echo "[$(date '+%F %T')] starting on $(hostname)"
echo "EXAMPLE_VAR=${EXAMPLE_VAR:-unset}"

# TODO: 替换为真实命令，例如：
#   exec /opt/xxx/bin/xxx-server --port "${EXAMPLE_VAR}"
exec tail -f /dev/null
