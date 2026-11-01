import { h } from 'vue'
import { ElMessageBox } from 'element-plus'
import { api } from './api'

// 本会话提交任务的失败跟踪：失败弹模态框（排队依次展示），成功静默。
// 支持分组：trackTaskGroup 把多个任务聚合为一条汇总结果弹窗。
const tracked = new Map()   // taskId -> { context, gid? }
const groups = new Map()    // gid -> { summary, total, done, ok, failed: [{context, lines}] }
let timer = null
let gidSeq = 0
const alertQueue = []
let alertShowing = false

function startPoller() {
  if (!timer) timer = setInterval(poll, 3000)
  poll()
}

export function trackTask(taskId, context) {
  if (!taskId) return
  tracked.set(taskId, { context, gid: null })
  startPoller()
}

export function trackTaskGroup(tasks, summary) {
  const valid = tasks.filter((t) => t && t.id)
  if (!valid.length) return
  const gid = ++gidSeq
  groups.set(gid, { summary, total: valid.length, done: 0, ok: 0, failed: [] })
  for (const t of valid) tracked.set(t.id, { context: t.context, gid })
  startPoller()
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
      const lines = []
      for (const s of detail.subtasks || []) {
        if (s.status === 'failed') lines.push(`${s.node}：${s.error || '未知错误'}`)
      }
      const text = lines.length ? lines.join('\n') : '任务失败，详情见「任务历史」'
      if (item.gid != null) {
        const g = groups.get(item.gid)
        if (g) {
          g.failed.push({ context: item.context, text })
          g.done += 1
          flushGroup(item.gid)
        }
      } else {
        alertQueue.push({ title: `任务失败：${item.context}`, text })
        showNext()
      }
    } else if (item.gid != null) {
      const g = groups.get(item.gid)
      if (g) {
        g.ok += 1
        g.done += 1
        flushGroup(item.gid)
      }
    }
  }
  if (!tracked.size && !groups.size && !alertQueue.length) {
    clearInterval(timer)
    timer = null
  }
}

function flushGroup(gid) {
  const g = groups.get(gid)
  if (!g || g.done < g.total) return
  groups.delete(gid)
  if (g.failed.length) {
    const body = g.failed.map((f) => `● ${f.context}\n${f.text}`).join('\n\n')
    alertQueue.push({
      title: `${g.summary}：${g.ok} 成功 / ${g.failed.length} 失败`,
      text: body,
    })
    showNext()
  }
}

function showNext() {
  if (alertShowing || !alertQueue.length) return
  alertShowing = true
  const { title, text } = alertQueue.shift()
  ElMessageBox.alert(
    h('div', { style: 'white-space: pre-line; word-break: break-all; max-height: 320px; overflow: auto; font-size: 13px; line-height: 1.7;' },
      text),
    title,
    {
      type: 'error',
      confirmButtonText: '知道了',
      callback: () => { alertShowing = false; showNext() },
    },
  )
}
