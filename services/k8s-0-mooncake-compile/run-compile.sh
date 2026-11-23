#!/usr/bin/env bash
#
# k8s-0-mooncake-compile —— 复用已启动的编译容器，容器内编译，产物拷出
#
# 服务运行在编译机（node4-compile）上，通过 docker exec 在**已存在的容器**内完成编译。
# 容器由用户预先 `docker run` 启动，本服务只借用：
#   - 不新建容器（不再从镜像 cold start）
#   - 不删除、不停止容器（编译结束或失败都保留原样）
# 好处：容器内的 build/ 目录、ccache、Go module 缓存得以保留，后续编译是增量而非从 0 开始。
#
# 全流程（按顺序）：
#   1. 预检（docker / 目标容器运行中 / 代理可选 / 编译脚本已部署）
#   2. 校验目标容器存在且运行中（复用，不新起、不删除）
#   3. 校验容器内仓库存在，并解析打印 分支 / commit（必须在拉取代码之前打印）
#   4. 容器内拉取代码（git config 注入代理；校验分支/commit 存在；fetch/checkout/reset）
#   5. 注入编译脚本（服务目录 <BUILD_SCRIPT> → 容器内 CONTAINER_SCRIPT_DIR）
#   6. 【环境变量注入】把 FREQ_VARS 写入容器 build.env（SRC_ROOT/CLEAN_BUILD/VENV，代理变量仅当 PROXY_IP 非空时写入）
#   7. 容器内执行编译脚本（先 source build.env；输出随服务日志可见，即监视）—— 成功即完成
#   8. 容器保留（不删除，供下次复用）
#   9. 汇总
#
# 失败语义：
#   - 编译脚本失败 → 非零退出；容器始终保留，便于排查与复用。
#   - 容器内已有编译进程（他人任务/上次残留）→ 退出码 3（BUILD_SKIPPED），本次不启动。
#   - 停止：stop-compile.sh 按本实例 token 精确终止容器内编译进程树，绝不误杀他人进程。
#
# 说明：
#   - 编译脚本随服务一起部署到服务目录（与 run-compile.sh 同目录，即 SCRIPT_DIR），
#     用 BUILD_SCRIPT 变量选择要注入并执行哪一个。
#   - 容器内仓库已 clone 好（REPO_DIR 可配），本服务只做 fetch / checkout / reset。
#   - 容器通常以 root 运行而仓库属主可能不是 root，git 会报 "dubious ownership" 并拒绝操作；
#     这里通过 GIT_CONFIG_* 环境变量（等价于 git config --global safe.directory='*'）消除该限制，
#     不改镜像、不落盘任何 git 配置。
#   - 代理（可选）：PROXY_IP 为空表示不使用代理。此时 git 拉取与编译脚本均直连，
#     依赖容器自身网络/代理配置；仅当 PROXY_IP 非空时才注入 git config 与 build.env 代理变量。
#
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ===================== 配置项（来自 service.json variables，可被任务覆盖） =====================

# 本服务自行拉起/销毁的运行时容器名
CONTAINER_NAME="${CONTAINER_NAME:-mooncake-compile}"

REPO_DIR="${REPO_DIR:-/workspace/Mooncake}"
GIT_BRANCH="${GIT_BRANCH:-}"          # 空 → 使用容器内当前分支
COMMIT_ID="${COMMIT_ID:-}"            # 空 → 使用分支最新提交（origin/<branch> tip）

BUILD_SCRIPT="${BUILD_SCRIPT:-build-mooncake.sh}"
# 编译脚本随服务部署到服务目录（SCRIPT_DIR），不再依赖外部 scp 目录
BUILD_SCRIPT_SRC="${SCRIPT_DIR}/${BUILD_SCRIPT}"

# 容器内编译脚本存放目录（编译脚本与 build.env 都落在这里；不是宿主机路径）
CONTAINER_SCRIPT_DIR="${CONTAINER_SCRIPT_DIR:-${SCRIPT_DEST_DIR:-/workspace}}"

# 代理（可选）：PROXY_IP 为空表示不使用代理；PROXY_PORT 默认 3128
PROXY_IP="${PROXY_IP:-}"
PROXY_PORT="${PROXY_PORT:-3128}"
PROXY_URL=""
PULL_PROXY_FLAGS=()

# 产物拷出（host 侧，必填，无默认）

# 注入编译脚本的环境变量（FREQ_VARS）
CLEAN_BUILD="${CLEAN_BUILD:-false}"
VENV="${VENV:-}"
# 功能开关：编译脚本按这两个开关控制 TENT 后端与 kvtest 基准（默认开，任务可覆盖为 0）
ENABLE_KVTEST="${ENABLE_KVTEST:-1}"
ENABLE_TENT="${ENABLE_TENT:-1}"

# 本实例编译进程标识（按实例/run_id 生成）：注入到容器内编译进程的环境变量，
# stop 时据此精确识别「本服务本实例启动的」进程；他人进程没有该 token，绝不动。
SERVICE_ID="$(basename "${SCRIPT_DIR}")"
INSTANCE_TOKEN="sdcompile:${SERVICE_ID}:${SD_RUN_ID:-$(date '+%Y%m%d%H%M%S')-$$}"
TOKEN_FILE="${SCRIPT_DIR}/run/compile.token"

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
    if [[ "${rc}" -eq 3 ]]; then
        ERROR "BUILD_SKIPPED (rc=3)：容器内已有编译在运行，本次未启动编译"
    else
        ERROR "编译编排失败（rc=${rc}${CURRENT_STEP:+，步骤：${CURRENT_STEP}}）"
    fi
    # 容器由外部启动、本服务只借用，失败时保留原样（不 stop、不删除），便于排查与复用
    WARN "容器已保留（未删除）: ${CONTAINER_NAME}"
    exit "$rc"
}
trap on_error ERR

# ============================================================
# STEP 0. 预检（运行时打印 STEP 1）
# ============================================================
STEP "预检（docker / 目标容器运行中 / 代理可选 / 编译脚本已部署）"

command -v docker >/dev/null 2>&1 || { ERROR "未找到 docker（本服务需在编译机上执行）"; exit 1; }

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

# 编译脚本（随服务部署到 SCRIPT_DIR）必须存在
if [[ ! -f "${BUILD_SCRIPT_SRC}" ]]; then
    ERROR "编译脚本不存在: ${BUILD_SCRIPT_SRC}（确认 deploy.files 已包含该脚本且服务已 reload/deploy）"
    exit 1
fi
INFO "编译脚本(部署): ${BUILD_SCRIPT_SRC}"

# ============================================================
# STEP 1. 校验目标容器已存在且运行中（运行时打印 STEP 2）
# ============================================================
STEP "校验目标容器: ${CONTAINER_NAME}"

docker inspect -f '{{.State.Running}}' "${CONTAINER_NAME}" >/dev/null 2>&1 \
    || { ERROR "容器不存在: ${CONTAINER_NAME}（本服务复用已启动的容器，请先手动 docker run 启动它）"; exit 1; }

[[ "$(docker inspect -f '{{.State.Running}}' "${CONTAINER_NAME}")" == "true" ]] \
    || { ERROR "容器未运行: ${CONTAINER_NAME}（请先 docker start ${CONTAINER_NAME}）"; exit 1; }

docker exec "${CONTAINER_NAME}" true >/dev/null 2>&1 \
    || { ERROR "容器无法执行命令: ${CONTAINER_NAME}"; exit 1; }
INFO "目标容器就绪（复用已有容器，保留其 build 缓存与 Go 依赖）: ${CONTAINER_NAME}"

# ============================================================
# STEP 2. 校验仓库存在 + 解析并打印分支 / commit（运行时打印 STEP 3）
# ============================================================
STEP "校验容器内仓库并解析 分支 / commit（拉取代码前）"

# 容器内 REPO_DIR 必须是 git 工作区
docker exec "${GIT_SAFE_FLAGS[@]}" "${CONTAINER_NAME}" git -C "${REPO_DIR}" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || { ERROR "容器内未找到 git 仓库: ${REPO_DIR}（容器内 REPO_DIR 应为已 clone 的 git 仓库）"; exit 1; }
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
# STEP 3. 容器内拉取代码（运行时打印 STEP 4）
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
echo ">> 已切到 HEAD: $(git rev-parse HEAD)"
'
INFO "代码拉取完成"

# ---- 切换结果重点确认（与「拉取代码前确认」同款式）----
# 采集切换后的实际 HEAD 信息；任一查询失败仅降级为 "-"，不中断主流程。
POST_BRANCH="$(docker exec "${GIT_SAFE_FLAGS[@]}" "${CONTAINER_NAME}" \
    git -C "${REPO_DIR}" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
ACTUAL_COMMIT="$(docker exec "${GIT_SAFE_FLAGS[@]}" "${CONTAINER_NAME}" \
    git -C "${REPO_DIR}" rev-parse --short HEAD 2>/dev/null || true)"
ACTUAL_COMMIT_SUBJECT="$(docker exec "${GIT_SAFE_FLAGS[@]}" "${CONTAINER_NAME}" \
    git -C "${REPO_DIR}" log -1 --format=%s 2>/dev/null || true)"
[[ -n "${POST_BRANCH}" ]] || POST_BRANCH="-"
[[ -n "${ACTUAL_COMMIT}" ]] || ACTUAL_COMMIT="-"
[[ -n "${ACTUAL_COMMIT_SUBJECT}" ]] || ACTUAL_COMMIT_SUBJECT="-"

# 指定 COMMIT_ID 时 git 处于 detached HEAD，分支名显示为请求的分支并标注 detached
if [[ "${POST_BRANCH}" == "HEAD" ]]; then
    BANNER_BRANCH="${EFF_BRANCH}（detached）"
else
    BANNER_BRANCH="${POST_BRANCH}"
fi

echo
echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
echo "!! 已切换到 HEAD（务必核对，产物正确性以此为准）"
echo "!!   分支 BRANCH  : ${BANNER_BRANCH}"
echo "!!   提交 COMMIT  : ${ACTUAL_COMMIT}"
echo "!!   提交标题     : ${ACTUAL_COMMIT_SUBJECT}"
echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
echo

# ============================================================
# STEP 4. 注入编译脚本（运行时打印 STEP 5）
# ============================================================
STEP "注入编译脚本(容器内): ${BUILD_SCRIPT_SRC} → ${CONTAINER_NAME}:${CONTAINER_SCRIPT_DIR}/${BUILD_SCRIPT}"

docker exec "${CONTAINER_NAME}" mkdir -p "${CONTAINER_SCRIPT_DIR}"
docker cp "${BUILD_SCRIPT_SRC}" "${CONTAINER_NAME}:${CONTAINER_SCRIPT_DIR}/${BUILD_SCRIPT}"
docker exec "${CONTAINER_NAME}" test -x "${CONTAINER_SCRIPT_DIR}/${BUILD_SCRIPT}" \
    || docker exec "${CONTAINER_NAME}" chmod +x "${CONTAINER_SCRIPT_DIR}/${BUILD_SCRIPT}"
INFO "编译脚本已注入(容器内): ${CONTAINER_SCRIPT_DIR}/${BUILD_SCRIPT}"

# ============================================================
# STEP 5. 【环境变量注入】写入 FREQ_VARS 到 build.env（运行时打印 STEP 6）
# ============================================================
STEP "【环境变量注入】写入 build.env(容器内 ${CONTAINER_SCRIPT_DIR}/build.env)"

prepare_build_env() {
    local env_path="${CONTAINER_SCRIPT_DIR}/build.env"
    docker exec "${CONTAINER_NAME}" mkdir -p "${CONTAINER_SCRIPT_DIR}"
    # 通过 stdin 写入，避免主机 shell 二次展开；变量值在主机侧已确定，单引号保护
    # 仅当配置 PROXY_IP 时注入代理变量；否则让编译脚本使用容器自身代理/直连配置
    {
        echo "# Auto-generated by run-compile.sh — sourced by the build script"
        echo "export SRC_ROOT='${REPO_DIR}'"
        echo "export CLEAN_BUILD='${CLEAN_BUILD}'"
        echo "export VENV='${VENV}'"
        echo "export ENABLE_KVTEST='${ENABLE_KVTEST}'"
        echo "export ENABLE_TENT='${ENABLE_TENT}'"
        if [[ -n "${PROXY_IP}" ]]; then
            echo "export PROXY_IP='${PROXY_IP}'"
            echo "export PROXY_PORT='${PROXY_PORT}'"
        fi
    } | docker exec -i "${CONTAINER_NAME}" bash -c "cat > '${env_path}'"
    INFO "build.env 已写入(容器内) ${env_path}（SRC_ROOT/CLEAN_BUILD/VENV/ENABLE_KVTEST/ENABLE_TENT${PROXY_IP:+ +PROXY_IP/PROXY_PORT}）"
}
prepare_build_env

# ============================================================
# STEP 6. 容器内执行编译脚本（运行时打印 STEP 7）
# ============================================================
STEP "执行编译脚本（日志进入服务日志，可实时监视）"

# ---- 互斥检查：容器内是否已有编译进程（他人任务 / 上次未清理的残留）----
# 只检测、不杀；退出码 3 表示「本次未启动编译」，与「编译失败(1)」区分。
if docker exec "${CONTAINER_NAME}" sh -c 'command -v pgrep >/dev/null 2>&1'; then
    RUNNING_PIDS="$(docker exec "${CONTAINER_NAME}" pgrep -f "${BUILD_SCRIPT}" 2>/dev/null || true)"
else
    # 无 pgrep 时回退到 /proc 扫描（排除自身 pid 与 pid 1）
    RUNNING_PIDS="$(docker exec "${CONTAINER_NAME}" sh -c '
name="$1"
for p in /proc/[0-9]*; do
    pid=${p#/proc/}
    [ "$pid" = "$$" ] && continue
    [ "$pid" = "1" ] && continue
    cmd=$(tr "\0" " " 2>/dev/null < "$p/cmdline" || true)
    case "$cmd" in *"$name"*) echo "$pid";; esac
done' sh "${BUILD_SCRIPT}" 2>/dev/null || true)"
fi
if [[ -n "${RUNNING_PIDS//[[:space:]]/}" ]]; then
    ERROR "BUILD_SKIPPED: 容器内已有 ${BUILD_SCRIPT} 进程在运行（本次不启动编译）"
    ERROR "  容器: ${CONTAINER_NAME}"
    ERROR "  占用 pid: $(printf '%s' "${RUNNING_PIDS}" | tr '\n' ' ')"
    ERROR "  常见原因：上一次编译未被清理，或他人正在同一容器内并行编译。"
    ERROR "  本服务不会杀掉非本实例的进程；若确认是本服务上次残留，请对该实例执行「停止」。"
    exit 3
fi
INFO "互斥检查通过：容器内无 ${BUILD_SCRIPT} 进程"

# 记录本实例 token（供 stop 在宿主机侧兜底识别；正常路径由 SD_RUN_ID 精确匹配）
mkdir -p "${SCRIPT_DIR}/run"
printf '%s\n' "${INSTANCE_TOKEN}" > "${TOKEN_FILE}"

# 进入容器执行：先 source build.env（含 FREQ_VARS），再运行编译脚本。
# SD_COMPILE_TOKEN 会进入该进程树的环境，stop 时按 /proc/<pid>/environ 精确匹配。
docker exec \
    -e "CONTAINER_SCRIPT_DIR=${CONTAINER_SCRIPT_DIR}" \
    -e "BUILD_SCRIPT=${BUILD_SCRIPT}" \
    -e "SD_COMPILE_TOKEN=${INSTANCE_TOKEN}" \
    "${CONTAINER_NAME}" bash -c '
set -euo pipefail
cd "${CONTAINER_SCRIPT_DIR}"
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

# 编译成功即完成：不再解析/拷贝产物到宿主机。
# 产物保留在容器内（编译脚本自身的输出目录，如 ${REPO_DIR}/outputs/mooncake-<commit>-<arch>），
# 需要时由下游服务（如 k8s-1-mooncake-build-image 通过 ARTIFACT_DIR）直接从容器取用。

# ============================================================
# STEP 7. 容器保留（不删除，供下次复用）（运行时打印 STEP 8）
# ============================================================
STEP "容器保留: ${CONTAINER_NAME}"

# 容器由外部启动，本服务只借用；不 stop、不删除，
# 以便下次编译复用其中的 build 目录、ccache 与 Go module 缓存。
docker inspect -f '{{.State.Running}}' "${CONTAINER_NAME}" >/dev/null 2>&1 \
    && INFO "容器仍运行（未删除）: ${CONTAINER_NAME}" \
    || WARN "容器当前未运行: ${CONTAINER_NAME}"

# 定位容器内真实产物目录（mooncake-<commit>-<arch>-linux），供汇总打印与下游取用
ARTIFACT_PATH=""
if [[ -n "${ACTUAL_COMMIT}" && "${ACTUAL_COMMIT}" != "-" ]]; then
    ARTIFACT_ARCH="$(docker exec "${CONTAINER_NAME}" uname -m 2>/dev/null || true)"
    CANDIDATE="${REPO_DIR}/outputs/mooncake-${ACTUAL_COMMIT}-${ARTIFACT_ARCH}-linux"
    if docker exec "${CONTAINER_NAME}" test -d "${CANDIDATE}" 2>/dev/null; then
        ARTIFACT_PATH="${CANDIDATE}"
    else
        # 兜底：按 commit 通配（唯一命中才采用）
        ENTRIES="$(docker exec "${CONTAINER_NAME}" ls -1 "${REPO_DIR}/outputs" 2>/dev/null || true)"
        MATCHES=()
        while IFS= read -r entry; do
            [[ -z "${entry}" ]] && continue
            if [[ "${entry}" == "mooncake-${ACTUAL_COMMIT}-"*"-linux" ]]; then
                MATCHES+=("${entry}")
            fi
        done <<< "${ENTRIES}"
        if [[ "${#MATCHES[@]}" -eq 1 ]]; then
            ARTIFACT_PATH="${REPO_DIR}/outputs/${MATCHES[0]}"
        fi
    fi
fi

# ============================================================
# STEP 8. 汇总（运行时打印 STEP 9）
# ============================================================
STEP "汇总"
echo
echo "============================================================"
echo "SUCCESS: Mooncake 编译编排完成"
echo "  container   : ${CONTAINER_NAME} (复用，未删除)"
echo "  branch      : ${EFF_BRANCH}"
echo "  commit      : ${EFF_COMMIT:-<latest>} (actual ${ACTUAL_COMMIT})"
echo "  build script: 容器内 ${CONTAINER_SCRIPT_DIR}/${BUILD_SCRIPT}"
if [[ -n "${ARTIFACT_PATH}" ]]; then
    echo "  artifacts   : 容器内 ${ARTIFACT_PATH}"
else
    echo "  artifacts   : 容器内 ${REPO_DIR}/outputs/（未定位到具体产物目录）"
fi

echo "============================================================"
exit "${RC}"
