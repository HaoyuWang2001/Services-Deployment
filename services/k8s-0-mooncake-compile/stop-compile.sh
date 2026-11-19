#!/usr/bin/env bash
#
# k8s-0-mooncake-compile 的 stop 清理脚本。
# 正常流程 finish 时已自行删除容器；此脚本用于「用户手动 stop / 中断」时
# 兜底清理本服务拉起的编译容器，避免容器泄漏。
#
set -euo pipefail

CONTAINER_NAME="${CONTAINER_NAME:-mooncake-compile-w00921547}"

if docker inspect -f '{{.State.Running}}' "${CONTAINER_NAME}" >/dev/null 2>&1; then
    echo "[INFO] 清理编译容器: ${CONTAINER_NAME}"
    docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
else
    echo "[INFO] 未发现运行中的编译容器: ${CONTAINER_NAME}（无需清理）"
fi
echo "[INFO] stop-compile.sh 完成"
