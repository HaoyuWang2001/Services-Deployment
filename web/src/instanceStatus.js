export function statusType(row) {
  if (row.status === 'dead') {
    if (row.exit_code === 0) return 'success'
    if (row.exit_code != null) return 'danger'
    return 'warning'  // 无退出码 = 被终止/异常结束
  }
  return { running: 'success', legacy: 'warning', reused: 'danger',
           nopidfile: 'info', nows: 'warning', unknown: 'info' }[row.status] || 'info'
}

export function statusText(row) {
  if (row.status === 'dead') {
    if (row.exit_code === 0) return '已退出(0)'
    if (row.exit_code != null) return `已退出(码=${row.exit_code})`
    return '已退出(无码)'
  }
  return { running: '运行中', legacy: '旧实例(需手动处理)', reused: 'PID复用',
           nopidfile: '未启动', nows: '未部署', unknown: '未知' }[row.status] || row.status
}
