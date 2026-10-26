<template>
  <div v-loading="loading">
    <el-alert v-for="e in serviceErrors" :key="e.service" :title="`${e.service}：${e.error}`"
              type="warning" show-icon :closable="false" style="margin-bottom: 12px" />

    <div class="header-row">
      <span class="hint">服务是模板，启动后按 (服务, 节点) 生成实例；实例是重启/停止的操作单位</span>
      <el-button size="small" @click="load" :loading="loading">刷新</el-button>
      <el-button size="small" type="primary" @click="createDialog = true">新建服务</el-button>
    </div>

    <el-dialog v-model="createDialog" title="新建服务" width="480px">
      <el-form label-width="90px">
        <el-form-item label="服务名称">
          <el-input v-model="newName" placeholder="仅字母数字._- ，如 etcd" maxlength="64" />
        </el-form-item>
      </el-form>
      <el-alert type="info" :closable="false" show-icon
                title="将从 services/example 模板克隆（含示例脚本），创建后请在子页面修改 workspace 等配置并替换真实启动脚本" />
      <template #footer>
        <el-button @click="createDialog = false">取消</el-button>
        <el-button type="primary" :loading="creating" @click="create">创建并编辑</el-button>
      </template>
    </el-dialog>

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
import { useRouter } from 'vue-router'
import { api } from '../api'

const router = useRouter()
const services = ref([])
const serviceErrors = ref([])
const loading = ref(false)
const instanceSummary = reactive({}) // service -> {running, total}
const createDialog = ref(false)
const newName = ref('')
const creating = ref(false)

function runningCount(name) { return instanceSummary[name]?.running || 0 }
function instanceCount(name) { return instanceSummary[name]?.total || 0 }

async function create() {
  const name = newName.value.trim()
  if (!/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(name)) {
    ElMessage.warning('服务名仅允许字母数字._-，且以字母数字开头')
    return
  }
  creating.value = true
  try {
    await api.createService(name)
    ElMessage.success(`服务 ${name} 已创建（克隆自 example 模板）`)
    createDialog.value = false
    newName.value = ''
    router.push(`/services/${name}`)
  } catch (e) {
    ElMessage.error(`创建失败: ${e.message}`)
  } finally {
    creating.value = false
  }
}

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
