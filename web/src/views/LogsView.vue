<template>
  <div class="logs-page">
    <el-tabs v-if="tabs.length" v-model="activeTabId" type="card" closable addable
             class="tabs" @tab-add="newTab({})" @tab-remove="(id) => closeTab(id)">
      <el-tab-pane v-for="tab in tabs" :key="tab.id" :name="String(tab.id)" :label="tabTitle(tab)" lazy>
        <div class="ctrl-row">
          <div class="ctrl-item">
            <span class="sd-label">服务</span>
            <el-select v-model="tab.service" filterable placeholder="选择服务" size="small" style="width: 170px" @change="onServiceChange(tab)">
              <el-option v-for="s in services" :key="s" :label="s" :value="s" />
            </el-select>
          </div>
          <div class="ctrl-item">
            <span class="sd-label">节点</span>
            <el-select v-model="tab.nodeSel" multiple filterable placeholder="可多选合并" size="small" style="width: 240px" @change="loadRuns(tab)">
              <el-option v-for="n in nodes" :key="n" :label="n" :value="n" />
            </el-select>
          </div>
          <div class="ctrl-item">
            <span class="sd-label">运行批次</span>
            <el-select v-model="tab.runId" size="small" style="width: 170px" :loading="tab.runsLoading">
              <el-option label="最新（latest）" value="latest" />
              <el-option v-for="r in tab.runOptions" :key="r" :label="r" :value="r" />
            </el-select>
          </div>
          <div class="ctrl-item">
            <span class="sd-label">尾部行数</span>
            <el-input-number v-model="tab.tail" :min="10" :max="10000" :step="50" size="small" style="width: 105px" />
          </div>
          <div class="ctrl-actions">
            <el-button size="small" :type="tab.connected ? 'default' : 'primary'" @click="toggle(tab)">
              {{ tab.connected ? '断开' : '连接' }}
            </el-button>
            <el-button size="small" @click="clearTab(tab)">清屏</el-button>
            <el-button size="small" :disabled="!tab.service || !tab.nodeSel.length" @click="download(tab)">下载快照</el-button>
            <el-switch v-model="tab.autoscroll" size="small" active-text="自动滚动" />
            <el-switch v-model="tab.autoReconnect" size="small" active-text="自动重连" />
            <el-switch v-model="tab.wrapLines" size="small" active-text="换行" />
          </div>
        </div>

        <div class="search-row">
          <el-input :model-value="tab.searchInput" size="small" clearable class="search-input"
                    placeholder="搜索当前日志（忽略大小写，Enter 下一个）"
                    @update:model-value="(v) => onSearchInput(tab, v)"
                    @keydown.enter.prevent="jumpMatch(tab, $event.shiftKey ? -1 : 1)"
                    @keydown.esc.prevent="clearSearch(tab)" />
          <span class="match-count sd-num">{{ matchCountText(tab) }}</span>
          <el-button size="small" :disabled="!matchInfo(tab).list.length" @click="jumpMatch(tab, 'first')">首个</el-button>
          <el-button size="small" :disabled="!matchInfo(tab).list.length" @click="jumpMatch(tab, -1)">上一个</el-button>
          <el-button size="small" :disabled="!matchInfo(tab).list.length" @click="jumpMatch(tab, 1)">下一个</el-button>
          <el-button size="small" :disabled="!matchInfo(tab).list.length" @click="jumpMatch(tab, 'last')">最后一个</el-button>
          <el-switch v-model="tab.filterOnly" size="small" active-text="仅显示匹配行" :disabled="!matchInfo(tab).kw" />
          <span v-if="tab.gaveUp" class="reconnect-hint gave-up">服务不可达，已暂停自动重连</span>
          <span v-else-if="tab.reconnecting" class="reconnect-hint">自动重连中（第 {{ tab.reconnectAttempts }} 次）</span>
        </div>

        <div class="sd-term logs-term" :class="{ 'no-wrap': !tab.wrapLines }" :ref="(el) => setTerm(tab.id, el)">
          <div v-for="item in displayLines(tab)" :key="item.srcIdx" class="line"
               :class="[item.kind, { 'cur-match': isCurrentMatch(tab, item.srcIdx) }]"
               :data-line="item.srcIdx">
            <span v-if="item.kind === 'line'" class="node-tag" :style="{ color: nodeColor(item.node) }">[{{ item.node }}]</span>
            <span class="text">
              <template v-for="(seg, i) in segments(tab, item)" :key="i">
                <mark v-if="seg.hit" class="hit">{{ seg.t }}</mark>
                <template v-else>{{ seg.t }}</template>
              </template>
            </span>
          </div>
          <div v-if="!tab.lines.length" class="empty">选择服务与节点后点击「连接」，实时日志将在此滚动显示（tail -F）</div>
        </div>
      </el-tab-pane>
    </el-tabs>

    <div v-else class="empty-page">
      <el-empty description="暂无日志标签，新建一个标签开始查看">
        <el-button type="primary" @click="newTab({})">新建日志标签</el-button>
      </el-empty>
    </div>
  </div>
</template>

<script setup>
import { computed, nextTick, onActivated, onMounted, onUnmounted, reactive, ref, watch } from 'vue'
import { ElMessage, ElMessageBox } from 'element-plus'
import { useRoute } from 'vue-router'
import { api, fetchLogText } from '../api'
import { nodeColor } from '../ui/nodeColors'

const route = useRoute()
const services = ref([])
const nodes = ref([])
const tabs = reactive([])
const activeTabId = ref('')
let tabSeq = 0

const terms = new Map()
function setTerm(id, el) {
  if (el) terms.set(id, el)
  else terms.delete(id)
}

function tabTitle(tab) {
  const ns = tab.nodeSel
  const shown = ns.length > 2 ? `${ns.slice(0, 2).join(',')} 等 ${ns.length} 个` : ns.join(',')
  return `${tab.service || '？'} @ ${shown || '-'}`
}

function push(tab, kind, node, text) {
  tab.lines.push({ kind, node, text })
  if (tab.lines.length > 8000) tab.lines.splice(0, tab.lines.length - 8000)
  if (tab.autoscroll && String(tab.id) === activeTabId.value) scrollTerm(tab)
}

function scrollTerm(tab) {
  nextTick(() => {
    const el = terms.get(tab.id)
    // 页面被 KeepAlive 隐藏时（display:none）scrollHeight 为 0，
    // 写入 scrollTop 会把位置重置为顶部，必须跳过，等待 onActivated 再滚
    if (el && el.clientHeight > 0) el.scrollTop = el.scrollHeight
  })
}

async function clearTab(tab) {
  if (!tab.lines.length) return
  try {
    await ElMessageBox.confirm('清屏只清除当前浏览器缓冲区，不影响节点上的日志文件。继续？', '清屏确认',
      { type: 'warning', confirmButtonText: '清屏', cancelButtonText: '取消' })
  } catch { return }
  tab.lines = []
}

// ---------------------------------------------------------------- 搜索 ----
const searchIndex = computed(() => {
  const out = new Map()
  for (const tab of tabs) {
    const kw = (tab.search || '').trim().toLowerCase()
    const list = []
    const set = new Set()
    if (kw) {
      tab.lines.forEach((l, i) => {
        if (l.text.toLowerCase().includes(kw)) {
          list.push(i)
          set.add(i)
        }
      })
    }
    out.set(tab.id, { kw, list, set })
  }
  return out
})

function matchInfo(tab) {
  return searchIndex.value.get(tab.id) || { kw: '', list: [], set: new Set() }
}

function curIdx(tab) {
  const { list } = matchInfo(tab)
  return list.length ? Math.min(Math.max(tab.matchIdx, 0), list.length - 1) : -1
}

function matchCountText(tab) {
  const { kw, list } = matchInfo(tab)
  if (!kw) return ''
  const n = list.length ? curIdx(tab) + 1 : 0
  return `${n}/${list.length}`
}

const searchTimers = new Map()
function onSearchInput(tab, v) {
  tab.searchInput = v
  clearTimeout(searchTimers.get(tab.id))
  searchTimers.set(tab.id, setTimeout(() => { tab.search = v }, 150))
}

function clearSearch(tab) {
  clearTimeout(searchTimers.get(tab.id))
  tab.searchInput = ''
  tab.search = ''
}

function flushSearch(tab) {
  if (tab.searchInput !== tab.search) {
    clearTimeout(searchTimers.get(tab.id))
    tab.search = tab.searchInput
  }
}

function displayLines(tab) {
  const { kw, set } = matchInfo(tab)
  const arr = tab.lines.map((l, i) => ({ ...l, srcIdx: i }))
  if (kw && tab.filterOnly) return arr.filter((x) => set.has(x.srcIdx))
  return arr
}

function isCurrentMatch(tab, srcIdx) {
  const { kw, list } = matchInfo(tab)
  return !!kw && list[curIdx(tab)] === srcIdx
}

function segments(tab, item) {
  const { kw } = matchInfo(tab)
  if (!kw) return [{ t: item.text, hit: false }]
  const text = item.text
  const lower = text.toLowerCase()
  const out = []
  let pos = 0
  while (true) {
    const idx = lower.indexOf(kw, pos)
    if (idx === -1) break
    if (idx > pos) out.push({ t: text.slice(pos, idx), hit: false })
    out.push({ t: text.slice(idx, idx + kw.length), hit: true })
    pos = idx + kw.length
  }
  if (pos < text.length) out.push({ t: text.slice(pos), hit: false })
  return out.length ? out : [{ t: '', hit: false }]
}

function jumpMatch(tab, dir) {
  flushSearch(tab)
  const { list } = matchInfo(tab)
  if (!list.length) return
  let idx = curIdx(tab)
  if (dir === 'first') idx = 0
  else if (dir === 'last') idx = list.length - 1
  else idx = (idx + dir + list.length) % list.length
  tab.matchIdx = idx
  tab.autoscroll = false
  const srcIdx = list[idx]
  nextTick(() => {
    const el = terms.get(tab.id)?.querySelector(`[data-line="${srcIdx}"]`)
    if (el) el.scrollIntoView({ block: 'center' })
  })
}

// ---------------------------------------------------------------- 标签管理 ----
function newTab(preset = {}, autoConnect = false) {
  tabSeq += 1
  const tab = reactive({
    id: tabSeq,
    service: preset.service || services.value[0] || '',
    nodeSel: preset.nodes || [],
    runId: preset.runId || 'latest',
    tail: preset.tail || 100,
    autoscroll: preset.autoscroll ?? true,
    autoReconnect: preset.autoReconnect ?? true,
    wrapLines: preset.wrapLines ?? true,
    manualStop: false,
    reconnecting: false,
    reconnectAttempts: 0,
    failedStreak: 0,     // 连续“建连失败”次数（onopen 从未触发）
    gaveUp: false,       // 连续失败达上限后暂停自动重连
    reconnectTimer: null,
    searchInput: '',
    search: '',
    filterOnly: false,
    matchIdx: 0,
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
  clearTimeout(tab.reconnectTimer)
  clearTimeout(searchTimers.get(tab.id))
  searchTimers.delete(tab.id)
  disconnectWs(tab)
  const idx = tabs.indexOf(tab)
  tabs.splice(idx, 1)
  terms.delete(tab.id)
  if (activeTabId.value === String(id) && tabs.length) {
    activeTabId.value = String(tabs[Math.max(0, idx - 1)].id)
  }
}

// ---------------------------------------------------------------- 运行批次 ----
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

// ---------------------------------------------------------------- WS 连接 ----
function disconnectWs(tab) {
  if (tab.ws) {
    tab.ws.onclose = null
    tab.ws.close()
    tab.ws = null
  }
  tab.connected = false
}

function scheduleReconnect(tab) {
  if (!tab.autoReconnect || tab.manualStop || tab.gaveUp) return
  if (!tabs.includes(tab) || tab.reconnectTimer) return
  tab.reconnecting = true
  tab.reconnectAttempts += 1
  push(tab, 'notice', '', `3 秒后自动重连（第 ${tab.reconnectAttempts} 次）…`)
  tab.reconnectTimer = setTimeout(() => {
    tab.reconnectTimer = null
    if (tabs.includes(tab) && !tab.manualStop) connect(tab)
  }, 3000)
}

const MAX_FAILED_STREAK = 5

function toggle(tab) {
  if (tab.connected) {
    tab.manualStop = true
    clearTimeout(tab.reconnectTimer)
    tab.reconnectTimer = null
    tab.reconnecting = false
    disconnectWs(tab)
    push(tab, 'notice', '', '已断开连接')
  } else {
    // 手动重试：重置失败计数与放弃状态
    tab.failedStreak = 0
    tab.gaveUp = false
    connect(tab)
  }
}

function connect(tab) {
  if (!tab.service || !tab.nodeSel.length) {
    ElMessage.warning('请先选择服务与节点')
    return
  }
  tab.manualStop = false
  clearTimeout(tab.reconnectTimer)
  tab.reconnectTimer = null
  disconnectWs(tab)
  const proto = location.protocol === 'https:' ? 'wss' : 'ws'
  const params = new URLSearchParams({
    service: tab.service,
    nodes: tab.nodeSel.join(','),
    run_id: tab.runId || 'latest',
    tail: String(tab.tail),
  })
  push(tab, 'notice', '', `连接 ${tab.service} @ ${tab.nodeSel.join('、')}（run_id=${tab.runId || 'latest'}）…`)
  tab.ws = new WebSocket(`${proto}://${location.host}/api/logs/ws/logs?${params}`)
  let opened = false
  tab.ws.onopen = () => {
    opened = true
    tab.connected = true
    tab.reconnecting = false
    tab.reconnectAttempts = 0
    tab.failedStreak = 0
  }
  tab.ws.onmessage = (ev) => {
    try {
      const m = JSON.parse(ev.data)
      if (m.type === 'line') push(tab, 'line', m.node, m.data)
      else if (m.type === 'meta') push(tab, 'notice', m.node, `已连接 ${m.node} 的日志流（run_id=${m.run_id}，文件 ${m.file}）`)
      else if (m.type === 'error') {
        push(tab, 'error', m.node, `${m.node}：${m.message}`)
        scheduleReconnect(tab)
      } else if (m.type === 'ended') {
        push(tab, 'notice', m.node, `${m.node}：${m.message}`)
        scheduleReconnect(tab)
      }
    } catch { /* ignore */ }
  }
  tab.ws.onclose = () => {
    tab.connected = false
    if (!opened) {
      // 建连失败（服务不可达）：连续达上限则暂停自动重连
      tab.failedStreak += 1
      if (tab.failedStreak >= MAX_FAILED_STREAK) {
        tab.reconnecting = false
        tab.gaveUp = true
        clearTimeout(tab.reconnectTimer)
        tab.reconnectTimer = null
        push(tab, 'error', '', `连续 ${MAX_FAILED_STREAK} 次无法连接服务，已暂停自动重连（点击「连接」手动重试）`)
        return
      }
    }
    push(tab, 'notice', '', '连接已关闭')
    scheduleReconnect(tab)
  }
  tab.ws.onerror = () => push(tab, 'error', '', 'WebSocket 错误')
}

// 下载快照：多节点合并导出（缓冲区优先；无缓冲时按节点拉取快照拼接）
async function download(tab) {
  let text
  if (tab.lines.length) {
    text = tab.lines
      .map((l) => (l.kind === 'line' ? `[${l.node}] ${l.text}` : l.text))
      .join('\n')
  } else {
    const parts = []
    for (const node of tab.nodeSel) {
      try {
        const content = await fetchLogText(tab.service, node, tab.runId || 'latest', tab.tail)
        parts.push(`===== ${node} =====\n${content}`)
      } catch (e) {
        parts.push(`===== ${node} =====\n（读取失败：${e.message}）`)
      }
    }
    text = parts.join('\n\n')
  }
  const blob = new Blob([text], { type: 'text/plain;charset=utf-8' })
  const url = URL.createObjectURL(blob)
  const a = document.createElement('a')
  const stamp = new Date().toISOString().slice(0, 19).replace(/[:T]/g, '-')
  a.href = url
  a.download = `${tab.service}-${tab.nodeSel.join('+')}-${tab.runId || 'latest'}-${stamp}.log`
  a.click()
  setTimeout(() => URL.revokeObjectURL(url), 1000)
}

// ------------------------------------------------------- 标签配置持久化 ----
const TABS_KEY = 'sd:log-tabs'

const tabsConfig = computed(() => tabs.map((t) => ({
  service: t.service,
  nodes: [...t.nodeSel],
  runId: t.runId,
  tail: t.tail,
  autoscroll: t.autoscroll,
  autoReconnect: t.autoReconnect,
  wrapLines: t.wrapLines,
})))

watch(tabsConfig, (config) => {
  try { localStorage.setItem(TABS_KEY, JSON.stringify(config)) } catch { /* ignore */ }
}, { deep: true })

function restoreTabs() {
  let saved
  try { saved = JSON.parse(localStorage.getItem(TABS_KEY) || '[]') } catch { return }
  if (!Array.isArray(saved) || !saved.length) return
  for (const t of saved) {
    if (!t || typeof t !== 'object') continue
    newTab({
      service: services.value.includes(t.service) ? t.service : '',
      nodes: Array.isArray(t.nodes) ? t.nodes.filter((n) => nodes.value.includes(n)) : [],
      runId: t.runId || 'latest',
      tail: t.tail,
      autoscroll: t.autoscroll,
      autoReconnect: t.autoReconnect,
      wrapLines: t.wrapLines,
    })
  }
}

// ---------------------------------------------------------------- 路由进入 ----
function handleQuery() {
  const q = route.query
  if (!q.service) return
  const nodesArr = String(q.node || '').split(',').filter((n) => n && nodes.value.includes(n))
  const runId = q.run_id ? String(q.run_id) : 'latest'
  // 幂等：已存在同会话标签 → 聚焦（必要时连接）；不存在（含刚被关闭）→ 新建
  const existing = tabs.find((t) =>
    t.service === q.service && t.runId === runId &&
    [...t.nodeSel].sort().join(',') === [...nodesArr].sort().join(','))
  if (existing) {
    activeTabId.value = String(existing.id)
    if (q.connect === '1' && !existing.connected) {
      existing.failedStreak = 0
      existing.gaveUp = false
      connect(existing)
    }
  } else {
    newTab({ service: String(q.service), nodes: nodesArr, runId }, q.connect === '1')
  }
}

watch(() => route.query, () => { if (route.path === '/logs') handleQuery() })
watch(activeTabId, () => {
  const tab = tabs.find((t) => String(t.id) === activeTabId.value)
  if (tab && tab.autoscroll) scrollTerm(tab)
})

// 返回日志页：自动滚动开 → 跳到底部（含离开期间积压的新行）；关 → 保留原位置
onActivated(() => {
  const tab = tabs.find((t) => String(t.id) === activeTabId.value)
  if (tab && tab.autoscroll) scrollTerm(tab)
})

onMounted(async () => {
  try {
    const [svcData, nodeData] = await Promise.all([api.services(), api.nodes()])
    services.value = svcData.services.map((s) => s.name)
    nodes.value = nodeData.nodes.map((n) => n.name)
  } catch (e) {
    ElMessage.error(`加载失败：${e.message}`)
    return
  }
  if (route.query.service) handleQuery()
  else restoreTabs()
})
onUnmounted(() => tabs.forEach((t) => {
  clearTimeout(t.reconnectTimer)
  clearTimeout(searchTimers.get(t.id))
  disconnectWs(t)
}))
</script>

<style scoped>
.logs-page { display: flex; flex-direction: column; height: 100%; }
.tabs { display: flex; flex-direction: column; height: 100%; }
.tabs :deep(.el-tabs__content) { flex: 1; overflow: hidden; }
.tabs :deep(.el-tab-pane) { height: 100%; display: flex; flex-direction: column; gap: var(--sd-space-2); }
.ctrl-row { display: flex; flex-wrap: wrap; align-items: center; gap: var(--sd-space-3); flex-shrink: 0; }
.ctrl-item { display: flex; align-items: center; gap: var(--sd-space-1); }
.ctrl-actions { display: flex; align-items: center; gap: var(--sd-space-2); margin-left: auto; }
.search-row {
  display: flex; flex-wrap: wrap; align-items: center; gap: var(--sd-space-2); flex-shrink: 0;
  background: var(--el-fill-color-light); border-radius: var(--sd-radius); padding: 6px 10px;
}
.search-input { width: 300px; }
.match-count { color: var(--el-text-color-secondary); font-size: 12px; min-width: 44px; text-align: center; font-family: var(--sd-font-mono); }
.reconnect-hint { margin-left: auto; color: var(--el-color-warning); font-size: 12px; }
.reconnect-hint.gave-up { color: var(--el-color-danger); }
.logs-term { flex: 1; min-height: 220px; }
.node-tag { margin-right: var(--sd-space-2); font-weight: 600; }
.empty-page { display: flex; align-items: center; justify-content: center; height: 100%; }
</style>
