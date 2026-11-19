#!/usr/bin/env bash
#
# k8s-0-mooncake-compile 的 stop 脚本。
#
# 本服务复用「用户预先启动的」编译容器，只通过 docker exec 在容器内执行命令，
# 不在宿主机侧留下需要清理的进程或临时容器。因此 stop 无需清理任何容器：
# 容器及其 build 缓存 / Go 依赖必须保留，供下次编译增量复用。
#
# 注意：这里刻意不 docker rm / docker stop 目标容器。
#
set -euo pipefail

CONTAINER_NAME="${CONTAINER_NAME:-mooncake-compile}"

if docker inspect -f '{{.State.Running}}' "${CONTAINER_NAME}" >/dev/null 2>&1; then
    echo "[INFO] 编译容器 ${CONTAINER_NAME} 保留（复用模型，不停止、不删除）"
else
    echo "[INFO] 未发现编译容器 ${CONTAINER_NAME}（无需处理）"
fi
echo "[INFO] stop-compile.sh 完成"
