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
          <el-button size="small" type="success" plain :disabled="!canStart" @click="openBatch('start')">
            启动选中 ({{ selected.length }})
          </el-button>
          <el-button size="small" type="warning" plain :disabled="!canStop" @click="openBatch('stop')">
            停止选中 ({{ selected.length }})
          </el-button>
          <el-button size="small" type="danger" :disabled="!canDelete" @click="openBatch('delete')">
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
      <el-table-column label="操作" width="80">
        <template #default="{ row }">
          <el-button size="small" link type="primary" @click="viewLog(row)">日志</el-button>
        </template>
      </el-table-column>
      <el-table-column label="状态" width="140">
        <template #default="{ row }">
          <el-tooltip v-if="row.status === 'abnormal'" :content="ABNORMAL_HINT" placement="top">
            <el-tag :type="statusType(row.status)" size="small">{{ statusText(row) }}</el-tag>
          </el-tooltip>
          <el-tag v-else :type="statusType(row.status)" size="small">{{ statusText(row) }}</el-tag>
        </template>
      </el-table-column>
      <el-table-column label="清理状态" width="120">
        <template #default="{ row }">
          <el-tag :type="cleanupType(row.cleanup_status)" size="small" effect="plain">
            {{ cleanupText(row.cleanup_status) }}
          </el-tag>
        </template>
      </el-table-column>
      <el-table-column prop="pid" label="PID" width="80" />
      <el-table-column prop="run_id" label="run_id" width="165" />
      <el-table-column prop="started_at" label="最近启动" width="175" />
      <el-table-column prop="log_path" label="日志路径" min-width="220" show-overflow-tooltip />
    </el-table>

    <!-- 批量操作预检确认框 -->
    <el-dialog v-model="batchDialog" :title="`${ACTION_TEXT[batchAction]}确认（实时状态预检）`" width="620px">
      <el-table :data="batchTargets" size="small" v-loading="batchChecking">
              empty-text="无选中的实例">
        <el-table-column label="实例" min-width="200">
          <template #default="{ row }">
            <span class="mono">{{ row.service }}@{{ row.node }}</span>
          </template>
        </el-table-column>
        <el-table-column label="当前状态" width="150">
          <template #default="{ row }">
            <el-tag :type="statusType(row.status)" size="small">{{ statusText(row) }}</el-tag>
          </template>
        </el-table-column>
        <el-table-column label="本次" width="90">
          <template #default="{ row }">
            <el-tag v-if="row.eligible" type="success" size="small">执行</el-tag>
            <el-tag v-else type="info" size="small">跳过</el-tag>
          </template>
        </el-table-column>
      </el-table>
      <div class="batch-hint">
        <span v-if="allEligible">将执行 {{ batchTargets.length }} 个</span>
        <span v-else class="batch-warn">
          存在 {{ ineligibleCount }} 个状态不符实例，不允许部分执行；请重新预检或刷新后重新勾选
        </span>
        <el-button size="small" link type="primary" style="margin-left: 10px"
                   @click="refreshBatchTargets">重新预检</el-button>
      </div>
      <template #footer>
        <el-button @click="batchDialog = false">取消</el-button>
        <el-button type="primary" :disabled="!allEligible" @click="confirmBatch">
          确认{{ ACTION_TEXT[batchAction] }}（{{ batchTargets.length }}）
        </el-button>
      </template>
    </el-dialog>
  </el-card>
</template>

<script setup>
import { computed, onActivated, onDeactivated, onMounted, onUnmounted, ref } from 'vue'
import { ElMessage } from 'element-plus'
import { Refresh } from '@element-plus/icons-vue'
import { useRouter } from 'vue-router'
import { api, ACTION_TEXT } from '../api'
import { trackTaskGroup } from '../taskNotify'
import {
  ABNORMAL_HINT, DELETABLE, STARTABLE, STOPPABLE,
  cleanupText, cleanupType, statusText, statusType,
} from '../instanceStatus'

const router = useRouter()
const instances = ref([])
const selected = ref([])
const instTable = ref(null)
const loading = ref(false)
const autoRefresh = ref(true)
let timer = null

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

// 严格全部门禁：全部选中实例符合该动作允许状态才可点击
const everyIn = (set) => computed(() =>
  selected.value.length > 0 && selected.value.every((r) => set.includes(r.status)))
const canStart = everyIn(STARTABLE)
const canStop = everyIn(STOPPABLE)
const canDelete = everyIn(DELETABLE)

function setTimer() {
  clearInterval(timer)
  if (autoRefresh.value) timer = setInterval(() => load(true), 10000)
}

function viewLog(row) {
  router.push({ path: '/logs', query: { service: row.service, node: row.node, run_id: row.run_id, connect: '1', _t: String(Date.now()) } })
}

// ---------------------------------------------------------------- 批量预检 ----
const batchDialog = ref(false)
const batchAction = ref('stop')
const batchTargets = ref([])       // {service, node, status, cleanup_status, exit_code, eligible}
const batchChecking = ref(false)

// 严格预检：全部符合才允许确认（不允许部分执行）
const allEligible = computed(() =>
  batchTargets.value.length > 0 && batchTargets.value.every((t) => t.eligible))
const ineligibleCount = computed(() => batchTargets.value.filter((t) => !t.eligible).length)

const ELIGIBLE_SETS = { start: STARTABLE, stop: STOPPABLE, delete: DELETABLE }

async function fetchFreshInstances() {
  try { return (await api.instances()).instances } catch { return null }
}

function markEligible(action, targets, freshList) {
  const byKey = new Map((freshList || []).map((i) => [`${i.service}:${i.node}`, i]))
  return targets.map((t) => {
    const live = byKey.get(`${t.service}:${t.node}`)
    const status = live?.status ?? t.status
    return {
      ...t,
      run_id: live?.run_id ?? t.run_id,
      status,
      cleanup_status: live?.cleanup_status ?? t.cleanup_status,
      exit_code: live?.exit_code ?? t.exit_code,
      eligible: (ELIGIBLE_SETS[action] || []).includes(status),
    }
  })
}

async function openBatch(action) {
  if (!selected.value.length) return
  batchAction.value = action
  batchDialog.value = true
  batchChecking.value = true
  batchTargets.value = markEligible(action, selected.value, await fetchFreshInstances())
  batchChecking.value = false
}

async function refreshBatchTargets() {
  batchChecking.value = true
  batchTargets.value = markEligible(batchAction.value, batchTargets.value, await fetchFreshInstances())
  batchChecking.value = false
}

async function confirmBatch() {
  if (!allEligible.value) return
  const rows = batchTargets.value
  // 立即清空勾选（须在任何 await 之前，避免 reserve-selection 在轮询刷新时恢复勾选的竞态）
  selected.value = []
  instTable.value?.clearSelection()
  batchDialog.value = false
  await submitGroups(batchAction.value, rows)
}

async function submitGroups(action, rows) {
  // 按服务分组，各生成一个任务；结果聚合并单弹窗
  const groupsMap = new Map()
  for (const r of rows) {
    if (!groupsMap.has(r.service)) groupsMap.set(r.service, [])
    groupsMap.get(r.service).push(r.node)
  }
  const submitted = []
  for (const [service, nodes] of groupsMap) {
    try {
      const task = await api.createTask({ service, action, nodes })
      submitted.push({ id: task.id, context: `${ACTION_TEXT[action]}实例 ${service}` })
    } catch (e) {
      ElMessage.error(`${service} ${ACTION_TEXT[action]}任务创建失败: ${e.message}`)
    }
  }
  if (submitted.length) {
    trackTaskGroup(submitted, `${ACTION_TEXT[action]} ${rows.length} 个实例`)
    ElMessage.success(`已提交 ${submitted.length} 个任务（覆盖 ${rows.length} 个实例）`)
  }
  instTable.value?.clearSelection()
  setTimeout(() => load(true), 1000)
  setTimeout(() => load(true), 4000)
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
.mono { font-family: Consolas, monospace; font-size: 13px; }
.batch-hint { color: var(--el-text-color-secondary); font-size: 12px; margin-top: 10px; display: flex; align-items: center; }
.batch-warn { color: var(--el-color-danger); }
</style>
