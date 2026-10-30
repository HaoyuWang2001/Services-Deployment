#!/usr/bin/env bash
# 应用清理脚本模板（可选）
#
# 职责边界：本脚本【只做应用层清理】（如拆除集群、删除临时资源）——
# 进程终止完全由管理端负责，请勿在此 kill 任何 PID。
#
# 执行时机：
#   1. 手动「停止 / 重启 / 删除」：管理端先整组终止进程，成功后执行本脚本
#   2. start.sh 自然退出（含非零退出）：自动执行本脚本完成清理
#      （被停止/杀死的路径不会触发自动执行）
#
# 建议：清理命令尽量幂等（容忍重复执行与资源已不存在的情况）。
set -euo pipefail

echo "[$(date '+%F %T')] cleanup on $(hostname)"
# TODO: 应用清理，例如：
#   kind delete cluster --name demo
#   k3s-killall.sh || true
