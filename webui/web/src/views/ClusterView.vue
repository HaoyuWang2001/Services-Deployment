<template>
  <div class="sd-page">
    <PageHeader title="集群节点" description="cluster.json 中的节点列表；测试 SSH 连通性与监听端口">
      <template #actions>
        <el-button size="small" @click="openPortQuery">端口查询</el-button>
        <el-button size="small" @click="reloadConfig" :loading="reloading">重新加载配置</el-button>
        <el-button size="small" type="primary" @click="testAll" :loading="testing">全部测试连接</el-button>
      </template>
    </PageHeader>

    <el-alert v-if="error" :title="`cluster.json 加载失败：${error}`" type="error" show-icon :closable="false" />

    <el-card shadow="never">
      <el-table :data="nodes" v-loading="loading" size="small">
        <template #empty>
          <el-empty description="暂无节点配置">
            <el-button size="small" @click="reloadConfig" :loading="reloading">重新加载配置</el-button>
          </el-empty>
        </template>
        <el-table-column prop="name" label="名称" width="140" />
        <el-table-column label="IP" width="160">
          <template #default="{ row }"><span class="sd-mono">{{ row.ip }}</span></template>
        </el-table-column>
        <el-table-column prop="username" label="用户名" width="110" />
        <el-table-column label="端口" width="80">
          <template #default="{ row }"><span class="sd-num">{{ row.port }}</span></template>
        </el-table-column>
        <el-table-column prop="private_key" label="私钥" min-width="180" show-overflow-tooltip />
        <el-table-column label="sudo" width="70">
          <template #default="{ row }">
            <el-tooltip v-if="row.sudo" content="特权操作（端口监控）经 sudo -n 执行" placement="top">
              <el-tag type="warning" size="small">sudo</el-tag>
            </el-tooltip>
            <span v-else class="sd-muted">-</span>
          </template>
        </el-table-column>
        <el-table-column label="连接状态" width="120">
          <template #default="{ row }">
            <el-tag v-if="results[row.name]?.ok" type="success" size="small">正常</el-tag>
            <el-tooltip v-else-if="results[row.name]" :content="results[row.name].detail" placement="top">
              <el-tag type="danger" size="small">失败</el-tag>
            </el-tooltip>
            <el-tag v-else type="info" size="small" effect="plain">未测试</el-tag>
          </template>
        </el-table-column>
        <el-table-column label="环境" min-width="140">
          <template #default="{ row }">
            <span v-if="results[row.name]?.ok">{{ results[row.name].kernel }}（{{ results[row.name].arch }}）</span>
            <span v-else class="sd-muted">-</span>
          </template>
        </el-table-column>
        <el-table-column label="操作" width="130">
          <template #default="{ row }">
            <el-button size="small" link type="primary" @click="testOne(row.name)">测试</el-button>
            <el-button size="small" link type="primary" @click="openPorts(row.name)">端口</el-button>
          </template>
        </el-table-column>
      </el-table>
    </el-card>

    <!-- 节点端口抽屉 -->
    <el-drawer v-model="portsVisible" :title="`节点 ${portsNode} 监听端口`" size="62%">
      <div class="drawer-toolbar">
        <el-input v-model="portsFilter" placeholder="按端口/进程/用户过滤" size="small" clearable style="width: 260px" />
        <el-button size="small" @click="loadPorts(portsNode)" :loading="portsLoading">刷新</el-button>
      </div>
      <el-alert v-if="portsWarning" :title="portsWarning" type="warning" show-icon :closable="false" class="mb-3" />
      <el-alert v-if="portsError" :title="portsError" type="error" show-icon :closable="false" class="mb-3" />
      <el-table :data="filteredPorts" v-loading="portsLoading" size="small">
        <template #empty><el-empty description="暂无监听端口（或节点不可达）" :image-size="60" /></template>
        <el-table-column prop="proto" label="协议" width="70" />
        <el-table-column prop="state" label="状态" width="90" />
        <el-table-column prop="local_addr" label="监听地址" min-width="140" />
        <el-table-column label="端口" width="90" sortable>
          <template #default="{ row }"><span class="sd-num">{{ row.port }}</span></template>
        </el-table-column>
        <el-table-column label="用户" width="110">
          <template #default="{ row }">
            <span v-if="usersOf(row).length">{{ usersOf(row).join('、') }}</span>
            <span v-else class="sd-muted">-</span>
          </template>
        </el-table-column>
        <el-table-column label="进程" min-width="200">
          <template #default="{ row }">
            <span v-if="row.processes.length">
              <span v-for="(p, i) in row.processes" :key="i" class="sd-mono">
                {{ p.process }}<span class="pid">（#{{ p.pid }}）</span>{{ i < row.processes.length - 1 ? '、' : '' }}
              </span>
            </span>
            <span v-else class="sd-muted">-</span>
          </template>
        </el-table-column>
      </el-table>
    </el-drawer>

    <!-- 端口对照查询 -->
    <el-dialog v-model="portQueryVisible" title="端口查询：多节点占用对照" width="760px">
      <div class="pq-form">
        <span class="sd-label">端口号</span>
        <el-input-number v-model="pqPort" :min="1" :max="65535" controls-position="right" size="small" style="width: 140px" />
        <span class="sd-label">节点</span>
        <el-select v-model="pqNodes" multiple filterable placeholder="选择节点" size="small" style="width: 360px">
          <el-option v-for="n in nodes" :key="n.name" :label="n.name" :value="n.name" />
        </el-select>
        <el-button type="primary" size="small" :loading="pqLoading" @click="runPortQuery">查询</el-button>
      </div>
      <el-table :data="pqResults" v-loading="pqLoading" size="small" class="mt-3">
        <template #empty><el-empty description="输入端口号并选择节点后查询" :image-size="60" /></template>
        <el-table-column prop="node" label="节点" width="110" />
        <el-table-column label="结果" width="100">
          <template #default="{ row }">
            <el-tag v-if="row.ok === null" type="info" size="small" effect="plain">未查询</el-tag>
            <el-tag v-else-if="row.ok && row.matches.length" type="danger" size="small">占用</el-tag>
            <el-tag v-else-if="row.ok" type="success" size="small">空闲</el-tag>
            <el-tag v-else type="warning" size="small">失败</el-tag>
          </template>
        </el-table-column>
        <el-table-column label="占用进程 / 说明" min-width="320">
          <template #default="{ row }">
            <span v-if="row.ok && row.matches.length" class="sd-mono">
              <span v-for="(m, i) in row.matches" :key="i">
                {{ m.proto }} {{ m.local_addr }}:{{ m.port }} → {{ m.processes.map(p => `${p.user || '?'}:${p.process}（#${p.pid}）`).join('、') || '未知进程' }}{{ i < row.matches.length - 1 ? '；' : '' }}
              </span>
            </span>
            <span v-else>{{ row.detail || '-' }}</span>
          </template>
        </el-table-column>
      </el-table>
    </el-dialog>
  </div>
</template>

<script setup>
import { computed, onActivated, reactive, ref } from 'vue'
import { ElMessage, ElMessageBox } from 'element-plus'
import { api } from '../api'
import PageHeader from '../components/PageHeader.vue'

const nodes = ref([])
const error = ref(null)
const loading = ref(false)
const testing = ref(false)
const reloading = ref(false)
const results = reactive({})

const TEST_CONCURRENCY = 5

async function load() {
  loading.value = true
  try {
    const data = await api.nodes()
    nodes.value = data.nodes
    error.value = data.error
  } catch (e) {
    ElMessage.error(`加载节点失败：${e.message}`)
  } finally {
    loading.value = false
  }
}

async function probeNode(name) {
  try {
    const r = await api.testNode(name)
    results[name] = { ...r }
    return { name, ok: !!r.ok, detail: r.detail }
  } catch (e) {
    results[name] = { ok: false, detail: e.message }
    return { name, ok: false, detail: e.message }
  }
}

async function testOne(name) {
  const r = await probeNode(name)
  if (!r.ok) ElMessage.warning(`${name}：${r.detail}`)
}

async function testAll() {
  if (!nodes.value.length) {
    ElMessage.warning('暂无节点可测试')
    return
  }
  testing.value = true
  const queue = nodes.value.map((n) => n.name)
  const out = []
  const worker = async () => {
    while (queue.length) out.push(await probeNode(queue.shift()))
  }
  try {
    await Promise.all(Array.from({ length: Math.min(TEST_CONCURRENCY, queue.length) }, worker))
    const failed = out.filter((r) => !r.ok)
    if (!failed.length) {
      ElMessage.success(`全部 ${out.length} 个节点连接正常`)
    } else {
      ElMessage.warning(`${out.length} 个节点中 ${failed.length} 个连接失败：${failed.map((f) => f.name).join('、')}`)
    }
  } finally {
    testing.value = false
  }
}

async function reloadConfig() {
  try {
    await ElMessageBox.confirm(
      '将重新读取 cluster.json 与 services/ 配置。未保存的配置编辑内容会丢失，确定继续？',
      '重新加载配置',
      { type: 'warning', confirmButtonText: '重新加载', cancelButtonText: '取消' },
    )
  } catch { return }
  reloading.value = true
  try {
    const r = await api.reloadConfig()
    await load()
    if (r.service_errors?.length) {
      ElMessage.warning(`已重载：${r.nodes} 节点，${r.services.length} 服务，${r.service_errors.length} 个服务配置错误`)
    } else {
      ElMessage.success(`已重载：${r.nodes} 节点，${r.services.length} 服务`)
    }
  } catch (e) {
    ElMessage.error(e.message)
  } finally {
    reloading.value = false
  }
}

// ---------------------------------------------------------------- 端口抽屉
const portsVisible = ref(false)
const portsNode = ref('')
const portsData = ref([])
const portsLoading = ref(false)
const portsError = ref(null)
const portsWarning = ref(null)
const portsFilter = ref('')

const filteredPorts = computed(() => {
  const kw = portsFilter.value.trim().toLowerCase()
  if (!kw) return portsData.value
  return portsData.value.filter((p) =>
    String(p.port).includes(kw) ||
    p.processes.some((x) =>
      x.process.toLowerCase().includes(kw) || (x.user || '').toLowerCase().includes(kw)))
})

function usersOf(row) {
  return [...new Set(row.processes.map((p) => p.user).filter(Boolean))]
}

async function loadPorts(name) {
  portsLoading.value = true
  portsError.value = null
  try {
    const r = await api.nodePorts(name)
    if (r.ok) {
      portsData.value = r.ports
      portsWarning.value = r.warning
    } else {
      portsData.value = []
      portsWarning.value = null
      portsError.value = r.detail
    }
  } catch (e) {
    portsData.value = []
    portsError.value = e.message
  } finally {
    portsLoading.value = false
  }
}

async function openPorts(name) {
  portsNode.value = name
  portsFilter.value = ''
  portsVisible.value = true
  await loadPorts(name)
}

// ---------------------------------------------------------------- 端口查询
const portQueryVisible = ref(false)
const pqPort = ref(22)
const pqNodes = ref([])
const pqLoading = ref(false)
const pqResults = ref([])

async function runPortQuery() {
  if (!pqPort.value || !pqNodes.value.length) {
    ElMessage.warning('请输入端口号并选择节点')
    return
  }
  pqLoading.value = true
  pqResults.value = pqNodes.value.map((n) => ({ node: n, ok: null, matches: [], detail: '' }))
  await Promise.all(pqNodes.value.map(async (n) => {
    const row = pqResults.value.find((r) => r.node === n)
    try {
      const r = await api.nodePorts(n)
      if (r.ok) {
        row.ok = true
        row.matches = r.ports.filter((p) => p.port === pqPort.value)
        row.detail = ''
      } else {
        row.ok = false
        row.detail = r.detail
      }
    } catch (e) {
      row.ok = false
      row.detail = e.message
    }
  }))
  pqLoading.value = false
}

function openPortQuery() {
  if (!pqNodes.value.length) pqNodes.value = nodes.value.map((n) => n.name)
  portQueryVisible.value = true
}

onActivated(load)
</script>

<style scoped>
.drawer-toolbar { display: flex; gap: var(--sd-space-2); align-items: center; margin-bottom: var(--sd-space-3); }
.pid { color: var(--el-text-color-secondary); }
.pq-form { display: flex; align-items: center; gap: var(--sd-space-2); }
.mb-3 { margin-bottom: var(--sd-space-3); }
.mt-3 { margin-top: var(--sd-space-3); }
</style>
