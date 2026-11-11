#!/bin/bash

set -o pipefail

# ================= 配置区域 =================

REMOTE_IMAGE_DIR="${REMOTE_IMAGE_DIR:-/home/w00921547/downloads}"
SSH_USER="${SSH_USER:-root}"

SSH_OPTS=(
    -o BatchMode=yes
    -o ConnectTimeout=10
    -o LogLevel=ERROR
    -o RequestTTY=no
)

SCP_OPTS=(
    -o BatchMode=yes
    -o ConnectTimeout=10
    -o LogLevel=ERROR
)

# pause 镜像逻辑名称与实际 ctr 引用
PAUSE_IMAGE="pause:3.8-aarch64"
PAUSE_IMAGE_REF="pause-aarch64:3.8"
PAUSE_TAR="/root/kubernetes/images/pause-3.8-aarch64.tar"

# memory-pressure 镜像
MEMORY_PRESSURE_TAR="/home/w00921547/downloads/memory-pressure.tar"
MEMORY_PRESSURE_IMAGE="memory-pressure:latest"

# stream_bandwidth 可执行文件
STREAM_BANDWIDTH_FILE="/home/w00921547/downloads/stream_bandwidth"

# ================= 函数定义 =================

# 检查远程镜像是否存在，忽略 Registry 和 Namespace 前缀
check_image() {
    local IP="$1"
    local IMAGE="$2"

    ssh -T "${SSH_OPTS[@]}" "${SSH_USER}@${IP}" \
        "ctr -n k8s.io image ls | awk -v expected='$IMAGE' 'NR > 1 {name=\$1; sub(/^.*\\//,\"\",name); if (name == expected) found=1} END {exit !found}'"
}

# 通用文件分发函数
# 分发文件到所有 Kubernetes 节点
# 参数1：本地文件路径
# 参数2：远程文件名
# 参数3：是否设置可执行权限（true/false）
distribute_file() {

    local LOCAL_FILE="$1"
    local REMOTE_FILENAME="$2"
    local EXECUTABLE="${3:-false}"

    local LOCAL_SIZE
    local REMOTE_SIZE
    local REMOTE_FILE="${REMOTE_IMAGE_DIR}/${REMOTE_FILENAME}"

    if [ ! -f "$LOCAL_FILE" ]; then
        echo "[LOCAL] ERROR: File not found: $LOCAL_FILE"
        return 1
    fi

    LOCAL_SIZE=$(stat -c %s "$LOCAL_FILE") || {
        echo "[LOCAL] ERROR: Failed to get file size: $LOCAL_FILE"
        return 1
    }

    echo
    echo "Distributing: $REMOTE_FILENAME"
    echo "Local size: $LOCAL_SIZE bytes"

    for IP in $NODE_IPS; do

        echo "[$IP] Checking remote file..."

        REMOTE_SIZE=$(ssh -T "${SSH_OPTS[@]}" "${SSH_USER}@${IP}" \
            "if [ -f '$REMOTE_FILE' ]; then stat -c %s '$REMOTE_FILE'; else echo MISSING; fi") || {
            echo "[$IP] ERROR: SSH connection failed"
            return 1
        }

        if [ "$REMOTE_SIZE" = "$LOCAL_SIZE" ]; then
            echo "[$IP] File already exists and size matches, skip SCP"
        else

            if [ "$REMOTE_SIZE" != "MISSING" ]; then
                echo "[$IP] File size mismatch, removing old file..."

                ssh -T "${SSH_OPTS[@]}" "${SSH_USER}@${IP}" \
                    "rm -f '$REMOTE_FILE'" || {
                    echo "[$IP] ERROR: Failed to remove old file"
                    return 1
                }
            else
                echo "[$IP] File not found, preparing SCP..."
            fi

            ssh -T "${SSH_OPTS[@]}" "${SSH_USER}@${IP}" \
                "mkdir -p '$REMOTE_IMAGE_DIR'" || {
                echo "[$IP] ERROR: Failed to create remote directory"
                return 1
            }

            echo "[$IP] Copying file..."

            scp "${SCP_OPTS[@]}" "$LOCAL_FILE" \
                "${SSH_USER}@${IP}:${REMOTE_FILE}" || {
                echo "[$IP] ERROR: SCP failed"
                return 1
            }

            REMOTE_SIZE=$(ssh -T "${SSH_OPTS[@]}" "${SSH_USER}@${IP}" \
                "stat -c %s '$REMOTE_FILE'") || {
                echo "[$IP] ERROR: Failed to verify copied file"
                return 1
            }

            if [ "$REMOTE_SIZE" != "$LOCAL_SIZE" ]; then
                echo "[$IP] ERROR: File size verification failed"
                echo "[$IP] Local: $LOCAL_SIZE"
                echo "[$IP] Remote: $REMOTE_SIZE"
                return 1
            fi

            echo "[$IP] File copied and verified"
        fi

        # 可执行文件设置权限
        if [ "$EXECUTABLE" = "true" ]; then
            ssh -T "${SSH_OPTS[@]}" "${SSH_USER}@${IP}" \
                "chmod +x '$REMOTE_FILE'" || {
                echo "[$IP] ERROR: Failed to set executable permission"
                return 1
            }
        fi

        echo "[$IP] SUCCESS: $REMOTE_FILENAME is ready"

    done

    return 0
}

# ================= 参数检查 =================

# 参数检查及镜像来源处理
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

FULL_MODE=false
IMAGE_TAR=""

if [ $# -eq 0 ]; then

    echo "Mode: Auxiliary files and pause image only"

elif [ $# -eq 1 ] && [ -f "$1" ] && [[ "$1" == *.tar ]]; then

    # ------------------------------------------------------------
    # 本地镜像模式
    # ------------------------------------------------------------

    echo "Mode: Full image distribution (local)"

    FULL_MODE=true
    IMAGE_TAR="$(readlink -f "$1")"

elif [ $# -eq 2 ] && [ "$1" = "--remote" ]; then

    # ------------------------------------------------------------
    # 远程镜像模式
    # ------------------------------------------------------------

    echo "Mode: Full image distribution (remote)"

    FULL_MODE=true

    REMOTE_IMAGE_SOURCE="$2"

    if [[ "$REMOTE_IMAGE_SOURCE" != *:* ]]; then
        echo "ERROR: Invalid remote image source"
        echo "Expected: user@host:/absolute/path/image.tar"
        exit 1
    fi

    REMOTE_IMAGE_BASENAME="${REMOTE_IMAGE_SOURCE##*/}"

    if [[ -z "$REMOTE_IMAGE_BASENAME" || "$REMOTE_IMAGE_BASENAME" != *.tar ]]; then
        echo "ERROR: Remote image must have a valid .tar filename"
        exit 1
    fi

    IMAGE_TAR="${SCRIPT_DIR}/${REMOTE_IMAGE_BASENAME}"

    echo "[LOCAL] Downloading remote image:"
    echo "  Source:      ${REMOTE_IMAGE_SOURCE}"
    echo "  Destination: ${IMAGE_TAR}"

    # 先下载到临时文件，成功后再替换正式文件
    TMP_IMAGE="$(mktemp "${SCRIPT_DIR}/.image-download.XXXXXX")"

    if ! scp -p -- "$REMOTE_IMAGE_SOURCE" "$TMP_IMAGE"; then
        echo "ERROR: Failed to download remote image"
        rm -f "$TMP_IMAGE"
        exit 1
    fi

    if [ ! -s "$TMP_IMAGE" ]; then
        echo "ERROR: Downloaded image is empty"
        rm -f "$TMP_IMAGE"
        exit 1
    fi

    if ! mv -f "$TMP_IMAGE" "$IMAGE_TAR"; then
        echo "ERROR: Failed to move downloaded image"
        rm -f "$TMP_IMAGE"
        exit 1
    fi

    echo "[LOCAL] Remote image downloaded successfully"

else

    echo "ERROR: Invalid arguments"
    echo
    echo "Usage:"
    echo "  $0"
    echo "  $0 <local-image.tar>"
    echo "  $0 --remote user@host:/path/image.tar"
    exit 1

fi

# 统一解析镜像名称和 Tag
if [ "$FULL_MODE" = true ]; then

    IMAGE_FILE="$(basename "$IMAGE_TAR")"
    IMAGE_BASE="${IMAGE_FILE%.tar}"

    if [[ "$IMAGE_BASE" != *-* ]]; then
        echo "ERROR: Invalid image filename: $IMAGE_FILE"
        exit 1
    fi

    IMAGE_NAME="${IMAGE_BASE%-*}"
    IMAGE_TAG="${IMAGE_BASE##*-}"
    IMAGE="${IMAGE_NAME}:${IMAGE_TAG}"
    IMAGE_LATEST="${IMAGE_NAME}:latest"

    echo
    echo "[LOCAL] Image configuration:"
    echo "  Tar:   ${IMAGE_TAR}"
    echo "  Name:  ${IMAGE_NAME}"
    echo "  Tag:   ${IMAGE_TAG}"
    echo "  Image: ${IMAGE}"

fi

# ================= 获取 Kubernetes 节点 =================

echo
echo "========================================"
echo "Discover Kubernetes nodes"
echo "========================================"

NODE_IPS=$(kubectl get nodes -o wide --no-headers |
    awk '$6 != "<none>" && $6 != "" {print $6}') || {
    echo "ERROR: Failed to get Kubernetes nodes"
    exit 1
}

if [ -z "$NODE_IPS" ]; then
    echo "ERROR: No valid Kubernetes node IPs"
    exit 1
fi

echo "[LOCAL] Discovered nodes:"

for IP in $NODE_IPS; do
    echo "  - $IP"
done

NODE_COUNT=$(echo "$NODE_IPS" | wc -w)

echo "[LOCAL] Total nodes: $NODE_COUNT"

# ================= 阶段一：检查并准备 tar 包 =================

if [ "$FULL_MODE" = true ]; then
echo
echo "========================================"
echo "Stage 1: Check and prepare image tar"
echo "========================================"

echo "[LOCAL] Checking image tar size: $IMAGE_TAR"

LOCAL_SIZE=$(stat -c %s "$IMAGE_TAR") || {
    echo "[LOCAL] ERROR: Failed to get file size"
    exit 1
}

if [ -z "$LOCAL_SIZE" ]; then
    echo "[LOCAL] ERROR: File size is empty"
    exit 1
fi

echo "[LOCAL] Image: $IMAGE"
echo "[LOCAL] Tar size: $LOCAL_SIZE bytes"

REMOTE_FILE="${REMOTE_IMAGE_DIR}/${IMAGE_FILE}"

# 串行检查并 SCP
for IP in $NODE_IPS; do

    echo "[$IP] Checking remote image tar..."

    REMOTE_SIZE=$(ssh -T "${SSH_OPTS[@]}" "${SSH_USER}@${IP}" \
        "if [ -f '$REMOTE_FILE' ]; then stat -c %s '$REMOTE_FILE'; else echo MISSING; fi") || {
        echo "[$IP] ERROR: SSH connection failed"
        exit 1
    }

    if [ "$REMOTE_SIZE" = "$LOCAL_SIZE" ]; then
        echo "[$IP] Tar already exists and file size matches, skip SCP"
        continue
    fi

    if [ "$REMOTE_SIZE" != "MISSING" ]; then
        echo "[$IP] File size mismatch, removing old tar..."

        ssh -T "${SSH_OPTS[@]}" "${SSH_USER}@${IP}" \
            "rm -f '$REMOTE_FILE'" || {
            echo "[$IP] ERROR: Failed to remove old tar"
            exit 1
        }
    else
        echo "[$IP] Tar not found, preparing SCP..."
    fi

    ssh -T "${SSH_OPTS[@]}" "${SSH_USER}@${IP}" \
        "mkdir -p '$REMOTE_IMAGE_DIR'" || {
        echo "[$IP] ERROR: Failed to create remote directory"
        exit 1
    }

    echo "[$IP] Copying tar..."

    scp "${SCP_OPTS[@]}" "$IMAGE_TAR" \
        "${SSH_USER}@${IP}:${REMOTE_FILE}" || {
        echo "[$IP] ERROR: SCP failed"
        exit 1
    }

    # SCP 后再次校验文件字节数
    REMOTE_SIZE=$(ssh -T "${SSH_OPTS[@]}" "${SSH_USER}@${IP}" \
        "stat -c %s '$REMOTE_FILE'") || {
        echo "[$IP] ERROR: Failed to verify copied tar"
        exit 1
    }

    if [ "$REMOTE_SIZE" != "$LOCAL_SIZE" ]; then
        echo "[$IP] ERROR: File size verification failed after SCP"
        echo "[$IP] Local size: $LOCAL_SIZE bytes"
        echo "[$IP] Remote size: $REMOTE_SIZE bytes"
        exit 1
    fi

    echo "[$IP] SCP completed, file size verified"

done

echo "[LOCAL] All image tar files are ready"
fi

# ================= 阶段 1.5：分发辅助文件 =================

echo
echo "========================================"
echo "Stage 1.5: Distribute auxiliary files"
echo "========================================"

# 分发 memory-pressure.tar
distribute_file \
    "$MEMORY_PRESSURE_TAR" \
    "memory-pressure.tar" \
    false || exit 1

# 分发 stream_bandwidth
distribute_file \
    "$STREAM_BANDWIDTH_FILE" \
    "stream_bandwidth" \
    true || exit 1

echo
echo "[LOCAL] All auxiliary files are ready"

# ================= 阶段二：导入指定镜像 =================

if [ "$FULL_MODE" = true ]; then
echo
echo "========================================"
echo "Stage 2: Import target image"
echo "Image: $IMAGE"
echo "========================================"

LOG_DIR=$(mktemp -d) || {
    echo "ERROR: Failed to create temporary log directory"
    exit 1
}

PIDS=()
PID_IPS=()

for IP in $NODE_IPS; do

    (
        echo "[$IP] Checking whether image already exists..."

        if check_image "$IP" "$IMAGE"; then
            echo "[$IP] Image already exists, skip import"
        else
            echo "[$IP] Image not found, starting import..."

            ssh -T "${SSH_OPTS[@]}" "${SSH_USER}@${IP}" \
                "ctr -n k8s.io image import '${REMOTE_FILE}'" || {
                echo "[$IP] ERROR: Image import failed"
                exit 1
            }

            echo "[$IP] Checking imported image..."

            check_image "$IP" "$IMAGE" || {
                echo "[$IP] ERROR: Image verification failed: $IMAGE"
                exit 1
            }

            echo "[$IP] Image imported and verified"
        fi

        # ------------------------------------------------------------
        # 为主镜像增加 latest 标签
        # ------------------------------------------------------------

        echo "[$IP] Tagging image: $IMAGE -> $IMAGE_LATEST"

        # containerd 中实际登记的完整镜像名称
        IMAGE_FULL="docker.io/library/${IMAGE}"
        IMAGE_LATEST_FULL="docker.io/library/${IMAGE_LATEST}"

        ssh -T "${SSH_OPTS[@]}" "${SSH_USER}@${IP}" \
            "ctr -n k8s.io image tag --force '${IMAGE_FULL}' '${IMAGE_LATEST_FULL}'" || {
            echo "[$IP] ERROR: Failed to tag image as latest"
            exit 1
        }

        # 验证 latest 标签
        check_image "$IP" "$IMAGE_LATEST" || {
            echo "[$IP] ERROR: latest tag verification failed: $IMAGE_LATEST"
            exit 1
        }

        echo "[$IP] SUCCESS: $IMAGE and $IMAGE_LATEST are ready"

    ) > "$LOG_DIR/$IP.log" 2>&1 &

    PIDS+=("$!")
    PID_IPS+=("$IP")

done

# 等待所有节点完成，按节点顺序输出日志

ERROR_COUNT=0

for i in "${!PIDS[@]}"; do

    wait "${PIDS[$i]}"
    RET=$?

    echo "----------------------------------------"
    echo "[${PID_IPS[$i]}] Import log:"

    while IFS= read -r LINE; do
        echo "$LINE"
    done < "$LOG_DIR/${PID_IPS[$i]}.log"

    if [ "$RET" -ne 0 ]; then
        ERROR_COUNT=$((ERROR_COUNT + 1))
        echo "[${PID_IPS[$i]}] ERROR: Import task failed"
    fi

done

rm -rf "$LOG_DIR"

if [ "$ERROR_COUNT" -ne 0 ]; then
    echo "ERROR: $ERROR_COUNT node(s) failed image import"
    exit 1
fi

echo "[LOCAL] Target image is ready on all nodes"
fi

# ================= 阶段 2.5：导入 memory-pressure 镜像 =================

echo
echo "========================================"
echo "Stage 2.5: Import memory-pressure image"
echo "Image: $MEMORY_PRESSURE_IMAGE"
echo "========================================"

MEMORY_PRESSURE_REMOTE="${REMOTE_IMAGE_DIR}/memory-pressure.tar"

ERROR_COUNT=0

for IP in $NODE_IPS; do

    echo
    echo "[$IP] Checking memory-pressure image..."

    # 检查镜像是否已经存在
    if check_image "$IP" "$MEMORY_PRESSURE_IMAGE"; then

        echo "[$IP] Image already exists, skip import"

    else

        echo "[$IP] Image not found, starting import..."

        ssh -T "${SSH_OPTS[@]}" "${SSH_USER}@${IP}" \
            "ctr -n k8s.io image import '${MEMORY_PRESSURE_REMOTE}'" || {

            echo "[$IP] ERROR: Image import failed"
            ERROR_COUNT=$((ERROR_COUNT + 1))
            continue
        }

        echo "[$IP] Checking imported image..."

        check_image "$IP" "$MEMORY_PRESSURE_IMAGE" || {

            echo "[$IP] ERROR: Image verification failed"
            ERROR_COUNT=$((ERROR_COUNT + 1))
            continue
        }

    fi

    echo "[$IP] SUCCESS: $MEMORY_PRESSURE_IMAGE is ready"

done

if [ "$ERROR_COUNT" -ne 0 ]; then
    echo
    echo "ERROR: $ERROR_COUNT node(s) failed memory-pressure image import"
    exit 1
fi

echo
echo "[LOCAL] memory-pressure image is ready on all nodes"

# ================= 阶段三：检查并导入 pause =================

echo
echo "========================================"
echo "Stage 3: Check and import pause image"
echo "Image: $PAUSE_IMAGE"
echo "Actual ctr reference: $PAUSE_IMAGE_REF"
echo "========================================"

for IP in $NODE_IPS; do

    echo "[$IP] Checking $PAUSE_IMAGE..."

    if ! check_image "$IP" "$PAUSE_IMAGE_REF"; then

        echo "[$IP] $PAUSE_IMAGE not found, importing..."

        ssh -T "${SSH_OPTS[@]}" "${SSH_USER}@${IP}" \
            "test -f '$PAUSE_TAR' && ctr -n k8s.io image import '$PAUSE_TAR'" || {
            echo "[$IP] ERROR: Failed to import $PAUSE_IMAGE"
            exit 1
        }

        echo "[$IP] Verifying imported pause image..."

        check_image "$IP" "$PAUSE_IMAGE_REF" || {
            echo "[$IP] ERROR: $PAUSE_IMAGE verification failed"
            exit 1
        }

    fi

    echo "[$IP] SUCCESS: $PAUSE_IMAGE exists"

done

# ================= 完成 =================

echo
echo "========================================"
echo "SUCCESS: All images distributed and verified"
echo "========================================"

