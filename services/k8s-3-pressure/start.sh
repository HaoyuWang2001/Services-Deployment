#!/usr/bin/env bash
set -Eeuo pipefail

###############################################################################
# Kubernetes CPU + Memory Pressure
#
# Usage:
#   ./start.sh
###############################################################################

# ============================================================================
# Script Directory
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ============================================================================
# Kubernetes Configuration
# ============================================================================

export KUBECTL_BIN="kubectl"

# Use the default Kubernetes context.
# No --context argument will be passed.

# ============================================================================
# CPU Pressure Configuration
# ============================================================================

# Target namespaces, separated by comma.
export CPU_NAMESPACES="mooncake-rank,mooncake-recall"

# Target Pod name prefixes, separated by comma.
export CPU_POD_PREFIXES="mooncake-store"

# Empty means automatically select the only container in each Pod.
export CPU_CONTAINER=""

# CPU monitor scan interval (seconds).
export CPU_SCAN_INTERVAL=10

# ============================================================================
# Memory Pressure Configuration
# ============================================================================

export MEMORY_NAMESPACE="mooncake-memory-pressure"
export MEMORY_ROLLOUT_TIMEOUT="180s"

# ============================================================================
# Allow This File to Be Sourced by stop.sh
# ============================================================================

if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
    return 0
fi

# ============================================================================
# Module Paths
# ============================================================================

CPU_MANAGER="${SCRIPT_DIR}/cpu/cpu-pressure-k8s.sh"
MEMORY_MANAGER="${SCRIPT_DIR}/memory/memory-pressure.sh"

# ============================================================================
# Environment Check
# ============================================================================

check_environment() {
    if ! command -v "$KUBECTL_BIN" >/dev/null 2>&1; then
        echo "ERROR: kubectl not found: $KUBECTL_BIN" >&2
        return 1
    fi

    if [[ ! -f "$CPU_MANAGER" ]]; then
        echo "ERROR: CPU manager not found: $CPU_MANAGER" >&2
        return 1
    fi

    if [[ ! -f "$MEMORY_MANAGER" ]]; then
        echo "ERROR: Memory manager not found: $MEMORY_MANAGER" >&2
        return 1
    fi
}

# ============================================================================
# Main
# ============================================================================

main() {
    check_environment

    echo
    echo "============================================================"
    echo "Starting Kubernetes CPU + Memory Pressure"
    echo "============================================================"

    echo
    echo "CPU Configuration:"
    echo "  Namespaces:     $CPU_NAMESPACES"
    echo "  Pod prefixes:   $CPU_POD_PREFIXES"
    echo "  Container:      ${CPU_CONTAINER:-auto-select}"
    echo "  Scan interval:  ${CPU_SCAN_INTERVAL}s"

    echo
    echo "Memory Configuration:"
    echo "  Namespace:      $MEMORY_NAMESPACE"
    echo "  NUMA nodes:     0, 1, 2, 3"
    echo "  Bandwidth:      140 GB/s per NUMA"

    local failed=0

    # ------------------------------------------------------------------------
    # Start CPU Pressure
    # ------------------------------------------------------------------------

    echo
    echo "============================================================"
    echo "Stage 1: Start CPU Pressure"
    echo "============================================================"

    if bash "$CPU_MANAGER" start; then
        echo "CPU pressure monitor started successfully."
    else
        echo "ERROR: Failed to start CPU pressure monitor." >&2
        failed=$((failed + 1))
    fi

    # ------------------------------------------------------------------------
    # Start Memory Pressure
    # ------------------------------------------------------------------------

    echo
    echo "============================================================"
    echo "Stage 2: Start Memory Pressure"
    echo "============================================================"

    if bash "$MEMORY_MANAGER" start; then
        echo "Memory pressure started successfully."
    else
        echo "ERROR: Failed to start Memory pressure." >&2
        failed=$((failed + 1))
    fi

    # ------------------------------------------------------------------------
    # Summary
    # ------------------------------------------------------------------------

    echo
    echo "============================================================"

    if [[ "$failed" -gt 0 ]]; then
        echo "CPU + Memory Pressure started with $failed failure(s)."
        echo "Rolling back partially started pressure workloads..."

        bash "$CPU_MANAGER" stop || true
        bash "$MEMORY_MANAGER" stop || true

        echo "============================================================"
        return 1
    fi

    echo "CPU + Memory Pressure started successfully."
    echo "============================================================"
    echo
    echo "Pressure workloads are active. Waiting for a stop request..."

    # Services-Deployment treats a naturally exiting start script as a completed
    # service and automatically invokes stop.sh. Keep this process in the
    # foreground so the pressure remains active until the platform stops the
    # service process group and then runs stop.sh explicitly.
    local keepalive_pid=""

    shutdown() {
        echo "Stop signal received."
        if [[ -n "$keepalive_pid" ]]; then
            kill "$keepalive_pid" 2>/dev/null || true
        fi
        exit 0
    }

    trap shutdown TERM INT

    while true; do
        sleep 3600 &
        keepalive_pid=$!
        wait "$keepalive_pid" || true
    done
}

main "$@"
