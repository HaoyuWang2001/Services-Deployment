<template>
  <el-card shadow="never">
    <template #header>
      <div class="card-header">
        <div class="inst-title">
          <span>运行实例</span>
          <el-tooltip content="刷新" placement="top">
            <el-button size="small" circle :icon="Refresh" :loading="loading" @click="load()" />
          </el-tooltip>
        </div>
        <div class="inst-actions">
          <el-button size="small" type="success" plain :disabled="!selected.length" @click="batch('start')">
            启动选中 ({{ selected.length }})
          </el-button>
          <el-button size="small" type="warning" plain :disabled="!canRestart" @click="batch('restart')">
            重启选中 ({{ selected.length }})
          </el-button>
          <el-button size="small" type="danger" plain :disabled="!canStop" @click="batch('stop')">
            停止选中 ({{ selected.length }})
          </el-button>
          <el-button size="small" type="danger" :disabled="!selected.length" @click="batch('delete')">
            删除选中 ({{ selected.length }})
          </el-button>
          <el-switch v-model="autoRefresh" active-text="10s 自动刷新" style="margin-left: 12px" />
        </div>
      </div>
    </template>

    <el-table ref="instTable" :data="instances" v-loading="loading" size="small" row-key="key"
              @selection-change="(rows) => (selected = rows)"
              empty-text="暂无实例（在各服务页创建实例）">
      <el-table-column type="selection" reserve-selection width="45" />
      <el-table-column prop="service" label="服务" min-width="140" />
      <el-table-column prop="node" label="节点" width="100" />
      <el-table-column label="状态" width="140">
        <template #default="{ row }">
          <el-tag :type="statusType(row)" size="small">{{ statusText(row) }}</el-tag>
        </template>
      </el-table-column>
      <el-table-column prop="pid" label="PID" width="80" />
      <el-table-column prop="run_id" label="run_id" width="165" />
      <el-table-column prop="started_at" label="最近启动" width="175" />
      <el-table-column prop="log_path" label="日志路径" min-width="220" show-overflow-tooltip />
      <el-table-column label="操作" width="80">
        <template #default="{ row }">
          <el-button size="small" link type="primary" @click="viewLog(row)">日志</el-button>
        </template>
      </el-table-column>
    </el-table>
  </el-card>
</template>

<script setup>
import { computed, onActivated, onDeactivated, onMounted, onUnmounted, ref } from 'vue'
import { ElMessage, ElMessageBox } from 'element-plus'
import { Refresh } from '@element-plus/icons-vue'
import { useRouter } from 'vue-router'
import { api, ACTION_TEXT } from '../api'
import { trackTask } from '../taskNotify'
import { statusType, statusText } from '../instanceStatus'

const router = useRouter()
const instances = ref([])
const selected = ref([])
const instTable = ref(null)
const loading = ref(false)
const autoRefresh = ref(true)
let timer = null

// 重启/停止仅对「运行中」实例有意义：任一选中实例未运行则置灰
const allRunning = computed(() =>
  selected.value.length > 0 && selected.value.every((r) => r.status === 'running'))
const canRestart = allRunning
const canStop = allRunning

async function load(silent = false) {
  if (!silent) loading.value = true
  try {
    const data = await api.instances()
    instances.value = data.instances.map((i) => ({ ...i, key: `${i.service}:${i.node}` }))
    // 数据刷新后清理失效勾选（实例已被删除），保持勾选与数据一致
    const stale = selected.value.some((s) => !instances.value.some((i) => i.key === s.key))
    if (stale) instTable.value?.clearSelection()
  } catch (e) {
    if (!silent) ElMessage.error(`加载失败: ${e.message}`)
  } finally {
    if (!silent) loading.value = false
  }
}

function setTimer() {
  clearInterval(timer)
  if (autoRefresh.value) timer = setInterval(() => load(true), 10000)
}


function viewLog(row) {
  router.push({ path: '/logs', query: { service: row.service, node: row.node, run_id: row.run_id, connect: '1', _t: String(Date.now()) } })
}

async function submitGroups(action, rows) {
  // 按服务分组，各生成一个任务
  const groups = new Map()
  for (const r of rows) {
    if (!groups.has(r.service)) groups.set(r.service, [])
    groups.get(r.service).push(r.node)
  }
  let ok = 0
  for (const [service, nodes] of groups) {
    try {
      const task = await api.createTask({ service, action, nodes })
      trackTask(task.id, `${ACTION_TEXT[action]}实例 ${service}`)
      ok += 1
    } catch (e) {
      ElMessage.error(`${service} ${ACTION_TEXT[action]}任务创建失败: ${e.message}`)
    }
  }
  if (ok) ElMessage.success(`${ACTION_TEXT[action]}任务已提交（${ok} 个服务）`)
  instTable.value?.clearSelection()
  setTimeout(() => load(true), 1000)
  setTimeout(() => load(true), 4000)
}

async function confirmAction(action, targets) {
  const desc = targets.map((t) => `${t.service}@${t.node}`).join('、')
  const extra = action === 'delete' ? '（停止进程并从列表移除，节点文件保留）'
    : action === 'restart' ? '（停止后启动，日志续写并加分隔符）' : ''
  try {
    await ElMessageBox.confirm(
      `确定对 ${desc} 执行「${ACTION_TEXT[action]}」${extra}？`,
      `${ACTION_TEXT[action]}确认`, { type: action === 'start' ? 'info' : 'warning' })
  } catch { return false }
  return true
}

async function batch(action) {
  if (!selected.value.length) return
  if (await confirmAction(action, selected.value)) submitGroups(action, selected.value)
}

onMounted(() => { load(); setTimer() })
onActivated(() => { load(true); setTimer() })
onDeactivated(() => clearInterval(timer))
onUnmounted(() => clearInterval(timer))
</script>

<style scoped>
.card-header { display: flex; justify-content: space-between; align-items: center; }
.inst-title { display: flex; align-items: center; gap: 8px; }
.inst-actions { display: flex; align-items: center; }
</style>
