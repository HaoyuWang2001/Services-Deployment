<template>
  <div v-if="loadError" class="err-block">
    <el-alert :title="loadError" type="error" show-icon :closable="false" />
    <el-button class="mt-3" @click="$router.push('/services')">返回服务列表</el-button>
  </div>

  <div v-else v-loading="!cfg">
    <!-- 页头 -->
    <PageHeader :title="name" description="服务配置、实例创建与运行实例管理" back @back="$router.push('/services')">
      <template #badge>
        <el-tag v-if="dirty" type="warning" size="small">有未保存的修改</el-tag>
      </template>
      <template #actions>
        <el-button size="small" @click="refreshFromDisk" :loading="reloading">重新读取配置</el-button>
      </template>
    </PageHeader>

    <!-- 启动实例 -->
    <el-card shadow="never" class="block">
      <template #header>
        <div class="sd-card-head">
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
                :title="`该服务限定目标节点：${cfg.nodes.join('、')}`" class="mt-2" />
      <div class="node-select">
        <span class="label">目标节点：</span>
        <span class="node-ctrl">
          <el-button size="small" @click="selectedNodes = [...selectableNodes]">全选</el-button>
          <el-button size="small" @click="selectedNodes = []">清空</el-button>
        </span>
        <el-checkbox-group v-model="selectedNodes">
          <el-checkbox v-for="n in selectableNodes" :key="n" :value="n">{{ n }}</el-checkbox>
        </el-checkbox-group>
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
      <div class="args-form">
        <span class="label">启动参数：</span>
        <el-input v-model="launchArgs" class="args-input" size="small" clearable
                  placeholder="空格分隔，追加在静态参数之后，如 --verbose --port 2380" />
      </div>
      <div class="actions">
        <el-checkbox v-model="deployOnly" class="deploy-only">仅部署不启动</el-checkbox>
        <el-button class="start-btn" size="small" type="primary"
                   :disabled="blockReasons.length > 0" @click="submit('create')">创建实例</el-button>
        <span v-if="blockReasons.length" class="dirty-hint">{{ blockReasons.join('；') }}</span>
      </div>
      <div class="danger-row">
        <span class="danger-label">危险操作：</span>
        <el-button size="small" type="danger" plain
                   :disabled="blockReasons.length > 0" @click="openClean">节点清理</el-button>
        <span class="danger-desc">整目录删除所选节点上该服务的全部部署目录（含历史目录与日志）；须先删除实例后执行</span>
      </div>
    </el-card>

    <!-- 运行实例 -->
    <el-card shadow="never" class="block">
      <template #header>
        <div class="sd-card-head">
          <div class="inst-title">
            <span>运行实例</span>
            <el-tooltip content="刷新" placement="top">
              <el-button size="small" circle :icon="Refresh" :loading="instLoading" aria-label="刷新实例列表" @click="loadInstances()" />
            </el-tooltip>
          </div>
          <div class="inst-actions">
            <el-button size="small" type="success" :plain="isDark"
                       :disabled="!canStartInsts || dirty" @click="batchInstanceOp('start')">
              启动选中 ({{ selectedInsts.length }})
            </el-button>
            <el-button size="small" type="primary" :plain="isDark"
                       :disabled="!canRestartInsts || dirty" @click="batchInstanceOp('restart')">
              重启选中 ({{ selectedInsts.length }})
            </el-button>
            <el-button size="small" type="warning" :plain="isDark"
                       :disabled="!canStopInsts || dirty" @click="batchInstanceOp('stop')">
              停止选中 ({{ selectedInsts.length }})
            </el-button>
            <el-button size="small" type="danger" :plain="isDark"
                       :disabled="!canDeleteInsts || dirty" @click="batchInstanceOp('delete')">
              删除选中 ({{ selectedInsts.length }})
            </el-button>
            <el-switch v-model="autoRefresh" active-text="10 秒自动刷新" class="auto-switch" />
          </div>
        </div>
      </template>
      <el-table ref="instTable" :data="instances" v-loading="instLoading" size="small" row-key="node"
                @selection-change="(rows) => (selectedInsts = rows)">
        <template #empty><el-empty description="暂无实例，可在上方创建" :image-size="60" /></template>
        <el-table-column type="selection" reserve-selection width="45" />
        <el-table-column prop="node" label="节点" width="110" />
        <el-table-column label="状态" width="140">
          <template #default="{ row }">
            <el-popover v-if="row.status === 'abnormal'" placement="top" :width="300"
                        trigger="hover" :show-after="150" :content="ABNORMAL_HINT">
              <template #reference>
                <el-tag :type="statusType(row.status)" size="small" class="status-hint">{{ statusText(row) }}</el-tag>
              </template>
            </el-popover>
            <el-tag v-else :type="statusType(row.status)" size="small">{{ statusText(row) }}</el-tag>
          </template>
        </el-table-column>
        <el-table-column label="清理状态" width="120">
          <template #default="{ row }">
            <el-tag :type="cleanupType(row.cleanup_status)" size="small" effect="plain">
              {{ cleanupText(row.cleanup_status) }}
            </el-tag>
          </template>
        </el-table-column>
        <el-table-column label="PID" width="90">
          <template #default="{ row }"><span class="sd-mono sd-num">{{ row.pid ?? '-' }}</span></template>
        </el-table-column>
        <el-table-column label="run_id" width="160">
          <template #default="{ row }"><span class="sd-mono">{{ row.run_id }}</span></template>
        </el-table-column>
        <el-table-column label="最近启动" width="130">
          <template #default="{ row }">
            <span :title="fmtTime(row.started_at)">{{ fmtTimeRel(row.started_at) }}</span>
          </template>
        </el-table-column>
        <el-table-column prop="log_path" label="日志路径" min-width="200" show-overflow-tooltip />
        <el-table-column label="操作" width="80">
          <template #default="{ row }">
            <el-button size="small" link type="primary" @click="viewLog(row)">日志</el-button>
          </template>
        </el-table-column>
      </el-table>
    </el-card>

    <!-- 实例批量预检确认框 -->
    <el-dialog v-model="instBatchDialog" :title="`${ACTION_TEXT[instBatchAction]}确认（实时状态预检）`" width="560px">
      <el-table :data="instBatchTargets" size="small" v-loading="instBatchChecking">
        <el-table-column prop="node" label="节点" min-width="140" />
        <el-table-column label="当前状态" width="150">
          <template #default="{ row }">
            <el-popover v-if="row.status === 'abnormal'" placement="top" :width="300"
                        trigger="hover" :show-after="150" :content="ABNORMAL_HINT">
              <template #reference>
                <el-tag :type="statusType(row.status)" size="small" class="status-hint">{{ statusText(row) }}</el-tag>
              </template>
            </el-popover>
            <el-tag v-else :type="statusType(row.status)" size="small">{{ statusText(row) }}</el-tag>
          </template>
        </el-table-column>
        <el-table-column label="本次" width="90">
          <template #default="{ row }">
            <el-tag v-if="row.eligible" type="success" size="small">执行</el-tag>
            <el-tag v-else type="info" size="small">跳过</el-tag>
          </template>
        </el-table-column>
      </el-table>
      <div class="batch-hint">
        <span v-if="instBatchAllEligible">将执行 {{ instBatchTargets.length }} 个</span>
        <span v-else class="batch-warn">
          存在 {{ instBatchTargets.length - instBatchEligible.length }} 个状态不符实例，不允许部分执行；请重新预检或刷新后重新勾选
        </span>
        <el-button size="small" link type="primary" class="ml-2"
                   @click="refreshInstBatchTargets">重新预检</el-button>
      </div>
      <template #footer>
        <el-button @click="instBatchDialog = false">取消</el-button>
        <el-button :type="instBatchAction === 'delete' ? 'danger' : 'primary'" :disabled="!instBatchAllEligible" @click="confirmInstBatch">
          确认{{ ACTION_TEXT[instBatchAction] }}（{{ instBatchTargets.length }}）
        </el-button>
      </template>
    </el-dialog>

    <!-- 清理对话框 -->
    <el-dialog v-model="cleanDialog" title="清理服务文件" width="680px">
      <el-alert type="warning" :closable="false" show-icon class="mb-3"
                title="将删除所选节点上该服务的全部部署目录（含历史目录与日志，整目录删除）；仅当节点上不存在实例时允许清理" />
      <div v-for="(dirs, node) in cleanDirs" :key="node" class="clean-node">
        <div class="clean-node-name">{{ node }}</div>
        <div v-for="d in dirs" :key="d" class="clean-dir">
          <span class="clean-dir-path">{{ d }}</span>
          <el-tag v-if="d === cfg?.workspace" size="small">当前</el-tag>
          <el-tag v-else size="small" type="info">历史</el-tag>
        </div>
      </div>
      <el-form label-width="80px" class="mt-3">
        <el-form-item label="补录路径">
          <el-input v-model="extraPaths" type="textarea" :rows="2"
                    placeholder="每行一个绝对路径（本系统部署历史之外、确属该服务的旧目录）" />
        </el-form-item>
      </el-form>
      <template #footer>
        <el-button @click="cleanDialog = false">取消</el-button>
        <el-button type="danger" @click="submitClean">确认清理</el-button>
      </template>
    </el-dialog>

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
            <span class="stop-timeout-label">kill 超时（秒）</span>
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
import { api, ACTION_TEXT, fmtTime, fmtTimeRel } from '../api'
import { trackTask } from '../taskNotify'
import PageHeader from '../components/PageHeader.vue'
import { isDark } from '../theme'
import {
  ABNORMAL_HINT, DELETABLE, RESTARTABLE, STARTABLE, STOPPABLE,
  cleanupText, cleanupType, statusText, statusType,
} from '../instanceStatus'
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

const draftKey = computed(() => `sd:vars-override:${name.value}`)
const argsDraftKey = computed(() => `sd:launch-args:${name.value}`)
const launchArgs = ref('')

function loadDraft() {
  try {
    const d = JSON.parse(localStorage.getItem(draftKey.value) || '{}')
    return d && typeof d === 'object' ? d : {}
  } catch { return {} }
}

function saveDraft() {
  try {
    const filled = {}
    for (const [k, v] of Object.entries(varsOverride)) {
      if (v !== '') filled[k] = v
    }
    localStorage.setItem(draftKey.value, JSON.stringify(filled))
  } catch { /* localStorage 不可用时静默忽略 */ }
}

function loadArgsDraft() {
  try { return localStorage.getItem(argsDraftKey.value) || '' } catch { return '' }
}

function saveArgsDraft() {
  try { localStorage.setItem(argsDraftKey.value, launchArgs.value) } catch { /* ignore */ }
}

function rebuildOverride() {
  const draft = loadDraft()
  for (const k of Object.keys(varsOverride)) delete varsOverride[k]
  for (const k of Object.keys(cfg.value?.variables || {})) {
    varsOverride[k] = draft[k] != null ? String(draft[k]) : ''
  }
  launchArgs.value = loadArgsDraft()
}

watch(varsOverride, saveDraft, { deep: true })
watch(launchArgs, saveArgsDraft)

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

const deployOnly = ref(false)  // 勾选 = 创建实例但仅部署文件不启动

async function submit(action) {
  if (!selectedNodes.value.length) {
    ElMessage.warning('请先勾选目标节点')
    return
  }
  if (action === 'create') {
    const extra = deployOnly.value ? '（仅部署文件，不启动）' : '并立即启动'
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
  const args = launchArgs.value.trim() ? launchArgs.value.trim().split(/\s+/) : []
  try {
    const payload = { service: name.value, action, nodes: selectedNodes.value, variables }
    if (action === 'create') {
      payload.auto_start = !deployOnly.value
      payload.args = args
    }
    const task = await api.createTask(payload)
    trackTask(task.id, `创建实例 ${name.value}`)
    ElMessage.success(`任务已提交（${task.id}），进度可在「任务历史」查看`)
    setTimeout(() => loadInstances(true), 1000)
    setTimeout(() => loadInstances(true), 4000)
  } catch (e) {
    ElMessage.error(`创建任务失败: ${e.message}`)
  }
}

// ---------------------------------------------------------------- 清理 ----
const cleanDialog = ref(false)
const cleanDirs = ref({})      // node -> [dirs]（当前 + 历史）
const extraPaths = ref('')

async function openClean() {
  if (!selectedNodes.value.length) {
    ElMessage.warning('请先勾选目标节点')
    return
  }
  try {
    const h = await api.serviceHistory(name.value)
    const merged = {}
    for (const n of selectedNodes.value) {
      merged[n] = [...new Set([h.current, ...(h.history[n] || [])])]
    }
    cleanDirs.value = merged
    extraPaths.value = ''
    cleanDialog.value = true
  } catch (e) {
    ElMessage.error(`获取部署历史失败: ${e.message}`)
  }
}

async function submitClean() {
  const paths = extraPaths.value.split('\n').map((s) => s.trim()).filter(Boolean)
  const listing = Object.entries(cleanDirs.value)
    .map(([n, dirs]) => `${n}: ${dirs.join('、')}`).join('；')
  try {
    await ElMessageBox.confirm(
      `确定清理？${listing}${paths.length ? `；补录: ${paths.join('、')}` : ''}`,
      '清理确认', { type: 'warning' })
  } catch { return }
  try {
    const task = await api.createTask({ service: name.value, action: 'clean', nodes: selectedNodes.value, paths })
    trackTask(task.id, `清理 ${name.value}`)
    ElMessage.success(`清理任务已提交（${task.id}）`)
    cleanDialog.value = false
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

// ---------------------------------------------------------------- 实例批量预检 ----
// 严格全部门禁：全部选中实例符合该动作允许状态才可点击（叠加 dirty）
const everyInstIn = (set) => computed(() =>
  selectedInsts.value.length > 0 && selectedInsts.value.every((r) => set.includes(r.status)))
const canStartInsts = everyInstIn(STARTABLE)
const canRestartInsts = everyInstIn(RESTARTABLE)
const canStopInsts = everyInstIn(STOPPABLE)
const canDeleteInsts = everyInstIn(DELETABLE)

function setTimer() {
  clearInterval(timer)
  if (autoRefresh.value) timer = setInterval(() => loadInstances(true), 10000)
}

const instBatchDialog = ref(false)
const instBatchAction = ref('stop')
const instBatchTargets = ref([])   // {node, status, eligible}
const instBatchChecking = ref(false)
const instBatchEligible = computed(() => instBatchTargets.value.filter((t) => t.eligible))
// 严格预检：全部符合才允许确认（不允许部分执行）
const instBatchAllEligible = computed(() =>
  instBatchTargets.value.length > 0 && instBatchTargets.value.every((t) => t.eligible))

const ELIGIBLE_SETS = { start: STARTABLE, stop: STOPPABLE, restart: RESTARTABLE, delete: DELETABLE }

async function fetchFreshInstances() {
  try { return (await api.instances()).instances } catch { return null }
}

function markInstEligible(action, targets, freshList) {
  const byNode = new Map(
    (freshList || []).filter((i) => i.service === name.value).map((i) => [i.node, i]))
  return targets.map((t) => {
    const live = byNode.get(t.node)
    const status = live?.status ?? t.status
    return { ...t, status, exit_code: live?.exit_code ?? t.exit_code,
             eligible: (ELIGIBLE_SETS[action] || []).includes(status) }
  })
}

async function batchInstanceOp(action) {
  if (!selectedInsts.value.length || dirty.value) return
  instBatchAction.value = action
  instBatchDialog.value = true
  instBatchChecking.value = true
  instBatchTargets.value = markInstEligible(action, selectedInsts.value, await fetchFreshInstances())
  instBatchChecking.value = false
}

async function refreshInstBatchTargets() {
  instBatchChecking.value = true
  instBatchTargets.value = markInstEligible(instBatchAction.value, instBatchTargets.value, await fetchFreshInstances())
  instBatchChecking.value = false
}

async function confirmInstBatch() {
  if (!instBatchAllEligible.value) return
  // 立即清空勾选（须在任何 await 之前，避免 reserve-selection 在轮询刷新时恢复勾选的竞态）
  selectedInsts.value = []
  instTable.value?.clearSelection()
  instBatchDialog.value = false
  const nodeList = instBatchTargets.value.map((r) => r.node)
  try {
    const task = await api.createTask({ service: name.value, action: instBatchAction.value, nodes: nodeList })
    trackTask(task.id, `${ACTION_TEXT[instBatchAction.value]}实例 ${name.value}（${nodeList.length} 节点）`)
    ElMessage.success(
      `${ACTION_TEXT[instBatchAction.value]}任务已提交（${task.id}）`
      + (instBatchAction.value === 'delete' ? '；如需清理节点文件请使用「节点清理」' : ''))
    setTimeout(() => loadInstances(true), 800)
    setTimeout(() => loadInstances(true), 3000)
  } catch (e) {
    ElMessage.error(`创建任务失败: ${e.message}`)
  }
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
      + `。若该服务配置已被删除，其运行中实例仍可在「运行实例」页停止或删除。`
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
.block { margin-bottom: var(--sd-space-4); }
.mt-2 { margin-top: var(--sd-space-2); }
.mt-3 { margin-top: var(--sd-space-3); }
.mb-3 { margin-bottom: var(--sd-space-3); }
.ml-2 { margin-left: var(--sd-space-2); }
.cfg-form { max-width: 760px; }
.cfg-summary { margin-bottom: 12px; }
.hint-secondary { color: var(--el-text-color-secondary); font-size: 12px; margin-left: 10px; }
.actions .start-btn { margin-left: 20px; }
.actions .deploy-only { margin-right: 4px; }
.batch-hint { color: var(--el-text-color-secondary); font-size: 12px; margin-top: var(--sd-space-3); display: flex; align-items: center; gap: var(--sd-space-2); }
.batch-warn { color: var(--el-color-danger); }
.clean-node { margin-bottom: 10px; }
.clean-node-name { font-weight: 600; margin-bottom: 4px; }
.clean-dir { display: flex; align-items: center; gap: 8px; padding: 2px 0 2px 12px; }
.clean-dir-path { font-family: var(--sd-font-mono); font-size: 13px; word-break: break-all; }
.node-select .node-ctrl { display: inline-flex; align-items: center; margin-right: 12px; }
.danger-row { display: flex; align-items: center; gap: 10px; margin-top: 6px; }
.danger-label { color: var(--el-color-danger); font-size: 13px; font-weight: 600; }
.danger-desc { color: var(--el-text-color-secondary); font-size: 12px; }
.dialog-footer { display: flex; align-items: center; justify-content: flex-end; gap: 4px; }
.dialog-footer .dirty-hint { margin-right: auto; }
.field-hint { color: var(--el-text-color-secondary); font-size: 12px; margin-top: 4px; }
.stop-row { display: flex; align-items: center; gap: 10px; }
.stop-timeout-label { color: var(--el-text-color-secondary); font-size: 13px; }
.vars-editor { display: flex; flex-direction: column; gap: 8px; align-items: flex-start; }
.var-row { display: flex; align-items: center; gap: 8px; }
.dirty-hint { color: var(--el-color-warning); font-size: 12px; margin-left: 10px; }
.status-hint { cursor: help; }
.node-select { margin-bottom: 10px; display: flex; align-items: center; flex-wrap: wrap; gap: 4px; }
.label { color: var(--el-text-color-secondary); font-size: 13px; }
.args-form { margin-bottom: 10px; display: flex; align-items: center; }
.args-input { width: 380px; }
.var-form { margin-bottom: 10px; display: flex; align-items: flex-start; }
.var-form .label, .args-form .label { height: 24px; display: inline-flex; align-items: center; flex-shrink: 0; }
.var-inputs { display: flex; flex-wrap: wrap; gap: 8px; }
.var-input { display: flex; align-items: center; gap: 6px; }
.var-key { font-size: 12px; color: var(--el-text-color-regular); }
.inst-title { display: flex; align-items: center; gap: 8px; }
.inst-actions { display: flex; align-items: center; }
.auto-switch { margin-left: var(--sd-space-3); }
</style>
