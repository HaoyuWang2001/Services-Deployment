import { h } from 'vue'
import { ElMessageBox } from 'element-plus'
import { api } from './api'

// 本会话提交任务的失败跟踪：失败弹模态框（排队依次展示），成功静默
const tracked = new Map()   // taskId -> { context }
let timer = null
const alertQueue = []
let alertShowing = false

export function trackTask(taskId, context) {
  if (!taskId) return
  tracked.set(taskId, { context })
  if (!timer) timer = setInterval(poll, 3000)
  poll()
}

async function poll() {
  if (!tracked.size) return
  let data
  try {
    data = await api.tasks(50)
  } catch { return }  // 轮询失败下次重试
  for (const t of data.tasks || []) {
    const item = tracked.get(t.id)
    if (!item || t.status === 'running') continue
    tracked.delete(t.id)
    if (t.status === 'failed' || t.status === 'partial') {
      let detail = t
      try { detail = await api.task(t.id) } catch { /* 用摘要 */ }
      alertQueue.push({ context: item.context, task: detail })
    }
  }
  if (!tracked.size && !alertQueue.length) {
    clearInterval(timer)
    timer = null
  }
  showNext()
}

function showNext() {
  if (alertShowing || !alertQueue.length) return
  alertShowing = true
  const { context, task } = alertQueue.shift()
  const lines = []
  for (const s of task.subtasks || []) {
    if (s.status === 'failed') lines.push(`${s.node}：${s.error || '未知错误'}`)
  }
  const text = lines.length ? lines.join('\n') : '任务失败，详情见「任务历史」'
  ElMessageBox.alert(
    h('div', { style: 'white-space: pre-line; word-break: break-all; max-height: 300px; overflow: auto; font-size: 13px; line-height: 1.7;' },
      text),
    `任务失败：${context}`,
    {
      type: 'error',
      confirmButtonText: '知道了',
      callback: () => { alertShowing = false; showNext() },
    },
  )
}
