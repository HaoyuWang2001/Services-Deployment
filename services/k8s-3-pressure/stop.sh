#!/usr/bin/env bash
set -Eeuo pipefail
###############################################################################
# Mooncake Kubernetes cleanup script (enhanced)
###############################################################################
# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
###############################################################################
# Deployment configuration
# Must be consistent with start.sh
###############################################################################
MOONCAKE_NAMESPACE="mooncake"
MOONCAKE_ETCD_LABEL="mooncake-etcd"
MOONCAKE_MASTER_LABEL="mooncake-master"
MOONCAKE_STORE_LABEL="mooncake-store"
STOP_TIMEOUT=180
# 集群级资源（按需开启，当前无CRD可注释）
# MOONCAKE_CRD_LIST=("xxx.mooncake.io")
###############################################################################
# Logging
###############################################################################
INFO() {
    echo "[INFO $(date '+%Y-%m-%d %H:%M:%S')] $*"
}
WARN() {
    echo "[WARN $(date '+%Y-%m-%d %H:%M:%S')] $*" >&2
}
ERROR() {
    echo "[ERROR $(date '+%Y-%m-%d %H:%M:%S')] $*" >&2
}
###############################################################################
# Error handling
###############################################################################
FAILED=0
run_cleanup() {
    local description="$1"
    shift
    INFO "${description}"
    if "$@"; then
        INFO "完成: ${description}"
    else
        ERROR "失败: ${description}"
        FAILED=1
    fi
}
###############################################################################
# Environment checks
###############################################################################
check_environment() {
    if ! command -v kubectl >/dev/null 2>&1; then
        ERROR "未找到 kubectl"
        exit 1
    fi
    if ! kubectl cluster-info >/dev/null 2>&1; then
        ERROR "无法连接 Kubernetes 集群，请检查 kubeconfig 和集群状态"
        exit 1
    fi
    # 校验 jq
    if ! command -v jq >/dev/null 2>&1; then
        WARN "未检测到 jq，标签校验步骤会跳过"
    fi
}
###############################################################################
# Delete namespace with terminating fallback
###############################################################################
delete_mooncake_namespace() {
    if ! kubectl get namespace "$MOONCAKE_NAMESPACE" >/dev/null 2>&1; then
        INFO "Namespace ${MOONCAKE_NAMESPACE} 不存在，无需删除"
        return 0
    fi
    INFO "开始删除 namespace ${MOONCAKE_NAMESPACE}"
    if ! kubectl delete namespace "$MOONCAKE_NAMESPACE" \
        --wait=true \
        --timeout="${STOP_TIMEOUT}s"; then
        WARN "namespace 删除超时，尝试强制清理 finalizer"
        kubectl get ns "$MOONCAKE_NAMESPACE" -o json | jq '.spec.finalizers=[]' | kubectl replace --raw "/api/v1/namespaces/${MOONCAKE_NAMESPACE}/finalize" -f -
    fi
}
###############################################################################
# Remove node labels
###############################################################################
remove_node_label() {
    local label="$1"
    INFO "清理节点标签: ${label}"
    kubectl label nodes --all "${label}-" --overwrite
}
remove_all_node_labels() {
    remove_node_label "$MOONCAKE_ETCD_LABEL"
    remove_node_label "$MOONCAKE_MASTER_LABEL"
    remove_node_label "$MOONCAKE_STORE_LABEL"
}
###############################################################################
# Verify cleanup
###############################################################################
verify_cleanup() {
    INFO "检查 Namespace..."
    if kubectl get namespace "$MOONCAKE_NAMESPACE" >/dev/null 2>&1; then
        ERROR "Namespace ${MOONCAKE_NAMESPACE} 仍然存在"
        FAILED=1
    else
        INFO "Namespace 已删除"
    fi

    if ! command -v jq >/dev/null 2>&1; then
        WARN "跳过节点标签校验，缺少 jq"
        return 0
    fi

    INFO "检查节点标签..."
    for label in \
        "$MOONCAKE_ETCD_LABEL" \
        "$MOONCAKE_MASTER_LABEL" \
        "$MOONCAKE_STORE_LABEL"
    do
        remaining="$(
            kubectl get nodes -o json |
                jq -r --arg label "$label" \
                    '.items[] | select(.metadata.labels[$label] != null) | .metadata.name'
        )"
        if [[ -n "$remaining" ]]; then
            ERROR "仍有节点保留标签 ${label}:"
            echo "$remaining"
            FAILED=1
        else
            INFO "标签 ${label} 已清理"
        fi
    done
}
###############################################################################
# Main
###############################################################################
main() {
    INFO "=========================================="
    INFO "     Mooncake Kubernetes Stop (Enhanced)"
    INFO "=========================================="
    INFO "Namespace: ${MOONCAKE_NAMESPACE}"
    INFO "Etcd label: ${MOONCAKE_ETCD_LABEL}"
    INFO "Master label: ${MOONCAKE_MASTER_LABEL}"
    INFO "Store label: ${MOONCAKE_STORE_LABEL}"
    echo
    WARN "即将删除 Namespace ${MOONCAKE_NAMESPACE} 下的全部资源。"
    WARN "并清除所有 Kubernetes 节点上的 Mooncake 专用标签。"
    echo

    # 增加交互确认，不传 --yes 则人工确认
    local YES_MODE=0
    if [[ $# -ge 1 && "$1" == "--yes" ]]; then
        YES_MODE=1
    fi
    if [[ ${YES_MODE} -eq 0 ]]; then
        read -r -p "确认继续清理？输入 YES 确认：" confirm
        if [[ "${confirm}" != "YES" ]]; then
            INFO "用户取消清理，退出"
            exit 0
        fi
    else
        INFO "收到 --yes，非交互模式直接执行清理"
    fi
    echo

    check_environment
    # Step 1: Delete all Mooncake Kubernetes resources
    run_cleanup \
        "删除 Mooncake Namespace 及其全部资源" \
        delete_mooncake_namespace
    # Step 2: Remove Mooncake node labels
    run_cleanup \
        "清除 Mooncake 节点标签" \
        remove_all_node_labels
    # Step 3: Verify cleanup
    verify_cleanup
    echo
    INFO "=========================================="
    if [[ "$FAILED" -eq 0 ]]; then
        INFO "Mooncake Kubernetes 清理完成"
    else
        ERROR "Mooncake 清理未完全成功，请检查上面的错误信息"
        INFO "可以修复问题后重新执行 ./stop.sh --yes"
        exit 1
    fi
    INFO "=========================================="
}
main "$@"
