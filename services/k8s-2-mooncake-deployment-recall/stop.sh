#!/usr/bin/env bash
set -Eeuo pipefail

###############################################################################
# Mooncake Kubernetes cleanup script
###############################################################################

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

###############################################################################
# Deployment configuration
# Must be consistent with start.sh
###############################################################################

MOONCAKE_NAMESPACE="${MOONCAKE_NAMESPACE:-mooncake-recall}"

# Namespace deletion timeout
STOP_TIMEOUT="${STOP_TIMEOUT:-180}"

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
}

###############################################################################
# Delete Mooncake namespace
#
# This removes all namespaced resources created by Mooncake:
# - StatefulSets
# - Deployments
# - DaemonSets
# - Pods / containers
# - Services
# - ConfigMaps
# - Secrets
# - PVCs
# - Other namespaced resources
###############################################################################

delete_mooncake_namespace() {
    if ! kubectl get namespace "$MOONCAKE_NAMESPACE" >/dev/null 2>&1; then
        INFO "Namespace ${MOONCAKE_NAMESPACE} 不存在，无需删除"
        return 0
    fi

    kubectl delete namespace "$MOONCAKE_NAMESPACE" \
        --wait=true \
        --timeout="${STOP_TIMEOUT}s"
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
        INFO "Namespace ${MOONCAKE_NAMESPACE} 已删除"
    fi
}

###############################################################################
# Main
###############################################################################

main() {
    INFO "=========================================="
    INFO "       Mooncake Kubernetes Stop"
    INFO "=========================================="

    INFO "Namespace: ${MOONCAKE_NAMESPACE}"
    INFO "Timeout:   ${STOP_TIMEOUT}s"

    echo
    WARN "即将删除 Namespace ${MOONCAKE_NAMESPACE} 下的全部资源。"
    echo

    INFO "非交互模式，直接执行清理"
    echo

    check_environment

    # Step 1: Delete all Mooncake Kubernetes resources
    run_cleanup \
        "删除 Mooncake Namespace 及其全部资源" \
        delete_mooncake_namespace

    # Step 2: Verify cleanup
    verify_cleanup

    echo
    INFO "=========================================="

    if [[ "$FAILED" -eq 0 ]]; then
        INFO "Mooncake Kubernetes 清理完成"
    else
        ERROR "Mooncake 清理未完全成功，请检查上面的错误信息"
        INFO "可以修复问题后重新执行 stop.sh"
        exit 1
    fi

    INFO "=========================================="
}

main "$@"
