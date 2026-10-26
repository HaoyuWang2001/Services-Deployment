<template>
  <div>
    <el-alert v-if="error" :title="`cluster.json 加载失败：${error}`" type="error" show-icon :closable="false" style="margin-bottom: 16px" />

    <el-card shadow="never">
      <template #header>
        <div class="card-header">
          <span>集群节点（cluster.json）</span>
          <div>
            <el-button size="small" @click="openPortQuery">端口查询</el-button>
            <el-button size="small" @click="reloadConfig">重新加载配置</el-button>
            <el-button size="small" type="primary" @click="testAll" :loading="testing">全部测试连接</el-button>
          </div>
        </div>
      </template>

      <el-table :data="nodes" v-loading="loading" empty-text="暂无节点：请复制 cluster.example.json 为 cluster.json 并修改，然后点击「重新加载配置」">
        <el-table-column prop="name" label="名称" width="140" />
        <el-table-column prop="ip" label="IP" width="160" />
        <el-table-column prop="username" label="用户名" width="100" />
        <el-table-column prop="port" label="端口" width="80" />
        <el-table-column prop="private_key" label="私钥" min-width="180" show-overflow-tooltip />
        <el-table-column label="连接状态" width="120">
          <template #default="{ row }">
            <el-tag v-if="results[row.name]?.ok" type="success" size="small">正常</el-tag>
            <el-tooltip v-else-if="results[row.name]" :content="results[row.name].detail" placement="top">
              <el-tag type="danger" size="small">失败</el-tag>
            </el-tooltip>
            <el-tag v-else type="info" size="small">未测试</el-tag>
          </template>
        </el-table-column>
        <el-table-column label="环境" min-width="140">
          <template #default="{ row }">
            <span v-if="results[row.name]?.ok">{{ results[row.name].kernel }}（{{ results[row.name].arch }}）</span>
            <span v-else>-</span>
          </template>
        </el-table-column>
        <el-table-column label="操作" width="140">
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
        <el-input v-model="portsFilter" placeholder="按端口或进程名过滤" size="small" clearable style="width: 260px" />
        <el-button size="small" @click="loadPorts(portsNode)" :loading="portsLoading">刷新</el-button>
        <el-alert v-if="portsWarning" :title="portsWarning" type="warning" show-icon :closable="false" style="flex: 1" />
      </div>
      <el-alert v-if="portsError" :title="portsError" type="error" show-icon :closable="false" style="margin-bottom: 10px" />
      <el-table :data="filteredPorts" v-loading="portsLoading" size="small"
                empty-text="暂无监听端口（或节点不可达）">
        <el-table-column prop="proto" label="协议" width="70" />
        <el-table-column prop="state" label="状态" width="90" />
        <el-table-column prop="local_addr" label="监听地址" min-width="140" />
        <el-table-column prop="port" label="端口" width="90" sortable />
        <el-table-column label="进程" min-width="200">
          <template #default="{ row }">
            <span v-if="row.processes.length">
              <span v-for="(p, i) in row.processes" :key="i" class="proc">
                {{ p.process }}<span class="pid">(#{{ p.pid }})</span>{{ i < row.processes.length - 1 ? '、' : '' }}
              </span>
            </span>
            <span v-else class="no-proc">-</span>
          </template>
        </el-table-column>
      </el-table>
    </el-drawer>

    <!-- 端口对照查询 -->
    <el-dialog v-model="portQueryVisible" title="端口查询：多节点占用对照" width="760px">
      <div class="pq-form">
        <span class="label">端口号</span>
        <el-input-number v-model="pqPort" :min="1" :max="65535" controls-position="right" style="width: 140px" />
        <span class="label" style="margin-left: 16px">节点</span>
        <el-select v-model="pqNodes" multiple placeholder="选择节点" style="width: 360px">
          <el-option v-for="n in nodes" :key="n.name" :label="n.name" :value="n.name" />
        </el-select>
        <el-button type="primary" size="small" :loading="pqLoading" @click="runPortQuery">查询</el-button>
      </div>
      <el-table :data="pqResults" v-loading="pqLoading" size="small" style="margin-top: 12px"
                empty-text="输入端口号并选择节点后查询">
        <el-table-column prop="node" label="节点" width="110" />
        <el-table-column label="结果" width="100">
          <template #default="{ row }">
            <el-tag v-if="row.ok === null" type="info" size="small">未查询</el-tag>
            <el-tag v-else-if="row.ok && row.matches.length" type="danger" size="small">占用</el-tag>
            <el-tag v-else-if="row.ok" type="success" size="small">空闲</el-tag>
            <el-tag v-else type="warning" size="small">失败</el-tag>
          </template>
        </el-table-column>
        <el-table-column label="占用进程 / 说明" min-width="320">
          <template #default="{ row }">
            <span v-if="row.ok && row.matches.length">
              <span v-for="(m, i) in row.matches" :key="i" class="proc">
                {{ m.proto }} {{ m.local_addr }}:{{ m.port }} → {{ m.processes.map(p => `${p.process}(#${p.pid})`).join('、') || '未知进程' }}{{ i < row.matches.length - 1 ? '；' : '' }}
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
import { computed, onMounted, reactive, ref } from 'vue'
import { ElMessage } from 'element-plus'
import { api } from '../api'

const nodes = ref([])
const error = ref(null)
const loading = ref(false)
const testing = ref(false)
const results = reactive({})

async function load() {
  loading.value = true
  try {
    const data = await api.nodes()
    nodes.value = data.nodes
    error.value = data.error
  } catch (e) {
    ElMessage.error(`加载节点失败: ${e.message}`)
  } finally {
    loading.value = false
  }
}

async function testOne(name) {
  try {
    results[name] = { ...(await api.testNode(name)) }
    if (!results[name].ok) ElMessage.warning(`${name}: ${results[name].detail}`)
  } catch (e) {
    results[name] = { ok: false, detail: e.message }
    ElMessage.error(`${name}: ${e.message}`)
  }
}

async function testAll() {
  testing.value = true
  try {
    await Promise.all(nodes.value.map((n) => testOne(n.name)))
    ElMessage.success('测试完成')
  } finally {
    testing.value = false
  }
}

async function reloadConfig() {
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
    p.processes.some((x) => x.process.toLowerCase().includes(kw)))
})

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

onMounted(load)
</script>

<style scoped>
.card-header { display: flex; justify-content: space-between; align-items: center; }
.drawer-toolbar { display: flex; gap: 10px; align-items: center; margin-bottom: 10px; }
.proc { font-family: Consolas, monospace; }
.pid { color: var(--el-text-color-secondary); }
.no-proc { color: var(--el-text-color-placeholder); }
.pq-form { display: flex; align-items: center; gap: 8px; }
.pq-form .label { color: var(--el-text-color-secondary); font-size: 13px; }
</style>
