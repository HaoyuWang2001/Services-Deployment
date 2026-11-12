#!/bin/bash
set -euo pipefail
unset http_proxy https_proxy

USER="w00921547"
DIR="/home/${USER}/Mooncake/outputs/bin"
NEW="${DIR}/mooncake_client.new"
MOONCAKE_CLIENT="${DIR}/mooncake_client"

if [[ -f "$NEW" ]]; then
  mv -f "$NEW" "$MOONCAKE_CLIENT"
  chown "$USER:$USER" "$MOONCAKE_CLIENT"
  echo "[OK] 已更新 $MOONCAKE_CLIENT"
  echo "[OK] 文件属主和属组已设置为 $USER"
else
  echo "[INFO] 文件不存在，跳过更新：$NEW"
fi

export LD_LIBRARY_PATH=/home/${USER}/Mooncake/outputs/lib:${LD_LIBRARY_PATH:-}

# ============================================================================
# 日志
# ============================================================================
export MC_LOG_ENABLE=on
#export MC_LOG_DIR="/home/${USER}/wangyuqi-mooncake/logs/client_log"
#mkdir -p ${MC_LOG_DIR}
export MC_HIFREQ_LOG_SAMPLE_RATE=0

export MC_STORE_CLIENT_SETUP_RETRIES=3
export no_proxy="127.0.0.1,localhost,local,.local,192.168.0.0/16,10.0.0.0/8,172.16.0.0/12,141.61.17.0/24,141.61.11.0/24"
export MC_STORE_CLIENT_METRIC_BANDWIDTH=0
export MC_SLICE_SIZE=1048576

export MC_MAX_WR=32
export MC_WORKERS_PER_CTX=2
export MC_NUM_CQ_PER_CTX=2
export MC_YLT_RPC_POOL_WARMUP=1
export MC_YLT_RPC_POOL_IDLE_TIMEOUT_MS=604800000
export MC_YLT_RPC_POOL_SHORT_IDLE_TIMEOUT_MS=50000
export MC_OFFLOAD_RPC_THREAD_NUM=16
export MOONCAKE_OFFLOAD_USE_URING=0
export MC_URMA_TRANS_MODE=RM
#export MC_MAX_MR_SIZE=17179869184

export MC_URMA_ACTIVE_PORT=0
export MOONCAKE_OFFLOAD_FILE_STORAGE_PATH=/home/w00889253/mooncake_ssd
export MC_STORE_CLIENT_METRIC=0
export MC_STORE_CLIENT_METRIC_INTERVAL=3
export MC_URMA_BONDING_MULTIPATH_ENABLE=off
export MOONCAKE_OFFLOAD_BUCKET_KEYS_LIMIT=1
export GLOG_v=1

export MOONCAKE_OFFLOAD_CLIENT_BUFFER_GC_TTL_MS=60000

# ============================================================================
# Mooncake + ylt(URMA RPC) 运行时环境变量
# 适用：编译期带 -DYLT_ENABLE_URMA=ON，且 yalantinglibs 来自 extern/ 子模块
# ============================================================================
# 1) 总开关 目前存在冗余和语义混乱问题
export MC_RPC_PROTOCOL=urma          # 默认未设=tcp；可选 tcp|rdma|urma，大小写敏感
export MC_YLT_URMA_ENABLE=1          # 默认空=关；1|on|true|yes 均可（ylt 内部转小写）
# 2) URMA 设备与 socket 资源（ylt，均有默认值；不设即用默认/自动探测）
export MC_YLT_URMA_DEVICE=bonding_dev_0      # 默认空=自动探测首个可用设备
export MC_YLT_URMA_EID_INDEX=0               # 默认 0, 玮琪说使用1会用到primary eid
export MC_YLT_URMA_TP_TYPE=ctp               # 默认 ctp；可选 ctp|rtp 或 0|1
export MC_YLT_URMA_CQ_SIZE=128               # 默认 128
export MC_YLT_URMA_RECV_BUFFER_CNT=8         # 默认 8
export MC_YLT_URMA_SEND_BUFFER_CNT=4         # 默认 4
export MC_YLT_URMA_BUFFER_SIZE=4096          # 默认 4096（bonding CTP 单包上限）
export MC_YLT_URMA_MAX_MEMORY_USAGE=268435456 # 默认 256 MiB，per-device buffer pool 上限
export MC_YLT_URMA_PRIORITY=15               # 默认 15（URMA 最高优先级；>15 会被忽略）
export MC_YLT_URMA_EVENT_MODE=false          # 默认 true；false=走轮询，时延更低、CPU 更高
export MC_YLT_URMA_BUSY_POLL_BUDGET=16       # 默认 16，event_mode=false 时的忙轮询预算
export MC_YLT_URMA_POLL_INTERVAL=5           # 默认 5（微秒），轮询间隔
# 3) ylt 日志（easylog，进程内只初始化一次）
export MC_YLT_LOG_LEVEL=info                 # 默认 warn；trace|debug|info|warn|error|critical
export MC_YLT_LOG_PATH=./logs/rpc.log        # 默认 logs/rpc.log；目录需先存在
export MC_YLT_LOG_MAX_FILE_SIZE=1048576000   # 默认 1000 MiB（字节）
export MC_YLT_LOG_MAX_FILES=3                # 默认 3
# 4) RPC 连接池 / 超时（主要作用于 store 的 master/client coro_rpc 池）
export MC_YLT_RPC_POOL_MAX_CONNECTION=4        # 默认 100（每 target 上限）
export MC_YLT_RPC_POOL_IDLE_TIMEOUT_MS=3000000     # 默认 30s
export MC_YLT_RPC_POOL_SHORT_IDLE_TIMEOUT_MS=10000000 # 默认 1s
export MC_YLT_RPC_POOL_WARMUP=true               # 默认 true，建池预热
export MC_YLT_RPC_POOL_WARMUP_CONNECTIONS=1    # 默认 = MC_YLT_RPC_POOL_MAX_CONNECTION
export MC_RPC_TIMEOUT_MS=30000                   # 默认 coro_rpc 30s；负值=关闭单请求计时
export MC_RPC_CONNECT_TIMEOUT_MS=30000           # 默认 coro_rpc 30s
# 5) RPC IO 线程（ylt io_context 池）
export MC_RPC_CLIENT_IO_THREADS=16               # 默认 min(16, CPU 核数)
# export MC_TE_RPC_CLIENT_IO_THREADS=16          # 不设则继承上一项
# export MC_STORE_RPC_CLIENT_IO_THREADS=16       # 不设则继承上一项
# 6) IP与端口
export MC_TCP_BIND_ADDRESS=$(ip a | grep -Eo '192\.168\.84\.[0-9]+' | head -n1)

# ============================================================================
# 运行 Mooncake client 服务
# ============================================================================

# 绑numa0 16核35-50
exec numactl --physcpubind=35-50 --preferred=0 ${MOONCAKE_CLIENT} \
    --host=$(ip a | grep -Eo '192\.168\.84\.[0-9]+' | head -n1) \
    --metadata_server="etcd://141.61.84.151:17779" \
    --master_server_address="etcd://141.61.84.151:17779" \
    --protocol=ub \
    --device_names=bonding_dev_0 \
    --global_segment_size=214748364080 \
    --port=17704 \
    --threads=32 \
    --v=0 \
    --enable_offload=false
