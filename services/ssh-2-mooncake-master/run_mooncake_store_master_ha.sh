#!/bin/bash
set -euo pipefail

USER="w00921547"
DIR="/home/${USER}/Mooncake/outputs/bin"
NEW="${DIR}/mooncake_master.new"
MOONCAKE_MASTER="${DIR}/mooncake_master"

if [[ -f "$NEW" ]]; then
  mv -f "$NEW" "$MOONCAKE_MASTER"
  chown "$USER:$USER" "$MOONCAKE_MASTER"
  echo "[OK] 已更新 $MOONCAKE_MASTER"
  echo "[OK] 文件属主和属组已设置为 $USER"
else
  echo "[INFO] 文件不存在，跳过更新：$NEW"
fi

# ============================================================================
# 动态库配置
# ============================================================================

export LD_LIBRARY_PATH="/home/${USER}/Mooncake/outputs/lib:${LD_LIBRARY_PATH:-}"

# ============================================================================
# 日志
# ============================================================================

export MC_LOG_ENABLE=on
export MC_LOG_DIR="/home/${USER}/log/mooncake/master"
mkdir -p ${MC_LOG_DIR}

export MC_YLT_LOG_PATH="/home/${USER}/log/mooncake/master/ylt-rpc.log"

export MC_HIFREQ_LOG_SAMPLE_RATE=1

# ============================================================================
# Mooncake + ylt(URMA RPC) 运行时环境变量
# 适用：编译期带 -DYLT_ENABLE_URMA=ON，且 yalantinglibs 来自 extern/ 子模块
# ============================================================================
# 1) 总开关 目前存在冗余和语义混乱问题
export MC_RPC_PROTOCOL=tcp           # 默认未设=tcp；可选 tcp|rdma|urma，大小写敏感
export MC_YLT_URMA_ENABLE=0          # 默认空=关；1|on|true|yes 均可（ylt 内部转小写）
# 2) URMA 设备与 socket 资源（ylt，均有默认值；不设即用默认/自动探测）
export MC_YLT_URMA_DEVICE=bonding_dev_0      # 默认空=自动探测首个可用设备
export MC_YLT_URMA_EID_INDEX=0               # 默认 0, 玮琪说使用1会用到primary eid
export MC_YLT_URMA_TP_TYPE=ctp               # 默认 ctp；可选 ctp|rtp 或 0|1
export MC_YLT_URMA_CQ_SIZE=128               # 默认 128
export MC_YLT_URMA_RECV_BUFFER_CNT=8         # 默认 8
export MC_YLT_URMA_SEND_BUFFER_CNT=4         # 默认 4
export MC_YLT_URMA_BUFFER_SIZE=4096          # 默认 4096（bonding CTP 单包上限）
export MC_YLT_URMA_MAX_MEMORY_USAGE=268435456 # 默认 256 MiB，per-device buffer pool 上限
export MC_YLT_URMA_PRIORITY=7                # 默认 15（URMA 最高优先级；>15 会被忽略）
export MC_YLT_URMA_EVENT_MODE=false          # 默认 true；false=走轮询，时延更低、CPU 更高
export MC_YLT_URMA_BUSY_POLL_BUDGET=16       # 默认 16，event_mode=false 时的忙轮询预算
export MC_YLT_URMA_POLL_INTERVAL=5           # 默认 5（微秒），轮询间隔
# 3) ylt 日志（easylog，进程内只初始化一次）
export MC_YLT_LOG_LEVEL=info                 # 默认 warn；trace|debug|info|warn|error|critical
export MC_YLT_LOG_MAX_FILE_SIZE=5242880      # 默认 1000 MiB（字节）
export MC_YLT_LOG_MAX_FILES=3                # 默认 3
# 4) RPC 连接池 / 超时（主要作用于 store 的 master/client coro_rpc 池）
export MC_YLT_RPC_POOL_MAX_CONNECTION=16        # 默认 100（每 target 上限）
export MC_YLT_RPC_POOL_IDLE_TIMEOUT_MS=3000000     # 默认 30s
export MC_YLT_RPC_POOL_SHORT_IDLE_TIMEOUT_MS=100000 # 默认 1s
export MC_YLT_RPC_POOL_WARMUP=true               # 默认 true，建池预热
export MC_YLT_RPC_POOL_WARMUP_CONNECTIONS=16    # 默认 = MC_YLT_RPC_POOL_MAX_CONNECTION
export MC_RPC_TIMEOUT_MS=1000                   # 默认 coro_rpc 30s；负值=关闭单请求计时
export MC_RPC_CONNECT_TIMEOUT_MS=1000           # 默认 coro_rpc 30s
# 5) RPC IO 线程（ylt io_context 池）
export MC_RPC_CLIENT_IO_THREADS=16               # 默认 min(16, CPU 核数)
# export MC_TE_RPC_CLIENT_IO_THREADS=16          # 不设则继承上一项
# export MC_STORE_RPC_CLIENT_IO_THREADS=16       # 不设则继承上一项、
# 6) IP与端口
export MC_TCP_BIND_ADDRESS=$(ip a | grep -Eo '192\.168\.84\.[0-9]+' | head -n1)

# ============================================================================
# Mooncake Master 运行参数
# ============================================================================

export MC_STORE_PARTITION_SLOT_COUNT=32
export MOONCAKE_VSEGMENT_METRICS_REFRESH_INTERVAL_MS=1000000

export MC_VSEGMENT_OPLOG_MODE=aligned

# ============================================================================
# AWS S3 相关（可选，若不使用 snapshot 功能可不设）
# ============================================================================
#export MOONCAKE_AWS_ACCESS_KEY_ID="admin"
#export MOONCAKE_AWS_SECRET_ACCESS_KEY="adminadmin"
#export MOONCAKE_AWS_REGION="us-east-1"
#export MOONCAKE_AWS_BUCKET_NAME="mooncake-snapshot"
#export MOONCAKE_AWS_S3_ENDPOINT="http://141.61.84.151:9000"

#export MOONCAKE_SNAPSHOT_LOCAL_PATH=/home/${USER}/mooncake_snapshot
#export MOONCAKE_MASTER_SERVICE_SNAPSHOT_TEST_SKIP_CLEANUP=1

# ============================================================================
# 启动 Mooncake master 服务
# ============================================================================

# 绑numa0 8核27-34
exec numactl --physcpubind=27-34 --preferred=0 ${MOONCAKE_MASTER} \
  --default_kv_lease_ttl=300000 \
  --default_kv_soft_pin_ttl=300000 \
  --metrics_port=17702 \
  --rpc_port=17701 \
  --ha_backend_type=etcd \
  --etcd_endpoints="141.61.84.151:17779" \
  --enable_ha=true \
  --enable_oplog=true \
  --rpc_address=$(ip a | grep -Eo '192\.168\.84\.[0-9]+' | head -n1) \
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
  --vsegment_member_extent_size=2097152 \
  --vsegment_reserved_ratio=0 \
  --io_pattern_cold_eviction=false \
  --io_pattern_tier_down_bytes_per_cycle=0 \
  --io_pattern_admission_frequency_threshold=1
