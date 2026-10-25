<template>
  <div class="logs-page">
    <el-card shadow="never" class="ctrl">
      <div class="ctrl-row">
        <div class="ctrl-item">
          <span class="label">服务</span>
          <el-select v-model="service" filterable placeholder="选择服务" style="width: 200px" @change="onServiceChange">
            <el-option v-for="s in services" :key="s" :label="s" :value="s" />
          </el-select>
        </div>
        <div class="ctrl-item">
          <span class="label">节点</span>
          <el-select v-model="nodeSel" multiple filterable placeholder="选择节点（可多选合并）" style="width: 300px" @change="loadRunOptions">
            <el-option v-for="n in nodes" :key="n" :label="n" :value="n" />
          </el-select>
        </div>
        <div class="ctrl-item">
          <span class="label">运行批次</span>
          <el-select v-model="runId" style="width: 200px" :loading="runsLoading">
            <el-option label="最新(latest)" value="latest" />
            <el-option v-for="r in runOptions" :key="r" :label="r" :value="r" />
          </el-select>
        </div>
        <div class="ctrl-item">
          <span class="label">尾部行数</span>
          <el-input-number v-model="tail" :min="10" :max="10000" :step="50" style="width: 120px" />
        </div>
        <div class="ctrl-actions">
          <el-button :type="connected ? 'danger' : 'primary'" @click="toggle">
            {{ connected ? '断开' : '连接' }}
          </el-button>
          <el-button @click="lines = []">清屏</el-button>
          <el-button @click="download" :disabled="!service || !nodeSel.length">下载快照</el-button>
          <el-switch v-model="autoscroll" active-text="自动滚动" />
        </div>
      </div>
    </el-card>

    <div class="terminal" ref="term">
      <div v-for="(l, i) in lines" :key="i" class="line" :class="l.kind">
        <span v-if="l.kind === 'line'" class="node-tag" :style="{ color: nodeColor(l.node) }">[{{ l.node }}]</span>
        <span class="text">{{ l.text }}</span>
      </div>
      <div v-if="!lines.length" class="empty">选择服务与节点后点击「连接」，实时日志将在此滚动显示（tail -F）</div>
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
const nodeSel = ref([])
const service = ref('')
const runId = ref('latest')
const runOptions = ref([])
const runsLoading = ref(false)
const tail = ref(100)
const lines = reactive([])
const connected = ref(false)
const autoscroll = ref(true)
const term = ref(null)
let ws = null

const PALETTE = ['#67c23a', '#e6a23c', '#409eff', '#f56c6c', '#b37feb', '#36cfc9', '#ffd666', '#ff9c6e']
const colorMap = reactive({})
let colorSeq = 0
function nodeColor(n) {
  if (!colorMap[n]) colorMap[n] = PALETTE[colorSeq++ % PALETTE.length]
  return colorMap[n]
}

function push(kind, node, text) {
  lines.push({ kind, node, text })
  if (lines.length > 8000) lines.splice(0, lines.length - 8000)
  if (autoscroll.value) nextTick(() => { if (term.value) term.value.scrollTop = term.value.scrollHeight })
}

async function loadBase() {
  try {
    const [svcData, nodeData] = await Promise.all([api.services(), api.nodes()])
    services.value = svcData.services.map((s) => s.name)
    nodes.value = nodeData.nodes.map((n) => n.name)
    const q = route.query
    if (q.service && services.value.includes(q.service)) service.value = q.service
    else if (services.value.length) service.value = services.value[0]
    if (q.node) {
      const arr = String(q.node).split(',').filter((n) => nodes.value.includes(n))
      nodeSel.value = arr
    }
    if (q.run_id) runId.value = String(q.run_id)
    await loadRunOptions()
  } catch (e) {
    ElMessage.error(`加载失败: ${e.message}`)
  }
}

async function loadRunOptions() {
  if (!service.value || !nodeSel.value.length) { runOptions.value = []; return }
  runsLoading.value = true
  try {
    const all = await Promise.all(nodeSel.value.map((n) => api.archives(service.value, n).catch(() => null)))
    const union = new Set()
    for (const a of all) if (a?.archives) Object.keys(a.archives).forEach((r) => union.add(r))
    runOptions.value = [...union].sort().reverse()
  } finally {
    runsLoading.value = false
  }
}

function onServiceChange() { runId.value = 'latest'; loadRunOptions() }

function closeWs() {
  if (ws) { ws.onclose = null; ws.close(); ws = null }
  connected.value = false
}

function toggle() {
  if (connected.value) { closeWs(); push('notice', '', '已断开连接'); return }
  if (!service.value || !nodeSel.value.length) {
    ElMessage.warning('请先选择服务与节点')
    return
  }
  const proto = location.protocol === 'https:' ? 'wss' : 'ws'
  const params = new URLSearchParams({
    service: service.value,
    nodes: nodeSel.value.join(','),
    run_id: runId.value || 'latest',
    tail: String(tail.value),
  })
  push('notice', '', `连接 ${service.value} @ ${nodeSel.value.join(', ')} (run_id=${runId.value}) ...`)
  ws = new WebSocket(`${proto}://${location.host}/api/logs/ws/logs?${params}`)
  ws.onopen = () => { connected.value = true }
  ws.onmessage = (ev) => {
    try {
      const m = JSON.parse(ev.data)
      if (m.type === 'line') push('line', m.node, m.data)
      else if (m.type === 'meta') push('notice', m.node, `● 已连接 ${m.node} 的日志流（run_id=${m.run_id}，文件 ${m.file}）`)
      else if (m.type === 'error') push('error', m.node, `✖ ${m.node}: ${m.message}`)
      else if (m.type === 'ended') push('notice', m.node, `○ ${m.node}: ${m.message}`)
    } catch { /* ignore */ }
  }
  ws.onclose = () => {
    connected.value = false
    push('notice', '', '连接已关闭')
  }
  ws.onerror = () => push('error', '', 'WebSocket 错误')
}

function download() {
  const url = `/api/logs/services/${encodeURIComponent(service.value)}/nodes/${encodeURIComponent(nodeSel.value[0])}/content`
    + `?run_id=${encodeURIComponent(runId.value || 'latest')}&download=1`
  window.open(url, '_blank')
}

watch(nodeSel, () => loadRunOptions())
onMounted(loadBase)
onUnmounted(closeWs)
</script>

<style scoped>
.logs-page { display: flex; flex-direction: column; height: 100%; gap: 12px; }
.ctrl :deep(.el-card__body) { padding: 14px 16px; }
.ctrl-row { display: flex; flex-wrap: wrap; align-items: center; gap: 16px; }
.ctrl-item { display: flex; align-items: center; gap: 8px; }
.ctrl-actions { display: flex; align-items: center; gap: 10px; margin-left: auto; }
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
  min-height: 300px;
}
.line { white-space: pre-wrap; word-break: break-all; }
.line.error { color: #f38ba8; }
.line.notice { color: #6c7086; font-style: italic; }
.node-tag { margin-right: 8px; font-weight: 600; }
.empty { color: #6c7086; padding: 40px 0; text-align: center; }
</style>
