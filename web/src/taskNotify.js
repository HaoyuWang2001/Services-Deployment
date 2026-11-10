import { h } from 'vue'
import { ElNotification } from 'element-plus'
import { api } from './api'

// 本会话提交任务的跟踪：成功发轻量通知，失败聚合为一条通知（替代连环模态框）。
// 跟踪态持久化到 localStorage：刷新页面后仍能收到任务的结束通知。
const STORE_KEY = 'sd:task-notify'
const EXPIRE_MS = 60 * 60 * 1000   // 1 小时未结束则放弃跟踪（防僵尸条目）
const MAX_MISSES = 10              // 连续约 30 秒不在最近任务列表中则放弃跟踪

const tracked = new Map()   // taskId -> { context, gid, addedAt, misses? }
const groups = new Map()    // gid -> { summary, total, done, ok, failed, addedAt }
let timer = null
let gidSeq = 0

function persist() {
  try {
    localStorage.setItem(STORE_KEY, JSON.stringify({
      tracked: Object.fromEntries(tracked),
      groups: Object.fromEntries(groups),
      gidSeq,
    }))
  } catch { /* 存储不可用时仅内存跟踪 */ }
}

function loadState() {
  try {
    const raw = JSON.parse(localStorage.getItem(STORE_KEY) || 'null')
    if (!raw || typeof raw !== 'object') return
    const now = Date.now()
    for (const [id, item] of Object.entries(raw.tracked || {})) {
      if (now - (item.addedAt || 0) <= EXPIRE_MS) tracked.set(id, item)
    }
    for (const [gid, g] of Object.entries(raw.groups || {})) {
      if (now - (g.addedAt || 0) <= EXPIRE_MS) groups.set(Number(gid), g)
    }
    gidSeq = Math.max(Number(raw.gidSeq) || 0,
      ...Object.keys(raw.groups || {}).map((n) => Number(n) || 0))
  } catch { /* ignore */ }
}

function startPoller() {
  if (!timer) timer = setInterval(poll, 3000)
  poll()
}

export function trackTask(taskId, context) {
  if (!taskId) return
  tracked.set(taskId, { context, gid: null, addedAt: Date.now() })
  persist()
  startPoller()
}

export function trackTaskGroup(tasks, summary) {
  const valid = tasks.filter((t) => t && t.id)
  if (!valid.length) return
  const gid = ++gidSeq
  groups.set(gid, { summary, total: valid.length, done: 0, ok: 0, failed: [], addedAt: Date.now() })
  for (const t of valid) tracked.set(t.id, { context: t.context, gid, addedAt: Date.now() })
  persist()
  startPoller()
}

function notify(type, title, text) {
  ElNotification({
    type,
    title,
    message: h('div', {
      style: 'white-space: pre-line; word-break: break-all; max-height: 240px; overflow: auto; font-size: 13px; line-height: 1.7;',
    }, text),
    duration: type === 'success' ? 3000 : 8000,
  })
}

function dropTracked(id, item) {
  tracked.delete(id)
  if (item.gid != null) {
    const g = groups.get(item.gid)
    if (g) g.total = Math.max(g.done, g.total - 1)
  }
}

async function poll() {
  if (!tracked.size) {
    // 没有待跟踪任务：清理可能残留的分组与持久化状态，停止轮询
    if (groups.size) { groups.clear(); persist() }
    clearInterval(timer)
    timer = null
    try { localStorage.removeItem(STORE_KEY) } catch { /* ignore */ }
    return
  }
  let data
  try {
    data = await api.tasks(50)
  } catch { return }  // 轮询失败下次重试
  const now = Date.now()
  const seen = new Set()
  let changed = false
  for (const t of data.tasks || []) {
    seen.add(t.id)
    const item = tracked.get(t.id)
    if (!item || t.status === 'running') continue
    tracked.delete(t.id)
    changed = true
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
        notify('error', `任务失败：${item.context}`, text)
      }
    } else if (item.gid != null) {
      const g = groups.get(item.gid)
      if (g) {
        g.ok += 1
        g.done += 1
        flushGroup(item.gid)
      }
    } else {
      notify('success', '任务完成', item.context)
    }
  }
  // 过期 / 失踪条目清理（任务已被挤出最近列表或长时间未结束）
  for (const [id, item] of tracked) {
    if (!seen.has(id)) item.misses = (item.misses || 0) + 1
    else item.misses = 0
    if (now - (item.addedAt || 0) > EXPIRE_MS || item.misses >= MAX_MISSES) {
      dropTracked(id, item)
      changed = true
    }
  }
  for (const [gid, g] of groups) {
    if (now - (g.addedAt || 0) > EXPIRE_MS
        && ![...tracked.values()].some((i) => i.gid === gid)) {
      groups.delete(gid)
      changed = true
    }
  }
  for (const gid of [...groups.keys()]) {
    const g = groups.get(gid)
    if (g && g.done >= g.total) flushGroup(gid)
  }
  if (changed) persist()
  if (!tracked.size && !groups.size) {
    clearInterval(timer)
    timer = null
    try { localStorage.removeItem(STORE_KEY) } catch { /* ignore */ }
  }
}

function flushGroup(gid) {
  const g = groups.get(gid)
  if (!g || g.done < g.total) return
  groups.delete(gid)
  if (g.failed.length) {
    const body = g.failed.map((f) => `● ${f.context}\n${f.text}`).join('\n\n')
    notify('error', `${g.summary}：${g.ok} 成功 / ${g.failed.length} 失败`, body)
  } else {
    notify('success', g.summary, `${g.total} 个任务全部成功`)
  }
}

loadState()
if (tracked.size || groups.size) startPoller()
