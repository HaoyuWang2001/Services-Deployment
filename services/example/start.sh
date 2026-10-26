#!/usr/bin/env bash
# 服务启动脚本模板
# 说明：
#   1. 运行时工作目录为 service.json 中的 workspace，本目录文件已全部下发到该目录
#   2. 标准输出/错误由管理端重定向到 logs/<启动时间>/<日志文件名>，脚本内无需处理日志
#   3. variables（含启动时覆盖值）以环境变量注入，例如 ${EXAMPLE_VAR}
#   4. 管理端以 setsid 独立进程组启动本脚本，停止时会整组终止（脚本及其所有子进程），
#      但仍【强烈建议】以 exec 形式启动真实服务（如下所示）：PID 精确、语义最干净
#   5. 若脚本内需要服务后台运行（如 server & wait），停止同样有效，但避免再自行 setsid
set -euo pipefail

echo "[$(date '+%F %T')] starting on $(hostname)"
echo "EXAMPLE_VAR=${EXAMPLE_VAR:-unset}"

# TODO: 替换为真实命令，例如：
#   exec /opt/xxx/bin/xxx-server --port "${EXAMPLE_VAR}"
exec tail -f /dev/null
