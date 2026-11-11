#!/usr/bin/env bash
set -Eeuo pipefail

###############################################################################
# Memory Pressure Kubernetes Management
#
# Deploy four NUMA-specific Memory Pressure DaemonSets.
#
# Usage:
#   memory-pressure.sh start
#   memory-pressure.sh stop
#   memory-pressure.sh status
#
# Options:
#   --context NAME       Kubernetes context
#   -h, --help           Show this help message
###############################################################################

# ============================================================================
# Configuration
# ============================================================================

KUBECTL_BIN="${KUBECTL_BIN:-kubectl}"

MEMORY_NAMESPACE="${MEMORY_NAMESPACE:-mooncake-memory-pressure}"
MEMORY_ROLLOUT_TIMEOUT="${MEMORY_ROLLOUT_TIMEOUT:-180s}"
MEMORY_DELETE_TIMEOUT="${MEMORY_DELETE_TIMEOUT:-90s}"

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Memory Pressure manifest
MANIFEST="${SCRIPT_DIR}/memory-pressure.yaml"

# DaemonSet names
DAEMONSETS=(
    "memory-pressure-numa0"
    "memory-pressure-numa1"
    "memory-pressure-numa2"
    "memory-pressure-numa3"
)

# ============================================================================
# Runtime Variables
# ============================================================================

ACTION=""

CONTEXT=""

# ============================================================================
# Logging
# ============================================================================

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2
}

# ============================================================================
# Usage
# ============================================================================

usage() {
    cat <<EOF
Usage:
  $0 <start|stop|status> [options]

Actions:
  start                 Deploy Memory Pressure DaemonSets
  stop                  Remove Memory Pressure DaemonSets
  status                Show Memory Pressure status

Options:
  --context NAME        Kubernetes context
  -h, --help            Show this help message

Examples:

  # Start on all eligible nodes
  $0 start --context my-cluster

  # Query status
  $0 status --context my-cluster

  # Stop Memory Pressure
  $0 stop --context my-cluster

EOF
}

# ============================================================================
# Argument Parsing
# ============================================================================

parse_args() {
    if [[ $# -lt 1 ]]; then
        usage
        exit 1
    fi

    ACTION="$1"
    shift

    case "$ACTION" in
        start|stop|status)
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            error "Invalid action: $ACTION"
            usage
            exit 1
            ;;
    esac

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --context)
                [[ $# -ge 2 ]] || {
                    error "Missing value for --context"
                    exit 1
                }
                CONTEXT="$2"
                shift 2
                ;;

            -h|--help)
                usage
                exit 0
                ;;

            *)
                error "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done
}

# ============================================================================
# Environment Check
# ============================================================================

check_environment() {
    if ! command -v "$KUBECTL_BIN" >/dev/null 2>&1; then
        error "kubectl not found."
        return 1
    fi

    if [[ ! -f "$MANIFEST" ]]; then
        error "Manifest not found: $MANIFEST"
        return 1
    fi
}

# ============================================================================
# Kubernetes Arguments
# ============================================================================

build_kubectl_args() {
    KUBECTL_ARGS=()

    if [[ -n "$CONTEXT" ]]; then
        KUBECTL_ARGS+=(--context "$CONTEXT")
    fi
}

# ============================================================================
# Start
# ============================================================================

start() {
    log "Starting Memory Pressure..."
    log "Context:   ${CONTEXT:-current-context}"
    log "Namespace: $MEMORY_NAMESPACE"
    log "Manifest:  $MANIFEST"
    log "Target:    All eligible Kubernetes nodes"

    if ! "$KUBECTL_BIN" "${KUBECTL_ARGS[@]}" create namespace \
        "$MEMORY_NAMESPACE" --dry-run=client -o yaml | \
        "$KUBECTL_BIN" "${KUBECTL_ARGS[@]}" apply -f -; then

        error "Failed to create or update Namespace: $MEMORY_NAMESPACE"
        return 1
    fi

    if ! "$KUBECTL_BIN" "${KUBECTL_ARGS[@]}" \
        --namespace "$MEMORY_NAMESPACE" apply -f "$MANIFEST"; then

        error "Failed to deploy Memory Pressure DaemonSets."
        return 1
    fi

    log "Waiting for Memory Pressure DaemonSets to become ready..."

    local ds
    local counts
    local desired
    local ready

    for ds in "${DAEMONSETS[@]}"; do
        if ! "$KUBECTL_BIN" "${KUBECTL_ARGS[@]}" \
            --namespace "$MEMORY_NAMESPACE" rollout status \
            "daemonset/$ds" --timeout="$MEMORY_ROLLOUT_TIMEOUT"; then

            error "DaemonSet did not become ready: $ds"
            return 1
        fi

        counts="$(
            "$KUBECTL_BIN" "${KUBECTL_ARGS[@]}" \
                --namespace "$MEMORY_NAMESPACE" get daemonset "$ds" \
                -o jsonpath='{.status.desiredNumberScheduled}{" "}{.status.numberReady}'
        )" || return 1

        read -r desired ready <<< "$counts"
        desired="${desired:-0}"
        ready="${ready:-0}"

        if [[ "$desired" -lt 1 || "$ready" -ne "$desired" ]]; then
            error "DaemonSet is not fully ready: $ds (desired=$desired, ready=$ready)"
            return 1
        fi
    done

    log "Memory Pressure DaemonSets deployed and ready."

    echo
    log "DaemonSet status:"
    "$KUBECTL_BIN" "${KUBECTL_ARGS[@]}" \
        --namespace "$MEMORY_NAMESPACE" get daemonsets \
        -l app=memory-pressure

    echo
    log "Memory Pressure Pods:"
    "$KUBECTL_BIN" "${KUBECTL_ARGS[@]}" \
        --namespace "$MEMORY_NAMESPACE" get pods \
        -l app=memory-pressure \
        -o wide
}

# ============================================================================
# Stop
# ============================================================================


stop() {
    log "Stopping Memory Pressure..."
    log "Context:   ${CONTEXT:-current-context}"
    log "Namespace: $MEMORY_NAMESPACE"

    if ! "$KUBECTL_BIN" "${KUBECTL_ARGS[@]}" \
        get namespace "$MEMORY_NAMESPACE" \
        >/dev/null 2>&1; then

        log "Namespace does not exist. Nothing to stop."
        return 0
    fi

    log "Deleting Namespace: $MEMORY_NAMESPACE"

    if ! "$KUBECTL_BIN" "${KUBECTL_ARGS[@]}" \
        delete namespace "$MEMORY_NAMESPACE" \
        --wait=true --timeout="$MEMORY_DELETE_TIMEOUT"; then

        error "Failed to delete Namespace: $MEMORY_NAMESPACE"
        return 1
    fi

    log "Memory Pressure stopped successfully."
    log "Namespace deleted: $MEMORY_NAMESPACE"
    log "Node images retained."
}


# ============================================================================
# Status
# ============================================================================

status() {
    log "Memory Pressure Status"
    log "Context:   ${CONTEXT:-current-context}"
    log "Namespace: $MEMORY_NAMESPACE"

    echo
    log "========== DaemonSets =========="

    "$KUBECTL_BIN" "${KUBECTL_ARGS[@]}" \
        --namespace "$MEMORY_NAMESPACE" get daemonsets \
        -l app=memory-pressure \
        -o wide

    echo
    log "========== Pods =========="

    "$KUBECTL_BIN" "${KUBECTL_ARGS[@]}" \
        --namespace "$MEMORY_NAMESPACE" get pods \
        -l app=memory-pressure \
        -o wide

    echo
    log "========== Pod Distribution =========="

    "$KUBECTL_BIN" "${KUBECTL_ARGS[@]}" \
        --namespace "$MEMORY_NAMESPACE" get pods \
        -l app=memory-pressure \
        -o custom-columns='NAME:.metadata.name,NODE:.spec.nodeName,NUMA:.metadata.labels.numa,STATUS:.status.phase,READY:.status.containerStatuses[0].ready'
}

# ============================================================================
# Main
# ============================================================================

main() {
    parse_args "$@"

    check_environment || exit 1

    build_kubectl_args

    log "Memory Pressure Kubernetes Management"

    case "$ACTION" in
        start)
            start
            ;;
        stop)
            stop
            ;;
        status)
            status
            ;;
    esac
}

main "$@"
