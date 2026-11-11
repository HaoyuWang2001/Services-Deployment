#!/usr/bin/env bash
#
# Mooncake Kubernetes startup + health monitor
#
# Usage:
#   chmod +x start-mooncake.sh
#   ./start-mooncake.sh
#
# Store scale:
#   STORE_PER_NODE=1 ./start-mooncake.sh
#   STORE_PER_NODE=2 ./start-mooncake.sh
#
# The script manages only Store DaemonSets carrying the
# mooncake.openai.com/managed-by=start-mooncake label.
#
set -Eeuo pipefail

# ============================================================
# 1. Configuration
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="${SCRIPT_DIR}/scripts"

export MOONCAKE_NAMESPACE="${MOONCAKE_NAMESPACE:-mooncake-rank}"
export MOONCAKE_IMAGE="${MOONCAKE_IMAGE:-mooncake-runtime-w00921547:${TAG:-latest}}"
export MOONCAKE_LOG_PATH="${MOONCAKE_LOG_PATH:-/home/w00921547/mooncake-logs}"
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
STARTUP_TIMEOUT="${STARTUP_TIMEOUT:-300}"
STARTING_MONITOR_INTERVAL="${STARTING_MONITOR_INTERVAL:-5}"
RUNNING_MONITOR_INTERVAL="${RUNNING_MONITOR_INTERVAL:-30}"
STARTUP_GRACE_PERIOD="${STARTUP_GRACE_PERIOD:-90}"
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
        kubectl get pods -n "${MOONCAKE_NAMESPACE}" -o wide || true
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
    "Etcd" || die "Etcd 未能正常启动，停止后续部署"


# ============================================================================
# Stage 2: Master
# ============================================================================

INFO "部署 Master..."
envsubst '${MOONCAKE_NAMESPACE} ${MOONCAKE_IMAGE} ${MOONCAKE_LOG_PATH} ${MOONCAKE_MASTER_REPLICAS}' \
    < "$MASTER_YAML" | kubectl apply -f -

wait_rollout \
    "deployment/mooncake-master" \
    "Master" || die "Master 未能正常启动，停止后续部署"

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
# 8. Pod diagnostics
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
# 11. Manual intervention pause
# ============================================================

pause_for_manual_intervention() {
    echo
    echo "============================================================"
    ERROR "脚本已挂起，等待人工排查"
    INFO "排查完成后，按 Ctrl+C 关闭脚本"
    echo "============================================================"

    trap 'echo; INFO "收到 Ctrl+C，脚本退出"; exit 130' INT
    while true; do sleep 3600; done
}

# ============================================================
# 12. Initial startup wait
# ============================================================

INFO "等待 Mooncake 工作负载启动..."
INFO "启动超时: ${STARTUP_TIMEOUT}s"

START_TIME="$(date +%s)"
API_ERROR_REPORTED=0
declare -A PREVIOUS_POD_READY=()

while true; do
    NOW="$(date +%s)"
    ELAPSED=$((NOW - START_TIME))
    INFO "等待 Pod 就绪... (${ELAPSED}/${STARTUP_TIMEOUT}s)"

    if ! pod_json="$(get_mooncake_pods_json 2>/dev/null)"; then
        if (( API_ERROR_REPORTED == 0 )); then
            WARN "暂时无法连接 Kubernetes API，正在等待恢复..."
            API_ERROR_REPORTED=1
        fi
        if (( ELAPSED >= STARTUP_TIMEOUT )); then
            ERROR "启动等待超时：始终无法获取 Pod 状态"
            pause_for_manual_intervention
        fi
        sleep "$STARTING_MONITOR_INTERVAL"
        continue
    fi
    API_ERROR_REPORTED=0

    pod_count="$(jq '.items | length' <<< "$pod_json")"

    while IFS=$'\t' read -r pod node ready; do
        [[ -z "$pod" ]] && continue
        if [[ "$ready" == "true" && "${PREVIOUS_POD_READY[$pod]:-false}" != "true" ]]; then
            INFO "Pod Ready: ${pod} (Node: ${node})"
        fi
        PREVIOUS_POD_READY["$pod"]="$ready"
    done < <(
        jq -r '
            .items[]
            | [
                .metadata.name,
                (.spec.nodeName // "-"),
                (.status.phase == "Running"
                 and any(.status.conditions[]?; .type == "Ready" and .status == "True"))
            ] | @tsv
        ' <<< "$pod_json"
    )

    bad_pod="$(
        jq -r '
            .items[]
            | . as $pod
            | ([.status.containerStatuses[]?, .status.initContainerStatuses[]?]
               | map(select((.state.waiting.reason // "")
                 | test("CrashLoopBackOff|ImagePullBackOff|ErrImagePull|CreateContainerConfigError|CreateContainerError|RunContainerError|InvalidImageName")))) as $bad
            | select(.status.phase == "Failed" or .status.phase == "Unknown" or ($bad | length > 0))
            | [
                .metadata.name,
                (if .status.phase == "Failed" or .status.phase == "Unknown"
                 then .status.phase else $bad[0].state.waiting.reason end)
              ] | @tsv
        ' <<< "$pod_json" | head -n 1
    )"

    if [[ -n "$bad_pod" ]]; then
        IFS=$'\t' read -r pod reason <<< "$bad_pod"
        dump_pod "$pod" "$reason"
        pause_for_manual_intervention
    fi

    if (( pod_count > 0 )); then
        bad_pod="$(
            jq -r --argjson grace "$STARTUP_GRACE_PERIOD" '
                .items[]
                | select(.status.phase != "Running"
                  or ([.status.conditions[]? | select(.type == "Ready" and .status == "True")] | length == 0))
                | select((now - (.metadata.creationTimestamp | fromdateiso8601)) >= $grace)
                | [.metadata.name, "NotReady"] | @tsv
            ' <<< "$pod_json" | head -n 1
        )"
        if [[ -n "$bad_pod" ]]; then
            IFS=$'\t' read -r pod reason <<< "$bad_pod"
            dump_pod "$pod" "$reason"
            pause_for_manual_intervention
        fi
    fi

    controller_status=0
    check_controllers || controller_status=$?

    if (( pod_count > 0 )) &&
       jq -e '
           all(.items[];
             .status.phase == "Running"
             and any(.status.conditions[]?; .type == "Ready" and .status == "True"))
       ' <<< "$pod_json" >/dev/null &&
       (( controller_status == 0 )); then

        INFO "Mooncake 所有 Pod 和 Controller 已就绪！"
        print_workload_summary
        break
    fi

    if (( ELAPSED >= STARTUP_TIMEOUT )); then
        ERROR "Mooncake 启动超时（${STARTUP_TIMEOUT}s）"
        if (( pod_count == 0 )); then
            ERROR "没有发现任何 Mooncake Pod"
        else
            bad_pod="$(
                jq -r '
                    .items[]
                    | select(.status.phase != "Running"
                      or ([.status.conditions[]? | select(.type == "Ready" and .status == "True")] | length == 0))
                    | [.metadata.name, "StartupTimeout/NotReady"] | @tsv
                ' <<< "$pod_json" | head -n 1
            )"
            if [[ -n "$bad_pod" ]]; then
                IFS=$'\t' read -r pod reason <<< "$bad_pod"
                dump_pod "$pod" "$reason"
            fi
        fi

        if (( controller_status == 1 )); then
            ERROR "至少一个 Controller 尚未达到期望状态"
            kubectl get statefulset,deployment,daemonset -n "${MOONCAKE_NAMESPACE}" -o wide 2>/dev/null || true
        elif (( controller_status == 2 )); then
            WARN "无法获取 Controller 状态，可能是 Kubernetes API 不可用"
        fi
        pause_for_manual_intervention
    fi

    sleep "$STARTING_MONITOR_INTERVAL"
done

# ============================================================
# 13. Continuous monitoring
# ============================================================

INFO "Mooncake 启动成功，开始持续监控..."
INFO "检查间隔: ${RUNNING_MONITOR_INTERVAL}s"
INFO "发现异常后将自动挂起，等待人工排查"

API_ERROR_REPORTED=0

while true; do
    if ! pod_json="$(get_mooncake_pods_json 2>/dev/null)"; then
        if (( API_ERROR_REPORTED == 0 )); then
            WARN "暂时无法连接 Kubernetes API，正在等待恢复..."
            API_ERROR_REPORTED=1
        fi
        sleep "$RUNNING_MONITOR_INTERVAL"
        continue
    fi
    API_ERROR_REPORTED=0

    pod_count="$(jq '.items | length' <<< "$pod_json")"
    if (( pod_count == 0 )); then
        ERROR "没有发现任何 Mooncake Pod！"
        kubectl get pods -n "${MOONCAKE_NAMESPACE}" -o wide || true
        pause_for_manual_intervention
    fi

    bad_pod="$(
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
        ' <<< "$pod_json" | head -n 1
    )"

    if [[ -n "$bad_pod" ]]; then
        IFS=$'\t' read -r pod reason <<< "$bad_pod"
        dump_pod "$pod" "$reason"
        pause_for_manual_intervention
    fi

    controller_status=0
    check_controllers || controller_status=$?

    if (( controller_status == 2 )); then
        if (( API_ERROR_REPORTED == 0 )); then
            WARN "暂时无法获取 Controller 状态，稍后重试..."
            API_ERROR_REPORTED=1
        fi
        sleep "$RUNNING_MONITOR_INTERVAL"
        continue
    fi

    if (( controller_status == 1 )); then
        ERROR "发现 Controller 异常！"
        print_workload_summary
        pause_for_manual_intervention
    fi

    sleep "$RUNNING_MONITOR_INTERVAL"
done
