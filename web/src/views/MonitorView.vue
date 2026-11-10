<template>
  <div class="sd-page monitor-page">
    <PageHeader title="监控指令" description="按固定间隔在多个节点执行命令（watch 语义），可逐帧回看最近 500 帧输出">
      <template #actions>
        <el-button size="small" @click="saveDialogVisible = true" :disabled="!cmd.trim()">保存为监控项</el-button>
        <el-button v-if="selectedId" size="small" @click="updateSaved">更新当前项</el-button>
        <el-button v-if="selectedId" size="small" type="danger" plain @click="removeSaved">删除监控项</el-button>
      </template>
    </PageHeader>

    <el-card shadow="never" class="ctrl-card">
      <div class="ctrl-row">
        <el-select v-model="selectedId" placeholder="选择已保存监控项" size="small" style="width: 200px"
                   clearable @change="loadSaved">
          <el-option v-for="m in monitorsList" :key="m.id" :label="m.name" :value="m.id" />
        </el-select>
        <el-input v-model="cmd" size="small" class="cmd-input" clearable
                  placeholder="要执行的命令，如 df -h / free -m / nvidia-smi（回车开始）"
                  @keydown.enter.prevent="toggle" />
        <el-button size="small" :type="(connected || reconnecting) ? 'default' : 'primary'" @click="toggle">
          {{ (connected || reconnecting) ? '停止' : '开始' }}
        </el-button>
        <span v-if="reconnecting" class="sd-muted">重连中（第 {{ reconnectAttempts }} 次）</span>
        <span v-else-if="gaveUp" class="reconnect-failed">已暂停自动重连，点击「开始」重试</span>
      </div>
      <div class="ctrl-row">
        <span class="sd-label">间隔</span>
        <el-input-number v-model="interval" :min="1" :max="60" size="small" style="width: 100px" />
        <span class="sd-label">秒</span>
        <span class="sd-label">节点</span>
        <el-select v-model="nodeSel" multiple filterable size="small" style="width: 240px" placeholder="可多选">
          <el-option v-for="n in nodes" :key="n" :label="n" :value="n" />
        </el-select>
        <el-switch v-model="autoReconnect" size="small" active-text="自动重连" />
        <span class="sd-muted">保存监控项时会一并记住所选节点</span>
      </div>
    </el-card>

    <div v-if="!Object.keys(blocks).length" class="empty-block">
      <el-empty description="选择已保存的监控项，或输入命令并选择节点后点击「开始」" />
    </div>

    <div v-for="(block, nodeName) in blocks" :key="nodeName" class="node-block">
      <div class="block-head">
        <span class="node-name" :style="{ color: nodeColor(nodeName) }">{{ nodeName }}</span>
        <span class="cmd-text">{{ block.cmd || cmd }}（{{ interval }} 秒）</span>
        <template v-if="currentFrame(block)">
          <span class="frame-time">{{ fmtTime(currentFrame(block).ts) }}</span>
          <el-tag v-if="currentFrame(block).error" type="danger" size="small">执行错误</el-tag>
          <el-tag v-else-if="currentFrame(block).exit_code === 0" type="success" size="small">exit 0</el-tag>
          <el-tag v-else type="danger" size="small">exit {{ currentFrame(block).exit_code }}</el-tag>
        </template>
        <span v-else-if="block.lastError" class="err-text">{{ block.lastError }}</span>
        <div class="frame-nav">
          <template v-if="block.frames.length">
            <el-button-group>
              <el-button size="small" :disabled="block.viewIdx === 0" aria-label="首帧" @click="block.viewIdx = 0">
                <el-icon><DArrowLeft /></el-icon>
              </el-button>
              <el-button size="small" :disabled="frameIdx(block) <= 0" aria-label="上一帧" @click="step(block, -1)">
                <el-icon><ArrowLeft /></el-icon>
              </el-button>
              <el-button size="small" :disabled="frameIdx(block) >= block.frames.length - 1" aria-label="下一帧" @click="step(block, 1)">
                <el-icon><ArrowRight /></el-icon>
              </el-button>
              <el-button size="small" :disabled="block.viewIdx === null" aria-label="最新帧" @click="block.viewIdx = null">
                <el-icon><DArrowRight /></el-icon>
              </el-button>
            </el-button-group>
            <span class="frame-count sd-num">{{ frameIdx(block) + 1 }}/{{ block.frames.length }}</span>
            <el-tag v-if="block.viewIdx !== null" type="info" size="small" effect="plain">查看历史帧</el-tag>
            <el-tag v-if="newCount(block) > 0" size="small" type="warning">{{ newCount(block) }} 帧新输出</el-tag>
          </template>
        </div>
      </div>
      <div class="sd-term monitor-term">
        <template v-if="currentFrame(block)">
          <pre class="out">{{ currentFrame(block).stdout }}</pre>
          <pre v-if="currentFrame(block).stderr" class="err">{{ currentFrame(block).stderr }}</pre>
        </template>
        <div v-else class="waiting">等待首次采集…</div>
      </div>
    </div>

    <el-dialog v-model="saveDialogVisible" title="保存为监控项" width="440px">
      <el-form label-width="70px">
        <el-form-item label="名称">
          <el-input v-model="saveName" placeholder="如 磁盘使用率" maxlength="64" />
        </el-form-item>
      </el-form>
      <div class="save-hint">将保存命令、间隔与所选节点（{{ cmd }} / {{ interval }} 秒 / {{ nodeSel.length ? nodeSel.join('、') : '未选节点' }}），所有浏览器共享</div>
      <template #footer>
        <el-button @click="saveDialogVisible = false">取消</el-button>
        <el-button type="primary" @click="saveNew">保存</el-button>
      </template>
    </el-dialog>
  </div>
</template>

<script setup>
import { onMounted, onUnmounted, reactive, ref, watch } from 'vue'
import { ElMessage } from 'element-plus'
import { ArrowLeft, ArrowRight, DArrowLeft, DArrowRight } from '@element-plus/icons-vue'
import { api, fmtTime } from '../api'
import PageHeader from '../components/PageHeader.vue'
import { nodeColor } from '../ui/nodeColors'
import { confirmDanger } from '../ui/confirm'

const monitorsList = ref([])
const selectedId = ref('')
const cmd = ref('')
const interval = ref(2)
const nodes = ref([])
const nodeSel = ref([])
const connected = ref(false)
const reconnecting = ref(false)
const reconnectAttempts = ref(0)
const autoReconnect = ref(true)
const gaveUp = ref(false)
const saveDialogVisible = ref(false)
const saveName = ref('')
let ws = null
let reconnectTimer = null
let manualStop = false
let failedStreak = 0

const MAX_FAILED_STREAK = 5

const blocks = reactive({})   // node -> {frames:[], viewIdx: null|number, cmd, lastError}

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
// ---------------------------------------------------------------- 连接 ----
function clearReconnect() {
  clearTimeout(reconnectTimer)
  reconnectTimer = null
  reconnecting.value = false
}

function closeWs() {
  clearReconnect()
  if (ws) { ws.onclose = null; ws.close(); ws = null }
  connected.value = false
}

function scheduleReconnect() {
  if (!autoReconnect.value || manualStop || gaveUp.value || reconnectTimer) return
  reconnecting.value = true
  reconnectAttempts.value += 1
  reconnectTimer = setTimeout(() => {
    reconnectTimer = null
    if (!manualStop) openWs()
  }, 3000)
}

function toggle() {
  if (connected.value || reconnecting.value) {
    manualStop = true
    closeWs()
    return
  }
  if (!cmd.value.trim() || !nodeSel.value.length) {
    ElMessage.warning('请输入命令并选择节点')
    return
  }
  manualStop = false
  gaveUp.value = false
  failedStreak = 0
  reconnectAttempts.value = 0
  for (const k of Object.keys(blocks)) delete blocks[k]
  openWs()
}

function openWs() {
  // 仅关闭旧连接，保留重连状态直至本次尝试出结果（onopen/onclose）
  clearTimeout(reconnectTimer)
  reconnectTimer = null
  if (ws) { ws.onclose = null; ws.close(); ws = null }
  connected.value = false
  const proto = location.protocol === 'https:' ? 'wss' : 'ws'
  const params = new URLSearchParams({
    nodes: nodeSel.value.join(','),
    interval: String(interval.value),
    cmd: cmd.value.trim(),
  })
  ws = new WebSocket(`${proto}://${location.host}/api/monitors/ws/monitor?${params}`)
  let opened = false
  ws.onopen = () => {
    opened = true
    connected.value = true
    reconnecting.value = false
    reconnectAttempts.value = 0
    failedStreak = 0
  }
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
  ws.onclose = () => {
    connected.value = false
    if (manualStop) return
    if (!opened) {
      // 连续建连失败：达上限后暂停自动重连，等待手动重试
      failedStreak += 1
      if (failedStreak >= MAX_FAILED_STREAK) {
        gaveUp.value = true
        clearReconnect()
        ElMessage.warning(`连续 ${MAX_FAILED_STREAK} 次无法连接，已暂停自动重连（点击「开始」手动重试）`)
        return
      }
    }
    scheduleReconnect()
  }
  ws.onerror = () => { /* 交由 onclose 统一处理重连 */ }
}

watch(autoReconnect, (v) => { if (!v) clearReconnect() })

// ---------------------------------------------------------------- 监控项 ----
async function loadMonitors() {
  try {
    monitorsList.value = (await api.monitors()).monitors
  } catch (e) {
    ElMessage.warning(`监控项加载失败：${e.message}`)
  }
}

function loadSaved(id) {
  const m = monitorsList.value.find((x) => x.id === id)
  if (!m) return
  cmd.value = m.cmd
  interval.value = m.interval
  if (m.nodes?.length) nodeSel.value = m.nodes.filter((n) => nodes.value.includes(n))
}

async function saveNew() {
  const name = saveName.value.trim()
  if (!name) { ElMessage.warning('请输入名称'); return }
  try {
    await api.createMonitor({
      name, cmd: cmd.value.trim(), interval: interval.value, nodes: [...nodeSel.value],
    })
    ElMessage.success('已保存')
    saveDialogVisible.value = false
    saveName.value = ''
    await loadMonitors()
  } catch (e) {
    ElMessage.error(`保存失败：${e.message}`)
  }
}

async function updateSaved() {
  const m = monitorsList.value.find((x) => x.id === selectedId.value)
  if (!m) return
  try {
    await api.updateMonitor(m.id, {
      cmd: cmd.value.trim(), interval: interval.value, nodes: [...nodeSel.value],
    })
    ElMessage.success(`已更新「${m.name}」`)
    await loadMonitors()
  } catch (e) {
    ElMessage.error(`更新失败：${e.message}`)
  }
}

async function removeSaved() {
  const m = monitorsList.value.find((x) => x.id === selectedId.value)
  if (!m) return
  try {
    await confirmDanger(`确定删除监控项「${m.name}」？`, { title: '删除监控项', confirmText: '删除' })
  } catch { return }
  try {
    await api.deleteMonitor(m.id)
    selectedId.value = ''
    await loadMonitors()
    ElMessage.success('已删除')
  } catch (e) {
    ElMessage.error(`删除失败：${e.message}`)
  }
}

onMounted(async () => {
  loadMonitors()
  try {
    nodes.value = (await api.nodes()).nodes.map((n) => n.name)
  } catch (e) {
    ElMessage.warning(`节点加载失败：${e.message}`)
  }
})
onUnmounted(() => { manualStop = true; closeWs() })
</script>

<style scoped>
.monitor-page { overflow: auto; }
.ctrl-card :deep(.el-card__body) {
  padding: var(--sd-space-3) var(--sd-space-4);
  display: flex;
  flex-direction: column;
  gap: var(--sd-space-2);
}
.ctrl-row { display: flex; flex-wrap: wrap; align-items: center; gap: var(--sd-space-2); }
.cmd-input { flex: 1; min-width: 260px; }
.empty-block { flex: 1; display: flex; align-items: center; justify-content: center; }
.node-block { display: flex; flex-direction: column; gap: 6px; }
.block-head { display: flex; align-items: center; gap: var(--sd-space-2); flex-wrap: wrap; }
.node-name { font-weight: 600; }
.cmd-text { color: var(--el-text-color-secondary); font-size: 12px; font-family: var(--sd-font-mono); }
.frame-time { color: var(--el-text-color-secondary); font-size: 12px; }
.err-text { color: var(--el-color-danger); font-size: 12px; }
.frame-nav { margin-left: auto; display: flex; align-items: center; gap: var(--sd-space-1); }
.frame-count { font-size: 12px; color: var(--el-text-color-secondary); font-family: var(--sd-font-mono); min-width: 44px; text-align: center; }
.monitor-term { max-height: 420px; min-height: 60px; }
.reconnect-failed { color: var(--el-color-danger); font-size: 12px; }
.save-hint { color: var(--el-text-color-secondary); font-size: 12px; margin-top: var(--sd-space-1); }
</style>
