<template>
  <div class="sd-page">
    <PageHeader title="运行实例" description="全部服务的实例总表；可多选批量操作，或用行内菜单单独操作">
      <template #actions>
        <el-tooltip content="刷新" placement="top">
          <el-button size="small" circle :icon="Refresh" :loading="loading" aria-label="刷新实例列表" @click="load()" />
        </el-tooltip>
        <el-switch v-model="autoRefresh" active-text="10 秒自动刷新" />
      </template>
    </PageHeader>

    <el-card shadow="never" class="table-card">
      <div class="toolbar">
        <span class="sd-muted">已选 {{ selected.length }} / {{ instances.length }} 个实例</span>
        <div class="toolbar-actions">
          <el-tooltip :disabled="canStart" content="请勾选实例；且选中实例需全部处于可启动状态" placement="top">
            <span><el-button size="small" :disabled="!canStart" @click="openBatch('start')">启动选中</el-button></span>
          </el-tooltip>
          <el-tooltip :disabled="canRestart" content="请勾选实例；且选中实例需全部处于运行中" placement="top">
            <span><el-button size="small" :disabled="!canRestart" @click="openBatch('restart')">重启选中</el-button></span>
          </el-tooltip>
          <el-tooltip :disabled="canStop" content="请勾选实例；且选中实例需全部处于可停止状态" placement="top">
            <span><el-button size="small" :disabled="!canStop" @click="openBatch('stop')">停止选中</el-button></span>
          </el-tooltip>
          <el-button size="small" type="danger" plain :disabled="!canDelete" @click="openBatch('delete')">
            删除选中
          </el-button>
        </div>
      </div>

      <el-table ref="instTable" :data="instances" v-loading="loading" size="small" row-key="key"
                @selection-change="(rows) => (selected = rows)">
        <template #empty>
          <el-empty description="暂无实例">
            <el-button size="small" type="primary" @click="$router.push('/services')">到服务管理创建实例</el-button>
          </el-empty>
        </template>
        <el-table-column type="selection" reserve-selection width="45" />
        <el-table-column prop="service" label="服务" min-width="150" />
        <el-table-column prop="node" width="110" label="节点" />
        <el-table-column label="状态" width="150">
          <template #default="{ row }">
            <el-popover v-if="row.status === 'abnormal'" placement="top" :width="300"
                        trigger="hover" :show-after="150" :content="ABNORMAL_HINT">
              <template #reference>
                <el-tag :type="statusType(row.status)" size="small" class="status-hint">{{ statusText(row) }}</el-tag>
              </template>
            </el-popover>
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
        <el-table-column label="PID" width="90">
          <template #default="{ row }"><span class="sd-mono sd-num">{{ row.pid ?? '-' }}</span></template>
        </el-table-column>
        <el-table-column label="run_id" width="160">
          <template #default="{ row }"><span class="sd-mono">{{ row.run_id }}</span></template>
        </el-table-column>
        <el-table-column label="最近启动" width="130">
          <template #default="{ row }">
            <span :title="fmtTime(row.started_at)">{{ fmtTimeRel(row.started_at) }}</span>
          </template>
        </el-table-column>
        <el-table-column prop="log_path" label="日志路径" min-width="200" show-overflow-tooltip />
        <el-table-column label="操作" width="150">
          <template #default="{ row }">
            <el-button size="small" link type="primary" @click="viewLog(row)">日志</el-button>
            <el-dropdown trigger="click" class="row-more" @command="(cmd) => rowOp(cmd, row)">
              <el-button size="small" link type="primary">
                更多<el-icon class="el-icon--right"><ArrowDown /></el-icon>
              </el-button>
              <template #dropdown>
                <el-dropdown-menu>
                  <el-dropdown-item command="start" :disabled="!isEligible('start', row.status)">启动</el-dropdown-item>
                  <el-dropdown-item command="restart" :disabled="!isEligible('restart', row.status)">重启</el-dropdown-item>
                  <el-dropdown-item command="stop" :disabled="!isEligible('stop', row.status)">停止</el-dropdown-item>
                  <el-dropdown-item command="delete" :disabled="!isEligible('delete', row.status)" divided>删除</el-dropdown-item>
                </el-dropdown-menu>
              </template>
            </el-dropdown>
          </template>
        </el-table-column>
      </el-table>
    </el-card>

    <!-- 批量操作预检确认框 -->
    <el-dialog v-model="batchDialog" :title="`${ACTION_TEXT[batchAction]}确认（实时状态预检）`" width="620px">
      <el-table :data="batchTargets" size="small" v-loading="batchChecking">
        <template #empty><el-empty description="无选中的实例" :image-size="60" /></template>
        <el-table-column label="实例" min-width="200">
          <template #default="{ row }">
            <span class="sd-mono">{{ row.service }}@{{ row.node }}</span>
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
        <el-button size="small" link type="primary" @click="refreshBatchTargets">重新预检</el-button>
      </div>
      <template #footer>
        <el-button @click="batchDialog = false">取消</el-button>
        <el-button :type="batchAction === 'delete' ? 'danger' : 'primary'" :disabled="!allEligible" @click="confirmBatch">
          确认{{ ACTION_TEXT[batchAction] }}（{{ batchTargets.length }}）
        </el-button>
      </template>
    </el-dialog>
  </div>
</template>

<script setup>
import { computed, onActivated, onDeactivated, onMounted, onUnmounted, ref } from 'vue'
import { ElMessage } from 'element-plus'
import { ArrowDown, Refresh } from '@element-plus/icons-vue'
import { useRouter } from 'vue-router'
import { api, ACTION_TEXT, fmtTime, fmtTimeRel } from '../api'
import { trackTask, trackTaskGroup } from '../taskNotify'
import PageHeader from '../components/PageHeader.vue'
import { confirmDanger } from '../ui/confirm'
import {
  ABNORMAL_HINT, DELETABLE, RESTARTABLE, STARTABLE, STOPPABLE,
  cleanupText, cleanupType, isEligible, statusText, statusType,
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
    if (!silent) ElMessage.error(`加载失败：${e.message}`)
  } finally {
    if (!silent) loading.value = false
  }
}

// 严格全部门禁：全部选中实例符合该动作允许状态才可点击
const everyIn = (set) => computed(() =>
  selected.value.length > 0 && selected.value.every((r) => set.includes(r.status)))
const canStart = everyIn(STARTABLE)
const canRestart = everyIn(RESTARTABLE)
const canStop = everyIn(STOPPABLE)
const canDelete = everyIn(DELETABLE)

function setTimer() {
  clearInterval(timer)
  if (autoRefresh.value) timer = setInterval(() => load(true), 10000)
}

function viewLog(row) {
  router.push({ path: '/logs', query: { service: row.service, node: row.node, run_id: row.run_id, connect: '1', _t: String(Date.now()) } })
}

// ---------------------------------------------------------------- 行内操作 ----
async function rowOp(action, row) {
  if (action === 'delete') {
    try {
      await confirmDanger(
        `确定删除实例 ${row.service}@${row.node}？运行中的实例会先停止再删除。`,
        { title: '删除实例确认', confirmText: '删除实例' },
      )
    } catch { return }
  }
  try {
    const task = await api.createTask({ service: row.service, action, nodes: [row.node] })
    trackTask(task.id, `${ACTION_TEXT[action]}实例 ${row.service}@${row.node}`)
    ElMessage.success(`已提交${ACTION_TEXT[action]}任务`)
    setTimeout(() => load(true), 800)
  } catch (e) {
    ElMessage.error(`${ACTION_TEXT[action]}失败：${e.message}`)
  }
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
      eligible: isEligible(action, status),
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
      ElMessage.error(`${service} ${ACTION_TEXT[action]}任务创建失败：${e.message}`)
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
.table-card :deep(.el-card__body) { padding: var(--sd-space-3) var(--sd-space-4) var(--sd-space-4); }
.toolbar { display: flex; flex-wrap: wrap; align-items: center; justify-content: space-between; gap: var(--sd-space-2); margin-bottom: var(--sd-space-3); }
.toolbar-actions { display: flex; align-items: center; gap: var(--sd-space-2); }
.row-more { margin-left: var(--sd-space-2); }
.batch-hint { color: var(--el-text-color-secondary); font-size: 12px; margin-top: var(--sd-space-3); display: flex; align-items: center; gap: var(--sd-space-2); }
.batch-warn { color: var(--el-color-danger); }
.status-hint { cursor: help; }
</style>
