<template>
  <div>
    <el-alert v-if="error" :title="`cluster.json 加载失败：${error}`" type="error" show-icon :closable="false" style="margin-bottom: 16px" />

    <el-card shadow="never">
      <template #header>
        <div class="card-header">
          <span>集群节点（cluster.json）</span>
          <div>
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
        <el-table-column label="操作" width="100">
          <template #default="{ row }">
            <el-button size="small" link type="primary" @click="testOne(row.name)">测试</el-button>
          </template>
        </el-table-column>
      </el-table>
    </el-card>
  </div>
</template>

<script setup>
import { onMounted, reactive, ref } from 'vue'
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

onMounted(load)
</script>

<style scoped>
.card-header { display: flex; justify-content: space-between; align-items: center; }
</style>
