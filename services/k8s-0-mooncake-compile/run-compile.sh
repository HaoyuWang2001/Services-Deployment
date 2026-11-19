#!/usr/bin/env bash
#
# k8s-0-mooncake-compile —— 自起编译容器，容器内编译，产物拷出，最后销毁容器
#
# 与 k8s-0-mooncake-build-image 同源：服务运行在编译机（node4-compile）上，
# 通过 docker 驱动编译容器完成工作，自身不直接编译。
#
# 全流程（按顺序）：
#   0. 预检（docker / 镜像存在 / 编译脚本已就位 / 代理参数）
#   1. 启动编译容器（从 COMPILE_IMAGE:COMPILE_IMAGE_TAG 起一个常驻容器）
#   2. 解析并打印 分支 / commit（必须在拉取代码之前打印）
#   3. 容器内拉取代码（fetch/checkout/reset；本步按需在 exec 注入代理）
#   4. 注入编译脚本（host 上 SCRIPT_HOST_DIR/<BUILD_SCRIPT> → 容器 SCRIPT_DEST_DIR）
#   5. 【环境变量注入】占位桩（见 prepare_build_env，当前不真正注入，后续订正）
#   6. 容器内执行编译脚本（输出随服务日志可见，即监视）
#   7. 拷贝编译产物：容器 ARTIFACT_SRC → host ARTIFACT_DST（docker cp）
#   8. 关闭并删除编译容器
#   9. 汇总
#
# 失败语义：任一步失败 → on_error 尽力清理容器后非零退出（避免容器泄漏）。
#
# 说明：
#   - 编译脚本由用户从本机 scp 到 SCRIPT_HOST_DIR（host 目录），本服务不创建它；
#     支持多个编译脚本，用 BUILD_SCRIPT 环境变量选择要注入并执行哪一个。
#   - 容器内源码仓库已 clone 好（REPO_DIR 可配），本服务只做 fetch / checkout / reset。
#   - 代理仅在「拉取代码」这一步注入（PROXY_IP + PROXY_PORT），不影响编译脚本执行环境；
#     若编译脚本也需要代理，请在其内部自行设置，或后续订正时统一注入。
#
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ===================== 配置项（来自 service.json variables，可被任务覆盖） =====================

COMPILE_IMAGE="${COMPILE_IMAGE:-mooncake-compile-w00921547-base}"
COMPILE_IMAGE_TAG="${COMPILE_IMAGE_TAG:-latest}"
FULL_IMAGE="${COMPILE_IMAGE}:${COMPILE_IMAGE_TAG}"

# 本服务自行拉起/销毁的运行时容器名
CONTAINER_NAME="${CONTAINER_NAME:-mooncake-compile-w00921547}"

REPO_DIR="${REPO_DIR:-/workspace/Mooncake}"
GIT_BRANCH="${GIT_BRANCH:-}"          # 空 → 使用容器内当前分支
COMMIT_ID="${COMMIT_ID:-}"            # 空 → 使用分支最新提交（origin/<branch> tip）

BUILD_SCRIPT="${BUILD_SCRIPT:-build-mooncake.sh}"
SCRIPT_HOST_DIR="${SCRIPT_HOST_DIR:-/home/haoyu/k8s-ws/k8s-0-mooncake-compile/build-scripts}"
SCRIPT_DEST_DIR="${SCRIPT_DEST_DIR:-/workspace}"

# 代理（可选）：同时提供 PROXY_IP 与 PROXY_PORT 时，仅在「拉取代码」exec 注入
PROXY_IP="${PROXY_IP:-}"
PROXY_PORT="${PROXY_PORT:-}"

# 产物拷出（容器外指定目录）
ARTIFACT_SRC="${ARTIFACT_SRC:-${REPO_DIR}/outputs}"   # 容器内产物目录（默认跟随 REPO_DIR）
ARTIFACT_DST="${ARTIFACT_DST:-/home/haoyu/k8s-ws/k8s-0-mooncake-compile/artifacts}"  # host 目录

# ===================== 日志辅助 =====================

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
    ERROR "编译编排失败（rc=${rc}${CURRENT_STEP:+，步骤：${CURRENT_STEP}}）"
    # 尽力清理容器，避免泄漏（失败不致命）
    if docker inspect -f '{{.State.Running}}' "${CONTAINER_NAME}" >/dev/null 2>&1; then
        WARN "异常退出，清理编译容器: ${CONTAINER_NAME}"
        docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
    fi
    exit "$rc"
}
trap on_error ERR

# ============================================================
# STEP 0. 预检
# ============================================================
STEP "预检（docker / 镜像 / 编译脚本 / 代理参数）"

command -v docker >/dev/null 2>&1 || { ERROR "未找到 docker（本服务需在编译机上执行）"; exit 1; }

docker image inspect "${FULL_IMAGE}" >/dev/null 2>&1 \
    || { ERROR "镜像不存在: ${FULL_IMAGE}（请先构建/拉取基础镜像）"; exit 1; }
INFO "镜像就绪: ${FULL_IMAGE}"

# 若已存在同名容器，先移除（幂等，便于重跑）
if docker inspect -f '{{.State.Running}}' "${CONTAINER_NAME}" >/dev/null 2>&1; then
    WARN "同名容器已存在，先移除: ${CONTAINER_NAME}"
    docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
fi

# host 侧脚本目录（用户 scp 目标）确保存在
mkdir -p "${SCRIPT_HOST_DIR}"
BUILD_SCRIPT_HOST="${SCRIPT_HOST_DIR}/${BUILD_SCRIPT}"
[[ -f "${BUILD_SCRIPT_HOST}" ]] \
    || { ERROR "编译脚本不存在: ${BUILD_SCRIPT_HOST}（请先从本机 scp 该脚本到 SCRIPT_HOST_DIR）"; exit 1; }
INFO "编译脚本(host): ${BUILD_SCRIPT_HOST}"

# 代理检测
PULL_PROXY_FLAGS=()
if [[ -n "${PROXY_IP}" && -n "${PROXY_PORT}" ]]; then
    PROXY_URL="http://${PROXY_IP}:${PROXY_PORT}"
    INFO "将为「拉取代码」步骤注入代理: ${PROXY_URL}"
    PULL_PROXY_FLAGS+=( -e "http_proxy=${PROXY_URL}" -e "https_proxy=${PROXY_URL}" )
    PULL_PROXY_FLAGS+=( -e "HTTP_PROXY=${PROXY_URL}" -e "HTTPS_PROXY=${PROXY_URL}" )
    PULL_PROXY_FLAGS+=( -e "no_proxy=localhost,127.0.0.1" )
elif [[ -n "${PROXY_IP}" || -n "${PROXY_PORT}" ]]; then
    ERROR "PROXY_IP 与 PROXY_PORT 需同时提供（当前仅提供一个）"
    exit 1
else
    INFO "未配置代理（拉取代码直连）"
fi

# ============================================================
# STEP 1. 启动编译容器
# ============================================================
STEP "启动编译容器: ${FULL_IMAGE} → ${CONTAINER_NAME}"

docker run -d --name "${CONTAINER_NAME}" \
    --entrypoint /bin/sh \
    "${FULL_IMAGE}" -c 'while true; do sleep 3600; done' >/dev/null

READY=false
for _ in $(seq 1 30); do
    if docker exec "${CONTAINER_NAME}" true >/dev/null 2>&1; then
        READY=true
        break
    fi
    sleep 1
done
[[ "${READY}" == "true" ]] || { ERROR "编译容器未能就绪: ${CONTAINER_NAME}"; exit 1; }
INFO "容器就绪: ${CONTAINER_NAME}"

# ============================================================
# STEP 2. 解析并打印分支 + commit（必须在拉取之前）
# ============================================================
STEP "解析并打印 分支 / commit（拉取代码前）"

RESOLVED="$(docker exec \
    -e "REPO_DIR=${REPO_DIR}" \
    -e "GIT_BRANCH=${GIT_BRANCH}" \
    -e "COMMIT_ID=${COMMIT_ID}" \
    "${CONTAINER_NAME}" bash -c '
set -euo pipefail
cd "${REPO_DIR}"
_branch="${GIT_BRANCH:-}"
if [[ -z "${_branch}" ]]; then
    _branch="$(git rev-parse --abbrev-ref HEAD)"
fi
_commit="${COMMIT_ID:-}"
printf "BRANCH=%s\n" "${_branch}"
printf "COMMIT=%s\n" "${_commit}"
')"
EFF_BRANCH="$(printf '%s\n' "${RESOLVED}" | sed -n 's/^BRANCH=//p')"
EFF_COMMIT="$(printf '%s\n' "${RESOLVED}"  | sed -n 's/^COMMIT=//p')"

echo
echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
echo "!! 拉取代码前确认（务必核对）"
echo "!!   分支 BRANCH  : ${EFF_BRANCH}"
if [[ -z "${EFF_COMMIT}" ]]; then
    echo "!!   提交 COMMIT  : (空) → 使用分支最新提交 origin/${EFF_BRANCH}"
else
    echo "!!   提交 COMMIT  : ${EFF_COMMIT}"
fi
echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
echo

# ============================================================
# STEP 3. 容器内拉取代码（仅在 exec 注入代理）
# ============================================================
STEP "容器内拉取代码: ${EFF_BRANCH}${EFF_COMMIT:+ @ ${EFF_COMMIT}}"

docker exec \
    "${PULL_PROXY_FLAGS[@]}" \
    -e "REPO_DIR=${REPO_DIR}" \
    -e "EFF_BRANCH=${EFF_BRANCH}" \
    -e "EFF_COMMIT=${EFF_COMMIT}" \
    "${CONTAINER_NAME}" bash -c '
set -euo pipefail
cd "${REPO_DIR}"
git fetch origin --prune --quiet
git checkout -q "${EFF_BRANCH}"
if [[ -z "${EFF_COMMIT}" ]]; then
    git reset --hard -q "origin/${EFF_BRANCH}"
else
    git reset --hard -q "${EFF_COMMIT}"
fi
echo ">> 已切到 HEAD: $(git rev-parse HEAD)  ($(git log -1 --format=%s))"
'
INFO "代码拉取完成"

# ============================================================
# STEP 4. 注入编译脚本（docker cp 进容器）
# ============================================================
STEP "注入编译脚本: ${BUILD_SCRIPT_HOST} → ${CONTAINER_NAME}:${SCRIPT_DEST_DIR}/${BUILD_SCRIPT}"

docker exec "${CONTAINER_NAME}" mkdir -p "${SCRIPT_DEST_DIR}"
docker cp "${BUILD_SCRIPT_HOST}" "${CONTAINER_NAME}:${SCRIPT_DEST_DIR}/${BUILD_SCRIPT}"
docker exec "${CONTAINER_NAME}" test -x "${SCRIPT_DEST_DIR}/${BUILD_SCRIPT}" \
    || docker exec "${CONTAINER_NAME}" chmod +x "${SCRIPT_DEST_DIR}/${BUILD_SCRIPT}"
INFO "编译脚本已注入: ${SCRIPT_DEST_DIR}/${BUILD_SCRIPT}"

# ============================================================
# STEP 5. 【环境变量注入】—— 占位区（当前为清晰桩，后续订正）
# ============================================================
# 设计（待订正）：
#   - 不常更改的环境变量：直接写在编译脚本 build-mooncake.sh 内部。
#   - 经常更改的环境变量：由本服务注入进容器，使编译脚本可见。
#   注入方式（草案）：本函数把下面两类变量写出到容器内
#     ${SCRIPT_DEST_DIR}/build.env，执行编译脚本前 source 之（已在 STEP 6 处理）。
#   当前先写成空文件 + 打印 TODO，等变量清单确定后填充 STABLE_* / FREQ_*。
STEP "【环境变量注入】占位（详见脚本内 prepare_build_env，当前不真正注入）"

prepare_build_env() {
    # TODO(订正): 确定变量清单后在此填充。
    # 不常更改（建议留在编译脚本内，这里仅作示例占位）:
    local -a STABLE_VARS=()
    # 经常更改（由服务注入）:
    local -a FREQ_VARS=()

    # 占位：暂未写入任何变量，仅创建空 build.env（执行前会被 source）
    docker exec "${CONTAINER_NAME}" bash -c "mkdir -p ${SCRIPT_DEST_DIR} && : > ${SCRIPT_DEST_DIR}/build.env"
    INFO "build.env 已准备（空，待订正注入变量）"
    INFO "  STABLE_VARS(${#STABLE_VARS[@]}) / FREQ_VARS(${#FREQ_VARS[@]}) —— 待订正填充"
}
prepare_build_env

# ============================================================
# STEP 6. 容器内执行编译脚本（输出随服务日志可见，即监视）
# ============================================================
STEP "执行编译脚本（日志进入服务日志，可实时监视）"

# 进入容器执行：先 source build.env（若有），再运行编译脚本。
docker exec \
    -e "SCRIPT_DEST_DIR=${SCRIPT_DEST_DIR}" \
    -e "BUILD_SCRIPT=${BUILD_SCRIPT}" \
    "${CONTAINER_NAME}" bash -c '
set -euo pipefail
cd "${SCRIPT_DEST_DIR}"
# 注入的环境变量（占位：当前 build.env 为空）
if [[ -f build.env ]]; then
    set -a
    source build.env
    set +a
fi
exec bash "./${BUILD_SCRIPT}"
'
RC=$?
INFO "编译脚本退出码: ${RC}"

# ============================================================
# STEP 7. 拷贝编译产物到容器外指定目录
# ============================================================
STEP "拷贝编译产物: ${CONTAINER_NAME}:${ARTIFACT_SRC}/. → ${ARTIFACT_DST}/ (host)"

docker exec "${CONTAINER_NAME}" test -d "${ARTIFACT_SRC}" \
    || { ERROR "容器内产物目录不存在: ${ARTIFACT_SRC}（请确认编译脚本输出位置，或调整 ARTIFACT_SRC 变量）"; exit 1; }

mkdir -p "${ARTIFACT_DST}"
docker cp "${CONTAINER_NAME}:${ARTIFACT_SRC}/." "${ARTIFACT_DST}/"
INFO "产物已拷出: ${ARTIFACT_DST}"
{
    echo "[INFO] 产物清单（前 40 项）:"
    ls -laR "${ARTIFACT_DST}" 2>/dev/null | head -n 40
} || true

# ============================================================
# STEP 8. 关闭并删除编译容器
# ============================================================
STEP "关闭并删除编译容器: ${CONTAINER_NAME}"

docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
INFO "容器已删除: ${CONTAINER_NAME}"

# ============================================================
# STEP 9. 汇总
# ============================================================
STEP "汇总"
echo
echo "============================================================"
echo "SUCCESS: Mooncake 编译编排完成"
echo "  image       : ${FULL_IMAGE}"
echo "  branch      : ${EFF_BRANCH}"
echo "  commit      : ${EFF_COMMIT:-<latest>}"
echo "  build script: ${SCRIPT_DEST_DIR}/${BUILD_SCRIPT}"
echo "  artifacts   : ${ARTIFACT_DST} (host)"
echo "  container   : ${CONTAINER_NAME} (已删除)"
echo "============================================================"
exit "${RC}"
