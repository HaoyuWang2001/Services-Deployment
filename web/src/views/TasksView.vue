<template>
  <el-card shadow="never">
    <template #header>
      <div class="card-header">
        <span>任务历史</span>
        <div>
          <el-switch v-model="auto" active-text="自动刷新" style="margin-right: 12px" />
          <el-button size="small" @click="load" :loading="loading">刷新</el-button>
        </div>
      </div>
    </template>

    <el-table :data="tasks" v-loading="loading" empty-text="暂无任务" row-key="id">
      <el-table-column type="expand">
        <template #default="{ row }">
          <div class="sub-wrap">
            <el-table :data="row.subtasks" size="small" border>
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
              <el-table-column prop="pid" label="PID" width="90" />
              <el-table-column prop="run_id" label="run_id" width="170" />
              <el-table-column label="日志" min-width="240">
                <template #default="{ row: s }">
                  <el-link v-if="s.run_id" type="primary" :underline="false"
                           @click="$router.push({ path: '/logs', query: { service: row.service, node: s.node, run_id: s.run_id } })">
                    {{ s.log_path }}
                  </el-link>
                  <span v-else>-</span>
                </template>
              </el-table-column>
              <el-table-column label="耗时" width="80">
                <template #default="{ row: s }">{{ fmtDuration(s.started_at, s.finished_at) }}</template>
              </el-table-column>
            </el-table>
          </div>
        </template>
      </el-table-column>
      <el-table-column label="任务 ID" prop="id" width="130" />
      <el-table-column label="时间" width="175">
        <template #default="{ row }">{{ fmtTime(row.created_at) }}</template>
      </el-table-column>
      <el-table-column label="操作" width="80">
        <template #default="{ row }">
          <el-tag size="small" :type="{ deploy: 'info', start: 'success', stop: 'danger', restart: 'warning' }[row.action]">
            {{ ACTION_TEXT[row.action] || row.action }}
          </el-tag>
        </template>
      </el-table-column>
      <el-table-column prop="service" label="服务" min-width="150" />
      <el-table-column label="节点" min-width="180">
        <template #default="{ row }">{{ row.nodes.join('、') }}</template>
      </el-table-column>
      <el-table-column label="状态" width="100">
        <template #default="{ row }">
          <el-tag :type="taskStatusType(row.status)" size="small">{{ taskStatusText(row.status) }}</el-tag>
        </template>
      </el-table-column>
      <el-table-column label="结果" width="120">
        <template #default="{ row }">
          <span class="ok">{{ row.counts.success }} 成功</span> /
          <span :class="{ err: row.counts.failed }">{{ row.counts.failed }} 失败</span>
        </template>
      </el-table-column>
      <el-table-column label="耗时" width="80">
        <template #default="{ row }">{{ fmtDuration(row.created_at, row.finished_at) }}</template>
      </el-table-column>
    </el-table>
  </el-card>
</template>

<script setup>
import { onMounted, onUnmounted, ref } from 'vue'
import { ElMessage } from 'element-plus'
import { ACTION_TEXT, fmtDuration, fmtTime, api } from '../api'

const tasks = ref([])
const loading = ref(false)
const auto = ref(true)
let timer = null

async function load() {
  loading.value = true
  try {
    const data = await api.tasks(100)
    tasks.value = data.tasks
  } catch (e) {
    ElMessage.error(`加载失败: ${e.message}`)
  } finally {
    loading.value = false
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
  if (auto.value) timer = setInterval(load, 3000)
}

onMounted(() => { load(); setTimer() })
onUnmounted(() => clearInterval(timer))
</script>

<style scoped>
.card-header { display: flex; justify-content: space-between; align-items: center; }
.sub-wrap { padding: 4px 12px 12px 48px; }
.err { color: var(--el-color-danger); }
.ok { color: var(--el-color-success); }
</style>
