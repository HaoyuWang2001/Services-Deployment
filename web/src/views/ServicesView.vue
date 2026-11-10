<template>
  <div class="sd-page" v-loading="loading">
    <PageHeader title="服务管理" description="服务是模板，启动后按（服务、节点）生成实例；实例是启动/停止/重启的操作单位">
      <template #actions>
        <el-tooltip content="刷新" placement="top">
          <el-button size="small" circle :icon="Refresh" :loading="loading" aria-label="刷新服务列表" @click="load" />
        </el-tooltip>
        <el-button size="small" type="primary" @click="openCreate">新建服务</el-button>
      </template>
    </PageHeader>

    <el-alert v-for="e in serviceErrors" :key="e.service" :title="`${e.service}：${e.error}`"
              type="warning" show-icon :closable="false" />

    <el-dialog v-model="createDialog" title="新建服务" width="480px">
      <el-form ref="formRef" :model="form" :rules="rules" label-width="90px" @submit.prevent>
        <el-form-item label="服务名称" prop="name">
          <el-input v-model="form.name" placeholder="仅字母数字 ._-，如 etcd" maxlength="64"
                    @keydown.enter.prevent="create" />
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
      <el-col v-for="svc in services" :key="svc.name" :xs="24" :sm="12" :lg="8" class="col">
        <el-card shadow="hover" class="svc-card" tabindex="0" role="link"
                 :aria-label="`进入服务 ${svc.name}`"
                 @click="openService(svc)"
                 @keydown.enter.prevent="openService(svc)"
                 @keydown.space.prevent="openService(svc)">
          <div class="svc-title">
            <span class="svc-name">{{ svc.name }}</span>
            <el-tag v-if="runningCount(svc.name)" type="success" size="small">
              {{ runningCount(svc.name) }} 节点运行中
            </el-tag>
            <el-tag v-else-if="instanceCount(svc.name)" type="info" size="small" effect="plain">
              {{ instanceCount(svc.name) }} 实例未运行
            </el-tag>
            <el-tag v-else type="info" size="small" effect="plain">无实例</el-tag>
            <el-icon class="enter-icon" aria-hidden="true"><ArrowRight /></el-icon>
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

    <el-empty v-if="!loading && !services.length" description="services/ 目录下暂无有效服务">
      <el-button type="primary" @click="openCreate">新建服务</el-button>
      <el-button @click="$router.push('/cluster')">到集群节点页重载配置</el-button>
    </el-empty>
  </div>
</template>

<script setup>
import { onActivated, reactive, ref } from 'vue'
import { ElMessage } from 'element-plus'
import { ArrowRight, Refresh } from '@element-plus/icons-vue'
import { useRouter } from 'vue-router'
import { api } from '../api'
import PageHeader from '../components/PageHeader.vue'

const router = useRouter()
const services = ref([])
const serviceErrors = ref([])
const loading = ref(false)
const instanceSummary = reactive({}) // service -> {running, total}
const createDialog = ref(false)
const creating = ref(false)
const formRef = ref(null)
const form = reactive({ name: '' })
const rules = {
  name: [
    { required: true, message: '请输入服务名称', trigger: 'blur' },
    { pattern: /^[A-Za-z0-9][A-Za-z0-9._-]*$/, message: '仅允许字母数字 ._-，且以字母数字开头', trigger: 'blur' },
  ],
}

function runningCount(name) { return instanceSummary[name]?.running || 0 }
function instanceCount(name) { return instanceSummary[name]?.total || 0 }

function openService(svc) {
  router.push(`/services/${svc.name}`)
}

function openCreate() {
  form.name = ''
  createDialog.value = true
  formRef.value?.clearValidate()
}

async function create() {
  try { await formRef.value.validate() } catch { return }
  const name = form.name.trim()
  creating.value = true
  try {
    await api.createService(name)
    ElMessage.success(`服务 ${name} 已创建（克隆自 example 模板）`)
    createDialog.value = false
    router.push(`/services/${name}`)
  } catch (e) {
    ElMessage.error(`创建失败：${e.message}`)
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
    ElMessage.error(`加载失败：${e.message}`)
  } finally {
    loading.value = false
  }
}

onActivated(load)
</script>

<style scoped>
.col { margin-bottom: var(--sd-space-4); }
.svc-card {
  cursor: pointer;
  transition: border-color 150ms ease-out;
  height: 100%;
  border-radius: var(--sd-radius);
  outline: none;
}
.svc-card:hover, .svc-card:focus-visible { border-color: var(--el-color-primary); }
.svc-title { display: flex; align-items: center; gap: var(--sd-space-2); margin-bottom: var(--sd-space-2); }
.svc-name { font-weight: 600; font-size: 14px; }
.enter-icon { margin-left: auto; color: var(--el-text-color-placeholder); }
.svc-desc { color: var(--el-text-color-secondary); font-size: 13px; margin-bottom: var(--sd-space-3); min-height: 20px; }
.svc-meta { border-top: 1px solid var(--el-border-color-lighter); padding-top: var(--sd-space-2); }
.meta-line { display: flex; font-size: 12px; line-height: 1.9; }
.meta-line .k { color: var(--el-text-color-secondary); width: 72px; flex-shrink: 0; }
.meta-line .v { color: var(--el-text-color-regular); word-break: break-all; font-family: var(--sd-font-mono); }
</style>
