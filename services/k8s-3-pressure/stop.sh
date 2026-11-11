#!/usr/bin/env bash
set -Eeuo pipefail

###############################################################################
# Kubernetes CPU + Memory Pressure Cleanup
#
# Usage:
#   ./stop.sh
###############################################################################

# ============================================================================
# Load Configuration from start.sh
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# start.sh detects that it is being sourced and only exports configuration.
source "${SCRIPT_DIR}/start.sh"

# ============================================================================
# Module Paths
# ============================================================================

CPU_MANAGER="${SCRIPT_DIR}/cpu/cpu-pressure-k8s.sh"
MEMORY_MANAGER="${SCRIPT_DIR}/memory/memory-pressure.sh"

# ============================================================================
# Main
# ============================================================================

main() {
    echo
    echo "============================================================"
    echo "Stopping Kubernetes CPU + Memory Pressure"
    echo "============================================================"

    local failed=0

    # ------------------------------------------------------------------------
    # Stop CPU Pressure
    # ------------------------------------------------------------------------

    echo
    echo "============================================================"
    echo "Stage 1: Stop CPU Pressure"
    echo "============================================================"

    if bash "$CPU_MANAGER" stop; then
        echo "CPU pressure stopped successfully."
    else
        echo "ERROR: Failed to completely stop CPU pressure." >&2
        failed=$((failed + 1))
    fi

    # ------------------------------------------------------------------------
    # Stop Memory Pressure
    # ------------------------------------------------------------------------

    echo
    echo "============================================================"
    echo "Stage 2: Stop Memory Pressure"
    echo "============================================================"

    if bash "$MEMORY_MANAGER" stop; then
        echo "Memory pressure stopped successfully."
    else
        echo "ERROR: Failed to stop Memory pressure." >&2
        failed=$((failed + 1))
    fi

    # ------------------------------------------------------------------------
    # Summary
    # ------------------------------------------------------------------------

    echo
    echo "============================================================"

    if [[ "$failed" -eq 0 ]]; then
        echo "CPU + Memory Pressure stopped successfully."
    else
        echo "CPU + Memory Pressure stopped with $failed failure(s)."
    fi

    echo "============================================================"

    return "$((failed > 0 ? 1 : 0))"
}

main "$@"
