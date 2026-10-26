<template>
  <div v-loading="loading">
    <el-alert v-for="e in serviceErrors" :key="e.service" :title="`${e.service}：${e.error}`"
              type="warning" show-icon :closable="false" style="margin-bottom: 12px" />

    <div class="header-row">
      <span class="hint">点击服务进入子页面：配置编辑 / 启停操作 / 运行实例 / 日志</span>
      <el-button size="small" @click="load" :loading="loading">刷新</el-button>
    </div>

    <el-row :gutter="16">
      <el-col v-for="svc in services" :key="svc.name" :xs="24" :sm="12" :lg="8" style="margin-bottom: 16px">
        <el-card shadow="hover" class="svc-card" @click="$router.push(`/services/${svc.name}`)">
          <div class="svc-title">
            <span class="svc-name">{{ svc.name }}</span>
            <el-tag v-if="runningCount(svc.name)" type="success" size="small">
              {{ runningCount(svc.name) }} 节点运行中
            </el-tag>
            <el-tag v-else-if="instanceCount(svc.name)" type="info" size="small">
              {{ instanceCount(svc.name) }} 实例未运行
            </el-tag>
          </div>
          <div class="svc-desc">{{ svc.description || '（无描述）' }}</div>
          <div class="svc-meta">
            <div class="meta-line"><span class="k">workspace</span><span class="v">{{ svc.workspace }}</span></div>
            <div class="meta-line"><span class="k">启动脚本</span><span class="v">{{ svc.start.script }}</span></div>
            <div class="meta-line">
              <span class="k">日志</span>
              <span class="v">logs/&lt;run_id&gt;/{{ svc.start.log }}</span>
            </div>
          </div>
        </el-card>
      </el-col>
    </el-row>

    <el-empty v-if="!loading && !services.length"
              description="services/ 目录下暂无有效服务，请添加后到「集群节点」页重载配置" />
  </div>
</template>

<script setup>
import { onActivated, onMounted, reactive, ref } from 'vue'
import { ElMessage } from 'element-plus'
import { api } from '../api'

const services = ref([])
const serviceErrors = ref([])
const loading = ref(false)
const instanceSummary = reactive({}) // service -> {running, total}

function runningCount(name) { return instanceSummary[name]?.running || 0 }
function instanceCount(name) { return instanceSummary[name]?.total || 0 }

async function load() {
  loading.value = true
  try {
    const [svcData, instData] = await Promise.all([
      api.services(),
      api.instances().catch(() => ({ instances: [] })),
    ])
    services.value = svcData.services
    serviceErrors.value = svcData.errors
    for (const s of services.value) delete instanceSummary[s.name]
    for (const inst of instData.instances) {
      const item = instanceSummary[inst.service] || (instanceSummary[inst.service] = { running: 0, total: 0 })
      item.total += 1
      if (inst.status === 'running') item.running += 1
    }
  } catch (e) {
    ElMessage.error(`加载失败: ${e.message}`)
  } finally {
    loading.value = false
  }
}

onMounted(load)
onActivated(load)
</script>

<style scoped>
.header-row { display: flex; justify-content: flex-end; align-items: center; gap: 12px; margin-bottom: 14px; }
.hint { color: var(--el-text-color-secondary); font-size: 13px; margin-right: auto; }
.svc-card { cursor: pointer; transition: border-color .2s; height: 100%; }
.svc-card:hover { border-color: var(--el-color-primary); }
.svc-title { display: flex; align-items: center; gap: 10px; margin-bottom: 8px; }
.svc-name { font-weight: 600; font-size: 15px; }
.svc-desc { color: var(--el-text-color-secondary); font-size: 13px; margin-bottom: 12px; min-height: 20px; }
.svc-meta { border-top: 1px solid var(--el-border-color-lighter); padding-top: 10px; }
.meta-line { display: flex; font-size: 12px; line-height: 1.9; }
.meta-line .k { color: var(--el-text-color-secondary); width: 72px; flex-shrink: 0; }
.meta-line .v { color: var(--el-text-color-regular); word-break: break-all; font-family: Consolas, monospace; }
</style>
