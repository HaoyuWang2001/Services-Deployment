#!/usr/bin/env bash
#
# Mooncake runtime 镜像构建与导出
#
# 前置（手动）：在编译容器内拉取并选定 Mooncake 代码（代码就绪后运行本脚本）。
#
# 流程：
#   0. 预检（docker / 编译容器运行中 / 源码目录）
#   1. 向编译容器注入并执行 build-mooncake.sh（输出直落实例日志，可实时观察）
#   2. 从编译容器导出四份产物（bin/ lib/ dist/ mooncake-<commit>-aarch64-linux/）到本地暂存
#   3. 以基础镜像新建 runtime 容器，把产物按原位置放回 /home/Mooncake/outputs
#      （绝对软链原样保留，不重建——两容器内路径一致，链接自然可解析）
#   4. pip3 安装 wheel
#   5. /home/check-mooncake-ldd.sh 校验
#   6. /home/check-mooncake-wheel.sh 校验
#   7. docker commit → <IMAGE_NAME>:<YYYYmmddHHMM>.<commitId>
#   8. docker save 导出 tar 并校验（tar 根含 manifest.json）
#
# 失败语义（部署工具集成，run-to-completion 任务）：
#   - 任一步失败 → 非零退出 → 实例显示异常(码)；stop 无脚本，无副作用
#   - 成功：删除 runtime 容器 + 清理暂存；失败：两者保留便于排查
#
# 环境变量（可被实例变量覆盖）：
#   COMPILE_CONTAINER  (mooncake-compile-w00921547)
#   RUNTIME_CONTAINER  (mooncake-runtime-w00921547)
#   BASE_IMAGE         (mooncake-runtime-w00921547-base:latest)
#   IMAGE_NAME         (mooncake-runtime-w00921547)
#   MOONCAKE_OUTPUTS   (/home/Mooncake/outputs)    编译容器内产物根
#   TAR_OUTPUT_DIR     (/home/w00921547/downloads/mooncake-runtime-images)
#   STAGING_DIR        (<脚本目录>/staging)
#
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

COMPILE_CONTAINER="${COMPILE_CONTAINER:-mooncake-compile-w00921547}"
RUNTIME_CONTAINER="${RUNTIME_CONTAINER:-mooncake-runtime-w00921547}"
BASE_IMAGE="${BASE_IMAGE:-mooncake-runtime-w00921547-base:latest}"
IMAGE_NAME="${IMAGE_NAME:-mooncake-runtime-w00921547}"
MOONCAKE_OUTPUTS="${MOONCAKE_OUTPUTS:-/home/Mooncake/outputs}"
TAR_OUTPUT_DIR="${TAR_OUTPUT_DIR:-/home/w00921547/downloads/mooncake-runtime-images}"
STAGING_DIR="${STAGING_DIR:-${SCRIPT_DIR}/staging}"
BUILD_SCRIPT="${BUILD_SCRIPT:-${SCRIPT_DIR}/build-mooncake.sh}"
CONTAINER_BUILD_SCRIPT="/home/build-mooncake.sh"
CHECK_LDD="/home/check-mooncake-ldd.sh"
CHECK_WHEEL="/home/check-mooncake-wheel.sh"

SRC_DIR="$(dirname "${MOONCAKE_OUTPUTS}")"   # 例：/home/Mooncake

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

on_error() {
    local rc=$?
    ERROR "构建失败（rc=${rc}${CURRENT_STEP:+，步骤：${CURRENT_STEP}}）"
    ERROR "现场已保留：runtime 容器 ${RUNTIME_CONTAINER}、暂存目录 ${STAGING_DIR}"
    ERROR "排查：docker logs ${RUNTIME_CONTAINER} 2>&1 | tail -100"
    ERROR "     docker inspect ${RUNTIME_CONTAINER}"
    exit "$rc"
}
trap on_error ERR

# ============================================================
# STEP 0. 预检
# ============================================================
STEP "预检环境"

command -v docker >/dev/null 2>&1 || { ERROR "未找到 docker"; exit 1; }
[[ -f "${BUILD_SCRIPT}" ]] || { ERROR "构建脚本不存在: ${BUILD_SCRIPT}"; exit 1; }

[[ "$(docker inspect -f '{{.State.Running}}' "${COMPILE_CONTAINER}" 2>/dev/null || echo missing)" == "true" ]] \
    || { ERROR "编译容器未运行: ${COMPILE_CONTAINER}（请先手动启动并确认代码就绪）"; exit 1; }

docker exec "${COMPILE_CONTAINER}" test -d "${SRC_DIR}" \
    || { ERROR "编译容器内源码目录不存在: ${SRC_DIR}"; exit 1; }

INFO "编译容器 : ${COMPILE_CONTAINER}"
INFO "产物根   : ${MOONCAKE_OUTPUTS}"
INFO "基础镜像 : ${BASE_IMAGE}"
INFO "镜像名   : ${IMAGE_NAME}"
INFO "tar 目录 : ${TAR_OUTPUT_DIR}"

# ============================================================
# STEP 1. 注入并执行 build-mooncake.sh
# ============================================================
STEP "注入并执行构建脚本（输出实时落入实例日志）"

docker cp "${BUILD_SCRIPT}" "${COMPILE_CONTAINER}:${CONTAINER_BUILD_SCRIPT}"
docker exec "${COMPILE_CONTAINER}" chmod +x "${CONTAINER_BUILD_SCRIPT}"
docker exec "${COMPILE_CONTAINER}" bash "${CONTAINER_BUILD_SCRIPT}"

COMMIT_ID="$(docker exec "${COMPILE_CONTAINER}" git -C "${SRC_DIR}" rev-parse --short HEAD)"
COMMIT_ID="$(echo "${COMMIT_ID}" | tr -d '[:space:]')"
[[ -n "${COMMIT_ID}" ]] || { ERROR "无法获取 commit id"; exit 1; }
REAL_DIR_NAME="mooncake-${COMMIT_ID}-aarch64-linux"
INFO "commit id : ${COMMIT_ID}"
INFO "产物目录 : ${MOONCAKE_OUTPUTS}/${REAL_DIR_NAME}"

# ============================================================
# STEP 2. 导出产物到暂存目录
# ============================================================
STEP "导出产物到暂存目录: ${STAGING_DIR}"

rm -rf "${STAGING_DIR}"
mkdir -p "${STAGING_DIR}"

for d in bin lib dist "${REAL_DIR_NAME}"; do
    docker cp "${COMPILE_CONTAINER}:${MOONCAKE_OUTPUTS}/${d}" "${STAGING_DIR}/"
    [[ -d "${STAGING_DIR}/${d}" ]] || { ERROR "产物缺失: ${d}"; exit 1; }
    INFO "已暂存: ${d}"
done

[[ -n "$(ls -A "${STAGING_DIR}/${REAL_DIR_NAME}")" ]] \
    || { ERROR "产物目录为空: ${REAL_DIR_NAME}"; exit 1; }

# ============================================================
# STEP 3. 基于基础镜像新建 runtime 容器并放回产物
# ============================================================
STEP "新建 runtime 容器并放置产物（保留绝对软链）"

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

docker exec "${RUNTIME_CONTAINER}" mkdir -p "${MOONCAKE_OUTPUTS}"

for d in bin lib dist "${REAL_DIR_NAME}"; do
    docker cp "${STAGING_DIR}/${d}" "${RUNTIME_CONTAINER}:${MOONCAKE_OUTPUTS}/"
    docker exec "${RUNTIME_CONTAINER}" test -d "${MOONCAKE_OUTPUTS}/${d}" \
        || { ERROR "容器内产物缺失: ${MOONCAKE_OUTPUTS}/${d}"; exit 1; }
    INFO "已放置: ${MOONCAKE_OUTPUTS}/${d}"
done

# ============================================================
# STEP 4. 安装 wheel
# ============================================================
STEP "pip3 安装 wheel"

docker exec "${RUNTIME_CONTAINER}" bash -c \
    "pip3 install ${MOONCAKE_OUTPUTS}/dist/mooncake_transfer_engine*.whl"

# ============================================================
# STEP 5-6. 校验脚本
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
# STEP 7. commit 镜像
# ============================================================
TAG="$(date +%Y%m%d%H%M).${COMMIT_ID}"
IMAGE_REF="${IMAGE_NAME}:${TAG}"

STEP "提交镜像 ${IMAGE_REF}"

docker commit "${RUNTIME_CONTAINER}" "${IMAGE_REF}" >/dev/null
docker image inspect "${IMAGE_REF}" >/dev/null
INFO "镜像已提交: ${IMAGE_REF}"

# ============================================================
# STEP 8. 导出并校验 tar
# ============================================================
TAR_PATH="${TAR_OUTPUT_DIR}/${IMAGE_NAME}-${TAG}.tar"

STEP "导出 tar: ${TAR_PATH}"

mkdir -p "${TAR_OUTPUT_DIR}"
docker save -o "${TAR_PATH}" "${IMAGE_REF}"

[[ -s "${TAR_PATH}" ]] || { ERROR "tar 包为空: ${TAR_PATH}"; exit 1; }
tar -tf "${TAR_PATH}" | grep -qx 'manifest.json' \
    || { ERROR "tar 包校验失败（缺少 manifest.json）: ${TAR_PATH}"; exit 1; }

TAR_SIZE="$(stat -c %s "${TAR_PATH}")"
INFO "tar 校验通过（含 manifest.json）"

# ============================================================
# 收尾：清理现场并汇总
# ============================================================
STEP "清理并汇总"

docker rm -f "${RUNTIME_CONTAINER}" >/dev/null 2>&1 || true
rm -rf "${STAGING_DIR}"

echo
echo "============================================================"
echo "SUCCESS: Mooncake runtime 镜像构建完成"
echo "  commit : ${COMMIT_ID}"
echo "  image  : ${IMAGE_REF}"
echo "  tar    : ${TAR_PATH} (${TAR_SIZE} bytes)"
echo "  分发示例: distribute-image.sh --remote <user>@node4-compile:${TAR_PATH}"
echo "============================================================"
