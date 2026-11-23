#!/usr/bin/env bash
#
# Mooncake runtime 镜像构建与导出
#
# 前置（手动）：已在编译容器内完成 Mooncake 编译；产物目录名遵循 build-mooncake.sh
# 的规范：mooncake-<COMMIT_ID>-<容器架构>-linux（架构由容器内 uname -m 得出，
# 如 aarch64 / x86_64）。只需提供产物【根目录】ARTIFACT_DIR 与 COMMIT_ID。
#
# 流程（产物不落宿主机磁盘：编译容器 --docker 管道--> runtime 容器）：
#   1. 预检（docker / COMMIT_ID / ARTIFACT_DIR 必填 / 编译容器运行中）
#   2. 按 mooncake-<COMMIT_ID>-<arch>-linux 拼出产物目录；不存在时用
#      mooncake-<COMMIT_ID>-*-linux 通配兜底（唯一命中采用）；再校验 bin/lib/dist
#   3. 以基础镜像新建 runtime 容器（名称自动追加 -<COMMIT_ID>），并建好 bin/lib/dist
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
#   COMPILE_CONTAINER  (mooncake-compile)
#   ARTIFACT_DIR       【必填】编译容器内产物【根目录】（如 /home/Mooncake/outputs）；
#                              产物目录 = <ARTIFACT_DIR>/mooncake-<COMMIT_ID>-<arch>-linux
#   COMMIT_ID          【必填】产物目录名 + 镜像 TAG 的唯一依据
#   BASE_IMAGE         (mooncake-runtime-w00921547-base:latest)
#   PROXY_IP           (空 = 不使用代理)             pip 安装时的代理地址（常变，运行期传入）
#   PROXY_PORT         (3128)
#   TAR_OUTPUT_DIR     【必填】tar 包导出目录（无默认值，未填则预检报错退出）
#   RUNTIME_CONTAINER  (mooncake-runtime-w00921547；运行时自动追加 -<COMMIT_ID>)
#   IMAGE_NAME         (mooncake-runtime-w00921547；脚本内固定)
#   MOONCAKE_OUTPUTS   (/home/Mooncake/outputs)    runtime 容器内的产物落地根目录
#   PIP_NO_PROXY       (192.168.0.0/16,141.0.0.0/8,10.0.0.0/8,172.16.0.0/12,
#                       127.0.0.1,localhost,local,.local)
#
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

COMPILE_CONTAINER="${COMPILE_CONTAINER:-mooncake-compile}"
ARTIFACT_DIR="${ARTIFACT_DIR:-}"            # 必填；产物根目录
COMMIT_ID="${COMMIT_ID:-}"                  # 必填
BASE_IMAGE="${BASE_IMAGE:-mooncake-runtime-w00921547-base:latest}"
PROXY_IP="${PROXY_IP:-}"
PROXY_PORT="${PROXY_PORT:-3128}"
TAR_OUTPUT_DIR="${TAR_OUTPUT_DIR:-}"        # 必填
RUNTIME_CONTAINER="${RUNTIME_CONTAINER:-mooncake-runtime-w00921547}"
IMAGE_NAME="${IMAGE_NAME:-mooncake-runtime-w00921547}"
MOONCAKE_OUTPUTS="${MOONCAKE_OUTPUTS:-/home/Mooncake/outputs}"
PIP_NO_PROXY="${PIP_NO_PROXY:-192.168.0.0/16,141.0.0.0/8,10.0.0.0/8,172.16.0.0/12,127.0.0.1,localhost,local,.local}"
CHECK_LDD="/home/check-mooncake-ldd.sh"
CHECK_WHEEL="/home/check-mooncake-wheel.sh"

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
    ERROR "取回产物：docker cp ${RUNTIME_CONTAINER}:${MOONCAKE_OUTPUTS}/${ARTIFACT_NAME:-<产物目录名>} ./"
    exit "$rc"
}
trap on_error ERR

# ============================================================
# STEP 1. 预检
# ============================================================
STEP "预检环境（docker / COMMIT_ID / ARTIFACT_DIR / 编译容器）"

command -v docker >/dev/null 2>&1 || { ERROR "未找到 docker"; exit 1; }

[[ -n "${COMMIT_ID}" ]] || {
    ERROR "COMMIT_ID 必须传入（创建实例时在「变量覆盖」中填写）"
    exit 1
}

# TAR_OUTPUT_DIR 必填：无默认值，空 → 直接失败，避免 tar 落到当前工作目录
[[ -n "${TAR_OUTPUT_DIR}" ]] || {
    ERROR "TAR_OUTPUT_DIR 必须传入（tar 包导出目录，创建实例时在「变量覆盖」中填写）"
    exit 1
}

# ARTIFACT_DIR 必填：编译容器内的产物根目录（绝对路径）
[[ -n "${ARTIFACT_DIR}" ]] || {
    ERROR "ARTIFACT_DIR 必须传入（编译容器内产物根目录，如 /home/Mooncake/outputs）"
    exit 1
}
[[ "${ARTIFACT_DIR}" == /* ]] || {
    ERROR "ARTIFACT_DIR 必须是容器内的绝对路径（当前：${ARTIFACT_DIR}）"
    exit 1
}

[[ "$(docker inspect -f '{{.State.Running}}' "${COMPILE_CONTAINER}" 2>/dev/null || echo missing)" == "true" ]] \
    || { ERROR "编译容器未运行: ${COMPILE_CONTAINER}（请先手动完成编译）"; exit 1; }

# runtime 容器名始终追加 -<COMMIT_ID>：同一 commit 重跑幂等、不同 commit 不冲突
RUNTIME_CONTAINER="${RUNTIME_CONTAINER}-${COMMIT_ID}"

# 与 build-mooncake.sh 相同的目录命名规范：mooncake-<COMMIT_ID>-<机器架构>-linux
ARCH="$(docker exec "${COMPILE_CONTAINER}" uname -m)"
[[ -n "${ARCH}" ]] || { ERROR "无法获取编译容器架构（docker exec uname -m 失败）"; exit 1; }

ARTIFACT_NAME="mooncake-${COMMIT_ID}-${ARCH}-linux"
ARTIFACT_SRC_PATH="${ARTIFACT_DIR}/${ARTIFACT_NAME}"
ARTIFACT_DEST_PATH="${MOONCAKE_OUTPUTS}/${ARTIFACT_NAME}"

# 按规范拼出的目录不存在时，用 mooncake-<COMMIT_ID>-*-linux 通配兜底（唯一命中才采用）
if ! docker exec "${COMPILE_CONTAINER}" test -d "${ARTIFACT_SRC_PATH}"; then
    WARN "未找到按规范构造的产物目录: ${ARTIFACT_SRC_PATH}"
    WARN "尝试在 ${ARTIFACT_DIR} 下按 mooncake-${COMMIT_ID}-*-linux 匹配..."
    ENTRIES="$(docker exec "${COMPILE_CONTAINER}" ls -1 "${ARTIFACT_DIR}")" || {
        ERROR "无法列出产物根目录: ${ARTIFACT_DIR}"
        exit 1
    }
    MATCHES=()
    while IFS= read -r entry; do
        [[ -z "${entry}" ]] && continue
        if [[ "${entry}" == "mooncake-${COMMIT_ID}-"*"-linux" ]]; then
            MATCHES+=("${entry}")
        fi
    done <<< "${ENTRIES}"
    case "${#MATCHES[@]}" in
        0)
            ERROR "未找到 commit ${COMMIT_ID} 的产物（${ARTIFACT_DIR}/mooncake-${COMMIT_ID}-*-linux）；请确认编译已完成且 COMMIT_ID 正确"
            exit 1
            ;;
        1)
            ARTIFACT_NAME="${MATCHES[0]}"
            WARN "使用通配命中的产物目录: ${ARTIFACT_NAME}"
            ARTIFACT_SRC_PATH="${ARTIFACT_DIR}/${ARTIFACT_NAME}"
            ARTIFACT_DEST_PATH="${MOONCAKE_OUTPUTS}/${ARTIFACT_NAME}"
            ;;
        *)
            ERROR "commit ${COMMIT_ID} 命中多个产物目录，无法唯一确定：${MATCHES[*]}"
            exit 1
            ;;
    esac
fi

INFO "编译容器 : ${COMPILE_CONTAINER}"
INFO "commit id : ${COMMIT_ID}"
INFO "产物架构 : ${ARCH}"
INFO "产物源   : ${COMPILE_CONTAINER}:${ARTIFACT_SRC_PATH}（编译容器内）"
INFO "产物传输 : 编译容器 → ${RUNTIME_CONTAINER}（docker 管道，不落宿主机）"
INFO "基础镜像 : ${BASE_IMAGE}"
INFO "镜像名   : ${IMAGE_NAME}"
INFO "tar 目录 : ${TAR_OUTPUT_DIR}"

# ============================================================
# STEP 2. 在编译容器内校验产物（不触碰 runtime 容器）
# ============================================================
STEP "校验编译容器内产物: ${ARTIFACT_SRC_PATH}"

docker exec "${COMPILE_CONTAINER}" test -d "${ARTIFACT_SRC_PATH}" \
    || { ERROR "产物目录缺失: ${COMPILE_CONTAINER}:${ARTIFACT_SRC_PATH}"; exit 1; }
[[ -n "$(docker exec "${COMPILE_CONTAINER}" ls -A "${ARTIFACT_SRC_PATH}")" ]] \
    || { ERROR "产物目录为空: ${COMPILE_CONTAINER}:${ARTIFACT_SRC_PATH}"; exit 1; }

for sub in bin lib dist; do
    docker exec "${COMPILE_CONTAINER}" test -d "${ARTIFACT_SRC_PATH}/${sub}" \
        || { ERROR "产物缺少子目录: ${ARTIFACT_SRC_PATH}/${sub}"; exit 1; }
    if [[ -n "$(docker exec "${COMPILE_CONTAINER}" \
            find "${ARTIFACT_SRC_PATH}/${sub}" -mindepth 1 -type d -print -quit)" ]]; then
        WARN "产物子目录 ${sub} 内含嵌套目录，软链重建仅处理单层文件"
    fi
    INFO "产物校验通过: ${sub}（$(docker exec "${COMPILE_CONTAINER}" \
        ls "${ARTIFACT_SRC_PATH}/${sub}" | wc -l) 项）"
done

# ============================================================
# STEP 3. 新建 runtime 容器（直传要求目标容器先存在）
# ============================================================
STEP "新建 runtime 容器 ${RUNTIME_CONTAINER} 并准备 bin/lib/dist 目录"

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
docker cp "${COMPILE_CONTAINER}:${ARTIFACT_SRC_PATH}" - \
    | docker cp - "${RUNTIME_CONTAINER}:${MOONCAKE_OUTPUTS}/"

docker exec "${RUNTIME_CONTAINER}" test -d "${ARTIFACT_DEST_PATH}" \
    || { ERROR "容器内产物缺失: ${ARTIFACT_DEST_PATH}"; exit 1; }
[[ -n "$(docker exec "${RUNTIME_CONTAINER}" ls -A "${ARTIFACT_DEST_PATH}")" ]] \
    || { ERROR "容器内产物目录为空: ${ARTIFACT_DEST_PATH}"; exit 1; }

for sub in bin lib dist; do
    docker exec "${RUNTIME_CONTAINER}" test -d "${ARTIFACT_DEST_PATH}/${sub}" \
        || { ERROR "容器内产物缺少子目录: ${ARTIFACT_DEST_PATH}/${sub}"; exit 1; }
    INFO "已接收: ${sub}（$(docker exec "${RUNTIME_CONTAINER}" \
        ls "${ARTIFACT_DEST_PATH}/${sub}" | wc -l) 项）"
done
INFO "产物已落地: ${ARTIFACT_DEST_PATH}"

# ============================================================
# STEP 5. 容器内重建软链并校验
# ============================================================
STEP "在 runtime 容器内重建 bin/lib/dist 软链（绝对路径）"

# 对照产物内容重建软链（绝对路径，与编译容器产物布局一致）。
# 全部在容器内枚举与创建，不依赖宿主机上的任何副本。
LINK_COUNT="$(docker exec \
    -e "MOONCAKE_OUTPUTS=${MOONCAKE_OUTPUTS}" \
    -e "ARTIFACT_NAME=${ARTIFACT_NAME}" \
    "${RUNTIME_CONTAINER}" bash -c '
set -euo pipefail
src="${MOONCAKE_OUTPUTS}/${ARTIFACT_NAME}"
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
# 基础镜像的检查脚本仍固定旧 wheel 版本；本次产物预期为 0.3.14。
# 只替换已知的旧值，并确认替换成功，避免意外跳过版本校验。
docker exec "${RUNTIME_CONTAINER}" sed -i \
    's/^EXPECTED_VERSION="0\.3\.12\.post1"$/EXPECTED_VERSION="0.3.14"/' \
    "${CHECK_WHEEL}"
docker exec "${RUNTIME_CONTAINER}" grep -qx 'EXPECTED_VERSION="0.3.14"' "${CHECK_WHEEL}" \
    || { ERROR "wheel 校验脚本版本配置不符合预期: ${CHECK_WHEEL}"; exit 1; }
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
echo "  commit     : ${COMMIT_ID}"
echo "  artifact   : ${ARTIFACT_DIR}/${ARTIFACT_NAME}"
echo "  container  : ${RUNTIME_CONTAINER}（已清理）"
echo "  image      : ${IMAGE_REF}"
echo "  tar        : ${TAR_ABS} (${TAR_SIZE} bytes)"
echo "============================================================"
