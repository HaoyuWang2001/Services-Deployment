<template>
  <div class="sd-page">
    <PageHeader title="任务历史" description="每次部署 / 启动 / 停止 / 清理等操作的任务与各节点结果">
      <template #actions>
        <el-tooltip content="刷新" placement="top">
          <el-button size="small" circle :icon="Refresh" :loading="loading" aria-label="刷新任务列表" @click="load()" />
        </el-tooltip>
        <el-switch v-model="auto" active-text="3 秒自动刷新" />
      </template>
    </PageHeader>

    <el-card shadow="never">
      <div class="filters">
        <el-select v-model="filterService" placeholder="全部服务" size="small" clearable style="width: 160px">
          <el-option v-for="s in serviceOptions" :key="s" :label="s" :value="s" />
        </el-select>
        <el-select v-model="filterAction" placeholder="全部动作" size="small" clearable style="width: 130px">
          <el-option v-for="(text, key) in ACTION_TEXT" :key="key" :label="text" :value="key" />
        </el-select>
        <el-select v-model="filterStatus" placeholder="全部状态" size="small" clearable style="width: 130px">
          <el-option label="执行中" value="running" />
          <el-option label="已完成" value="completed" />
          <el-option label="部分成功" value="partial" />
          <el-option label="失败" value="failed" />
        </el-select>
        <span class="sd-muted">共 {{ filteredTasks.length }} / {{ tasks.length }} 条</span>
      </div>

      <el-table :data="pagedTasks" v-loading="loading" row-key="id" size="small" @expand-change="onExpand">
        <template #empty>
          <el-empty :description="tasks.length ? '没有符合筛选条件的任务' : '暂无任务'">
            <el-button v-if="tasks.length" size="small" @click="resetFilters">清除筛选</el-button>
          </el-empty>
        </template>
        <el-table-column type="expand">
          <template #default="{ row }">
            <div class="sub-wrap" v-loading="row._loading">
              <el-table :data="row.subtasks || []" size="small">
                <el-table-column prop="node" label="节点" width="110" />
                <el-table-column label="结果" width="90">
                  <template #default="{ row: s }">
                    <el-tag :type="s.status === 'success' ? 'success' : 'danger'" size="small">
                      {{ s.status === 'success' ? '成功' : '失败' }}
                    </el-tag>
                  </template>
                </el-table-column>
                <el-table-column label="详情 / 错误" min-width="260">
                  <template #default="{ row: s }">
                    <span v-if="s.status === 'success'">{{ s.detail }}</span>
                    <span v-else class="err">{{ s.error }}</span>
                  </template>
                </el-table-column>
                <el-table-column label="PID" width="90">
                  <template #default="{ row: s }"><span class="sd-mono sd-num">{{ s.pid ?? '-' }}</span></template>
                </el-table-column>
                <el-table-column label="run_id" width="170">
                  <template #default="{ row: s }"><span class="sd-mono">{{ s.run_id || '-' }}</span></template>
                </el-table-column>
                <el-table-column label="日志" min-width="240" show-overflow-tooltip>
                  <template #default="{ row: s }">
                    <el-link v-if="s.run_id" type="primary" :underline="false"
                             @click="$router.push({ path: '/logs', query: { service: row.service, node: s.node, run_id: s.run_id, connect: '1', _t: String(Date.now()) } })">
                      {{ s.log_path }}
                    </el-link>
                    <span v-else class="sd-muted">-</span>
                  </template>
                </el-table-column>
                <el-table-column label="耗时" width="90">
                  <template #default="{ row: s }">{{ fmtDuration(s.started_at, s.finished_at) }}</template>
                </el-table-column>
              </el-table>
            </div>
          </template>
        </el-table-column>
        <el-table-column label="任务 ID" width="140">
          <template #default="{ row }"><span class="sd-mono">{{ row.id }}</span></template>
        </el-table-column>
        <el-table-column label="时间" width="130">
          <template #default="{ row }">
            <span :title="fmtTime(row.created_at)">{{ fmtTimeRel(row.created_at) }}</span>
          </template>
        </el-table-column>
        <el-table-column label="动作" width="90">
          <template #default="{ row }">
            <el-tag size="small" :type="ACTION_TAG[row.action] || 'info'">
              {{ ACTION_TEXT[row.action] || row.action }}
            </el-tag>
          </template>
        </el-table-column>
        <el-table-column prop="service" label="服务" min-width="150" />
        <el-table-column label="节点" min-width="180" show-overflow-tooltip>
          <template #default="{ row }">{{ row.nodes.join('、') }}</template>
        </el-table-column>
        <el-table-column label="状态" width="100">
          <template #default="{ row }">
            <el-tag :type="taskStatusType(row.status)" size="small">{{ taskStatusText(row.status) }}</el-tag>
          </template>
        </el-table-column>
        <el-table-column label="结果" width="130">
          <template #default="{ row }">
            <span class="ok">{{ row.counts.success }} 成功</span> /
            <span :class="{ err: row.counts.failed }">{{ row.counts.failed }} 失败</span>
          </template>
        </el-table-column>
        <el-table-column label="耗时" width="90">
          <template #default="{ row }">{{ fmtDuration(row.created_at, row.finished_at) }}</template>
        </el-table-column>
      </el-table>
      <div v-if="filteredTasks.length" class="pager">
        <el-pagination
          v-model:current-page="page"
          v-model:page-size="pageSize"
          :page-sizes="PAGE_SIZES"
          :total="filteredTasks.length"
          layout="total, sizes, prev, pager, next"
          size="small"
          background
        />
      </div>
    </el-card>
  </div>
</template>

<script setup>
import { computed, onActivated, onDeactivated, onUnmounted, ref, watch } from 'vue'
import { ElMessage } from 'element-plus'
import { Refresh } from '@element-plus/icons-vue'
import { useRoute, useRouter } from 'vue-router'
import {
  ACTION_TEXT, fmtDuration, fmtTime, fmtTimeRel, api,
} from '../api'
import PageHeader from '../components/PageHeader.vue'

const ACTION_TAG = {
  deploy: 'info', create: 'success', start: 'success', stop: 'warning',
  restart: 'warning', delete: 'danger', clean: 'danger',
}

const route = useRoute()
const router = useRouter()
const tasks = ref([])
const loading = ref(false)
const auto = ref(true)
const filterService = ref('')
const filterAction = ref('')
const filterStatus = ref('')
const page = ref(1)
const pageSize = ref(50)
const PAGE_SIZES = [20, 50, 100]
let timer = null
let syncing = false

const serviceOptions = computed(() => [...new Set(tasks.value.map((t) => t.service))].sort())
const filteredTasks = computed(() => tasks.value.filter((t) =>
  (!filterService.value || t.service === filterService.value)
  && (!filterAction.value || t.action === filterAction.value)
  && (!filterStatus.value || t.status === filterStatus.value)))

const pagedTasks = computed(() => {
  const start = (page.value - 1) * pageSize.value
  return filteredTasks.value.slice(start, start + pageSize.value)
})

// 筛选条件与分页写入 URL（刷新 / 分享可恢复）
function applyQuery() {
  syncing = true
  const q = route.query
  filterService.value = q.service ? String(q.service) : ''
  filterAction.value = q.action ? String(q.action) : ''
  filterStatus.value = q.status ? String(q.status) : ''
  const size = Number(q.size)
  pageSize.value = PAGE_SIZES.includes(size) ? size : 50
  const p = Number(q.page)
  page.value = Number.isFinite(p) && p >= 1 ? p : 1
  syncing = false
}

function syncQuery() {
  const q = {}
  if (filterService.value) q.service = filterService.value
  if (filterAction.value) q.action = filterAction.value
  if (filterStatus.value) q.status = filterStatus.value
  if (page.value > 1) q.page = String(page.value)
  if (pageSize.value !== 50) q.size = String(pageSize.value)
  router.replace({ query: q })
}

watch([filterService, filterAction, filterStatus], () => {
  if (syncing) return
  page.value = 1
  syncQuery()
}, { flush: 'sync' })
watch([page, pageSize], () => {
  if (syncing) return
  const maxPage = Math.max(1, Math.ceil(filteredTasks.value.length / pageSize.value))
  if (page.value > maxPage) { page.value = maxPage; return }
  syncQuery()
}, { flush: 'sync' })
watch(() => filteredTasks.value.length, (len) => {
  const maxPage = Math.max(1, Math.ceil(len / pageSize.value))
  if (page.value > maxPage) page.value = maxPage
})

function resetFilters() {
  syncing = true
  filterService.value = ''
  filterAction.value = ''
  filterStatus.value = ''
  page.value = 1
  syncing = false
  syncQuery()
}

async function load(silent = false) {
  if (!silent) loading.value = true
  try {
    const data = await api.tasks(300)
    // 保留已展开行懒加载的 subtasks，避免刷新时丢失
    const old = new Map(tasks.value.map((t) => [t.id, t.subtasks]))
    tasks.value = data.tasks.map((t) => ({ ...t, subtasks: old.get(t.id) || null }))
  } catch (e) {
    if (!silent) ElMessage.error(`加载失败：${e.message}`)
  } finally {
    if (!silent) loading.value = false
  }
}

async function onExpand(row, expandedRows) {
  if (!expandedRows.includes(row) || row.subtasks) return
  row._loading = true
  try {
    const detail = await api.task(row.id)
    row.subtasks = detail.subtasks
  } catch (e) {
    ElMessage.error(`加载任务详情失败：${e.message}`)
  } finally {
    row._loading = false
  }
}

function taskStatusType(s) {
  return { completed: 'success', partial: 'warning', failed: 'danger', running: 'primary' }[s] || 'info'
}
function taskStatusText(s) {
  return { completed: '已完成', partial: '部分成功', failed: '失败', running: '执行中' }[s] || s
}

function setTimer() {
  clearInterval(timer)
  if (auto.value) timer = setInterval(() => load(true), 3000)
}

onActivated(() => { applyQuery(); load(true); setTimer() })
onDeactivated(() => clearInterval(timer))
onUnmounted(() => clearInterval(timer))
</script>

<style scoped>
.filters { display: flex; flex-wrap: wrap; align-items: center; gap: var(--sd-space-2); margin-bottom: var(--sd-space-3); }
.sub-wrap { padding: var(--sd-space-1) var(--sd-space-3) var(--sd-space-3) 48px; }
.pager { display: flex; justify-content: flex-end; margin-top: var(--sd-space-3); }
.err { color: var(--el-color-danger); }
.ok { color: var(--el-color-success); }
</style>
