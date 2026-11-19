#!/usr/bin/env bash
#
# Mooncake runtime 镜像构建与导出
#
# 前置：已获得 Mooncake 编译产物（bin/lib/dist）。产物来源二选一（ARTIFACT_SOURCE）：
#   container（默认，兼容旧流程）：编译产物仍在运行中的编译容器里
#       ${COMPILE_CONTAINER}:${MOONCAKE_OUTPUTS}/mooncake-${COMMIT_ID}-aarch64-linux
#   host：编译产物已在宿主机某目录（如 k8s-0-mooncake-compile 服务拷出的 ARTIFACT_DST）
#       ${ARTIFACT_HOST_DIR}（可直接含 bin/lib/dist，也可含 mooncake-<commit>-aarch64-linux 子目录）
#
# 流程（产物最终落到 runtime 容器 /home/Mooncake/outputs）：
#   1. 预检（docker / COMMIT_ID 必填 / 按来源校验产物）
#   2. 校验产物目录含 bin/lib/dist（失败即停，不触碰 runtime 容器）
#   3. 以基础镜像新建 runtime 容器，并建好 bin/lib/dist 三个目录
#   4-1. container 源：docker cp 流式管道直传（宿主机仅作内存流中转）
#   4-2. host 源：docker cp 宿主机目录 → runtime 容器
#   5. 在 runtime 容器内对照产物内容重建全部软链（绝对路径）并逐链接校验
#   6. pip3 安装 wheel（运行时注入代理，不固化进基础镜像）
#   7-8. /home/check-mooncake-ldd.sh、/home/check-mooncake-wheel.sh 校验
#   9. docker commit → <IMAGE_NAME>:<YYYYmmddHHMM>.<COMMIT_ID>
#  10. docker save 导出 tar 并校验（tar 根含 manifest.json），打印绝对路径
#  11. 清理 runtime 容器并汇总（镜像与 tar 保留）
#
# 失败语义（部署工具集成，run-to-completion 任务）：
#   - 任一步失败 → 非零退出 → 实例显示异常(码)；stop 无脚本，无副作用
#   - 成功：删除 runtime 容器；失败：保留 runtime 容器便于排查
#
# 环境变量（可被实例变量覆盖）：
#   ARTIFACT_SOURCE    (container) 产物来源：container | host
#   COMPILE_CONTAINER  (mooncake-compile-w00921547)  container 源：编译容器名
#   ARTIFACT_HOST_DIR  (/home/haoyu/k8s-ws/k8s-0-mooncake-compile/artifacts)  host 源：宿主机产物目录
#   RUNTIME_CONTAINER  (mooncake-runtime-w00921547)
#   BASE_IMAGE         (mooncake-runtime-w00921547-base:latest)
#   IMAGE_NAME         (mooncake-runtime-w00921547)
#   COMMIT_ID          【必填】镜像 TAG 与产物目录名中的 commitId
#   MOONCAKE_OUTPUTS   (/home/Mooncake/outputs)    容器内产物根（runtime 容器落地位置）
#   TAR_OUTPUT_DIR     (/home/w00921547/downloads/mooncake-runtime-images)
#   PROXY_IP           (空 = 不使用代理)             pip 安装时的代理地址（常变，运行期传入）
#   PROXY_PORT         (3128)
#   PIP_NO_PROXY       (192.168.0.0/16,141.0.0.0/8,10.0.0.0/8,172.16.0.0/12,
#                       127.0.0.1,localhost,local,.local)
#
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ARTIFACT_SOURCE="${ARTIFACT_SOURCE:-container}"
COMPILE_CONTAINER="${COMPILE_CONTAINER:-mooncake-compile-w00921547}"
ARTIFACT_HOST_DIR="${ARTIFACT_HOST_DIR:-/home/haoyu/k8s-ws/k8s-0-mooncake-compile/artifacts}"
RUNTIME_CONTAINER="${RUNTIME_CONTAINER:-mooncake-runtime-w00921547}"
BASE_IMAGE="${BASE_IMAGE:-mooncake-runtime-w00921547-base:latest}"
IMAGE_NAME="${IMAGE_NAME:-mooncake-runtime-w00921547}"
MOONCAKE_OUTPUTS="${MOONCAKE_OUTPUTS:-/home/Mooncake/outputs}"
TAR_OUTPUT_DIR="${TAR_OUTPUT_DIR:-/home/w00921547/downloads/mooncake-runtime-images}"
CHECK_LDD="/home/check-mooncake-ldd.sh"
CHECK_WHEEL="/home/check-mooncake-wheel.sh"

# pip 安装代理（PROXY_IP 常变，运行期传入，不固化进基础镜像）
PROXY_IP="${PROXY_IP:-}"
PROXY_PORT="${PROXY_PORT:-3128}"
PIP_NO_PROXY="${PIP_NO_PROXY:-192.168.0.0/16,141.0.0.0/8,10.0.0.0/8,172.16.0.0/12,127.0.0.1,localhost,local,.local}"

STEP_NO=0
CURRENT_STEP=""
STEP() {
    STEP_NO=$((STEP_NO + 1))
    CURRENT_STEP="$*"
    echo
    echo "===== [$(date '+%F %T')] STEP ${STEP_NO}: $* ====="
}
INFO()  { echo "[INFO  $(date '+%F %T')] $*"; }
WARN()  { echo "[WARN  $(date '+%F %T')] $*" >&2; }
ERROR() { echo "[ERROR $(date '+%F %T')] $*" >&2; }

# 宿主机产物源目录（host 模式解析后赋值）
HOST_SRC_DIR=""

on_error() {
    local rc=$?
    ERROR "构建失败（rc=${rc}${CURRENT_STEP:+，步骤：${CURRENT_STEP}}）"
    ERROR "现场已保留：runtime 容器 ${RUNTIME_CONTAINER}"
    ERROR "排查：docker logs ${RUNTIME_CONTAINER} 2>&1 | tail -100"
    ERROR "     docker inspect ${RUNTIME_CONTAINER}"
    if [[ "${ARTIFACT_SOURCE}" == "host" ]]; then
        ERROR "产物源（宿主机，原样保留）：${HOST_SRC_DIR:-${ARTIFACT_HOST_DIR}}"
    else
        ERROR "取回产物：docker cp ${RUNTIME_CONTAINER}:${MOONCAKE_OUTPUTS}/${REAL_DIR_NAME:-mooncake-<commit>-aarch64-linux} ./"
    fi
    exit "$rc"
}
trap on_error ERR

# ============================================================
# STEP 1. 预检
# ============================================================
STEP "预检环境（docker / COMMIT_ID / 产物来源：${ARTIFACT_SOURCE}）"

command -v docker >/dev/null 2>&1 || { ERROR "未找到 docker"; exit 1; }

COMMIT_ID="${COMMIT_ID:-}"
[[ -n "${COMMIT_ID}" ]] || {
    ERROR "COMMIT_ID 必须传入（创建实例时在「变量覆盖」中填写）"
    exit 1
}

case "${ARTIFACT_SOURCE}" in
    container|host) ;;
    *) ERROR "ARTIFACT_SOURCE 只能是 container 或 host（当前：${ARTIFACT_SOURCE}）"; exit 1 ;;
esac

REAL_DIR_NAME="mooncake-${COMMIT_ID}-aarch64-linux"

if [[ "${ARTIFACT_SOURCE}" == "container" ]]; then
    [[ "$(docker inspect -f '{{.State.Running}}' "${COMPILE_CONTAINER}" 2>/dev/null || echo missing)" == "true" ]] \
        || { ERROR "编译容器未运行: ${COMPILE_CONTAINER}（请先手动完成编译，或改用 ARTIFACT_SOURCE=host）"; exit 1; }
    INFO "产物源   : ${COMPILE_CONTAINER}:${MOONCAKE_OUTPUTS}/${REAL_DIR_NAME}（编译容器内）"
else
    [[ -n "${ARTIFACT_HOST_DIR}" ]] || { ERROR "ARTIFACT_SOURCE=host 时 ARTIFACT_HOST_DIR 必填"; exit 1; }
    # 兼容两种宿主机布局：目录本身含 bin/lib/dist，或其下含 mooncake-<commit>-aarch64-linux 子目录
    if [[ -d "${ARTIFACT_HOST_DIR}/${REAL_DIR_NAME}" ]]; then
        HOST_SRC_DIR="${ARTIFACT_HOST_DIR}/${REAL_DIR_NAME}"
    elif [[ -d "${ARTIFACT_HOST_DIR}/bin" && -d "${ARTIFACT_HOST_DIR}/lib" && -d "${ARTIFACT_HOST_DIR}/dist" ]]; then
        HOST_SRC_DIR="${ARTIFACT_HOST_DIR}"
    else
        ERROR "宿主机产物目录无效: ${ARTIFACT_HOST_DIR}（需直接含 bin/lib/dist，或含 ${REAL_DIR_NAME}/ 子目录）"
        exit 1
    fi
    INFO "产物源   : ${HOST_SRC_DIR}（宿主机）"
fi

INFO "commit id : ${COMMIT_ID}"
INFO "基础镜像 : ${BASE_IMAGE}"
INFO "镜像名   : ${IMAGE_NAME}"
INFO "tar 目录 : ${TAR_OUTPUT_DIR}"

# ============================================================
# STEP 2. 校验产物（按来源，不触碰 runtime 容器）
# ============================================================
STEP "校验产物（来源：${ARTIFACT_SOURCE}）"

if [[ "${ARTIFACT_SOURCE}" == "container" ]]; then
    docker exec "${COMPILE_CONTAINER}" test -d "${MOONCAKE_OUTPUTS}/${REAL_DIR_NAME}" \
        || { ERROR "产物目录缺失: ${COMPILE_CONTAINER}:${MOONCAKE_OUTPUTS}/${REAL_DIR_NAME}"; exit 1; }
    [[ -n "$(docker exec "${COMPILE_CONTAINER}" ls -A "${MOONCAKE_OUTPUTS}/${REAL_DIR_NAME}")" ]] \
        || { ERROR "产物目录为空: ${COMPILE_CONTAINER}:${MOONCAKE_OUTPUTS}/${REAL_DIR_NAME}"; exit 1; }

    for sub in bin lib dist; do
        docker exec "${COMPILE_CONTAINER}" test -d "${MOONCAKE_OUTPUTS}/${REAL_DIR_NAME}/${sub}" \
            || { ERROR "产物缺少子目录: ${MOONCAKE_OUTPUTS}/${REAL_DIR_NAME}/${sub}"; exit 1; }
        if [[ -n "$(docker exec "${COMPILE_CONTAINER}" \
                find "${MOONCAKE_OUTPUTS}/${REAL_DIR_NAME}/${sub}" -mindepth 1 -type d -print -quit)" ]]; then
            WARN "产物子目录 ${sub} 内含嵌套目录，软链重建仅处理单层文件"
        fi
        INFO "产物校验通过: ${sub}（$(docker exec "${COMPILE_CONTAINER}" \
            ls "${MOONCAKE_OUTPUTS}/${REAL_DIR_NAME}/${sub}" | wc -l) 项）"
    done
else
    [[ -d "${HOST_SRC_DIR}" ]] || { ERROR "宿主机产物目录缺失: ${HOST_SRC_DIR}"; exit 1; }
    [[ -n "$(ls -A "${HOST_SRC_DIR}")" ]] || { ERROR "宿主机产物目录为空: ${HOST_SRC_DIR}"; exit 1; }

    for sub in bin lib dist; do
        [[ -d "${HOST_SRC_DIR}/${sub}" ]] \
            || { ERROR "产物缺少子目录: ${HOST_SRC_DIR}/${sub}"; exit 1; }
        if [[ -n "$(find "${HOST_SRC_DIR}/${sub}" -mindepth 1 -type d -print -quit)" ]]; then
            WARN "产物子目录 ${sub} 内含嵌套目录，软链重建仅处理单层文件"
        fi
        INFO "产物校验通过: ${sub}（$(ls "${HOST_SRC_DIR}/${sub}" | wc -l) 项）"
    done
fi

# ============================================================
# STEP 3. 新建 runtime 容器（直传要求目标容器先存在）
# ============================================================
STEP "新建 runtime 容器并准备 bin/lib/dist 目录"

docker rm -f "${RUNTIME_CONTAINER}" >/dev/null 2>&1 || true
docker run -d --name "${RUNTIME_CONTAINER}" --entrypoint /bin/sh \
    "${BASE_IMAGE}" -c 'while true; do sleep 3600; done' >/dev/null

READY=false
for _ in $(seq 1 30); do
    if docker exec "${RUNTIME_CONTAINER}" true >/dev/null 2>&1; then
        READY=true
        break
    fi
    sleep 1
done
[[ "${READY}" == "true" ]] || { ERROR "runtime 容器未能就绪: ${RUNTIME_CONTAINER}"; exit 1; }

docker exec "${RUNTIME_CONTAINER}" mkdir -p "${MOONCAKE_OUTPUTS}/bin" \
    "${MOONCAKE_OUTPUTS}/lib" "${MOONCAKE_OUTPUTS}/dist"
if [[ "${ARTIFACT_SOURCE}" == "host" ]]; then
    docker exec "${RUNTIME_CONTAINER}" mkdir -p "${MOONCAKE_OUTPUTS}/${REAL_DIR_NAME}"
fi

# ============================================================
# STEP 4. 传输产物到 runtime 容器
# ============================================================
if [[ "${ARTIFACT_SOURCE}" == "container" ]]; then
    STEP "直传产物: ${COMPILE_CONTAINER} → ${RUNTIME_CONTAINER}（管道，不落宿主机）"

    # 前置已确认 runtime 容器刚创建、容器内无历史产物，无需清理旧目录。
    # 双端均为容器引用、宿主机侧参数为 "-"：产物只经内存流中转，不写宿主机磁盘。
    # pipefail（顶部 set -Eeuo pipefail）保证任一端失败都会立即进入 on_error。
    docker cp "${COMPILE_CONTAINER}:${MOONCAKE_OUTPUTS}/${REAL_DIR_NAME}" - \
        | docker cp - "${RUNTIME_CONTAINER}:${MOONCAKE_OUTPUTS}/"
else
    STEP "复制产物: ${HOST_SRC_DIR} → ${RUNTIME_CONTAINER}:${MOONCAKE_OUTPUTS}/${REAL_DIR_NAME}"

    docker cp "${HOST_SRC_DIR}/." "${RUNTIME_CONTAINER}:${MOONCAKE_OUTPUTS}/${REAL_DIR_NAME}/"
fi

docker exec "${RUNTIME_CONTAINER}" test -d "${MOONCAKE_OUTPUTS}/${REAL_DIR_NAME}" \
    || { ERROR "容器内产物缺失: ${MOONCAKE_OUTPUTS}/${REAL_DIR_NAME}"; exit 1; }
[[ -n "$(docker exec "${RUNTIME_CONTAINER}" ls -A "${MOONCAKE_OUTPUTS}/${REAL_DIR_NAME}")" ]] \
    || { ERROR "容器内产物目录为空: ${MOONCAKE_OUTPUTS}/${REAL_DIR_NAME}"; exit 1; }

for sub in bin lib dist; do
    docker exec "${RUNTIME_CONTAINER}" test -d "${MOONCAKE_OUTPUTS}/${REAL_DIR_NAME}/${sub}" \
        || { ERROR "容器内产物缺少子目录: ${MOONCAKE_OUTPUTS}/${REAL_DIR_NAME}/${sub}"; exit 1; }
    INFO "已接收: ${sub}（$(docker exec "${RUNTIME_CONTAINER}" \
        ls "${MOONCAKE_OUTPUTS}/${REAL_DIR_NAME}/${sub}" | wc -l) 项）"
done
INFO "产物已按原位置放回: ${MOONCAKE_OUTPUTS}/${REAL_DIR_NAME}"

# ============================================================
# STEP 5. 容器内重建软链并校验
# ============================================================
STEP "在 runtime 容器内重建 bin/lib/dist 软链（绝对路径）"

# 对照产物内容重建软链（绝对路径，与编译容器产物布局一致）。
# 全部在容器内枚举与创建，不依赖宿主机上的任何副本。
LINK_COUNT="$(docker exec \
    -e "MOONCAKE_OUTPUTS=${MOONCAKE_OUTPUTS}" \
    -e "REAL_DIR_NAME=${REAL_DIR_NAME}" \
    "${RUNTIME_CONTAINER}" bash -c '
set -euo pipefail
src="${MOONCAKE_OUTPUTS}/${REAL_DIR_NAME}"
n=0
for sub in bin lib dist; do
    for f in "${src}/${sub}"/*; do
        [ -e "${f}" ] || continue
        ln -sfn "${f}" "${MOONCAKE_OUTPUTS}/${sub}/$(basename "${f}")"
        n=$((n + 1))
    done
done
echo "${n}"
')"
INFO "已重建软链 ${LINK_COUNT} 个（bin/lib/dist 对照产物内容）"

# 逐链接校验容器内可解析（只遍历 bin/lib/dist 下确为软链的项）
docker exec \
    -e "MOONCAKE_OUTPUTS=${MOONCAKE_OUTPUTS}" \
    "${RUNTIME_CONTAINER}" bash -c '
set -euo pipefail
broken=0
for sub in bin lib dist; do
    for f in "${MOONCAKE_OUTPUTS}/${sub}"/*; do
        [ -L "${f}" ] || continue
        if [ ! -e "${f}" ]; then
            echo "软链不可解析: ${f}" >&2
            broken=$((broken + 1))
        fi
    done
done
[ "${broken}" -eq 0 ] || { echo "存在 ${broken} 个不可解析的软链" >&2; exit 1; }
'
INFO "全部软链校验通过（容器内可解析）"

# ============================================================
# STEP 6. 安装 wheel
# ============================================================
STEP "pip3 安装 wheel"

PIP_EXEC_ENV=()
if [[ -n "${PROXY_IP}" ]]; then
    PROXY_URL="http://${PROXY_IP}:${PROXY_PORT}"
    INFO "代理: ${PROXY_URL}"
    PIP_EXEC_ENV=(
        -e "http_proxy=${PROXY_URL}"
        -e "https_proxy=${PROXY_URL}"
        -e "no_proxy=${PIP_NO_PROXY}"
    )
else
    WARN "未提供 PROXY_IP：pip 安装将不使用代理（如需代理请在「变量覆盖」中填写 PROXY_IP）"
fi

if [[ ${#PIP_EXEC_ENV[@]} -gt 0 ]]; then
    docker exec "${PIP_EXEC_ENV[@]}" "${RUNTIME_CONTAINER}" bash -c \
        "pip3 install ${MOONCAKE_OUTPUTS}/dist/mooncake_transfer_engine*.whl"
else
    docker exec "${RUNTIME_CONTAINER}" bash -c \
        "pip3 install ${MOONCAKE_OUTPUTS}/dist/mooncake_transfer_engine*.whl"
fi

# ============================================================
# STEP 7-8. 校验脚本
# ============================================================
STEP "执行 ${CHECK_LDD}"

docker exec "${RUNTIME_CONTAINER}" test -f "${CHECK_LDD}" \
    || { ERROR "校验脚本不存在: ${CHECK_LDD}"; exit 1; }
docker exec "${RUNTIME_CONTAINER}" bash "${CHECK_LDD}"

STEP "执行 ${CHECK_WHEEL}"

docker exec "${RUNTIME_CONTAINER}" test -f "${CHECK_WHEEL}" \
    || { ERROR "校验脚本不存在: ${CHECK_WHEEL}"; exit 1; }
docker exec "${RUNTIME_CONTAINER}" bash "${CHECK_WHEEL}"

# ============================================================
# STEP 9. commit 镜像
# ============================================================
TAG="$(date +%Y%m%d%H%M).${COMMIT_ID}"
IMAGE_REF="${IMAGE_NAME}:${TAG}"

STEP "提交镜像"

docker commit "${RUNTIME_CONTAINER}" "${IMAGE_REF}" >/dev/null
docker image inspect "${IMAGE_REF}" >/dev/null
INFO "镜像已提交: ${IMAGE_REF}"

# ============================================================
# STEP 10. 导出并校验 tar
# ============================================================
TAR_PATH="${TAR_OUTPUT_DIR}/${IMAGE_NAME}-${TAG}.tar"

STEP "导出 tar 包"

mkdir -p "${TAR_OUTPUT_DIR}"
docker save -o "${TAR_PATH}" "${IMAGE_REF}"

[[ -s "${TAR_PATH}" ]] || { ERROR "tar 包为空: ${TAR_PATH}"; exit 1; }
tar -tf "${TAR_PATH}" | grep -qx 'manifest.json' \
    || { ERROR "tar 包校验失败（缺少 manifest.json）: ${TAR_PATH}"; exit 1; }
INFO "tar 包已导出: ${TAR_PATH}"

TAR_ABS="$(readlink -f "${TAR_PATH}")"
TAR_SIZE="$(stat -c %s "${TAR_PATH}")"
INFO "tar 校验通过（含 manifest.json）"

# ============================================================
# 收尾：清理现场并汇总
# ============================================================
STEP "清理并汇总"

docker rm -f "${RUNTIME_CONTAINER}" >/dev/null 2>&1 || true

echo
echo "============================================================"
echo "SUCCESS: Mooncake runtime 镜像构建完成"
echo "  source     : ${ARTIFACT_SOURCE}"
echo "  commit     : ${COMMIT_ID}"
echo "  image      : ${IMAGE_REF}"
echo "  tar        : ${TAR_ABS} (${TAR_SIZE} bytes)"
echo "============================================================"
