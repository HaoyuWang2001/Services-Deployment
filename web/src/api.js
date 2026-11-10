const DEFAULT_TIMEOUT = 30000

async function fetchWithTimeout(url, options = {}, timeout = DEFAULT_TIMEOUT) {
  const ctrl = new AbortController()
  const timer = setTimeout(() => ctrl.abort(), timeout)
  try {
    return await fetch(url, { ...options, signal: ctrl.signal })
  } catch (e) {
    if (e?.name === 'AbortError') throw new Error('请求超时，请检查网络或后端状态')
    throw e
  } finally {
    clearTimeout(timer)
  }
}

async function request(method, url, body) {
  const res = await fetchWithTimeout(url, {
    method,
    headers: { 'Content-Type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  })
  if (!res.ok) {
    let detail = ''
    try { detail = (await res.json()).detail } catch { /* ignore */ }
    throw new Error(detail || `HTTP ${res.status}`)
  }
  if (res.status === 204) return null
  return res.json()
}

export const api = {
  nodes: () => request('GET', '/api/cluster/nodes'),
  testNode: (name) => request('POST', `/api/cluster/nodes/${encodeURIComponent(name)}/test`),
  nodePorts: (name) => request('GET', `/api/cluster/nodes/${encodeURIComponent(name)}/ports`),
  reloadConfig: () => request('POST', '/api/cluster/reload'),
  monitors: () => request('GET', '/api/monitors'),
  createMonitor: (payload) => request('POST', '/api/monitors', payload),
  updateMonitor: (id, payload) => request('PUT', `/api/monitors/${id}`, payload),
  deleteMonitor: (id) => request('DELETE', `/api/monitors/${id}`),
  services: () => request('GET', '/api/services'),
  service: (name) => request('GET', `/api/services/${encodeURIComponent(name)}`),
  serviceHistory: (name) => request('GET', `/api/services/${encodeURIComponent(name)}/history`),
  createService: (name) => request('POST', '/api/services', { name }),
  reloadServices: () => request('POST', '/api/services/reload'),
  updateService: (name, payload) =>
    request('PUT', `/api/services/${encodeURIComponent(name)}`, payload),
  reloadService: (name) =>
    request('POST', `/api/services/${encodeURIComponent(name)}/reload`),
  createTask: (payload) => request('POST', '/api/tasks', payload),
  tasks: (limit = 100) => request('GET', `/api/tasks?limit=${limit}`),
  task: (id) => request('GET', `/api/tasks/${id}`),
  instances: () => request('GET', '/api/instances'),
  archives: (service, node) =>
    request('GET', `/api/logs/services/${encodeURIComponent(service)}/nodes/${encodeURIComponent(node)}/archives`),
}

// 读取日志快照（纯文本响应，不能走 JSON request）
export async function fetchLogText(service, node, runId = 'latest', tail = 200) {
  const url = `/api/logs/services/${encodeURIComponent(service)}/nodes/${encodeURIComponent(node)}/content`
    + `?run_id=${encodeURIComponent(runId)}&tail=${tail}`
  const res = await fetchWithTimeout(url, {}, 60000)
  if (!res.ok) {
    let detail = ''
    try { detail = (await res.json()).detail } catch { /* 非 JSON */ }
    throw new Error(detail || `HTTP ${res.status}`)
  }
  return res.text()
}

export const ACTION_TEXT = {
  deploy: '部署', create: '创建', start: '启动', stop: '停止', restart: '重启',
  delete: '删除', clean: '清理',
}

const dtf = new Intl.DateTimeFormat('zh-CN', {
  year: 'numeric', month: '2-digit', day: '2-digit',
  hour: '2-digit', minute: '2-digit', second: '2-digit', hour12: false,
})
const rtf = new Intl.RelativeTimeFormat('zh-CN', { numeric: 'auto' })

export function fmtTime(ts) {
  if (!ts) return '-'
  return dtf.format(new Date(ts * 1000))
}

// 相对时间：1 分钟内精确到秒，1 小时内到分，24 小时内到小时，更早显示绝对时间。
export function fmtTimeRel(ts) {
  if (!ts) return '-'
  const diff = (ts * 1000 - Date.now()) / 1000
  const abs = Math.abs(diff)
  if (abs < 60) return rtf.format(Math.round(diff), 'second')
  if (abs < 3600) return rtf.format(Math.round(diff / 60), 'minute')
  if (abs < 86400) return rtf.format(Math.round(diff / 3600), 'hour')
  return fmtTime(ts)
}

export function fmtDuration(a, b) {
  if (!a || !b) return '-'
  const s = Math.max(0, Math.round(b - a))
  if (s < 1) return '<1 秒'
  if (s < 60) return `${s} 秒`
  const m = Math.floor(s / 60)
  if (m < 60) return `${m} 分 ${s % 60} 秒`
  return `${Math.floor(m / 60)} 时 ${m % 60} 分`
}
