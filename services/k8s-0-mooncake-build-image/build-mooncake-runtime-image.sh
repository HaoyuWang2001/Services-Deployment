#!/usr/bin/env bash
#
# Mooncake runtime 镜像构建与导出
#
# 前置（手动）：已在编译容器内完成 Mooncake 编译（产物位于
# ${MOONCAKE_OUTPUTS}/mooncake-${COMMIT_ID}-aarch64-linux）。
#
# 流程（产物不落宿主机磁盘：编译容器 --docker 管道--> runtime 容器）：
#   1. 预检（docker / COMMIT_ID 必填 / 编译容器运行中）
#   2. 在编译容器内校验真实产物目录 mooncake-${COMMIT_ID}-aarch64-linux
#      存在且含 bin/lib/dist（失败即停，不触碰 runtime 容器）
#   3. 以基础镜像新建 runtime 容器，并建好 bin/lib/dist 三个目录
#   4. docker cp 流式管道直传：编译容器产物 --(宿主机仅作内存流中转)-->
#      runtime 容器 /home/Mooncake/outputs，原位置放回
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
#     （产物只在容器内，需要时按 on_error 打印的命令手动 docker cp 取回）
#
# 环境变量（可被实例变量覆盖）：
#   COMPILE_CONTAINER  (mooncake-compile-w00921547)
#   RUNTIME_CONTAINER  (mooncake-runtime-w00921547)
#   BASE_IMAGE         (mooncake-runtime-w00921547-base:latest)
#   IMAGE_NAME         (mooncake-runtime-w00921547)
#   COMMIT_ID          【必填】镜像 TAG 中的 commitId
#   MOONCAKE_OUTPUTS   (/home/Mooncake/outputs)    编译容器内产物根（docker cp 源），
#                                                  也是 runtime 容器内的产物落地位置
#   TAR_OUTPUT_DIR     (/home/w00921547/downloads/mooncake-runtime-images)
#   PROXY_IP           (空 = 不使用代理)             pip 安装时的代理地址（常变，运行期传入）
#   PROXY_PORT         (3128)
#   PIP_NO_PROXY       (192.168.0.0/16,141.0.0.0/8,10.0.0.0/8,172.16.0.0/12,
#                       127.0.0.1,localhost,local,.local)
#
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

COMPILE_CONTAINER="${COMPILE_CONTAINER:-mooncake-compile-w00921547}"
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

on_error() {
    local rc=$?
    ERROR "构建失败（rc=${rc}${CURRENT_STEP:+，步骤：${CURRENT_STEP}}）"
    ERROR "现场已保留：runtime 容器 ${RUNTIME_CONTAINER}（产物仅在容器内，宿主机不留副本）"
    ERROR "排查：docker logs ${RUNTIME_CONTAINER} 2>&1 | tail -100"
    ERROR "     docker inspect ${RUNTIME_CONTAINER}"
    ERROR "取回产物：docker cp ${RUNTIME_CONTAINER}:${MOONCAKE_OUTPUTS}/${REAL_DIR_NAME:-mooncake-<commit>-aarch64-linux} ./"
    exit "$rc"
}
trap on_error ERR

# ============================================================
# STEP 1. 预检
# ============================================================
STEP "预检环境（docker / COMMIT_ID / 编译容器）"

command -v docker >/dev/null 2>&1 || { ERROR "未找到 docker"; exit 1; }

COMMIT_ID="${COMMIT_ID:-}"
[[ -n "${COMMIT_ID}" ]] || {
    ERROR "COMMIT_ID 必须传入（创建实例时在「变量覆盖」中填写）"
    exit 1
}

REAL_DIR_NAME="mooncake-${COMMIT_ID}-aarch64-linux"

[[ "$(docker inspect -f '{{.State.Running}}' "${COMPILE_CONTAINER}" 2>/dev/null || echo missing)" == "true" ]] \
    || { ERROR "编译容器未运行: ${COMPILE_CONTAINER}（请先手动完成编译）"; exit 1; }

INFO "编译容器 : ${COMPILE_CONTAINER}"
INFO "commit id : ${COMMIT_ID}"
INFO "产物源   : ${MOONCAKE_OUTPUTS}/${REAL_DIR_NAME}（编译容器内）"
INFO "产物传输 : 编译容器 → runtime 容器（docker 管道，不落宿主机）"
INFO "基础镜像 : ${BASE_IMAGE}"
INFO "镜像名   : ${IMAGE_NAME}"
INFO "tar 目录 : ${TAR_OUTPUT_DIR}"

# ============================================================
# STEP 2. 在编译容器内校验产物（不触碰 runtime 容器）
# ============================================================
STEP "校验编译容器内产物: ${MOONCAKE_OUTPUTS}/${REAL_DIR_NAME}"

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

# ============================================================
# STEP 4. 容器间直传（流式管道，宿主机不落盘）
# ============================================================
STEP "直传产物: ${COMPILE_CONTAINER} → ${RUNTIME_CONTAINER}（管道，不落宿主机）"

# 前置已确认 runtime 容器刚创建、容器内无历史产物，无需清理旧目录。
# 双端均为容器引用、宿主机侧参数为 "-"：产物只经内存流中转，不写宿主机磁盘。
# pipefail（顶部 set -Eeuo pipefail）保证任一端失败都会立即进入 on_error。
docker cp "${COMPILE_CONTAINER}:${MOONCAKE_OUTPUTS}/${REAL_DIR_NAME}" - \
    | docker cp - "${RUNTIME_CONTAINER}:${MOONCAKE_OUTPUTS}/"

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
STEP "pip3 安装 wheel（运行时注入代理，不固化进镜像）"

PIP_EXEC_ENV=()
if [[ -n "${PROXY_IP}" ]]; then
    PROXY_URL="http://${PROXY_IP}:${PROXY_PORT}"
    INFO "代理: ${PROXY_URL}（no_proxy=${PIP_NO_PROXY}）"
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

STEP "提交镜像 ${IMAGE_REF}"

docker commit "${RUNTIME_CONTAINER}" "${IMAGE_REF}" >/dev/null
docker image inspect "${IMAGE_REF}" >/dev/null
INFO "镜像已提交: ${IMAGE_REF}"

# ============================================================
# STEP 10. 导出并校验 tar
# ============================================================
TAR_PATH="${TAR_OUTPUT_DIR}/${IMAGE_NAME}-${TAG}.tar"

STEP "导出 tar: ${TAR_PATH}"

mkdir -p "${TAR_OUTPUT_DIR}"
docker save -o "${TAR_PATH}" "${IMAGE_REF}"

[[ -s "${TAR_PATH}" ]] || { ERROR "tar 包为空: ${TAR_PATH}"; exit 1; }
tar -tf "${TAR_PATH}" | grep -qx 'manifest.json' \
    || { ERROR "tar 包校验失败（缺少 manifest.json）: ${TAR_PATH}"; exit 1; }

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
echo "  commit : ${COMMIT_ID}"
echo "  image  : ${IMAGE_REF}"
echo "  tar    : ${TAR_ABS} (${TAR_SIZE} bytes)"
echo "  镜像内产物: ${MOONCAKE_OUTPUTS}/${REAL_DIR_NAME}（仅存在于镜像层，宿主机不留副本）"
echo "  分发示例: distribute-image.sh --remote <user>@node4-compile:${TAR_ABS}"
echo "============================================================"
