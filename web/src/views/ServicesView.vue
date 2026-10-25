<template>
  <div v-loading="loading">
    <el-alert v-for="e in serviceErrors" :key="e.service" :title="`${e.service}：${e.error}`"
              type="warning" show-icon :closable="false" style="margin-bottom: 12px" />

    <el-card v-for="svc in services" :key="svc.name" shadow="never" class="svc-card">
      <template #header>
        <div class="svc-header">
          <div>
            <span class="svc-name">{{ svc.name }}</span>
            <span class="svc-desc">{{ svc.description }}</span>
          </div>
        </div>
      </template>

      <el-descriptions :column="3" size="small" border class="svc-info">
        <el-descriptions-item label="workspace">{{ svc.workspace }}</el-descriptions-item>
        <el-descriptions-item label="启动脚本">{{ svc.start.script }} <template v-if="svc.start.args?.length">（args: {{ svc.start.args.join(' ') }}）</template></el-descriptions-item>
        <el-descriptions-item label="日志文件">logs/&lt;run_id&gt;/{{ svc.start.log }}</el-descriptions-item>
        <el-descriptions-item v-if="svc.stop.script" label="停止脚本">{{ svc.stop.script }}</el-descriptions-item>
        <el-descriptions-item v-else label="停止方式">按 PID kill（{{ svc.stop.timeout }}s 超时强杀）</el-descriptions-item>
        <el-descriptions-item v-if="Object.keys(svc.variables).length" label="默认变量">
          <code v-for="(v, k) in svc.variables" :key="k" class="var-chip">{{ k }}={{ v }}</code>
        </el-descriptions-item>
      </el-descriptions>

      <div class="op-area">
        <div class="node-select">
          <span class="label">目标节点：</span>
          <el-checkbox-group v-model="selected[svc.name]">
            <el-checkbox v-for="n in nodes" :key="n" :value="n">{{ n }}</el-checkbox>
          </el-checkbox-group>
        </div>

        <div v-if="Object.keys(svc.variables).length" class="var-form">
          <span class="label">变量覆盖：</span>
          <div class="var-inputs">
            <div v-for="(_, k) in svc.variables" :key="k" class="var-input">
              <span class="var-key">{{ k }}</span>
              <el-input v-model="vars[svc.name][k]" size="small" style="width: 220px" :placeholder="`默认 ${svc.variables[k]}`" />
            </div>
          </div>
        </div>

        <div class="actions">
          <el-button size="small" @click="submit(svc, 'deploy')">仅部署文件</el-button>
          <el-button size="small" type="primary" @click="submit(svc, 'start')">启动</el-button>
          <el-button size="small" type="warning" @click="submit(svc, 'restart')">重启</el-button>
          <el-button size="small" type="danger" @click="submit(svc, 'stop')">停止</el-button>
        </div>
      </div>
    </el-card>

    <el-empty v-if="!loading && !services.length" description="services/ 目录下暂无有效服务，请添加后到「集群节点」页重载配置" />
  </div>
</template>

<script setup>
import { onMounted, reactive, ref } from 'vue'
import { ElMessage, ElMessageBox } from 'element-plus'
import { useRouter } from 'vue-router'
import { ACTION_TEXT, api } from '../api'

const router = useRouter()
const services = ref([])
const serviceErrors = ref([])
const nodes = ref([])
const loading = ref(false)
const selected = reactive({})
const vars = reactive({})

async function load() {
  loading.value = true
  try {
    const [svcData, nodeData] = await Promise.all([api.services(), api.nodes()])
    services.value = svcData.services
    serviceErrors.value = svcData.errors
    nodes.value = nodeData.nodes.map((n) => n.name)
    for (const s of services.value) {
      if (!selected[s.name]) selected[s.name] = []
      if (!vars[s.name]) {
        vars[s.name] = {}
        for (const k of Object.keys(s.variables)) vars[s.name][k] = ''
      }
    }
  } catch (e) {
    ElMessage.error(`加载失败: ${e.message}`)
  } finally {
    loading.value = false
  }
}

async function submit(svc, action) {
  const nodesPicked = selected[svc.name] || []
  if (!nodesPicked.length) {
    ElMessage.warning('请先勾选目标节点')
    return
  }
  if (action === 'stop' || action === 'restart') {
    try {
      await ElMessageBox.confirm(
        `确定在 ${nodesPicked.join('、')} 上${ACTION_TEXT[action]}服务 ${svc.name}？`,
        `${ACTION_TEXT[action]}确认`, { type: 'warning' })
    } catch { return }
  }
  const variables = {}
  for (const [k, v] of Object.entries(vars[svc.name] || {})) {
    if (v !== '') variables[k] = v
  }
  try {
    const task = await api.createTask({ service: svc.name, action, nodes: nodesPicked, variables })
    ElMessage.success(`任务已提交（${task.id}），正在跳转任务页查看进度`)
    router.push('/tasks')
  } catch (e) {
    ElMessage.error(`创建任务失败: ${e.message}`)
  }
}

onMounted(load)
</script>

<style scoped>
.svc-card { margin-bottom: 16px; }
.svc-name { font-weight: 600; margin-right: 10px; }
.svc-desc { color: var(--el-text-color-secondary); font-size: 13px; }
.svc-info { margin-bottom: 14px; }
.var-chip { background: var(--el-fill-color); padding: 1px 6px; border-radius: 4px; margin-right: 6px; }
.label { color: var(--el-text-color-secondary); font-size: 13px; }
.node-select { margin-bottom: 10px; }
.var-form { margin-bottom: 10px; display: flex; align-items: flex-start; }
.var-inputs { display: flex; flex-wrap: wrap; gap: 8px; }
.var-input { display: flex; align-items: center; gap: 6px; }
.var-key { font-size: 12px; color: var(--el-text-color-regular); }
.actions { margin-top: 4px; }
</style>
