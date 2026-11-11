#!/bin/bash
set -euo pipefail

unset http_proxy https_proxy

# ============================================================================
# 基础配置
# ============================================================================

MOONCAKE_CLIENT="/home/Mooncake/outputs/bin/mooncake_client"
MOONCAKE_NAMESPACE="${MOONCAKE_NAMESPACE:-mooncake}"
export MOONCAKE_NAMESPACE

# 加载公共脚本
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/k8s-mooncake_common.sh"

# ============================================================================
# Kubernetes Pod 环境变量检查
# ============================================================================

REQUIRED_ENV_VARS=(
    POD_NAME
    POD_IP
    NODE_NAME
    STORE_SLOT
)

for var in "${REQUIRED_ENV_VARS[@]}"; do
    if [[ -z "${!var:-}" ]]; then
        echo "[ERROR] Required environment variable is missing: ${var}"
        exit 1
    fi
done

# 检查 Store Slot 编号是否合法
if [[ ! "${STORE_SLOT}" =~ ^[0-9]+$ ]]; then
    echo "[ERROR] Invalid STORE_SLOT: ${STORE_SLOT}"
    exit 1
fi

# ============================================================================
# 初始化 Mooncake 公共环境
# ============================================================================

mooncake_common_init || {
    echo "[ERROR] Mooncake common initialization failed"
    exit 1
}

# 检查公共初始化结果
: "${ETCD_ENDPOINT:?ETCD_ENDPOINT is not set}"
: "${URMA_DEVICE:?URMA_DEVICE is not set}"
: "${MC_TCP_BIND_ADDRESS:?MC_TCP_BIND_ADDRESS is not set}"
: "${MC_RPC_PROTOCOL:?MC_RPC_PROTOCOL is not set}"
: "${MC_YLT_URMA_ENABLE:?MC_YLT_URMA_ENABLE is not set}"

GLOBAL_SEGMENT_SIZE="60GB"
PORT=17704
THREADS=16

# 检查 Client 二进制文件
if [[ ! -x "${MOONCAKE_CLIENT}" ]]; then
    echo "[ERROR] Mooncake Client binary not found or not executable:"
    echo "        ${MOONCAKE_CLIENT}"
    exit 1
fi

# ============================================================================
# 动态库配置
# ============================================================================

export LD_LIBRARY_PATH="/usr/lib64/urma:${LD_LIBRARY_PATH:-}"
export LD_LIBRARY_PATH="/home/Mooncake/outputs/lib:${LD_LIBRARY_PATH:-}"

# ============================================================================
# 日志
# ============================================================================

export MC_LOG_ENABLE=on
export MC_LOG_DIR="/var/log/mooncake/store"
mkdir -p "${MC_LOG_DIR}"

export MC_YLT_LOG_PATH="/var/log/mooncake/store/ylt-rpc.log"

export MC_HIFREQ_LOG_SAMPLE_RATE=1
export MC_URMA_LOG_REDIRECT=1                 # 导入urma日志到glog，方便统一采集
export URMA_LOG_LEVEL=debug                   # urma日志级别
export GLOG_v=1                               # glog日志级别

# ============================================================================
# Mooncake Client 运行参数
# ============================================================================

export MC_STORE_CLIENT_SETUP_RETRIES=3

export MC_STORE_CLIENT_METRIC_BANDWIDTH=0
export MC_SLICE_SIZE=1048576

export MC_MAX_WR=32
export MC_WORKERS_PER_CTX=2
export MC_NUM_CQ_PER_CTX=2

export MC_OFFLOAD_RPC_THREAD_NUM=16
export MOONCAKE_OFFLOAD_USE_URING=0
export MC_URMA_TRANS_MODE=RM

# export MC_MAX_MR_SIZE=17179869184

export MC_URMA_ACTIVE_PORT=0
export MOONCAKE_OFFLOAD_FILE_STORAGE_PATH=/home/mooncake_ssd
export MC_STORE_CLIENT_METRIC=0
export MC_STORE_CLIENT_METRIC_INTERVAL=3
export MC_URMA_BONDING_MULTIPATH_ENABLE=on
export MC_UB_NUMA_AFFINITY_ENABLE=on
export MC_URMA_SET_BONDING_MODE=on
export MOONCAKE_OFFLOAD_BUCKET_KEYS_LIMIT=1

export MOONCAKE_OFFLOAD_CLIENT_BUFFER_GC_TTL_MS=60000

export MC_UB_NUMA_NODES=0

export MC_URMA_TE_PRIORITY=6

export MC_STORE_PARTITION_SLOT_COUNT=32

# ============================================================================
# 启动 Mooncake Client
# ============================================================================

echo "============================================================"
echo "Mooncake Client Runtime Configuration"
echo "============================================================"
echo "[INFO] MOONCAKE_NAMESPACE : ${MOONCAKE_NAMESPACE}"
echo "[INFO] STORE_SLOT         : ${STORE_SLOT}"
echo "[INFO] POD_NAME           : ${POD_NAME}"
echo "[INFO] POD_IP             : ${POD_IP}"
echo "[INFO] NODE_NAME          : ${NODE_NAME}"
echo "[INFO] ETCD_ENDPOINT      : ${ETCD_ENDPOINT}"
echo "[INFO] MC_TCP_BIND_ADDRESS: ${MC_TCP_BIND_ADDRESS}"
echo "[INFO] MC_RPC_PROTOCOL    : ${MC_RPC_PROTOCOL}"
echo "[INFO] MC_YLT_URMA_ENABLE : ${MC_YLT_URMA_ENABLE}"
echo "============================================================"

echo "[INFO] Starting Mooncake Client..."

exec "${MOONCAKE_CLIENT}" \
    --host="${POD_IP}" \
    --metadata_server="etcd://${ETCD_ENDPOINT}" \
    --master_server_address="etcd://${ETCD_ENDPOINT}" \
    --protocol=ub \
    --device_names="${URMA_DEVICE}" \
    --global_segment_size="${GLOBAL_SEGMENT_SIZE}" \
    --port="${PORT}" \
    --threads="${THREADS}" \
    --v=0 \
    --enable_offload=false \
    --alsologtostderr=1
