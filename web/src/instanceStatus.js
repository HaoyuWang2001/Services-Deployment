export const ABNORMAL_HINT = '进程异常退出，不会自动执行 kill 或 stop.sh 清理；请先「停止」（走停止中进入已停止，期间执行清理），之后才能启动或删除'

const STATUS_TYPE = {
  running: 'success',
  starting: 'primary',
  stopping: 'warning',
  stopped: 'info',
  deleting: 'warning',
  completed: 'success',
  abnormal: 'danger',
  created: 'info',
  notdeployed: 'warning',
  legacy: 'warning',
  reused: 'danger',
  unknown: 'info',
}

const STATUS_TEXT = {
  running: '运行中',
  starting: '启动中',
  stopping: '停止中',
  stopped: '已停止',
  deleting: '删除中',
  completed: '已完成(0)',
  abnormal: '异常',
  created: '未启动',
  notdeployed: '未部署',
  legacy: '旧实例(需手动处理)',
  reused: 'PID复用',
  unknown: '未知',
}

export function statusType(s) {
  return STATUS_TYPE[s] || 'info'
}

export function statusText(row) {
  const s = row.status
  if (s === 'abnormal') {
    return row.exit_code != null ? `异常(码=${row.exit_code})` : '异常(无码)'
  }
  return STATUS_TEXT[s] || s
}

const CLEANUP_TYPE = {
  none: 'info',
  running: 'warning',
  ok: 'success',
  killfail: 'danger',
  unclean: 'info',
}

export function cleanupType(c) {
  if (c && c.startsWith('failed:')) return 'danger'
  return CLEANUP_TYPE[c] || 'info'
}

export function cleanupText(c) {
  if (!c || c === 'none') return '—'
  if (c === 'running') return '执行中'
  if (c === 'ok') return '正常'
  if (c.startsWith('failed:')) return `清理失败(${c.slice(7)})`
  if (c === 'killfail') return '停止失败'
  if (c === 'unclean') return '未清理'
  return c
}

// 批量按钮门禁集合（按钮要求全部选中实例符合）
export const STOPPABLE = ['running', 'abnormal', 'completed']
export const STARTABLE = ['created', 'stopped', 'completed', 'notdeployed']
export const DELETABLE = ['created', 'stopped', 'completed', 'notdeployed', 'running']

const ELIGIBLE_SETS = { start: STARTABLE, stop: STOPPABLE, delete: DELETABLE }

export function isEligible(action, status) {
  return (ELIGIBLE_SETS[action] || []).includes(status)
}
