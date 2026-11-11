#!/usr/bin/env bash
set -Eeuo pipefail

###############################################################################
# CPU Pressure Kubernetes Manager
#
# Responsibilities:
#   1. Discover Pods by namespace and name prefixes.
#   2. Inject cpu-pressure.sh into target containers.
#   3. Start CPU pressure inside Benchmark containers.
#   4. Continuously discover new/restarted Pods.
#   5. Stop monitoring and clean up CPU pressure.
#
# Usage:
#   cpu-pressure-k8s.sh start
#   cpu-pressure-k8s.sh stop
#   cpu-pressure-k8s.sh status
###############################################################################

# ============================================================================
# Configuration
# ============================================================================

KUBECTL_BIN="${KUBECTL_BIN:-kubectl}"

CPU_SCRIPT_PATH="/home/cpu-pressure.sh"

CPU_MONITOR_PID_FILE="/tmp/cpu-pressure-k8s-monitor.pid"
CPU_MONITOR_LOG_FILE="/tmp/cpu-pressure-k8s-monitor.log"

# ============================================================================
# Runtime Configuration
# ============================================================================

ACTION="${1:-}"

CPU_NAMESPACES="${CPU_NAMESPACES:-}"
CPU_POD_PREFIXES="${CPU_POD_PREFIXES:-}"
CPU_CONTAINER="${CPU_CONTAINER:-}"
CPU_SCAN_INTERVAL="${CPU_SCAN_INTERVAL:-10}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CPU_SCRIPT_SOURCE="${SCRIPT_DIR}/cpu-pressure.sh"

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
# Utilities
# ============================================================================

trim() {
    local value="$1"

    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"

    echo "$value"
}

# ============================================================================
# Environment Check
# ============================================================================

check_environment() {
    if ! command -v "$KUBECTL_BIN" >/dev/null 2>&1; then
        error "kubectl not found: $KUBECTL_BIN"
        return 1
    fi

    if [[ ! -f "$CPU_SCRIPT_SOURCE" ]]; then
        error "CPU script not found: $CPU_SCRIPT_SOURCE"
        return 1
    fi

    if [[ -z "$CPU_NAMESPACES" ]]; then
        error "CPU_NAMESPACES is empty."
        return 1
    fi

    if [[ -z "$CPU_POD_PREFIXES" ]]; then
        error "CPU_POD_PREFIXES is empty."
        return 1
    fi

    if ! [[ "$CPU_SCAN_INTERVAL" =~ ^[0-9]+$ ]] ||
       [[ "$CPU_SCAN_INTERVAL" -lt 1 ]]; then
        error "CPU_SCAN_INTERVAL must be a positive integer."
        return 1
    fi

    if [[ "$CPU_SCRIPT_PATH" != /* ]]; then
        error "CPU_SCRIPT_PATH must be an absolute path."
        return 1
    fi
}

# ============================================================================
# Parse Configuration
# ============================================================================

parse_lists() {
    local IFS=','

    read -r -a NAMESPACE_LIST <<< "$CPU_NAMESPACES"
    read -r -a PREFIX_LIST <<< "$CPU_POD_PREFIXES"

    local i

    for i in "${!NAMESPACE_LIST[@]}"; do
        NAMESPACE_LIST[$i]="$(trim "${NAMESPACE_LIST[$i]}")"
    done

    for i in "${!PREFIX_LIST[@]}"; do
        PREFIX_LIST[$i]="$(trim "${PREFIX_LIST[$i]}")"
    done

    # Remove empty entries.
    local filtered=()

    for item in "${NAMESPACE_LIST[@]}"; do
        [[ -n "$item" ]] && filtered+=("$item")
    done

    NAMESPACE_LIST=("${filtered[@]}")

    filtered=()

    for item in "${PREFIX_LIST[@]}"; do
        [[ -n "$item" ]] && filtered+=("$item")
    done

    PREFIX_LIST=("${filtered[@]}")

    [[ ${#NAMESPACE_LIST[@]} -gt 0 ]] || {
        error "No valid namespace configured."
        return 1
    }

    [[ ${#PREFIX_LIST[@]} -gt 0 ]] || {
        error "No valid Pod prefix configured."
        return 1
    }
}

# ============================================================================
# Kubernetes Helpers
# ============================================================================

kubectl_exec() {
    "$KUBECTL_BIN" "$@"
}

get_matching_pods() {
    local namespace="$1"

    kubectl_exec get pods \
        -n "$namespace" \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.phase}{"\n"}{end}'
}

pod_matches_prefix() {
    local pod="$1"

    for prefix in "${PREFIX_LIST[@]}"; do
        if [[ "$pod" == "$prefix"* ]]; then
            return 0
        fi
    done

    return 1
}

# ============================================================================
# Container Selection
# ============================================================================

select_container() {
    local namespace="$1"
    local pod="$2"

    local containers
    local container_status

    containers="$(
        kubectl_exec get pod "$pod" \
            -n "$namespace" \
            -o jsonpath='{range .spec.containers[*]}{.name}{"\n"}{end}'
    )" || return 1

    local container_names=()
    mapfile -t container_names <<< "$containers"

    local selected=""

    if [[ -n "$CPU_CONTAINER" ]]; then
        local found=0

        for name in "${container_names[@]}"; do
            if [[ "$name" == "$CPU_CONTAINER" ]]; then
                found=1
                break
            fi
        done

        if [[ "$found" -ne 1 ]]; then
            error "Container '$CPU_CONTAINER' not found in Pod $namespace/$pod."
            return 1
        fi

        selected="$CPU_CONTAINER"
    else
        if [[ ${#container_names[@]} -ne 1 ]]; then
            error "Pod $namespace/$pod has ${#container_names[@]} containers. Set CPU_CONTAINER explicitly."
            return 1
        fi

        selected="${container_names[0]}"
    fi

    container_status="$(
        kubectl_exec get pod "$pod" \
            -n "$namespace" \
            -o jsonpath='{range .status.containerStatuses[*]}{.name}{"\t"}{.ready}{"\n"}{end}'
    )" || return 1

    if ! awk -F '\t' -v target="$selected" \
        '$1 == target && $2 == "true" { found=1 } END { exit !found }' \
        <<< "$container_status"; then

        error "Container $namespace/$pod/$selected is not ready."
        return 1
    fi

    echo "$selected"
}

# ============================================================================
# Inject CPU Script
# ============================================================================

inject_cpu_script() {
    local namespace="$1"
    local pod="$2"
    local container="$3"

    log "Injecting CPU script into $namespace/$pod/$container"

    kubectl_exec exec -i "$pod" \
        -n "$namespace" \
        -c "$container" \
        -- sh -c "cat > '$CPU_SCRIPT_PATH' && chmod 0755 '$CPU_SCRIPT_PATH'" \
        < "$CPU_SCRIPT_SOURCE"
}

# ============================================================================
# Execute CPU Pressure
# ============================================================================

execute_cpu_pressure() {
    local namespace="$1"
    local pod="$2"
    local container="$3"
    local action="$4"

    if ! inject_cpu_script "$namespace" "$pod" "$container"; then
        error "Failed to inject CPU script: $namespace/$pod"
        return 1
    fi

    log "Executing '$action': $namespace/$pod/$container"

    kubectl_exec exec "$pod" \
        -n "$namespace" \
        -c "$container" \
        -- bash "$CPU_SCRIPT_PATH" "$action"
}

# ============================================================================
# Scan Pods
# ============================================================================

scan_pods() {
    local action="$1"

    local namespace
    local pod
    local phase
    local container

    local matched=0
    local succeeded=0
    local failed=0

    log "Scanning target Pods. Action=$action"

    for namespace in "${NAMESPACE_LIST[@]}"; do

        log "Scanning Namespace: $namespace"

        local pod_list

        if ! pod_list="$(get_matching_pods "$namespace")"; then
            error "Failed to list Pods in Namespace: $namespace"
            failed=$((failed + 1))
            continue
        fi

        while IFS=$'\t' read -r pod phase; do

            [[ -n "$pod" ]] || continue

            if ! pod_matches_prefix "$pod"; then
                continue
            fi

            matched=$((matched + 1))

            if [[ "$phase" != "Running" ]]; then
                log "Skipping $namespace/$pod: phase=$phase"
                continue
            fi

            if ! container="$(select_container "$namespace" "$pod")"; then
                failed=$((failed + 1))
                continue
            fi

            if execute_cpu_pressure "$namespace" "$pod" "$container" "$action"; then
                succeeded=$((succeeded + 1))
            else
                error "Operation failed: $namespace/$pod"
                failed=$((failed + 1))
            fi

        done <<< "$pod_list"

    done

    log "Scan completed."
    log "Matched Pods: $matched"
    log "Succeeded:   $succeeded"
    log "Failed:      $failed"

    if [[ "$failed" -gt 0 ]]; then
        return 1
    fi

    return 0
}

# ============================================================================
# Monitor Process
# ============================================================================

is_monitor_running() {
    local pid="$1"

    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    kill -0 "$pid" 2>/dev/null || return 1

    local state
    state="$(ps -p "$pid" -o stat= 2>/dev/null | xargs || true)"

    [[ -n "$state" && "$state" != Z* ]]
}

monitor_loop() {
    trap 'log "CPU monitor stopping."; rm -f "$CPU_MONITOR_PID_FILE"; exit 0' TERM INT

    echo "$$" > "$CPU_MONITOR_PID_FILE"

    log "CPU monitor started."
    log "Namespaces: $CPU_NAMESPACES"
    log "Pod prefixes: $CPU_POD_PREFIXES"
    log "Container: ${CPU_CONTAINER:-auto-select}"
    log "Scan interval: ${CPU_SCAN_INTERVAL}s"

    while true; do
        scan_pods start || true
        sleep "$CPU_SCAN_INTERVAL"
    done
}

# ============================================================================
# Start
# ============================================================================

start_monitor() {
    if [[ -f "$CPU_MONITOR_PID_FILE" ]]; then
        local old_pid
        old_pid="$(cat "$CPU_MONITOR_PID_FILE" 2>/dev/null || true)"

        if [[ -n "$old_pid" ]] && is_monitor_running "$old_pid"; then
            log "CPU monitor is already running. PID=$old_pid"
            return 0
        fi

        rm -f "$CPU_MONITOR_PID_FILE"
    fi

    log "Starting CPU pressure monitor..."

    nohup bash "$SCRIPT_DIR/$(basename "$0")" _monitor \
        >> "$CPU_MONITOR_LOG_FILE" 2>&1 < /dev/null &

    local pid=$!

    echo "$pid" > "$CPU_MONITOR_PID_FILE"

    sleep 1

    if ! is_monitor_running "$pid"; then
        error "CPU monitor failed to start."
        cat "$CPU_MONITOR_LOG_FILE" || true
        rm -f "$CPU_MONITOR_PID_FILE"
        return 1
    fi

    log "CPU monitor started successfully. PID=$pid"
    log "Monitor log: $CPU_MONITOR_LOG_FILE"
}

# ============================================================================
# Stop
# ============================================================================

stop_monitor() {
    if [[ ! -f "$CPU_MONITOR_PID_FILE" ]]; then
        log "CPU monitor is not running."
        return 0
    fi

    local pid
    pid="$(cat "$CPU_MONITOR_PID_FILE" 2>/dev/null || true)"

    if [[ -z "$pid" ]] || ! is_monitor_running "$pid"; then
        log "Removing stale monitor PID file."
        rm -f "$CPU_MONITOR_PID_FILE"
        return 0
    fi

    log "Stopping CPU monitor. PID=$pid"

    kill -TERM "$pid"

    for ((i=0; i<10; i++)); do
        if ! is_monitor_running "$pid"; then
            break
        fi
        sleep 1
    done

    if is_monitor_running "$pid"; then
        error "CPU monitor did not stop in time. Sending SIGKILL."
        kill -KILL "$pid" 2>/dev/null || true
    fi

    rm -f "$CPU_MONITOR_PID_FILE"

    log "CPU monitor stopped."
}

# ============================================================================
# Status
# ============================================================================

show_status() {
    local pid=""

    if [[ -f "$CPU_MONITOR_PID_FILE" ]]; then
        pid="$(cat "$CPU_MONITOR_PID_FILE" 2>/dev/null || true)"
    fi

    if [[ -n "$pid" ]] && is_monitor_running "$pid"; then
        log "CPU monitor: RUNNING (PID=$pid)"
    else
        log "CPU monitor: STOPPED"
    fi

    scan_pods status || true
}

# ============================================================================
# Main
# ============================================================================

main() {
    if [[ "$ACTION" == "_monitor" ]]; then
        check_environment
        parse_lists
        monitor_loop
        return
    fi

    case "$ACTION" in
        start|stop|status)
            ;;
        -h|--help)
            echo "Usage: $0 {start|stop|status}"
            exit 0
            ;;
        *)
            error "Usage: $0 {start|stop|status}"
            exit 1
            ;;
    esac

    check_environment
    parse_lists

    case "$ACTION" in
        start)
            start_monitor
            ;;
        stop)
            stop_monitor
            scan_pods stop
            ;;
        status)
            show_status
            ;;
    esac
}

main
