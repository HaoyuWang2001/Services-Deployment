#!/bin/bash
set -Eeuo pipefail

# 本文件将提前放置在业务容器内部，此处仅作为备份

###############################################################################
# CPU Pressure Management
#
# Run inside Benchmark business container.
#
# Usage:
#   cpu-pressure.sh start
#   cpu-pressure.sh stop
#   cpu-pressure.sh status
###############################################################################

# ============================================================================
# Configuration
# ============================================================================

CPU_WORKERS=4
CPU_LOAD=50

STRESS_NG_BIN="/home/stress-ng"

PID_FILE="/tmp/cpu-pressure.pid"
LOG_FILE="/tmp/cpu-pressure.log"

STOP_TIMEOUT=10

# ============================================================================
# Utilities
# ============================================================================

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

is_running() {
    local pid="$1"

    [[ "$pid" =~ ^[0-9]+$ ]] || return 1

    # Check whether the process exists.
    kill -0 "$pid" 2>/dev/null || return 1

    # Check process state (exclude zombies).
    local process_state
    process_state="$(ps -p "$pid" -o stat= 2>/dev/null | xargs || true)"

    [[ -n "$process_state" ]] || return 1
    [[ "$process_state" != Z* ]] || return 1

    # Verify executable path to avoid PID reuse.
    local process_exe
    process_exe="$(readlink "/proc/$pid/exe" 2>/dev/null || true)"

    [[ "${process_exe% (deleted)}" == "$STRESS_NG_BIN" ]]
}

get_pid() {
    [[ -f "$PID_FILE" ]] || return 1

    local pid
    pid="$(cat "$PID_FILE")"

    [[ "$pid" =~ ^[0-9]+$ ]] || return 1

    echo "$pid"
}

# ============================================================================
# Start
# ============================================================================

start() {
    if [[ -f "$PID_FILE" ]]; then
        local old_pid
        old_pid="$(get_pid || true)"

        if [[ -n "$old_pid" ]] && is_running "$old_pid"; then
            log "CPU pressure is already running. PID=$old_pid"
            return 0
        fi

        log "Removing stale PID file."
        rm -f "$PID_FILE"
    fi

    if [[ ! -x "$STRESS_NG_BIN" ]]; then
        log "ERROR: stress-ng not found or not executable: $STRESS_NG_BIN"
        return 1
    fi

    log "Starting CPU pressure..."
    log "Executable: $STRESS_NG_BIN"
    log "Workers: $CPU_WORKERS"
    log "CPU load: ${CPU_LOAD}%"

    nohup "$STRESS_NG_BIN" \
        -c "$CPU_WORKERS" \
        --cpu-load "$CPU_LOAD" \
        --metrics-brief \
        > "$LOG_FILE" 2>&1 < /dev/null &

    local pid=$!

    echo "$pid" > "$PID_FILE"

    sleep 1

    if ! is_running "$pid"; then
        log "ERROR: stress-ng failed to start."
        cat "$LOG_FILE" || true
        rm -f "$PID_FILE"
        return 1
    fi

    log "CPU pressure started successfully."
    log "PID: $pid"
    log "Log: $LOG_FILE"
}

# ============================================================================
# Stop
# ============================================================================

stop() {
    local pid
    pid="$(get_pid || true)"

    if [[ -z "$pid" ]]; then
        log "CPU pressure is not running."
        rm -f "$PID_FILE"
        return 0
    fi

    if ! is_running "$pid"; then
        log "Stale PID file detected. Removing it."
        rm -f "$PID_FILE"
        return 0
    fi

    log "Stopping CPU pressure. PID=$pid"

    kill -TERM "$pid"

    for ((i=0; i<STOP_TIMEOUT; i++)); do
        if ! is_running "$pid"; then
            break
        fi

        sleep 1
    done

    if is_running "$pid"; then
        log "Graceful stop timed out. Sending SIGKILL."
        kill -KILL "$pid" 2>/dev/null || true
    fi

    rm -f "$PID_FILE"

    log "CPU pressure stopped."
}

# ============================================================================
# Status
# ============================================================================

status() {
    local pid
    pid="$(get_pid || true)"

    if [[ -z "$pid" ]] || ! is_running "$pid"; then
        log "CPU pressure: STOPPED"
        return 0
    fi

    log "CPU pressure: RUNNING"
    log "PID: $pid"
    log "Workers: $CPU_WORKERS"
    log "CPU load: ${CPU_LOAD}%"

    echo
    ps -p "$pid" -o pid,ppid,stat,etime,%cpu,comm
}

# ============================================================================
# Main
# ============================================================================

case "${1:-}" in
    start)
        start
        ;;
    stop)
        stop
        ;;
    status)
        status
        ;;
    *)
        echo "Usage: $0 {start|stop|status}"
        exit 1
        ;;
esac
