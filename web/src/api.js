async function request(method, url, body) {
  const res = await fetch(url, {
    method,
    headers: { 'Content-Type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  })
  if (!res.ok) {
    let detail = ''
    try { detail = (await res.json()).detail } catch { /* ignore */ }
    throw new Error(detail || `HTTP ${res.status}`)
  }
  return res.json()
}

export const api = {
  nodes: () => request('GET', '/api/cluster/nodes'),
  testNode: (name) => request('POST', `/api/cluster/nodes/${encodeURIComponent(name)}/test`),
  reloadConfig: () => request('POST', '/api/cluster/reload'),
  services: () => request('GET', '/api/services'),
  service: (name) => request('GET', `/api/services/${encodeURIComponent(name)}`),
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

export const ACTION_TEXT = { deploy: '部署', start: '启动', stop: '停止', restart: '重启' }

export function fmtTime(ts) {
  if (!ts) return '-'
  return new Date(ts * 1000).toLocaleString('zh-CN', { hour12: false })
}

export function fmtDuration(a, b) {
  if (!a || !b) return '-'
  const s = Math.max(0, Math.round(b - a))
  return s < 60 ? `${s}s` : `${Math.floor(s / 60)}m${s % 60}s`
}

export function fmtSize(n) {
  if (n == null) return '-'
  if (n < 1024) return `${n} B`
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} KB`
  return `${(n / 1024 / 1024).toFixed(1)} MB`
}
