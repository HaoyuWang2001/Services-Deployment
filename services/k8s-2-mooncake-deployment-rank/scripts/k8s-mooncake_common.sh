#!/bin/bash
# ============================================================================
# 公共基础配置
# ============================================================================
MOONCAKE_NAMESPACE="${MOONCAKE_NAMESPACE:-mooncake}"
ETCD_HOST="mooncake-etcd.${MOONCAKE_NAMESPACE}.svc.cluster.local"
ETCD_PORT="17779"
ETCD_ENDPOINT="${ETCD_HOST}:${ETCD_PORT}"
# ============================================================================
# 1. 获取 URMA bonding 设备
# ============================================================================
export_urma_device() {
    # 获取 bonding 设备
    if command -v urma_admin >/dev/null 2>&1; then
        echo "[INFO] urma_admin found: $(command -v urma_admin)"
    else
        echo "[ERROR] urma_admin command not found"
        return 1
    fi
    URMA_DEVICE=$(urma_admin show | awk '$1 ~ /^[0-9]+$/ && $2 ~ /^bonding_dev_/ {print $2; exit}')
    if [[ -z "${URMA_DEVICE}" ]]; then
        echo "[ERROR] No bonding_dev_* URMA device found"
        return 1
    fi
    export URMA_DEVICE
    echo "[INFO] URMA_DEVICE=${URMA_DEVICE}"
    echo "============================================================"
}
# ============================================================================
# 2. etcd DNS 解析、TCP 连通性与健康状态检查
# ============================================================================
check_etcd_health() {
    # 检查 etcd 配置
    if [[ -z "${ETCD_HOST}" || -z "${ETCD_PORT}" ]]; then
        echo "[ERROR] etcd endpoint configuration is empty"
        return 1
    fi
    for cmd in getent etcdctl timeout; do
        if ! command -v "${cmd}" >/dev/null 2>&1; then
            echo "[ERROR] Required command not found: ${cmd}"
            return 1
        fi
    done
    ETCD_MAX_WAIT=120
    ETCD_RETRY_INTERVAL=2
    ETCD_ELAPSED=0
    ETCD_READY=false
    echo "[INFO] Waiting for etcd to become healthy..."
    while (( ETCD_ELAPSED < ETCD_MAX_WAIT )); do
        echo
        echo "[INFO] etcd check (${ETCD_ELAPSED}/${ETCD_MAX_WAIT}s)"
        # ------------------------------------------------------------------------
        # 1. DNS 解析
        # ------------------------------------------------------------------------
        echo "[INFO] [DNS] Resolving ${ETCD_HOST} ..."
        if ETCD_DNS_OUTPUT=$(timeout 3 getent ahostsv4 "${ETCD_HOST}" 2>&1); then
            ETCD_DNS_STATUS=0
        else
            ETCD_DNS_STATUS=$?
        fi
        if [[ ${ETCD_DNS_STATUS} -eq 124 ]]; then
            ETCD_RESOLVED_IP=""
            echo "[ERROR] [DNS] Resolution timed out after 3 seconds: ${ETCD_HOST}"
        elif [[ ${ETCD_DNS_STATUS} -ne 0 ]]; then
            ETCD_RESOLVED_IP=""
            echo "[ERROR] [DNS] Resolution failed: ${ETCD_HOST}"
            echo "[ERROR] [DNS] ${ETCD_DNS_OUTPUT}"
        else
            ETCD_RESOLVED_IP=$(awk 'NR==1 {print $1}' <<< "${ETCD_DNS_OUTPUT}")
            echo "[INFO] [DNS] ${ETCD_HOST} -> ${ETCD_RESOLVED_IP}"
        fi
        if [[ -z "${ETCD_RESOLVED_IP}" ]]; then
            echo "[ERROR] [DNS] Failed to resolve: ${ETCD_HOST}"
            echo "[ERROR] [DNS] Please check CoreDNS and Kubernetes DNS configuration"
        else
            echo "[INFO] [DNS] ${ETCD_HOST} -> ${ETCD_RESOLVED_IP}"
            # --------------------------------------------------------------------
            # 2. TCP 连通性
            # --------------------------------------------------------------------
            if timeout 2 bash -c "</dev/tcp/${ETCD_HOST}/${ETCD_PORT}" \
                >/dev/null 2>&1; then
                echo "[INFO] [TCP] Connection successful: ${ETCD_RESOLVED_IP}:${ETCD_PORT}"
                # ----------------------------------------------------------------
                # 3. etcd 应用层健康检查
                # ----------------------------------------------------------------
                if ETCD_HEALTH_OUTPUT=$(
                    ETCDCTL_API=3 etcdctl \
                        --endpoints="http://${ETCD_ENDPOINT}" \
                        --dial-timeout=2s \
                        --command-timeout=3s \
                        endpoint health 2>&1
                ); then
                    echo "[INFO] [HEALTH] etcd health check passed"
                    echo "${ETCD_HEALTH_OUTPUT}"
                    ETCD_READY=true
                    break
                else
                    echo "[ERROR] [HEALTH] etcd health check failed"
                    echo "${ETCD_HEALTH_OUTPUT}"
                fi
            else
                echo "[ERROR] [TCP] Connection failed: ${ETCD_RESOLVED_IP}:${ETCD_PORT}"
                echo "[ERROR] [TCP] DNS is working, but the etcd port is unreachable"
            fi
        fi
        ETCD_ELAPSED=$((ETCD_ELAPSED + ETCD_RETRY_INTERVAL))
        if (( ETCD_ELAPSED < ETCD_MAX_WAIT )); then
            echo "[INFO] Retrying etcd check in ${ETCD_RETRY_INTERVAL}s..."
            sleep "${ETCD_RETRY_INTERVAL}"
        fi
    done
    if [[ "${ETCD_READY}" != "true" ]]; then
        echo
        echo "[ERROR] etcd did not become healthy within ${ETCD_MAX_WAIT} seconds"
        echo "[ERROR] Endpoint: ${ETCD_ENDPOINT}"
        return 1
    fi
    echo
    echo "[INFO] etcd is healthy and ready"
    echo "============================================================"
}
# ============================================================================
# 3. ylt 运行时环境变量
# ============================================================================
export_ylt_env() {
    # ============================================================================
    # ylt 运行时环境变量
    # ============================================================================
    # 1) RPC 协议
    export MC_RPC_PROTOCOL=tcp
    export MC_YLT_URMA_ENABLE=0
    # 2) URMA 设备与 socket 资源
    export MC_YLT_URMA_DEVICE="${URMA_DEVICE}"
    export MC_YLT_URMA_EID_INDEX=0
    export MC_YLT_URMA_TP_TYPE=ctp
    export MC_YLT_URMA_CQ_SIZE=128
    export MC_YLT_URMA_RECV_BUFFER_CNT=8
    export MC_YLT_URMA_SEND_BUFFER_CNT=4
    export MC_YLT_URMA_BUFFER_SIZE=4096
    export MC_YLT_URMA_MAX_MEMORY_USAGE=268435456
    export MC_YLT_URMA_PRIORITY=7
    export MC_YLT_URMA_EVENT_MODE=false
    export MC_YLT_URMA_BUSY_POLL_BUDGET=16
    export MC_YLT_URMA_POLL_INTERVAL=5
    # 3) ylt 日志
    export MC_YLT_LOG_LEVEL=info
    export MC_YLT_LOG_PATH=./logs/ylt-rpc.log
    export MC_YLT_LOG_MAX_FILE_SIZE=5242880
    export MC_YLT_LOG_MAX_FILES=1
    # 4) RPC 连接池 / 超时
    export MC_YLT_RPC_POOL_MAX_CONNECTION=16
    export MC_YLT_RPC_POOL_IDLE_TIMEOUT_MS=3000000
    export MC_YLT_RPC_POOL_SHORT_IDLE_TIMEOUT_MS=100000
    export MC_YLT_RPC_POOL_WARMUP=true
    export MC_YLT_RPC_POOL_WARMUP_CONNECTIONS=16
    export MC_RPC_TIMEOUT_MS=1000
    export MC_RPC_CONNECT_TIMEOUT_MS=1000
    # 5) RPC IO 线程
    export MC_RPC_CLIENT_IO_THREADS=16
    # 6) 网络地址
    # 使用 Pod IP，避免只监听容器本地回环地址
    export MC_TCP_BIND_ADDRESS="${POD_IP}"
    echo "[INFO] MC_RPC_PROTOCOL    : ${MC_RPC_PROTOCOL}"
    echo "[INFO] MC_YLT_URMA_ENABLE : ${MC_YLT_URMA_ENABLE}"
    echo "[INFO] MC_TCP_BIND_ADDRESS: ${MC_TCP_BIND_ADDRESS}"
}
# ============================================================================
# 统一初始化入口
# ============================================================================
mooncake_common_init() {
    echo "============================================================"
    echo "[INFO] Starting Mooncake common initialization"
    echo "============================================================"
    # 1. 获取 URMA bonding 设备
    export_urma_device || return 1
    # 2. 检查 etcd 健康状态
    check_etcd_health || return 1
    # 3. 设置 ylt 运行时环境变量
    export_ylt_env || return 1
    echo "============================================================"
    echo "[INFO] Mooncake common initialization completed"
    echo "============================================================"
}
