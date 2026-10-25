<template>
  <el-card shadow="never">
    <template #header>
      <div class="card-header">
        <span>运行实例</span>
        <div>
          <el-switch v-model="auto" active-text="10s 自动刷新" style="margin-right: 12px" />
          <el-button size="small" @click="load" :loading="loading">刷新</el-button>
        </div>
      </div>
    </template>

    <el-table :data="instances" v-loading="loading" empty-text="暂无运行实例">
      <el-table-column prop="service" label="服务" min-width="140" />
      <el-table-column prop="node" label="节点" width="110" />
      <el-table-column prop="pid" label="PID" width="90" />
      <el-table-column prop="run_id" label="run_id" width="170" />
      <el-table-column label="状态" width="110">
        <template #default="{ row }">
          <el-tag :type="statusType(row.status)" size="small">{{ statusText(row.status) }}</el-tag>
        </template>
      </el-table-column>
      <el-table-column prop="started_at" label="启动时间" width="180" />
      <el-table-column prop="log_path" label="日志路径" min-width="240" show-overflow-tooltip />
      <el-table-column label="操作" width="170">
        <template #default="{ row }">
          <el-button size="small" link type="primary"
                     @click="$router.push({ path: '/logs', query: { service: row.service, node: row.node, run_id: row.run_id } })">
            查看日志
          </el-button>
          <el-button size="small" link type="danger" @click="stopInstance(row)">停止</el-button>
        </template>
      </el-table-column>
    </el-table>
  </el-card>
</template>

<script setup>
import { onMounted, onUnmounted, ref } from 'vue'
import { ElMessage, ElMessageBox } from 'element-plus'
import { api } from '../api'

const instances = ref([])
const loading = ref(false)
const auto = ref(true)
let timer = null

async function load() {
  loading.value = true
  try {
    const data = await api.instances()
    instances.value = data.instances
  } catch (e) {
    ElMessage.error(`加载失败: ${e.message}`)
  } finally {
    loading.value = false
  }
}

async function stopInstance(row) {
  try {
    await ElMessageBox.confirm(
      `确定停止 ${row.node} 上的 ${row.service}（PID ${row.pid ?? '?'}）？`, '停止确认', { type: 'warning' })
  } catch { return }
  try {
    await api.createTask({ service: row.service, action: 'stop', nodes: [row.node] })
    ElMessage.success('停止任务已提交')
    setTimeout(load, 800)
  } catch (e) {
    ElMessage.error(`创建任务失败: ${e.message}`)
  }
}

function statusType(s) {
  return { running: 'success', dead: 'danger', nopidfile: 'info', nows: 'warning', unknown: 'info' }[s] || 'info'
}
function statusText(s) {
  return { running: '运行中', dead: '已退出', nopidfile: '无PID文件', nows: '未部署', unknown: '未知' }[s] || s
}

function setTimer() {
  clearInterval(timer)
  if (auto.value) timer = setInterval(load, 10000)
}

onMounted(() => { load(); setTimer() })
onUnmounted(() => clearInterval(timer))
</script>

<style scoped>
.card-header { display: flex; justify-content: space-between; align-items: center; }
</style>
