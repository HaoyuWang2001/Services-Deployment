<template>
  <div class="logs-page">
    <el-tabs v-if="tabs.length" v-model="activeTabId" type="card" closable addable
             class="tabs" @tab-add="newTab({})" @tab-remove="(id) => closeTab(id)">
      <el-tab-pane v-for="tab in tabs" :key="tab.id" :name="String(tab.id)" :label="tabTitle(tab)">
        <div class="ctrl-row">
          <div class="ctrl-item">
            <span class="label">服务</span>
            <el-select v-model="tab.service" filterable placeholder="选择服务" size="small" style="width: 180px" @change="onServiceChange(tab)">
              <el-option v-for="s in services" :key="s" :label="s" :value="s" />
            </el-select>
          </div>
          <div class="ctrl-item">
            <span class="label">节点</span>
            <el-select v-model="tab.nodeSel" multiple filterable placeholder="可多选合并" size="small" style="width: 260px" @change="loadRuns(tab)">
              <el-option v-for="n in nodes" :key="n" :label="n" :value="n" />
            </el-select>
          </div>
          <div class="ctrl-item">
            <span class="label">运行批次</span>
            <el-select v-model="tab.runId" size="small" style="width: 180px" :loading="tab.runsLoading">
              <el-option label="最新(latest)" value="latest" />
              <el-option v-for="r in tab.runOptions" :key="r" :label="r" :value="r" />
            </el-select>
          </div>
          <div class="ctrl-item">
            <span class="label">尾部行数</span>
            <el-input-number v-model="tab.tail" :min="10" :max="10000" :step="50" size="small" style="width: 110px" />
          </div>
          <div class="ctrl-actions">
            <el-button size="small" :type="tab.connected ? 'danger' : 'primary'" @click="toggle(tab)">
              {{ tab.connected ? '断开' : '连接' }}
            </el-button>
            <el-button size="small" @click="tab.lines = []">清屏</el-button>
            <el-button size="small" :disabled="!tab.service || !tab.nodeSel.length" @click="download(tab)">下载快照</el-button>
            <el-switch v-model="tab.autoscroll" size="small" active-text="自动滚动" />
          </div>
        </div>

        <div class="terminal" :ref="(el) => setTerm(tab.id, el)">
          <div v-for="(l, i) in tab.lines" :key="i" class="line" :class="l.kind">
            <span v-if="l.kind === 'line'" class="node-tag" :style="{ color: nodeColor(l.node) }">[{{ l.node }}]</span>
            <span class="text">{{ l.text }}</span>
          </div>
          <div v-if="!tab.lines.length" class="empty">选择服务与节点后点击「连接」，实时日志将在此滚动显示（tail -F）</div>
        </div>
      </el-tab-pane>
    </el-tabs>

    <div v-else class="empty-page">
      <el-empty description="暂无日志标签，点击下方按钮新建">
        <el-button type="primary" @click="newTab({})">新建日志标签</el-button>
      </el-empty>
    </div>
  </div>
</template>

<script setup>
import { nextTick, onMounted, onUnmounted, reactive, ref, watch } from 'vue'
import { ElMessage } from 'element-plus'
import { useRoute } from 'vue-router'
import { api } from '../api'

const route = useRoute()
const services = ref([])
const nodes = ref([])
const tabs = reactive([])
const activeTabId = ref('')
let tabSeq = 0
let lastQueryKey = ''

const PALETTE = ['#67c23a', '#e6a23c', '#409eff', '#f56c6c', '#b37feb', '#36cfc9', '#ffd666', '#ff9c6e']
const colorMap = reactive({})
let colorSeq = 0
function nodeColor(n) {
  if (!colorMap[n]) colorMap[n] = PALETTE[colorSeq++ % PALETTE.length]
  return colorMap[n]
}

const terms = new Map()
function setTerm(id, el) {
  if (el) terms.set(id, el)
  else terms.delete(id)
}

function tabTitle(tab) {
  return `${tab.service || '?'} @ ${tab.nodeSel.length ? tab.nodeSel.join(',') : '-'}`
}

function push(tab, kind, node, text) {
  tab.lines.push({ kind, node, text })
  if (tab.lines.length > 8000) tab.lines.splice(0, tab.lines.length - 8000)
  if (tab.autoscroll && String(tab.id) === activeTabId.value) scrollTerm(tab)
}

function scrollTerm(tab) {
  nextTick(() => {
    const el = terms.get(tab.id)
    if (el) el.scrollTop = el.scrollHeight
  })
}

// ---------------------------------------------------------------- 标签管理
function newTab(preset = {}, autoConnect = false) {
  tabSeq += 1
  const tab = reactive({
    id: tabSeq,
    service: preset.service || services.value[0] || '',
    nodeSel: preset.nodes || [],
    runId: preset.runId || 'latest',
    tail: 100,
    autoscroll: true,
    lines: [],
    connected: false,
    ws: null,
    runOptions: [],
    runsLoading: false,
  })
  tabs.push(tab)
  activeTabId.value = String(tab.id)
  if (tab.nodeSel.length) loadRuns(tab)
  if (autoConnect) nextTick(() => connect(tab))
  return tab
}

function closeTab(id) {
  const tab = tabs.find((t) => String(t.id) === String(id))
  if (!tab) return
  disconnectWs(tab)
  const idx = tabs.indexOf(tab)
  tabs.splice(idx, 1)
  terms.delete(tab.id)
  if (activeTabId.value === String(id) && tabs.length) {
    activeTabId.value = String(tabs[Math.max(0, idx - 1)].id)
  }
}

// ---------------------------------------------------------------- 运行批次
async function loadRuns(tab) {
  if (!tab.service || !tab.nodeSel.length) { tab.runOptions = []; return }
  tab.runsLoading = true
  try {
    const all = await Promise.all(
      tab.nodeSel.map((n) => api.archives(tab.service, n).catch(() => null)))
    const union = new Set()
    for (const a of all) if (a?.archives) Object.keys(a.archives).forEach((r) => union.add(r))
    tab.runOptions = [...union].sort().reverse()
  } finally {
    tab.runsLoading = false
  }
}

function onServiceChange(tab) {
  tab.runId = 'latest'
  loadRuns(tab)
}

// ---------------------------------------------------------------- WS 连接
function disconnectWs(tab) {
  if (tab.ws) {
    tab.ws.onclose = null
    tab.ws.close()
    tab.ws = null
  }
  tab.connected = false
}

function toggle(tab) {
  if (tab.connected) {
    disconnectWs(tab)
    push(tab, 'notice', '', '已断开连接')
  } else {
    connect(tab)
  }
}

function connect(tab) {
  if (!tab.service || !tab.nodeSel.length) {
    ElMessage.warning('请先选择服务与节点')
    return
  }
  disconnectWs(tab)
  const proto = location.protocol === 'https:' ? 'wss' : 'ws'
  const params = new URLSearchParams({
    service: tab.service,
    nodes: tab.nodeSel.join(','),
    run_id: tab.runId || 'latest',
    tail: String(tab.tail),
  })
  push(tab, 'notice', '', `连接 ${tab.service} @ ${tab.nodeSel.join(', ')}（run_id=${tab.runId || 'latest'}）...`)
  tab.ws = new WebSocket(`${proto}://${location.host}/api/logs/ws/logs?${params}`)
  tab.ws.onopen = () => { tab.connected = true }
  tab.ws.onmessage = (ev) => {
    try {
      const m = JSON.parse(ev.data)
      if (m.type === 'line') push(tab, 'line', m.node, m.data)
      else if (m.type === 'meta') push(tab, 'notice', m.node, `● 已连接 ${m.node} 的日志流（run_id=${m.run_id}，文件 ${m.file}）`)
      else if (m.type === 'error') push(tab, 'error', m.node, `✖ ${m.node}: ${m.message}`)
      else if (m.type === 'ended') push(tab, 'notice', m.node, `○ ${m.node}: ${m.message}`)
    } catch { /* ignore */ }
  }
  tab.ws.onclose = () => {
    tab.connected = false
    push(tab, 'notice', '', '连接已关闭')
  }
  tab.ws.onerror = () => push(tab, 'error', '', 'WebSocket 错误')
}

function download(tab) {
  const url = `/api/logs/services/${encodeURIComponent(tab.service)}/nodes/${encodeURIComponent(tab.nodeSel[0])}/content`
    + `?run_id=${encodeURIComponent(tab.runId || 'latest')}&download=1`
  window.open(url, '_blank')
}

// ---------------------------------------------------------------- 路由进入
function handleQuery() {
  const q = route.query
  if (!q.service) return
  const nodesArr = String(q.node || '').split(',').filter((n) => n && nodes.value.includes(n))
  const runId = q.run_id ? String(q.run_id) : 'latest'
  const key = `${q.service}|${[...nodesArr].sort().join(',')}|${runId}`
  if (key === lastQueryKey) return
  lastQueryKey = key
  const existing = tabs.find((t) =>
    t.service === q.service && t.runId === runId &&
    [...t.nodeSel].sort().join(',') === [...nodesArr].sort().join(','))
  if (existing) {
    activeTabId.value = String(existing.id)
    if (q.connect === '1' && !existing.connected) connect(existing)
  } else {
    newTab({ service: String(q.service), nodes: nodesArr, runId }, q.connect === '1')
  }
}

watch(() => route.query, () => { if (route.path === '/logs') handleQuery() })
watch(activeTabId, () => {
  const tab = tabs.find((t) => String(t.id) === activeTabId.value)
  if (tab && tab.autoscroll) scrollTerm(tab)
})

onMounted(async () => {
  try {
    const [svcData, nodeData] = await Promise.all([api.services(), api.nodes()])
    services.value = svcData.services.map((s) => s.name)
    nodes.value = nodeData.nodes.map((n) => n.name)
  } catch (e) {
    ElMessage.error(`加载失败: ${e.message}`)
    return
  }
  handleQuery()
})
onUnmounted(() => tabs.forEach(disconnectWs))
</script>

<style scoped>
.logs-page { display: flex; flex-direction: column; height: 100%; }
.tabs { display: flex; flex-direction: column; height: 100%; }
.tabs :deep(.el-tabs__content) { flex: 1; overflow: hidden; }
.tabs :deep(.el-tab-pane) { height: 100%; display: flex; flex-direction: column; gap: 10px; }
.ctrl-row { display: flex; flex-wrap: wrap; align-items: center; gap: 14px; flex-shrink: 0; }
.ctrl-item { display: flex; align-items: center; gap: 6px; }
.ctrl-actions { display: flex; align-items: center; gap: 8px; margin-left: auto; }
.label { color: var(--el-text-color-secondary); font-size: 13px; }
.terminal {
  flex: 1;
  background: #1e1e2e;
  color: #cdd6f4;
  border-radius: 8px;
  padding: 12px 16px;
  font-family: 'Cascadia Code', Consolas, 'Courier New', monospace;
  font-size: 13px;
  line-height: 1.6;
  overflow: auto;
  min-height: 260px;
}
.line { white-space: pre-wrap; word-break: break-all; }
.line.error { color: #f38ba8; }
.line.notice { color: #6c7086; font-style: italic; }
.node-tag { margin-right: 8px; font-weight: 600; }
.empty { color: #6c7086; padding: 40px 0; text-align: center; }
.empty-page { display: flex; align-items: center; justify-content: center; height: 100%; }
</style>
