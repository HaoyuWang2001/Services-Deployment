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
READY_NODE_LABEL_KEY="mooncake.openai.com/memory-pressure-ready"

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
# Ready Node Selection
# ============================================================================

label_ready_nodes() {
    local node_rows
    local ready_nodes=()

    node_rows="$(
        "$KUBECTL_BIN" "${KUBECTL_ARGS[@]}" get nodes \
            -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .status.conditions[?(@.type=="Ready")]}{.status}{end}{"\n"}{end}'
    )" || return 1

    mapfile -t ready_nodes < <(
        awk -F '\t' '$2 == "True" { print $1 }' <<< "$node_rows"
    )

    if [[ "${#ready_nodes[@]}" -eq 0 ]]; then
        error "No Ready Kubernetes nodes found."
        return 1
    fi

    # Clear stale eligibility first, then label only nodes that are Ready now.
    if ! "$KUBECTL_BIN" "${KUBECTL_ARGS[@]}" label nodes --all \
        "${READY_NODE_LABEL_KEY}-" --overwrite >/dev/null; then

        error "Failed to clear stale Memory Pressure node labels."
        return 1
    fi

    local node
    for node in "${ready_nodes[@]}"; do
        if ! "$KUBECTL_BIN" "${KUBECTL_ARGS[@]}" label node "$node" \
            "${READY_NODE_LABEL_KEY}=true" --overwrite >/dev/null; then

            error "Failed to label Ready node: $node"
            return 1
        fi
    done

    log "Ready target nodes (${#ready_nodes[@]}): ${ready_nodes[*]}"
}

clear_ready_node_labels() {
    if ! "$KUBECTL_BIN" "${KUBECTL_ARGS[@]}" label nodes --all \
        "${READY_NODE_LABEL_KEY}-" --overwrite >/dev/null 2>&1; then

        log "WARNING: Failed to clear Memory Pressure node labels."
        return 1
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
    log "Target:    Kubernetes nodes with Ready=True"

    if ! label_ready_nodes; then
        error "Failed to select Ready Kubernetes nodes."
        return 1
    fi

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
        clear_ready_node_labels || true
        return 0
    fi

    log "Deleting Memory Pressure DaemonSets..."

    if ! "$KUBECTL_BIN" "${KUBECTL_ARGS[@]}" \
        --namespace "$MEMORY_NAMESPACE" delete daemonset \
        -l app=memory-pressure \
        --ignore-not-found=true --wait=false; then

        error "Failed to request DaemonSet deletion."
        return 1
    fi

    log "Force deleting Memory Pressure Pods..."

    if ! "$KUBECTL_BIN" "${KUBECTL_ARGS[@]}" \
        --namespace "$MEMORY_NAMESPACE" delete pod \
        -l app=memory-pressure \
        --ignore-not-found=true \
        --grace-period=0 --force --wait=false; then

        error "Failed to request Pod deletion."
        return 1
    fi

    log "Requesting Namespace deletion: $MEMORY_NAMESPACE"

    if ! "$KUBECTL_BIN" "${KUBECTL_ARGS[@]}" \
        delete namespace "$MEMORY_NAMESPACE" \
        --ignore-not-found=true --wait=false; then

        error "Failed to request Namespace deletion: $MEMORY_NAMESPACE"
        return 1
    fi

    clear_ready_node_labels || true

    log "Memory Pressure stopped successfully."
    log "Namespace deletion requested: $MEMORY_NAMESPACE"
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
