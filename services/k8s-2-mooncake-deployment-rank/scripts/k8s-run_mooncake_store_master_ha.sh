#!/bin/bash
set -euo pipefail

# ============================================================================
# 基础配置
# ============================================================================

MOONCAKE_MASTER="/home/Mooncake/outputs/bin/mooncake_master"

# 加载公共脚本
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/k8s-mooncake_common.sh"
mooncake_common_init || {
    echo "[ERROR] Mooncake common initialization failed"
    exit 1
}

# ============================================================================
# Kubernetes Pod 环境变量检查
# ============================================================================

REQUIRED_ENV_VARS=(
    POD_NAME
    POD_IP
    NODE_NAME
)

echo "============================================================"
echo "Mooncake Master - Kubernetes Runtime Environment"
echo "============================================================"

for var in "${REQUIRED_ENV_VARS[@]}"; do
    if [[ -z "${!var:-}" ]]; then
        echo "[ERROR] Required environment variable is missing: ${var}"
        exit 1
    fi
done

echo "[INFO] POD_NAME     : ${POD_NAME}"
echo "[INFO] POD_IP       : ${POD_IP}"
echo "[INFO] NODE_NAME    : ${NODE_NAME}"
echo "[INFO] ETCD_ENDPOINT: ${ETCD_ENDPOINT}"

# 检查 Master 二进制文件
if [[ ! -x "${MOONCAKE_MASTER}" ]]; then
    echo "[ERROR] Mooncake Master binary not found or not executable:"
    echo "        ${MOONCAKE_MASTER}"
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
export MC_LOG_DIR="/var/log/mooncake/master"
mkdir -p "${MC_LOG_DIR}"

export MC_HIFREQ_LOG_SAMPLE_RATE=1

# ============================================================================
# Mooncake Master 运行参数
# ============================================================================

export MC_STORE_PARTITION_SLOT_COUNT=32
export MOONCAKE_VSEGMENT_METRICS_REFRESH_INTERVAL_MS=1000000

export MC_VSEGMENT_OPLOG_MODE=aligned

# ============================================================================
# AWS S3 相关（可选）
# ============================================================================

# export MOONCAKE_AWS_ACCESS_KEY_ID="admin"
# export MOONCAKE_AWS_SECRET_ACCESS_KEY="adminadmin"
# export MOONCAKE_AWS_REGION="us-east-1"
# export MOONCAKE_AWS_BUCKET_NAME="mooncake-snapshot"
# export MOONCAKE_AWS_S3_ENDPOINT="http://141.61.84.151:9000"

# export MOONCAKE_SNAPSHOT_LOCAL_PATH=/home/mooncake_snapshot
# export MOONCAKE_MASTER_SERVICE_SNAPSHOT_TEST_SKIP_CLEANUP=1

# ============================================================================
# 启动 Mooncake Master
# ============================================================================

echo "[INFO] Starting Mooncake Master..."
echo "[INFO] Pod      : ${POD_NAME}"
echo "[INFO] Pod IP   : ${POD_IP}"
echo "[INFO] Node     : ${NODE_NAME}"
echo "[INFO] etcd     : ${ETCD_ENDPOINT}"

echo "[INFO] Starting Mooncake Master..."

exec "${MOONCAKE_MASTER}" \
  --default_kv_lease_ttl=300000 \
  --default_kv_soft_pin_ttl=300000 \
  --metrics_port=17702 \
  --rpc_port=17701 \
  --ha_backend_type=etcd \
  --etcd_endpoints="${ETCD_ENDPOINT}" \
  --enable_ha=true \
  --enable_oplog=true \
  --rpc_address="${POD_IP}" \
  --enable_metrics_report_to_backend=true \
  --enable_offload=false \
  --enable_snapshot=false \
  --enable_snapshot_restore=false \
  --snapshot_interval_seconds=10 \
  --snapshot_retention_count=5 \
  --snapshot_object_store_type="s3" \
  --v=0 \
  --cluster_id=mooncake_cluster_w00921547 \
  --submaster_count=1 \
  --cvm_http_port=17703 \
  --vsegment_auto_plan=true \
  --vsegment_member_count=4 \
  --vsegment_stripe_size=2097152 \
  --vsegment_member_extent_size=402653184 \
  --vsegment_reserved_ratio=0 \
  --io_pattern_cold_eviction=false \
  --io_pattern_tier_down_bytes_per_cycle=0 \
  --io_pattern_admission_frequency_threshold=1
