<template>
  <div v-if="loadError" class="err-block">
    <el-alert :title="loadError" type="error" show-icon :closable="false" />
    <el-button style="margin-top: 12px" @click="$router.push('/services')">返回服务列表</el-button>
  </div>

  <div v-else v-loading="!cfg">
    <!-- 页头 -->
    <div class="page-head">
      <el-button link @click="$router.push('/services')">← 返回</el-button>
      <span class="title">{{ name }}</span>
      <el-tag v-if="dirty" type="warning" size="small">有未保存的修改</el-tag>
      <div class="head-actions">
        <el-button size="small" @click="refreshFromDisk" :loading="reloading">重新读取配置</el-button>
      </div>
    </div>

    <!-- 启动实例 -->
    <el-card shadow="never" class="block">
      <template #header>
        <div class="card-header">
          <span>启动实例</span>
          <el-button size="small" :type="dirty ? 'warning' : 'primary'" plain
                     :disabled="!cfg" @click="cfgDialog = true">修改服务配置</el-button>
        </div>
      </template>

      <el-descriptions v-if="cfg" :column="4" size="small" border class="cfg-summary">
        <el-descriptions-item label="workspace">{{ cfg.workspace }}</el-descriptions-item>
        <el-descriptions-item label="启动脚本">{{ cfg.start.script }}{{ cfg.start.args?.length ? ' ' + cfg.start.args.join(' ') : '' }}</el-descriptions-item>
        <el-descriptions-item label="日志文件">logs/&lt;run_id&gt;/{{ cfg.start.log }}</el-descriptions-item>
        <el-descriptions-item label="目标节点">{{ cfg.nodes?.length ? cfg.nodes.join('、') : '全部节点' }}</el-descriptions-item>
      </el-descriptions>

      <el-alert v-if="cfg?.nodes?.length" type="info" :closable="false" show-icon
                :title="`该服务限定目标节点：${cfg.nodes.join('、')}`" style="margin-top: 10px" />
      <div class="node-select">
        <span class="label">目标节点：</span>
        <el-checkbox-group v-model="selectedNodes">
          <el-checkbox v-for="n in selectableNodes" :key="n" :value="n">{{ n }}</el-checkbox>
        </el-checkbox-group>
        <el-button size="small" class="select-all-btn" @click="selectedNodes = [...selectableNodes]">全选</el-button>
        <el-button size="small" @click="selectedNodes = []">清空</el-button>
      </div>
      <div v-if="Object.keys(cfg?.variables || {}).length" class="var-form">
        <span class="label">变量覆盖：</span>
        <div class="var-inputs">
          <div v-for="(_, k) in cfg.variables" :key="k" class="var-input">
            <span class="var-key">{{ k }}</span>
            <el-input v-model="varsOverride[k]" size="small" style="width: 220px" :placeholder="`默认 ${cfg.variables[k]}`" />
          </div>
        </div>
      </div>
      <div class="actions">
        <el-button size="small" :disabled="blockReasons.length > 0" @click="submit('deploy')">仅部署文件</el-button>
        <el-checkbox v-model="autoStart" class="auto-start">立即启动</el-checkbox>
        <el-button class="start-btn" size="small" type="primary"
                   :disabled="blockReasons.length > 0" @click="submit('create')">创建实例</el-button>
        <span v-if="blockReasons.length" class="dirty-hint">{{ blockReasons.join('；') }}</span>
        <span v-else class="hint-secondary">创建后：启动 / 重启 / 停止 / 删除均在实例层级操作</span>
      </div>
    </el-card>

    <!-- 运行实例 -->
    <el-card shadow="never" class="block">
      <template #header>
        <div class="card-header">
          <div class="inst-title">
            <span>运行实例</span>
            <el-tooltip content="刷新" placement="top">
              <el-button size="small" circle :icon="Refresh" :loading="instLoading" @click="loadInstances()" />
            </el-tooltip>
          </div>
          <div class="inst-actions">
            <el-button size="small" type="success" plain
                       :disabled="!selectedInsts.length || dirty" @click="batchInstanceOp('start')">
              启动选中 ({{ selectedInsts.length }})
            </el-button>
            <el-button size="small" type="warning" plain
                       :disabled="!canRestart || dirty" @click="batchInstanceOp('restart')">
              重启选中 ({{ selectedInsts.length }})
            </el-button>
            <el-button size="small" type="danger" plain
                       :disabled="!canStop || dirty" @click="batchInstanceOp('stop')">
              停止选中 ({{ selectedInsts.length }})
            </el-button>
            <el-button size="small" type="danger"
                       :disabled="!selectedInsts.length || dirty" @click="batchInstanceOp('delete')">
              删除选中 ({{ selectedInsts.length }})
            </el-button>
            <el-switch v-model="autoRefresh" active-text="10s 自动刷新" style="margin-left: 12px" />
          </div>
        </div>
      </template>
      <el-table ref="instTable" :data="instances" v-loading="instLoading" size="small" row-key="node"
                @selection-change="(rows) => (selectedInsts = rows)"
                empty-text="暂无实例（尚未启动过）">
        <el-table-column type="selection" reserve-selection width="45" />
        <el-table-column prop="node" label="节点" width="110" />
        <el-table-column prop="pid" label="PID" width="90" />
        <el-table-column prop="run_id" label="run_id" width="170" />
        <el-table-column label="状态" width="140">
          <template #default="{ row }">
            <el-tag :type="statusType(row)" size="small">{{ statusText(row) }}</el-tag>
          </template>
        </el-table-column>
        <el-table-column prop="started_at" label="最近启动" width="180" />
        <el-table-column prop="log_path" label="日志路径" min-width="200" show-overflow-tooltip />
        <el-table-column label="操作" width="80">
          <template #default="{ row }">
            <el-button size="small" link type="primary" @click="viewLog(row)">日志</el-button>
          </template>
        </el-table-column>
      </el-table>
    </el-card>

    <!-- 服务配置弹窗 -->
    <el-dialog v-model="cfgDialog" title="修改服务配置（service.json）" width="820px"
               :before-close="confirmCloseDialog" :close-on-click-modal="false" append-to-body>
      <el-form label-width="110px" label-position="left" class="cfg-form">
        <el-form-item label="描述">
          <el-input v-model="form.description" placeholder="服务描述" />
        </el-form-item>
        <el-form-item label="workspace">
          <el-input v-model="form.workspace" placeholder="各节点上的部署根目录，如 /data/services/xxx" />
        </el-form-item>
        <el-form-item label="启动脚本">
          <el-input v-model="form.script" placeholder="服务目录内相对路径，如 start.sh" style="width: 320px" />
        </el-form-item>
        <el-form-item label="启动参数">
          <el-input v-model="form.argsText" placeholder="空格分隔，可留空" style="width: 320px" />
        </el-form-item>
        <el-form-item label="日志文件名">
          <el-input v-model="form.log" placeholder="如 master.log，实际存于 logs/<run_id>/ 下" style="width: 320px" />
        </el-form-item>
        <el-form-item label="停止方式">
          <div class="stop-row">
            <el-input v-model="form.stopScript" placeholder="停止脚本（留空则按 PID kill）" style="width: 320px" />
            <span class="stop-timeout-label">kill 超时(秒)</span>
            <el-input-number v-model="form.stopTimeout" :min="1" :max="300" style="width: 110px" />
          </div>
        </el-form-item>
        <el-form-item label="目标节点">
          <el-select v-model="form.nodes" multiple filterable placeholder="留空 = 允许集群全部节点" style="width: 420px">
            <el-option v-for="n in nodes" :key="n" :label="n" :value="n" />
          </el-select>
          <div class="field-hint">配置后仅允许在这些节点上启动该服务（如 etcd 仅 node4）</div>
        </el-form-item>
        <el-form-item label="重复启动">
          <el-switch v-model="form.allowDup" />
          <div class="field-hint">默认关闭（禁止重复启动）：同节点已有运行中实例时拒绝启动；开启后允许（旧实例进程需自行管理）</div>
        </el-form-item>
        <el-form-item label="默认变量">
          <div class="vars-editor">
            <div v-for="(row, i) in form.variables" :key="i" class="var-row">
              <el-input v-model="row.key" placeholder="变量名" size="small" style="width: 200px" />
              <el-input v-model="row.value" placeholder="默认值" size="small" style="width: 280px" />
              <el-button size="small" type="danger" link @click="form.variables.splice(i, 1)">删除</el-button>
            </div>
            <el-button size="small" @click="form.variables.push({ key: '', value: '' })">+ 添加变量</el-button>
          </div>
        </el-form-item>
      </el-form>
      <template #footer>
        <div class="dialog-footer">
          <span v-if="dirty" class="dirty-hint">有未保存的修改：保存前禁止启动 / 停止 / 重启操作</span>
          <el-button :disabled="!dirty" @click="discard">放弃修改</el-button>
          <el-button type="primary" :disabled="!dirty" :loading="saving" @click="save">保存并关闭</el-button>
        </div>
      </template>
    </el-dialog>
  </div>
</template>

<script setup>
import { computed, onActivated, onDeactivated, onMounted, reactive, ref, watch } from 'vue'
import { ElMessage, ElMessageBox } from 'element-plus'
import { Refresh } from '@element-plus/icons-vue'
import { useRoute, useRouter } from 'vue-router'
import { api, ACTION_TEXT } from '../api'
import { trackTask } from '../taskNotify'
import { statusType, statusText } from '../instanceStatus'
const route = useRoute()
const useRouterPush = useRouter().push

const name = computed(() => String(route.params.name || ''))
const cfg = ref(null)
const loadError = ref(null)
const nodes = ref([])
const selectedNodes = ref([])
const varsOverride = reactive({})

const form = reactive({
  description: '', workspace: '', nodes: [], allowDup: false,
  script: '', argsText: '', log: '', stopScript: '', stopTimeout: 10, variables: [],
})

const saving = ref(false)
const reloading = ref(false)
const cfgDialog = ref(false)

// ---------------------------------------------------------------- 配置编辑
function confirmCloseDialog(done) {
  if (!dirty.value) { done(); return }
  ElMessageBox.confirm(
    '有未保存的修改。关闭后编辑内容仍会保留，可重新打开「修改服务配置」继续编辑；期间启动 / 停止操作保持禁用。',
    '未保存的修改',
    { type: 'warning', confirmButtonText: '关闭', cancelButtonText: '继续编辑' },
  ).then(() => done()).catch(() => {})
}
function payloadFromCfg(c) {
  return {
    description: c.description || '',
    workspace: c.workspace,
    nodes: c.nodes || [],
    allow_duplicate_start: !!c.allow_duplicate_start,
    start: { script: c.start.script, args: c.start.args || [], log: c.start.log },
    stop: { script: c.stop.script || null, timeout: c.stop.timeout },
    variables: c.variables || {},
  }
}

function formPayload() {
  const args = form.argsText.trim() ? form.argsText.trim().split(/\s+/) : []
  const variables = {}
  for (const r of form.variables) {
    if (r.key.trim()) variables[r.key.trim()] = r.value
  }
  return {
    description: form.description,
    workspace: form.workspace.trim(),
    nodes: form.nodes,
    allow_duplicate_start: form.allowDup,
    start: { script: form.script.trim(), args, log: form.log.trim() },
    stop: { script: form.stopScript.trim() || null, timeout: form.stopTimeout },
    variables,
  }
}

const dirty = computed(() =>
  cfg.value && JSON.stringify(formPayload()) !== JSON.stringify(payloadFromCfg(cfg.value)))

function fillFromCfg(c) {
  form.description = c.description || ''
  form.workspace = c.workspace
  form.nodes = [...(c.nodes || [])]
  form.allowDup = !!c.allow_duplicate_start
  form.script = c.start.script
  form.argsText = (c.start.args || []).join(' ')
  form.log = c.start.log
  form.stopScript = c.stop.script || ''
  form.stopTimeout = c.stop.timeout
  form.variables = Object.entries(c.variables || {}).map(([key, value]) => ({ key, value }))
}

async function save() {
  if (!form.workspace.trim()) { ElMessage.warning('workspace 不能为空'); return }
  if (!form.script.trim()) { ElMessage.warning('启动脚本不能为空'); return }
  if (!form.log.trim()) { ElMessage.warning('日志文件名不能为空'); return }
  saving.value = true
  try {
    cfg.value = await api.updateService(name.value, formPayload())
    rebuildOverride()
    selectedNodes.value = selectedNodes.value.filter((n) => selectableNodes.value.includes(n))
    cfgDialog.value = false
    ElMessage.success('配置已保存')
  } catch (e) {
    ElMessage.error(`保存失败: ${e.message}`)
  } finally {
    saving.value = false
  }
}

async function discard() {
  try {
    await ElMessageBox.confirm('放弃当前未保存的修改？', '确认', { type: 'warning' })
  } catch { return }
  fillFromCfg(cfg.value)
}

async function refreshFromDisk() {
  if (dirty.value) {
    try {
      await ElMessageBox.confirm('重新读取将放弃未保存的修改，继续？', '确认', { type: 'warning' })
    } catch { return }
  }
  reloading.value = true
  try {
    cfg.value = await api.reloadService(name.value)
    fillFromCfg(cfg.value)
    rebuildOverride()
    ElMessage.success('已重新读取 service.json')
  } catch (e) {
    ElMessage.error(e.message)
  } finally {
    reloading.value = false
  }
}

function rebuildOverride() {
  for (const k of Object.keys(varsOverride)) delete varsOverride[k]
  for (const k of Object.keys(cfg.value?.variables || {})) varsOverride[k] = ''
}

// ---------------------------------------------------------------- 启动实例
const selectableNodes = computed(() => {
  const cluster = nodes.value
  if (cfg.value?.nodes?.length) return cfg.value.nodes.filter((n) => cluster.includes(n))
  return cluster
})

// 禁止启动/部署的原因（多条并存）
const blockReasons = computed(() => {
  const reasons = []
  if (dirty.value) reasons.push('有未保存的配置修改，请先保存或放弃')
  if (!nodes.value.length) reasons.push('集群无可用节点（cluster.json 未配置）')
  else if (cfg.value?.nodes?.length && !selectableNodes.value.length)
    reasons.push('目标节点白名单中的节点均不在当前集群中')
  if (!selectedNodes.value.length) reasons.push('请勾选目标节点')
  return reasons
})

const autoStart = ref(true)

async function submit(action) {
  if (!selectedNodes.value.length) {
    ElMessage.warning('请先勾选目标节点')
    return
  }
  if (action === 'create') {
    const extra = autoStart.value ? '并立即启动' : '（仅创建，稍后在实例列表启动）'
    try {
      await ElMessageBox.confirm(
        `确定在 ${selectedNodes.value.join('、')} 上创建服务 ${name.value} 的实例${extra}？`,
        '创建实例确认', { type: 'info' })
    } catch { return }
  }
  const variables = {}
  for (const [k, v] of Object.entries(varsOverride)) {
    if (v !== '') variables[k] = v
  }
  try {
    const payload = { service: name.value, action, nodes: selectedNodes.value, variables }
    if (action === 'create') payload.auto_start = autoStart.value
    const task = await api.createTask(payload)
    trackTask(task.id, `${action === 'create' ? '创建实例' : '部署文件'} ${name.value}`)
    ElMessage.success(`任务已提交（${task.id}），进度可在「任务历史」查看`)
    setTimeout(() => loadInstances(true), 1000)
    setTimeout(() => loadInstances(true), 4000)
  } catch (e) {
    ElMessage.error(`创建任务失败: ${e.message}`)
  }
}

// ---------------------------------------------------------------- 运行实例
const instances = ref([])
const instLoading = ref(false)
const autoRefresh = ref(true)
const selectedInsts = ref([])
const instTable = ref(null)
let timer = null

async function loadInstances(silent = false) {
  if (!silent) instLoading.value = true
  try {
    const data = await api.instances()
    instances.value = data.instances.filter((i) => i.service === name.value)
    // 数据刷新后清理失效勾选（实例已被删除），保持勾选与数据一致
    const stale = selectedInsts.value.some((s) =>
      !instances.value.some((i) => i.node === s.node))
    if (stale) instTable.value?.clearSelection()
  } catch { /* 静默：实例失败不打断页面 */ }
  finally { if (!silent) instLoading.value = false }
}

// 重启/停止仅对「运行中」实例有意义：任一选中实例未运行则置灰
const allInstsRunning = computed(() =>
  selectedInsts.value.length > 0 && selectedInsts.value.every((r) => r.status === 'running'))
const canRestart = allInstsRunning
const canStop = allInstsRunning

function setTimer() {
  clearInterval(timer)
  if (autoRefresh.value) timer = setInterval(() => loadInstances(true), 10000)
}

async function confirmInstOp(action, nodeList) {
  const extra = { delete: '（停止进程并从列表移除，节点文件保留）',
                  restart: '（停止后启动，日志续写并加分隔符）',
                  stop: '（终止进程，实例保留可再启动）' }[action] || ''
  try {
    await ElMessageBox.confirm(
      `确定${ACTION_TEXT[action]} ${nodeList.join('、')} 上的实例（共 ${nodeList.length} 个）${extra}？`,
      `${ACTION_TEXT[action]}确认`, { type: action === 'start' ? 'info' : 'warning' })
  } catch { return false }
  return true
}

async function submitInstOp(action, nodeList) {
  try {
    const task = await api.createTask({ service: name.value, action, nodes: nodeList })
    trackTask(task.id, `${ACTION_TEXT[action]}实例 ${name.value}`)
    ElMessage.success(`${ACTION_TEXT[action]}任务已提交（${task.id}）`)
    instTable.value?.clearSelection()
    setTimeout(() => loadInstances(true), 800)
    setTimeout(() => loadInstances(true), 3000)
  } catch (e) {
    ElMessage.error(`创建任务失败: ${e.message}`)
  }
}

async function batchInstanceOp(action) {
  const nodeList = selectedInsts.value.map((r) => r.node)
  if (!nodeList.length) return
  if (await confirmInstOp(action, nodeList)) submitInstOp(action, nodeList)
}

function viewLog(row) {
  useRouterPush({ path: '/logs', query: { service: row.service, node: row.node, run_id: row.run_id, connect: '1', _t: String(Date.now()) } })
}

// ---------------------------------------------------------------- 初始化
async function init() {
  loadError.value = null
  cfg.value = null
  instances.value = []
  selectedNodes.value = []
  selectedInsts.value = []
  instTable.value?.clearSelection()
  cfgDialog.value = false
  clearInterval(timer)
  try {
    const [svc, nodeData] = await Promise.all([api.service(name.value), api.nodes()])
    cfg.value = svc
    nodes.value = nodeData.nodes.map((n) => n.name)
    fillFromCfg(svc)
    rebuildOverride()
    loadInstances()
    setTimer()
  } catch (e) {
    loadError.value = `加载服务 ${name.value} 失败: ${e.message}`
  }
}

watch(() => name.value, (n, o) => { if (n && n !== o) init() })
watch(autoRefresh, setTimer)
onMounted(init)
onActivated(() => { if (cfg.value && name.value) { loadInstances(true); setTimer() } })
onDeactivated(() => clearInterval(timer))
</script>

<style scoped>
.err-block { max-width: 560px; margin: 40px auto; text-align: center; }
.page-head { display: flex; align-items: center; gap: 12px; margin-bottom: 14px; }
.page-head .title { font-size: 17px; font-weight: 600; }
.head-actions { margin-left: auto; }
.block { margin-bottom: 16px; }
.cfg-form { max-width: 760px; }
.cfg-summary { margin-bottom: 12px; }
.hint-secondary { color: var(--el-text-color-secondary); font-size: 12px; margin-left: 10px; }
.actions .start-btn { margin-left: 20px; }
.actions .auto-start { margin-left: 20px; margin-right: 4px; }
.node-select .select-all-btn { margin-left: 24px; }
.dialog-footer { display: flex; align-items: center; justify-content: flex-end; gap: 4px; }
.dialog-footer .dirty-hint { margin-right: auto; }
.field-hint { color: var(--el-text-color-secondary); font-size: 12px; margin-top: 4px; }
.stop-row { display: flex; align-items: center; gap: 10px; }
.stop-timeout-label { color: var(--el-text-color-secondary); font-size: 13px; }
.vars-editor { display: flex; flex-direction: column; gap: 8px; align-items: flex-start; }
.var-row { display: flex; align-items: center; gap: 8px; }
.dirty-hint { color: var(--el-color-warning); font-size: 12px; margin-left: 10px; }
.label { color: var(--el-text-color-secondary); font-size: 13px; }
.node-select { margin-bottom: 10px; display: flex; align-items: center; flex-wrap: wrap; gap: 4px; }
.var-form { margin-bottom: 10px; display: flex; align-items: flex-start; }
.var-inputs { display: flex; flex-wrap: wrap; gap: 8px; }
.var-input { display: flex; align-items: center; gap: 6px; }
.var-key { font-size: 12px; color: var(--el-text-color-regular); }
.card-header { display: flex; justify-content: space-between; align-items: center; }
.inst-title { display: flex; align-items: center; gap: 8px; }
.inst-actions { display: flex; align-items: center; }
</style>
