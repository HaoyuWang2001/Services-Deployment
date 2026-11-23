#!/usr/bin/env bash
#
# k8s-0-mooncake-compile 的 stop 脚本。
#
# 编译通过 docker exec 在容器内运行，宿主机侧的进程组 kill 触达不到容器内进程，
# 因此必须在这里显式、彻底地终止。
#
# 安全约束（严格）：
#   1. 只终止「本服务本实例」启动的编译进程：按注入到进程环境里的 SD_COMPILE_TOKEN 精确匹配；
#      他人启动的编译进程（即使同名 build-mooncake.sh 或改名）没有该 token，绝不杀。
#   2. 必须彻底终止：SIGTERM → 等待 → SIGKILL → 复检；仍有残留则返回非零，
#      不存在「跳过、下次再说」的中间状态。
#   3. 无匹配进程 = 已结束，视为成功（返回 0）。
#
# 容器本身不停止、不删除（长期复用，保留 build 缓存与 Go 依赖）。
#
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTAINER_NAME="${CONTAINER_NAME:-mooncake-compile}"

# token：优先 SD_RUN_ID（sd 注入，按实例粒度）；缺失时回退启动时写入的 token 文件。
SERVICE_ID="$(basename "${SCRIPT_DIR}")"
TOKEN=""
if [[ -n "${SD_RUN_ID:-}" ]]; then
    TOKEN="sdcompile:${SERVICE_ID}:${SD_RUN_ID}"
elif [[ -f "${SCRIPT_DIR}/run/compile.token" ]]; then
    TOKEN="$(head -n1 "${SCRIPT_DIR}/run/compile.token" 2>/dev/null || true)"
fi

if [[ -z "${TOKEN}" ]]; then
    echo "[ERROR] 无法确定本实例的编译进程标识：SD_RUN_ID 未注入且无 ${SCRIPT_DIR}/run/compile.token" >&2
    echo "[ERROR] 为避免误杀他人进程，已放弃终止操作" >&2
    exit 1
fi

echo "[INFO] 本实例编译标识: ${TOKEN}"

if [[ "$(docker inspect -f '{{.State.Running}}' "${CONTAINER_NAME}" 2>/dev/null || echo missing)" != "true" ]]; then
    echo "[INFO] 编译容器未运行: ${CONTAINER_NAME}（无容器内编译进程需要清理）"
    echo "[INFO] stop-compile.sh 完成"
    exit 0
fi

# 在容器内按环境变量精确匹配并终止整棵编译进程树。
# token 以位置参数传入（不放进环境），确保执行本检查的 shell 自身不会被匹配。
docker exec "${CONTAINER_NAME}" sh -c '
TOKEN="$1"

collect() {
    for p in /proc/[0-9]*; do
        pid=${p#/proc/}
        [ "$pid" = "$$" ] && continue
        [ "$pid" = "1" ] && continue
        [ -r "$p/environ" ] || continue
        if tr "\0" "\n" 2>/dev/null < "$p/environ" | grep -Fqx "SD_COMPILE_TOKEN=$TOKEN"; then
            echo "$pid"
        fi
    done
}

pids="$(collect)"
if [ -z "$pids" ]; then
    echo "NONE: 未发现在运行的编译进程（已结束）"
    exit 0
fi

echo "FOUND: $(echo $pids)"
kill -TERM $pids 2>/dev/null || true
i=0
while [ "$i" -lt 5 ]; do
    sleep 1
    pids="$(collect)"
    if [ -z "$pids" ]; then echo "STOPPED: 已终止"; exit 0; fi
    i=$((i+1))
done

echo "FORCE: $(echo $pids)"
kill -KILL $pids 2>/dev/null || true
i=0
while [ "$i" -lt 3 ]; do
    sleep 1
    pids="$(collect)"
    if [ -z "$pids" ]; then echo "STOPPED: 已强制终止"; exit 0; fi
    i=$((i+1))
done

echo "FAILED: 仍有编译进程未退出: $(echo $pids)"
exit 1
' sh "${TOKEN}"

echo "[INFO] stop-compile.sh 完成"
