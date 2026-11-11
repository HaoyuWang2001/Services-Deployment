#!/usr/bin/env bash
#
# Mooncake Kubernetes startup + health monitor
#
# Usage:
#   chmod +x start.sh
#   ./start.sh
#
# Store scale:
#   STORE_PER_NODE=1 ./start.sh
#   STORE_PER_NODE=2 ./start.sh
#
# The script manages only Store DaemonSets carrying the
# mooncake.openai.com/managed-by=start-mooncake label.
#
# Failure semantics (deployment-tool integration):
#   Stage 1 - local validation, ConfigMap and apply failures exit non-zero;
#             the deployment tool auto-runs stop.sh (namespace cleanup) and
#             the instance can be restarted directly.
#   Stage 2 - cluster-side readiness/health is monitored forever. Transient
#             issues (missing images you fix manually, k8s auto-restarting a
#             pod) are tolerated. Sustained issues switch the instance to
#             DEGRADED and recover automatically once workloads are ready.
#             The script only exits when the deployment tool stops it.
#
# Status heartbeat: workspace/run/deploy.status (STARTING | READY | DEGRADED|reason)
#
set -Eeuo pipefail

# ============================================================
# 1. Configuration
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="${SCRIPT_DIR}/scripts"

export MOONCAKE_NAMESPACE="${MOONCAKE_NAMESPACE:-mooncake-rank}"
export MOONCAKE_IMAGE="${MOONCAKE_IMAGE:-mooncake-runtime-w00921547:${TAG:-latest}}"
export MOONCAKE_LOG_PATH="${MOONCAKE_LOG_PATH:-/home/w00921547/mooncake-logs/rank}"
export MOONCAKE_SCRIPT_CONFIGMAP="${MOONCAKE_SCRIPT_CONFIGMAP:-mooncake-startup-scripts}"

# Master remains a Deployment. etcd remains a single-replica StatefulSet.
MOONCAKE_MASTER_REPLICAS="${MOONCAKE_MASTER_REPLICAS:-1}"

# Number of Store Pods per eligible Kubernetes Node.
STORE_PER_NODE="${STORE_PER_NODE:-1}"

# Store DaemonSet metadata label used for safe scale-down cleanup.
STORE_MANAGED_LABEL_KEY="mooncake.openai.com/managed-by"
STORE_MANAGED_LABEL_VALUE="start-mooncake"
STORE_SLOT_LABEL_KEY="mooncake.openai.com/store-slot"

NAMESPACE_YAML="${SCRIPT_DIR}/00-namespace.yaml"
ETCD_YAML="${SCRIPT_DIR}/01-etcd.yaml"
MASTER_YAML="${SCRIPT_DIR}/02-master.yaml"
STORE_SERVICE_YAML="${SCRIPT_DIR}/03-store-service.yaml"
STORE_TEMPLATE_YAML="${SCRIPT_DIR}/04-store-daemonset.yaml"

# Monitoring configuration
STARTUP_TIMEOUT="${STARTUP_TIMEOUT:-300}"          # 从未就绪持续超此时长 → DEGRADED（启动超时）
MONITOR_TOLERANCE="${MONITOR_TOLERANCE:-120}"      # 曾就绪后异常持续此时长 → DEGRADED
RE_DUMP_INTERVAL="${RE_DUMP_INTERVAL:-300}"        # DEGRADED 期间重复诊断间隔
STARTING_MONITOR_INTERVAL="${STARTING_MONITOR_INTERVAL:-5}"
RUNNING_MONITOR_INTERVAL="${RUNNING_MONITOR_INTERVAL:-30}"
LOG_LINES="${LOG_LINES:-100}"

ETCD_LABEL="app=mooncake-etcd"
MASTER_LABEL="app=mooncake-master"
STORE_LABEL="app=mooncake-store"
ALL_LABELS="app in (mooncake-etcd,mooncake-master,mooncake-store)"

# ============================================================
# 2. Logging and common helpers
# ============================================================

INFO()  { echo "[INFO $(date '+%Y-%m-%d %H:%M:%S')] $*"; }
WARN()  { echo "[WARN $(date '+%Y-%m-%d %H:%M:%S')] $*" >&2; }
ERROR() { echo "[ERROR $(date '+%Y-%m-%d %H:%M:%S')] $*" >&2; }

die() {
    ERROR "$*"
    exit 1
}

check_command() {
    command -v "$1" >/dev/null 2>&1 || die "找不到命令: $1"
}

validate_positive_integer() {
    local name="$1"
    local value="$2"
    [[ "$value" =~ ^[1-9][0-9]*$ ]] || die "${name} 必须是大于 0 的整数，当前值: ${value}"
}

# 部署状态心跳：STARTING / READY / DEGRADED|<原因>（workspace/run/deploy.status）
write_deploy_status() {
    local state="$1"
    local detail="${2:-}"
    mkdir -p "${SCRIPT_DIR}/run"
    if [[ -n "$detail" ]]; then
        printf '%s|%s\n' "$state" "$detail" > "${SCRIPT_DIR}/run/deploy.status"
    else
        printf '%s\n' "$state" > "${SCRIPT_DIR}/run/deploy.status"
    fi
}

store_ds_name() {
    printf 'mooncake-store-%s' "$1"
}

wait_rollout() {
    local resource="$1"
    local description="$2"

    INFO "等待 ${description} 就绪..."

    if ! kubectl rollout status "${resource}" \
        -n "${MOONCAKE_NAMESPACE}" \
        --timeout="${STARTUP_TIMEOUT}s"; then

        ERROR "${description} 启动失败或等待超时！"
        dump_unhealthy_pods
        kubectl get pods -n "${MOONCAKE_NAMESPACE}" -o wide || true
        WARN "${description} 未就绪，继续后续阶段；由持续监测循环等待自愈/修复"
        return 1
    fi

    INFO "${description} 已全部 Ready！"
}

# ============================================================
# 3. Validate configuration and local files
# ============================================================

validate_positive_integer "STORE_PER_NODE" "${STORE_PER_NODE}"
validate_positive_integer "MOONCAKE_MASTER_REPLICAS" "${MOONCAKE_MASTER_REPLICAS}"
validate_positive_integer "STARTUP_TIMEOUT" "${STARTUP_TIMEOUT}"
validate_positive_integer "STARTING_MONITOR_INTERVAL" "${STARTING_MONITOR_INTERVAL}"
validate_positive_integer "RUNNING_MONITOR_INTERVAL" "${RUNNING_MONITOR_INTERVAL}"
validate_positive_integer "MONITOR_TOLERANCE" "${MONITOR_TOLERANCE}"
validate_positive_integer "RE_DUMP_INTERVAL" "${RE_DUMP_INTERVAL}"

[[ "${MOONCAKE_NAMESPACE}" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] ||
    die "MOONCAKE_NAMESPACE 不是合法的 Kubernetes Namespace 名称: ${MOONCAKE_NAMESPACE}"

for cmd in kubectl envsubst jq awk grep date; do
    check_command "$cmd"
done

REQUIRED_SCRIPTS=(
    "k8s-start-etcd.sh"
    "k8s-mooncake_common.sh"
    "k8s-run_mooncake_store_master_ha.sh"
    "k8s-run_mooncake_store_realclient_ha.sh"
)

INFO "检查 Mooncake 启动脚本..."
for script in "${REQUIRED_SCRIPTS[@]}"; do
    script_path="${SCRIPTS_DIR}/${script}"
    [[ -f "$script_path" ]] || die "启动脚本不存在: ${script_path}"
    bash -n "$script_path" || die "启动脚本语法检查失败: ${script_path}"
done

for yaml in \
    "$NAMESPACE_YAML" \
    "$ETCD_YAML" \
    "$MASTER_YAML" \
    "$STORE_SERVICE_YAML" \
    "$STORE_TEMPLATE_YAML"
do
    [[ -f "$yaml" ]] || die "YAML 文件不存在: ${yaml}"
done

INFO "Deployment configuration:"
INFO "  Namespace:            ${MOONCAKE_NAMESPACE}"
INFO "  Image:                ${MOONCAKE_IMAGE}"
INFO "  Master replicas:      ${MOONCAKE_MASTER_REPLICAS}"
INFO "  Store Pods per node:  ${STORE_PER_NODE}"
INFO "  Log path:             ${MOONCAKE_LOG_PATH}"
INFO "  Startup timeout:      ${STARTUP_TIMEOUT}s"

INFO "检查 Kubernetes API..."
kubectl cluster-info >/dev/null 2>&1 || die "无法连接 Kubernetes API Server"
INFO "Kubernetes API Server 连接正常"

# ============================================================
# 3b. Pod diagnostics
# ============================================================

dump_pod() {
    local pod="$1"
    local reason="${2:-Unknown}"
    local pod_json

    pod_json="$(kubectl get pod "$pod" -n "${MOONCAKE_NAMESPACE}" -o json 2>/dev/null)" || {
        ERROR "无法获取异常 Pod 信息: ${pod}"
        return 0
    }

    echo
    echo "============================================================"
    ERROR "发现异常 Pod: ${pod} (${reason})"
    echo "============================================================"

    jq -r '
        "Pod       : \(.metadata.name)",
        "Namespace : \(.metadata.namespace)",
        "Node      : \(.spec.nodeName // "-")",
        "Pod IP    : \(.status.podIP // "-")",
        "Phase     : \(.status.phase // "Unknown")",
        "Reason    : \(.status.reason // "-")",
        "Message   : \(.status.message // "-")"
    ' <<< "$pod_json"

    echo
    echo "-------------------- Conditions --------------------"
    jq -r '
        .status.conditions[]? |
        "Type: \(.type)  Status: \(.status)  Reason: \(.reason // "-")  Message: \(.message // "-")"
    ' <<< "$pod_json"

    echo
    echo "-------------------- Container Status --------------------"

    while IFS=$'\t' read -r container state reason message exit_code restart_count ready; do
        [[ -z "$container" ]] && continue
        echo
        echo "Container : ${container}"
        echo "State     : ${state}"
        echo "Reason    : ${reason}"
        echo "Message   : ${message}"
        echo "Exit Code : ${exit_code}"
        echo "Restarts  : ${restart_count}"
        echo "Ready     : ${ready}"

        if [[ "$state" == "Running" || "$state" == "Terminated" ]]; then
            echo "------ 当前容器日志（最近 ${LOG_LINES} 行）------"
            kubectl logs "$pod" -n "${MOONCAKE_NAMESPACE}" -c "$container" \
                --tail="$LOG_LINES" --timestamps=true 2>&1 || true
        fi

        if [[ "$restart_count" =~ ^[0-9]+$ ]] && (( restart_count > 0 )); then
            echo "------ 上一次容器日志（最近 ${LOG_LINES} 行）------"
            kubectl logs "$pod" -n "${MOONCAKE_NAMESPACE}" -c "$container" \
                --previous --tail="$LOG_LINES" --timestamps=true 2>&1 || true
        fi
    done < <(
        jq -r '
            ((.status.initContainerStatuses // []) + (.status.containerStatuses // []))[]
            | [
                .name,
                (if .state.waiting then "Waiting"
                 elif .state.running then "Running"
                 elif .state.terminated then "Terminated"
                 else "Unknown" end),
                (.state.waiting.reason // .state.terminated.reason // "-"),
                (.state.waiting.message // .state.terminated.message // "-"),
                (.state.terminated.exitCode // "-"),
                (.restartCount // 0),
                (.ready // false)
            ] | @tsv
        ' <<< "$pod_json"
    )

    echo
    echo "-------------------- Recent Warning Events --------------------"
    local events_json
    if events_json="$(kubectl get events -n "${MOONCAKE_NAMESPACE}" \
        --field-selector "involvedObject.name=${pod},type=Warning" -o json 2>/dev/null)"; then
        jq -r '
            .items
            | sort_by(.lastTimestamp // .eventTime // .metadata.creationTimestamp)
            | .[-10:]
            | .[]
            | "[\(.reason // "Warning")] \(.message // "-")"
        ' <<< "$events_json"
    else
        WARN "无法获取该 Pod 的 Warning Events"
    fi

    echo "============================================================"
    ERROR "Pod 异常诊断完成: ${pod}"
    echo "============================================================"
}

# 对全部非就绪 Pod 逐个输出详细诊断（conditions / 容器日志 / 上次日志 / events）
dump_unhealthy_pods() {
    local pods_json
    if ! pods_json="$(kubectl get pods -n "${MOONCAKE_NAMESPACE}" -o json 2>/dev/null)"; then
        WARN "无法获取 Pod 列表，跳过诊断"
        return 0
    fi

    local names
    names="$(jq -r '
        .items[]
        | select(.status.phase != "Running"
          or ([.status.conditions[]? | select(.type == "Ready" and .status == "True")] | length == 0))
        | .metadata.name
    ' <<< "$pods_json")"

    if [[ -z "$names" ]]; then
        INFO "没有发现未就绪的 Pod"
        return 0
    fi

    local pod
    while IFS= read -r pod; do
        [[ -z "$pod" ]] && continue
        dump_pod "$pod" "未就绪"
    done <<< "$names"
}

# ============================================================
# 4. Apply Namespace and startup-script ConfigMap
# ============================================================

INFO "创建/更新 Namespace..."
envsubst '${MOONCAKE_NAMESPACE}' < "$NAMESPACE_YAML" | kubectl apply -f -

INFO "更新 Mooncake 启动脚本 ConfigMap..."
kubectl create configmap "${MOONCAKE_SCRIPT_CONFIGMAP}" \
    -n "${MOONCAKE_NAMESPACE}" \
    --from-file="${SCRIPTS_DIR}" \
    --dry-run=client -o yaml | kubectl apply -f -

kubectl get configmap "${MOONCAKE_SCRIPT_CONFIGMAP}" \
    -n "${MOONCAKE_NAMESPACE}" >/dev/null 2>&1 ||
    die "启动脚本 ConfigMap 创建失败"

# ============================================================
# 5. Apply etcd and Master sequentially
# ============================================================

# ============================================================================
# Stage 1: Etcd
# ============================================================================

INFO "部署 Etcd..."
envsubst '${MOONCAKE_NAMESPACE} ${MOONCAKE_IMAGE} ${MOONCAKE_LOG_PATH}' \
    < "$ETCD_YAML" | kubectl apply -f -

wait_rollout \
    "statefulset/mooncake-etcd" \
    "Etcd" || WARN "Etcd 未就绪，继续后续阶段；由持续监测循环等待自愈/修复"


# ============================================================================
# Stage 2: Master
# ============================================================================

INFO "部署 Master..."
envsubst '${MOONCAKE_NAMESPACE} ${MOONCAKE_IMAGE} ${MOONCAKE_LOG_PATH} ${MOONCAKE_MASTER_REPLICAS}' \
    < "$MASTER_YAML" | kubectl apply -f -

wait_rollout \
    "deployment/mooncake-master" \
    "Master" || WARN "Master 未就绪，继续后续阶段；由持续监测循环等待自愈/修复"

# ============================================================
# 6. Apply Store Headless Service
# ============================================================

INFO "部署 Store Headless Service..."
envsubst '${MOONCAKE_NAMESPACE}' < "$STORE_SERVICE_YAML" | kubectl apply -f -

# ============================================================
# 7. Generate and apply Store DaemonSets
# ============================================================

apply_store_daemonsets() {
    local slot
    local ds_name
    local rendered

    INFO "按 STORE_PER_NODE=${STORE_PER_NODE} 生成 Store DaemonSet..."

    for ((slot = 0; slot < STORE_PER_NODE; slot++)); do
        ds_name="$(store_ds_name "$slot")"
        rendered="$(mktemp)"

        STORE_DAEMONSET_NAME="${ds_name}" \
        STORE_SLOT="${slot}" \
        STORE_MANAGED_LABEL_KEY="${STORE_MANAGED_LABEL_KEY}" \
        STORE_MANAGED_LABEL_VALUE="${STORE_MANAGED_LABEL_VALUE}" \
        STORE_SLOT_LABEL_KEY="${STORE_SLOT_LABEL_KEY}" \
        envsubst \
            '${MOONCAKE_NAMESPACE} ${MOONCAKE_IMAGE} ${MOONCAKE_LOG_PATH} ${STORE_DAEMONSET_NAME} ${STORE_SLOT} ${STORE_MANAGED_LABEL_KEY} ${STORE_MANAGED_LABEL_VALUE} ${STORE_SLOT_LABEL_KEY} ${MOONCAKE_SCRIPT_CONFIGMAP}' \
            < "$STORE_TEMPLATE_YAML" > "$rendered"

        INFO "Apply Store DaemonSet: ${ds_name}"
        if ! kubectl apply -f "$rendered"; then
            rm -f "$rendered"
            die "Store DaemonSet 部署失败: ${ds_name}"
        fi
        rm -f "$rendered"
    done
}

# Delete only Store DaemonSets previously created/managed by this script.
# Unrelated DaemonSets are never touched.
cleanup_excess_store_daemonsets() {
    local ds_name
    local ds_json
    local slot

    INFO "清理 STORE_PER_NODE=${STORE_PER_NODE} 之外的旧 Store Slot..."

    ds_json="$(kubectl get daemonsets -n "${MOONCAKE_NAMESPACE}" \
        -l "${STORE_MANAGED_LABEL_KEY}=${STORE_MANAGED_LABEL_VALUE}" \
        -o json)" || die "无法查询受脚本管理的 Store DaemonSet"

    while IFS= read -r ds_name; do
        [[ -z "$ds_name" ]] && continue

        if [[ "$ds_name" =~ ^mooncake-store-([0-9]+)$ ]]; then
            slot="${BASH_REMATCH[1]}"
            if (( slot >= STORE_PER_NODE )); then
                WARN "删除多余 Store DaemonSet: ${ds_name}"
                kubectl delete daemonset "$ds_name" \
                    -n "${MOONCAKE_NAMESPACE}" --wait=false
            fi
        fi
    done < <(jq -r '.items[].metadata.name' <<< "$ds_json")
}

apply_store_daemonsets
cleanup_excess_store_daemonsets

INFO "所有 Kubernetes 资源已提交，当前 Pod 列表："
kubectl get pods -n "${MOONCAKE_NAMESPACE}" -l "${ALL_LABELS}" -o wide ||
    WARN "暂时无法获取 Pod 列表"

# ============================================================
# 9. Workload controller readiness
# ============================================================

check_statefulset_ready() {
    local name="$1"
    local json
    json="$(kubectl get statefulset "$name" -n "${MOONCAKE_NAMESPACE}" -o json 2>/dev/null)" || return 2

    jq -e '
        (.metadata.generation // 0) as $generation
        | (.status.observedGeneration // 0) as $observed
        | (.spec.replicas // 1) as $desired
        | (.status.readyReplicas // 0) as $ready
        | (.status.updatedReplicas // 0) as $updated
        | ($desired > 0 and $ready == $desired and $updated == $desired and $observed >= $generation)
    ' <<< "$json" >/dev/null
}

check_deployment_ready() {
    local name="$1"
    local json
    json="$(kubectl get deployment "$name" -n "${MOONCAKE_NAMESPACE}" -o json 2>/dev/null)" || return 2

    jq -e '
        (.metadata.generation // 0) as $generation
        | (.status.observedGeneration // 0) as $observed
        | (.spec.replicas // 1) as $desired
        | (.status.readyReplicas // 0) as $ready
        | (.status.updatedReplicas // 0) as $updated
        | ($desired > 0 and $ready == $desired and $updated == $desired and $observed >= $generation)
    ' <<< "$json" >/dev/null
}

check_daemonset_ready() {
    local name="$1"
    local json
    json="$(kubectl get daemonset "$name" -n "${MOONCAKE_NAMESPACE}" -o json 2>/dev/null)" || return 2

    jq -e '
        (.metadata.generation // 0) as $generation
        | (.status.observedGeneration // 0) as $observed
        | (.status.desiredNumberScheduled // 0) as $desired
        | (.status.numberReady // 0) as $ready
        | (.status.updatedNumberScheduled // 0) as $updated
        | (.status.numberMisscheduled // 0) as $misscheduled
        | ($desired > 0 and $ready == $desired and $updated == $desired
           and $misscheduled == 0 and $observed >= $generation)
    ' <<< "$json" >/dev/null
}

# Return codes:
#   0 = all controllers ready
#   1 = controller exists but is not ready / expected controller absent
#   2 = Kubernetes API query failure
check_controllers() {
    local slot
    local ds_name

    check_statefulset_ready "mooncake-etcd" || {
        local rc=$?
        return "$rc"
    }

    check_deployment_ready "mooncake-master" || {
        local rc=$?
        return "$rc"
    }

    for ((slot = 0; slot < STORE_PER_NODE; slot++)); do
        ds_name="$(store_ds_name "$slot")"
        check_daemonset_ready "$ds_name" || {
            local rc=$?
            return "$rc"
        }
    done

    return 0
}

# ============================================================
# 10. Pod readiness and status summary
# ============================================================

get_mooncake_pods_json() {
    kubectl get pods -n "${MOONCAKE_NAMESPACE}" -l "${ALL_LABELS}" -o json
}

pods_ready() {
    local json
    json="$(get_mooncake_pods_json 2>/dev/null)" || return 1

    jq -e '
        (.items | length) > 0
        and all(.items[];
            .status.phase == "Running"
            and any(.status.conditions[]?; .type == "Ready" and .status == "True")
        )
    ' <<< "$json" >/dev/null
}

print_workload_summary() {
    local slot
    local ds_name
    local json

    echo
    echo "============================================================"
    INFO "Mooncake 工作负载状态汇总"
    echo "============================================================"

    INFO "[etcd] StatefulSet"
    kubectl get statefulset mooncake-etcd -n "${MOONCAKE_NAMESPACE}" -o wide 2>/dev/null ||
        WARN "无法获取 etcd StatefulSet 状态"

    INFO "[Master] Deployment"
    kubectl get deployment mooncake-master -n "${MOONCAKE_NAMESPACE}" -o wide 2>/dev/null ||
        WARN "无法获取 Master Deployment 状态"

    INFO "[Master] Headless Service endpoints"
    kubectl get endpointslice -n "${MOONCAKE_NAMESPACE}" \
        -l kubernetes.io/service-name=mooncake-master -o wide 2>/dev/null ||
        WARN "无法获取 Master EndpointSlice"

    INFO "[Store] DaemonSets (STORE_PER_NODE=${STORE_PER_NODE})"
    for ((slot = 0; slot < STORE_PER_NODE; slot++)); do
        ds_name="$(store_ds_name "$slot")"
        kubectl get daemonset "$ds_name" -n "${MOONCAKE_NAMESPACE}" -o wide 2>/dev/null ||
            WARN "无法获取 Store DaemonSet: ${ds_name}"
    done

    INFO "[Store] Headless Service endpoints"
    kubectl get endpointslice -n "${MOONCAKE_NAMESPACE}" \
        -l kubernetes.io/service-name=mooncake-store -o wide 2>/dev/null ||
        WARN "无法获取 Store EndpointSlice"

    echo
    INFO "Mooncake Pod 列表:"
    kubectl get pods -n "${MOONCAKE_NAMESPACE}" -l "${ALL_LABELS}" -o wide ||
        WARN "无法获取 Mooncake Pod 列表"

    echo "============================================================"
}

# ============================================================
# 11. Continuous monitoring (STARTING → READY ⇄ DEGRADED)
# ============================================================
#
# DEGRADED 不是终点：脚本继续监测。工作负载恢复全部就绪后自动回到 READY。
# 仅在部署工具停止实例（SIGTERM）或阶段 1 快速失败时退出。

INFO "开始持续监测 Mooncake 工作负载..."
INFO "启动就绪门槛: ${STARTUP_TIMEOUT}s，运行期异常容忍窗: ${MONITOR_TOLERANCE}s"

write_deploy_status "STARTING"

MONITOR_STATE="STARTING"   # STARTING | READY | DEGRADED
UNHEALTHY_SINCE=0
LAST_DUMP_TS=0
API_ERROR_REPORTED=0

trap 'echo; INFO "收到终止信号，退出监测"; exit 143' TERM INT

# 首个异常原因（坏 Pod 优先，其次 Controller / 未就绪）
first_unhealthy_reason() {
    local pods_json="$1"
    local controller_status="$2"
    local bad

    bad="$(
        jq -r '
            .items[]
            | select(.status.phase != "Running"
              or ([.status.conditions[]? | select(.type == "Ready" and .status == "True")] | length == 0))
            | [
                .metadata.name,
                (if .status.phase == "Failed" or .status.phase == "Unknown"
                 then .status.phase
                 else ([.status.containerStatuses[]?, .status.initContainerStatuses[]?]
                       | map(.state.waiting.reason // .state.terminated.reason // empty)
                       | map(select(. != null and . != "")) | .[0] // "NotReady")
                 end)
              ] | @tsv
        ' <<< "$pods_json" | head -n 1
    )"

    if [[ -n "$bad" ]]; then
        printf '%s' "${bad//$'\t'/: }"
        return 0
    fi
    if (( controller_status == 1 )); then
        printf '%s' "Controller 未达到期望状态"
        return 0
    fi
    printf '%s' "Pod 未就绪"
}

while true; do
    NOW="$(date +%s)"

    if ! pod_json="$(get_mooncake_pods_json 2>/dev/null)"; then
        if (( API_ERROR_REPORTED == 0 )); then
            WARN "暂时无法连接 Kubernetes API，正在重试..."
            API_ERROR_REPORTED=1
        fi
        sleep "$RUNNING_MONITOR_INTERVAL" & wait $!
        continue
    fi
    API_ERROR_REPORTED=0

    pod_count="$(jq '.items | length' <<< "$pod_json")"

    controller_status=0
    check_controllers || controller_status=$?

    all_ready=false
    if (( pod_count > 0 )) && (( controller_status == 0 )) &&
       jq -e '
           all(.items[];
             .status.phase == "Running"
             and any(.status.conditions[]?; .type == "Ready" and .status == "True"))
       ' <<< "$pod_json" >/dev/null; then
        all_ready=true
    fi

    if [[ "$all_ready" == "true" ]]; then
        if [[ "$MONITOR_STATE" != "READY" ]]; then
            if [[ "$MONITOR_STATE" == "DEGRADED" ]]; then
                INFO "工作负载已恢复全部就绪，DEGRADED -> READY"
            else
                INFO "Mooncake 所有 Pod 和 Controller 已就绪！"
                print_workload_summary
            fi
            write_deploy_status "READY"
            MONITOR_STATE="READY"
        fi
        UNHEALTHY_SINCE=0
        LAST_DUMP_TS=0
        sleep "$RUNNING_MONITOR_INTERVAL" & wait $!
        continue
    fi

    # ---- 未全部就绪：容忍窗内只观察，超过阈值转 DEGRADED ----
    if (( UNHEALTHY_SINCE == 0 )); then
        UNHEALTHY_SINCE="$NOW"
    fi
    UNHEALTHY_FOR=$(( NOW - UNHEALTHY_SINCE ))

    if [[ "$MONITOR_STATE" == "STARTING" ]]; then
        THRESHOLD="$STARTUP_TIMEOUT"
    else
        THRESHOLD="$MONITOR_TOLERANCE"
    fi

    if [[ "$MONITOR_STATE" != "DEGRADED" ]] && (( UNHEALTHY_FOR >= THRESHOLD )); then
        REASON="$(first_unhealthy_reason "$pod_json" "$controller_status")"
        if (( pod_count == 0 )); then
            REASON="没有发现任何 Mooncake Pod"
        elif [[ "$MONITOR_STATE" == "STARTING" ]]; then
            REASON="启动超时（${UNHEALTHY_FOR}s）：${REASON}"
        fi
        ERROR "持续异常 ${UNHEALTHY_FOR}s：${REASON}"
        INFO "转入 DEGRADED 持续监测（工作负载恢复后自动回到 READY；如需清场请通过部署工具「停止」实例）"
        dump_unhealthy_pods
        print_workload_summary
        write_deploy_status "DEGRADED" "$REASON"
        MONITOR_STATE="DEGRADED"
        LAST_DUMP_TS="$NOW"
    elif [[ "$MONITOR_STATE" == "DEGRADED" ]] && (( NOW - LAST_DUMP_TS >= RE_DUMP_INTERVAL )); then
        INFO "DEGRADED 持续监测中（已 ${UNHEALTHY_FOR}s），刷新诊断..."
        dump_unhealthy_pods
        LAST_DUMP_TS="$NOW"
    elif [[ "$MONITOR_STATE" == "READY" ]]; then
        INFO "检测到 Pod/Controller 未就绪（持续 ${UNHEALTHY_FOR}s，容忍窗 ${THRESHOLD}s）"
    else
        INFO "等待工作负载就绪... (${UNHEALTHY_FOR}/${THRESHOLD}s)"
    fi

    if [[ "$MONITOR_STATE" == "STARTING" ]]; then
        sleep "$STARTING_MONITOR_INTERVAL" & wait $!
    else
        sleep "$RUNNING_MONITOR_INTERVAL" & wait $!
    fi
done
