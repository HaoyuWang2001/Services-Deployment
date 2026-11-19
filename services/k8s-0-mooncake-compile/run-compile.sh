#!/usr/bin/env bash
#
# k8s-0-mooncake-compile —— 自起编译容器，容器内编译，产物拷出，最后销毁容器
#
# 与 k8s-0-mooncake-build-image 同源：服务运行在编译机（node4-compile）上，
# 通过 docker 驱动编译容器完成工作，自身不直接编译。
#
# 全流程（按顺序）：
#   0. 预检（docker / 镜像存在 / 代理必填 / ARTIFACT_DST 必填 / 编译脚本已部署 / 容器名冲突）
#   1. 启动编译容器（从 COMPILE_IMAGE:COMPILE_IMAGE_TAG 起一个常驻容器）
#   2. 校验容器内仓库存在，并解析打印 分支 / commit（必须在拉取代码之前打印）
#   3. 容器内拉取代码（git config 注入代理；校验分支/commit 存在；fetch/checkout/reset）
#   4. 注入编译脚本（服务目录 <BUILD_SCRIPT> → 容器 SCRIPT_DEST_DIR）
#   5. 【环境变量注入】把 FREQ_VARS 写入容器 build.env（SRC_ROOT/CLEAN_BUILD/VENV，代理变量仅当 PROXY_IP 非空时写入）
#   6. 容器内执行编译脚本（先 source build.env；输出随服务日志可见，即监视）
#   7. 拷贝编译产物：容器 ARTIFACT_SRC（推导=REPO_DIR/outputs/mooncake-<commit>-aarch64-linux）→ host ARTIFACT_DST
#   8. 关闭并删除编译容器
#   9. 汇总
#
# 失败语义：任一步失败 → on_error 尽力清理容器后非零退出（避免容器泄漏）。
#
# 说明：
#   - 编译脚本随服务一起部署到服务目录（与 run-compile.sh 同目录，即 SCRIPT_DIR），
#     不再依赖外部 scp 目录；用 BUILD_SCRIPT 变量选择要注入并执行哪一个。
# 容器内仓库已 clone 好（REPO_DIR 可配），本服务只做 fetch / checkout / reset。
#   - 容器通常以 root 运行而仓库属主可能不是 root，git 会报 "dubious ownership" 并拒绝操作；
#     这里通过 GIT_CONFIG_* 环境变量（等价于 git config --global safe.directory='*'）消除该限制，
#     不改镜像、不落盘任何 git 配置。
#   - 代理（可选）：PROXY_IP 为空表示不使用代理。此时 git 拉取与编译脚本均直连，
#     依赖容器自身网络/代理配置；仅当 PROXY_IP 非空时才注入 git config 与 build.env 代理变量。
#   - ARTIFACT_SRC 不暴露为变量：产物目录在 checkout 之后按实际短 commit 推导。
#
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ===================== 配置项（来自 service.json variables，可被任务覆盖） =====================

COMPILE_IMAGE="${COMPILE_IMAGE:-mooncake-compile-w00921547-base}"
COMPILE_IMAGE_TAG="${COMPILE_IMAGE_TAG:-latest}"
FULL_IMAGE="${COMPILE_IMAGE}:${COMPILE_IMAGE_TAG}"

# 本服务自行拉起/销毁的运行时容器名
CONTAINER_NAME="${CONTAINER_NAME:-mooncake-compile-w00921547}"

REPO_DIR="${REPO_DIR:-/home/haoyu/Mooncake}"
GIT_BRANCH="${GIT_BRANCH:-}"          # 空 → 使用容器内当前分支
COMMIT_ID="${COMMIT_ID:-}"            # 空 → 使用分支最新提交（origin/<branch> tip）

BUILD_SCRIPT="${BUILD_SCRIPT:-build-mooncake.sh}"
# 编译脚本随服务部署到服务目录（SCRIPT_DIR），不再依赖外部 scp 目录
BUILD_SCRIPT_SRC="${SCRIPT_DIR}/${BUILD_SCRIPT}"

SCRIPT_DEST_DIR="${SCRIPT_DEST_DIR:-/workspace}"

# 代理（可选）：PROXY_IP 为空表示不使用代理；PROXY_PORT 默认 3128
PROXY_IP="${PROXY_IP:-}"
PROXY_PORT="${PROXY_PORT:-3128}"
PROXY_URL=""
PULL_PROXY_FLAGS=()

# 产物拷出（host 侧，必填，无默认）
ARTIFACT_DST="${ARTIFACT_DST:-}"      # 必填；STEP 0 校验非空

# 注入编译脚本的环境变量（FREQ_VARS）
CLEAN_BUILD="${CLEAN_BUILD:-true}"
VENV="${VENV:-}"

# 产物源目录——运行时推导（编译完成后取编译脚本实际生成的那个目录），此处仅声明
ARTIFACT_SRC=""
ARTIFACT_DIR_NAME=""
ACTUAL_COMMIT=""

# 容器内 git 统一附加的配置：safe.directory=*（规避 root 与仓库属主不一致时的 dubious ownership）
GIT_SAFE_FLAGS=( -e "GIT_CONFIG_COUNT=1"
                 -e "GIT_CONFIG_KEY_0=safe.directory"
                 -e "GIT_CONFIG_VALUE_0=*" )

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
STEP "预检（docker / 镜像 / 代理可选 / ARTIFACT_DST 必填 / 编译脚本已部署 / 容器名冲突）"

command -v docker >/dev/null 2>&1 || { ERROR "未找到 docker（本服务需在编译机上执行）"; exit 1; }

docker image inspect "${FULL_IMAGE}" >/dev/null 2>&1 \
    || { ERROR "镜像不存在: ${FULL_IMAGE}（请先构建/拉取基础镜像）"; exit 1; }
INFO "镜像就绪: ${FULL_IMAGE}"

# 代理（可选）：PROXY_IP 为空 → 不使用代理（git 直连、编译脚本也直连，依赖容器自身网络配置）
if [[ -n "${PROXY_IP}" ]]; then
    PROXY_URL="http://${PROXY_IP}:${PROXY_PORT}"
    INFO "代理: ${PROXY_URL}"
    PULL_PROXY_FLAGS+=( -e "http_proxy=${PROXY_URL}" -e "https_proxy=${PROXY_URL}" )
    PULL_PROXY_FLAGS+=( -e "HTTP_PROXY=${PROXY_URL}" -e "HTTPS_PROXY=${PROXY_URL}" )
    PULL_PROXY_FLAGS+=( -e "no_proxy=localhost,127.0.0.1" )
else
    INFO "未配置 PROXY_IP：不使用代理（git 拉取与编译均直连，依赖容器自身网络/代理配置）"
fi

# ARTIFACT_DST 必填（空 → 拒绝运行，避免误拷到宿主根目录）
if [[ -z "${ARTIFACT_DST}" ]]; then
    ERROR "ARTIFACT_DST 必填（host 侧产物目录，请手动指定）"
    exit 1
fi

# 编译脚本（随服务部署到 SCRIPT_DIR）必须存在
if [[ ! -f "${BUILD_SCRIPT_SRC}" ]]; then
    ERROR "编译脚本不存在: ${BUILD_SCRIPT_SRC}（确认 deploy.files 已包含该脚本且服务已 reload/deploy）"
    exit 1
fi
INFO "编译脚本(部署): ${BUILD_SCRIPT_SRC}"

# 容器名冲突处理：同名容器存在则先移除（幂等，便于重跑）
if docker inspect -f '{{.State.Running}}' "${CONTAINER_NAME}" >/dev/null 2>&1; then
    WARN "同名容器已存在，先移除: ${CONTAINER_NAME}"
    docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
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
# STEP 2. 校验仓库存在 + 解析并打印分支 / commit（必须在拉取之前）
# ============================================================
STEP "校验容器内仓库并解析 分支 / commit（拉取代码前）"

# 容器内 REPO_DIR 必须是 git 工作区
docker exec "${GIT_SAFE_FLAGS[@]}" "${CONTAINER_NAME}" git -C "${REPO_DIR}" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || { ERROR "容器内未找到 git 仓库: ${REPO_DIR}（基础镜像应已 clone）"; exit 1; }
INFO "容器内仓库就绪: ${REPO_DIR}"

RESOLVED="$(docker exec \
    "${GIT_SAFE_FLAGS[@]}" \
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
# STEP 3. 容器内拉取代码（git config 注入代理；校验分支/commit 存在）
# ============================================================
STEP "容器内拉取代码: ${EFF_BRANCH}${EFF_COMMIT:+ @ ${EFF_COMMIT}}"

docker exec \
    "${GIT_SAFE_FLAGS[@]}" \
    "${PULL_PROXY_FLAGS[@]}" \
    -e "REPO_DIR=${REPO_DIR}" \
    -e "EFF_BRANCH=${EFF_BRANCH}" \
    -e "EFF_COMMIT=${EFF_COMMIT}" \
    -e "PROXY_URL=${PROXY_URL}" \
    "${CONTAINER_NAME}" bash -c '
set -euo pipefail
cd "${REPO_DIR}"

# 拉取前按需注入 git 代理（仅当配置了 PROXY_IP）
if [[ -n "${PROXY_URL}" ]]; then
    git config http.proxy "${PROXY_URL}"
    git config https.proxy "${PROXY_URL}"
fi

git fetch origin --prune --quiet

# 校验分支存在（远端或本地）
if ! git rev-parse --verify --quiet "origin/${EFF_BRANCH}" >/dev/null 2>&1 \
   && ! git rev-parse --verify --quiet "${EFF_BRANCH}" >/dev/null 2>&1; then
    echo "ERROR: 分支不存在: ${EFF_BRANCH}" >&2
    exit 1
fi

# 校验指定 commit 存在（若指定）
if [[ -n "${EFF_COMMIT}" ]]; then
    if ! git cat-file -e "${EFF_COMMIT}^{commit}" 2>/dev/null; then
        echo "ERROR: 指定 COMMIT_ID 不存在: ${EFF_COMMIT}" >&2
        exit 1
    fi
fi

git checkout -q "${EFF_BRANCH}"
if [[ -z "${EFF_COMMIT}" ]]; then
    git reset --hard -q "origin/${EFF_BRANCH}"
else
    git reset --hard -q "${EFF_COMMIT}"
fi
echo ">> 已切到 HEAD: $(git rev-parse HEAD)  ($(git log -1 --format=%s))"
'
INFO "代码拉取完成"

# 产物源目录在编译脚本执行后推导（见 STEP 6 之后），此处不再提前计算。
ACTUAL_COMMIT="$(docker exec "${GIT_SAFE_FLAGS[@]}" "${CONTAINER_NAME}" git -C "${REPO_DIR}" rev-parse --short HEAD)"
INFO "已 checkout 的 commit: ${ACTUAL_COMMIT}（产物目录名由编译脚本自行决定，编译后解析）"

# ============================================================
# STEP 4. 注入编译脚本（docker cp 进容器）
# ============================================================
STEP "注入编译脚本: ${BUILD_SCRIPT_SRC} → ${CONTAINER_NAME}:${SCRIPT_DEST_DIR}/${BUILD_SCRIPT}"

docker exec "${CONTAINER_NAME}" mkdir -p "${SCRIPT_DEST_DIR}"
docker cp "${BUILD_SCRIPT_SRC}" "${CONTAINER_NAME}:${SCRIPT_DEST_DIR}/${BUILD_SCRIPT}"
docker exec "${CONTAINER_NAME}" test -x "${SCRIPT_DEST_DIR}/${BUILD_SCRIPT}" \
    || docker exec "${CONTAINER_NAME}" chmod +x "${SCRIPT_DEST_DIR}/${BUILD_SCRIPT}"
INFO "编译脚本已注入: ${SCRIPT_DEST_DIR}/${BUILD_SCRIPT}"

# ============================================================
# STEP 5. 【环境变量注入】—— 写入 FREQ_VARS 到容器 build.env
# ============================================================
STEP "【环境变量注入】写入 build.env（SRC_ROOT/CLEAN_BUILD/VENV，代理仅当 PROXY_IP 非空）"

prepare_build_env() {
    local env_path="${SCRIPT_DEST_DIR}/build.env"
    docker exec "${CONTAINER_NAME}" mkdir -p "${SCRIPT_DEST_DIR}"
    # 通过 stdin 写入，避免主机 shell 二次展开；变量值在主机侧已确定，单引号保护
    # 仅当配置 PROXY_IP 时注入代理变量；否则让编译脚本使用容器自身代理/直连配置
    {
        echo "# Auto-generated by run-compile.sh — sourced by the build script"
        echo "export SRC_ROOT='${REPO_DIR}'"
        echo "export CLEAN_BUILD='${CLEAN_BUILD}'"
        echo "export VENV='${VENV}'"
        if [[ -n "${PROXY_IP}" ]]; then
            echo "export PROXY_IP='${PROXY_IP}'"
            echo "export PROXY_PORT='${PROXY_PORT}'"
        fi
    } | docker exec -i "${CONTAINER_NAME}" bash -c "cat > '${env_path}'"
    INFO "build.env 已写入容器 ${env_path}（SRC_ROOT/CLEAN_BUILD/VENV${PROXY_IP:+ +PROXY_IP/PROXY_PORT}）"
}
prepare_build_env

# ============================================================
# STEP 6. 容器内执行编译脚本（输出随服务日志可见，即监视）
# ============================================================
STEP "执行编译脚本（日志进入服务日志，可实时监视）"

# 进入容器执行：先 source build.env（含 FREQ_VARS），再运行编译脚本。
docker exec \
    -e "SCRIPT_DEST_DIR=${SCRIPT_DEST_DIR}" \
    -e "BUILD_SCRIPT=${BUILD_SCRIPT}" \
    "${CONTAINER_NAME}" bash -c '
set -euo pipefail
cd "${SCRIPT_DEST_DIR}"
# 注入的环境变量（SRC_ROOT/CLEAN_BUILD/VENV；PROXY_IP/PROXY_PORT 仅当非空时由 build.env 提供）
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
# 解析编译脚本实际生成的产物目录
# ============================================================
# 目录名由编译脚本自己决定（其内部按 git rev-parse --short HEAD 拼
# mooncake-<commit>-<arch>），本服务不猜测，直接读取 ${REPO_DIR}/outputs
# 下本次编译刚刚生成的 mooncake-* 目录。
OUTPUTS_DIR="${REPO_DIR}/outputs"
# 只认本次构建新产出的目录：按修改时间取最新的 mooncake-* 目录
ARTIFACT_SRC="$(docker exec "${CONTAINER_NAME}" bash -c '
set -euo pipefail
d="$(ls -1dt "'"${OUTPUTS_DIR}"'"/mooncake-* 2>/dev/null | head -n1 || true)"
[ -n "${d}" ] && echo "${d}"
' 2>/dev/null || true)"

if [[ -z "${ARTIFACT_SRC}" ]]; then
    ERROR "未在 ${OUTPUTS_DIR} 找到产物目录 mooncake-*（编译脚本可能未产出）"
    exit 1
fi
ARTIFACT_DIR_NAME="$(basename "${ARTIFACT_SRC}")"
INFO "产物目录(编译脚本生成): ${ARTIFACT_SRC}"

# ============================================================
# STEP 7. 拷贝编译产物到容器外指定目录
# ============================================================
STEP "拷贝编译产物: ${CONTAINER_NAME}:${ARTIFACT_SRC} → ${ARTIFACT_DST}/ (host，保留目录层级)"

docker exec "${CONTAINER_NAME}" test -d "${ARTIFACT_SRC}" \
    || { ERROR "容器内产物目录不存在: ${ARTIFACT_SRC}（请确认编译脚本输出位置）"; exit 1; }

# 拷贝「整个 mooncake-<commit>-<arch> 目录」（不是其内容）：
#   docker cp <容器>:<目录> <宿主目录>/  → 落地为 <宿主目录>/mooncake-<commit>-<arch>/{bin,lib,dist,...}
# 注意不能写成 "${ARTIFACT_SRC}/."，那样会把 bin/lib/dist 直接摊平到 ARTIFACT_DST 下、丢掉版本目录层级。
mkdir -p "${ARTIFACT_DST}"
rm -rf "${ARTIFACT_DST}/${ARTIFACT_DIR_NAME}"
docker cp "${CONTAINER_NAME}:${ARTIFACT_SRC}" "${ARTIFACT_DST}/"

HOST_ARTIFACT_DIR="${ARTIFACT_DST}/${ARTIFACT_DIR_NAME}"
[[ -d "${HOST_ARTIFACT_DIR}" ]] \
    || { ERROR "产物目录未按预期落地: ${HOST_ARTIFACT_DIR}"; exit 1; }
INFO "产物已拷出: ${HOST_ARTIFACT_DIR}"
{
    echo "[INFO] 产物清单（前 40 项）:"
    ls -la "${HOST_ARTIFACT_DIR}" 2>/dev/null | head -n 20
    for sub in bin lib dist; do
        [[ -d "${HOST_ARTIFACT_DIR}/${sub}" ]] \
            && echo "  ${sub}: $(ls -A "${HOST_ARTIFACT_DIR}/${sub}" | wc -l) 项"
    done
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
echo "  commit      : ${EFF_COMMIT:-<latest>} (actual ${ACTUAL_COMMIT})"
echo "  build script: ${SCRIPT_DEST_DIR}/${BUILD_SCRIPT}"
echo "  artifacts   : ${HOST_ARTIFACT_DIR:-${ARTIFACT_DST}} (host，含 ${ARTIFACT_DIR_NAME:-mooncake-<commit>-${ARCH}} 目录)"
echo "  container   : ${CONTAINER_NAME} (已删除)"
echo "============================================================"
exit "${RC}"
