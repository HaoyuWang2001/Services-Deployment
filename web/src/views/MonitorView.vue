<template>
  <div class="monitor-page">
    <el-card shadow="never" class="ctrl-card">
      <div class="ctrl-row">
        <el-select v-model="selectedId" placeholder="已保存监控项" size="small" style="width: 200px"
                   clearable @change="loadSaved">
          <el-option v-for="m in monitorsList" :key="m.id" :label="m.name" :value="m.id" />
        </el-select>
        <el-input v-model="cmd" size="small" style="flex: 1; min-width: 260px" clearable
                  placeholder="要执行的命令，如 df -h / free -m / nvidia-smi（回车开始）"
                  @keydown.enter.prevent="toggle" />
        <span class="label">间隔(s)</span>
        <el-input-number v-model="interval" :min="1" :max="60" size="small" style="width: 100px" />
        <el-select v-model="nodeSel" multiple filterable size="small" style="width: 240px" placeholder="节点（可多选）">
          <el-option v-for="n in nodes" :key="n" :label="n" :value="n" />
        </el-select>
        <el-button size="small" :type="connected ? 'danger' : 'primary'" @click="toggle">
          {{ connected ? '停止' : '开始' }}
        </el-button>
        <el-button size="small" @click="saveDialogVisible = true" :disabled="!cmd.trim()">保存为监控项</el-button>
        <el-button v-if="selectedId" size="small" type="warning" plain @click="updateSaved">更新当前项</el-button>
        <el-button v-if="selectedId" size="small" type="danger" plain @click="removeSaved">删除</el-button>
      </div>
    </el-card>

    <div v-if="!Object.keys(blocks).length" class="empty-block">
      <el-empty description="输入命令并选择节点后点击「开始」，输出将按固定间隔刷新（watch 语义，可回看历史帧）" />
    </div>

    <div v-for="(block, nodeName) in blocks" :key="nodeName" class="node-block">
      <div class="block-head">
        <span class="node-name" :style="{ color: nodeColor(nodeName) }">{{ nodeName }}</span>
        <span class="cmd-text">{{ block.cmd || cmd }}（{{ interval }}s）</span>
        <template v-if="currentFrame(block)">
          <span class="frame-time">{{ fmtTs(currentFrame(block).ts) }}</span>
          <el-tag v-if="currentFrame(block).error" type="danger" size="small">执行错误</el-tag>
          <el-tag v-else-if="currentFrame(block).exit_code === 0" type="success" size="small">exit 0</el-tag>
          <el-tag v-else type="danger" size="small">exit {{ currentFrame(block).exit_code }}</el-tag>
        </template>
        <span v-else-if="block.lastError" class="err-text">{{ block.lastError }}</span>
        <div class="frame-nav">
          <template v-if="block.frames.length">
            <el-button size="small" link :disabled="block.viewIdx === 0" @click="block.viewIdx = 0">«首帧</el-button>
            <el-button size="small" link :disabled="frameIdx(block) <= 0" @click="step(block, -1)">‹上一帧</el-button>
            <span class="frame-count">{{ frameIdx(block) + 1 }}/{{ block.frames.length }}</span>
            <el-button size="small" link :disabled="frameIdx(block) >= block.frames.length - 1" @click="step(block, 1)">下一帧›</el-button>
            <el-button size="small" link :disabled="block.viewIdx === null" @click="block.viewIdx = null">最新»</el-button>
            <el-tag v-if="newCount(block) > 0" size="small" type="warning">⟳ 有 {{ newCount(block) }} 帧新输出</el-tag>
          </template>
        </div>
      </div>
      <div class="terminal" :class="{ 'is-history': block.viewIdx !== null }">
        <template v-if="currentFrame(block)">
          <pre class="out">{{ currentFrame(block).stdout }}</pre>
          <pre v-if="currentFrame(block).stderr" class="err">{{ currentFrame(block).stderr }}</pre>
        </template>
        <div v-else class="waiting">等待首次采集...</div>
      </div>
    </div>

    <el-dialog v-model="saveDialogVisible" title="保存为监控项" width="440px">
      <el-form label-width="70px">
        <el-form-item label="名称">
          <el-input v-model="saveName" placeholder="如 磁盘使用率" maxlength="64" />
        </el-form-item>
      </el-form>
      <div class="save-hint">将保存当前命令与间隔（{{ cmd }} / {{ interval }}s），所有浏览器共享</div>
      <template #footer>
        <el-button @click="saveDialogVisible = false">取消</el-button>
        <el-button type="primary" @click="saveNew">保存</el-button>
      </template>
    </el-dialog>
  </div>
</template>

<script setup>
import { onMounted, onUnmounted, reactive, ref } from 'vue'
import { ElMessage, ElMessageBox } from 'element-plus'
import { api } from '../api'

const monitorsList = ref([])
const selectedId = ref('')
const cmd = ref('')
const interval = ref(2)
const nodes = ref([])
const nodeSel = ref([])
const connected = ref(false)
const saveDialogVisible = ref(false)
const saveName = ref('')
let ws = null

const blocks = reactive({})   // node -> {frames:[], viewIdx: null|number, cmd, lastError}

const PALETTE = ['#67c23a', '#e6a23c', '#409eff', '#f56c6c', '#b37feb', '#36cfc9']
const colorMap = reactive({})
let colorSeq = 0
function nodeColor(n) {
  if (!colorMap[n]) colorMap[n] = PALETTE[colorSeq++ % PALETTE.length]
  return colorMap[n]
}

function ensureBlock(node) {
  if (!blocks[node]) blocks[node] = { frames: [], viewIdx: null, cmd: '', lastError: '' }
  return blocks[node]
}

function frameIdx(block) {
  return block.viewIdx === null ? block.frames.length - 1 : block.viewIdx
}
function currentFrame(block) {
  return block.frames[frameIdx(block)] || null
}
function newCount(block) {
  if (block.viewIdx === null) return 0
  return block.frames.length - 1 - block.viewIdx
}
function step(block, dir) {
  const idx = frameIdx(block) + dir
  if (idx >= 0 && idx < block.frames.length) block.viewIdx = idx
}
function fmtTs(ts) {
  if (!ts) return ''
  return new Date(ts * 1000).toLocaleString('zh-CN', { hour12: false })
}

// ---------------------------------------------------------------- 连接 ----
function closeWs() {
  if (ws) { ws.onclose = null; ws.close(); ws = null }
  connected.value = false
}

function toggle() {
  if (connected.value) { closeWs(); return }
  if (!cmd.value.trim() || !nodeSel.value.length) {
    ElMessage.warning('请输入命令并选择节点')
    return
  }
  for (const k of Object.keys(blocks)) delete blocks[k]
  const proto = location.protocol === 'https:' ? 'wss' : 'ws'
  const params = new URLSearchParams({
    nodes: nodeSel.value.join(','),
    interval: String(interval.value),
    cmd: cmd.value.trim(),
  })
  ws = new WebSocket(`${proto}://${location.host}/api/monitors/ws/monitor?${params}`)
  ws.onopen = () => { connected.value = true }
  ws.onmessage = (ev) => {
    try {
      const m = JSON.parse(ev.data)
      if (m.type === 'meta') {
        const b = ensureBlock(m.node)
        b.cmd = m.cmd
      } else if (m.type === 'output') {
        const b = ensureBlock(m.node)
        b.frames.push({ ts: m.ts, stdout: m.stdout, stderr: m.stderr, exit_code: m.exit_code })
        if (b.frames.length > 500) {
          const drop = b.frames.length - 500
          b.frames.splice(0, drop)
          if (b.viewIdx !== null) b.viewIdx = Math.max(0, b.viewIdx - drop)
        }
        b.lastError = ''
      } else if (m.type === 'error') {
        const b = ensureBlock(m.node)
        b.lastError = m.message
        b.frames.push({ ts: m.ts || Date.now() / 1000, stdout: '', stderr: m.message, exit_code: null, error: true })
      }
    } catch { /* ignore */ }
  }
  ws.onclose = () => { connected.value = false }
  ws.onerror = () => ElMessage.error('WebSocket 错误')
}

// ---------------------------------------------------------------- 监控项 ----
async function loadMonitors() {
  try {
    monitorsList.value = (await api.monitors()).monitors
  } catch { /* 静默 */ }
}

function loadSaved(id) {
  const m = monitorsList.value.find((x) => x.id === id)
  if (!m) return
  cmd.value = m.cmd
  interval.value = m.interval
}

async function saveNew() {
  const name = saveName.value.trim()
  if (!name) { ElMessage.warning('请输入名称'); return }
  try {
    await api.createMonitor({ name, cmd: cmd.value.trim(), interval: interval.value })
    ElMessage.success('已保存')
    saveDialogVisible.value = false
    saveName.value = ''
    await loadMonitors()
  } catch (e) {
    ElMessage.error(`保存失败: ${e.message}`)
  }
}

async function updateSaved() {
  const m = monitorsList.value.find((x) => x.id === selectedId.value)
  if (!m) return
  try {
    await api.updateMonitor(m.id, { cmd: cmd.value.trim(), interval: interval.value })
    ElMessage.success(`已更新「${m.name}」`)
    await loadMonitors()
  } catch (e) {
    ElMessage.error(`更新失败: ${e.message}`)
  }
}

async function removeSaved() {
  const m = monitorsList.value.find((x) => x.id === selectedId.value)
  if (!m) return
  try {
    await ElMessageBox.confirm(`确定删除监控项「${m.name}」？`, '删除确认', { type: 'warning' })
  } catch { return }
  try {
    await api.deleteMonitor(m.id)
    selectedId.value = ''
    await loadMonitors()
    ElMessage.success('已删除')
  } catch (e) {
    ElMessage.error(`删除失败: ${e.message}`)
  }
}

onMounted(async () => {
  loadMonitors()
  try {
    nodes.value = (await api.nodes()).nodes.map((n) => n.name)
  } catch { /* 静默 */ }
})
onUnmounted(closeWs)
</script>

<style scoped>
.monitor-page { display: flex; flex-direction: column; gap: 12px; height: 100%; overflow: auto; }
.ctrl-card :deep(.el-card__body) { padding: 12px 16px; }
.ctrl-row { display: flex; flex-wrap: wrap; align-items: center; gap: 10px; }
.label { color: var(--el-text-color-secondary); font-size: 13px; }
.empty-block { flex: 1; display: flex; align-items: center; justify-content: center; }
.node-block { display: flex; flex-direction: column; gap: 6px; }
.block-head { display: flex; align-items: center; gap: 10px; flex-wrap: wrap; }
.node-name { font-weight: 600; }
.cmd-text { color: var(--el-text-color-secondary); font-size: 12px; font-family: Consolas, monospace; }
.frame-time { color: var(--el-text-color-secondary); font-size: 12px; }
.err-text { color: var(--el-color-danger); font-size: 12px; }
.frame-nav { margin-left: auto; display: flex; align-items: center; gap: 4px; }
.frame-count { font-size: 12px; color: var(--el-text-color-secondary); font-family: Consolas, monospace; min-width: 44px; text-align: center; }
.terminal {
  background: #1e1e2e; color: #cdd6f4; border-radius: 8px; padding: 12px 16px;
  font-family: 'Cascadia Code', Consolas, 'Courier New', monospace; font-size: 13px;
  line-height: 1.55; overflow: auto; max-height: 420px; min-height: 60px;
}
.terminal.is-history { border: 1px solid var(--el-color-warning); }
.terminal .out { margin: 0; white-space: pre-wrap; word-break: break-all; }
.terminal .err { margin: 0; color: #f38ba8; white-space: pre-wrap; word-break: break-all; }
.waiting { color: #6c7086; }
.save-hint { color: var(--el-text-color-secondary); font-size: 12px; margin-top: 4px; }
</style>
