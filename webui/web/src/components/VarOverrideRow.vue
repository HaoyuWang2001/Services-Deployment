<template>
  <div class="var-override-row">
    <el-tooltip :content="varName" placement="top-start" :show-after="250"
                :popper-style="tooltipStyle" :disabled="!nameTruncated">
      <span ref="nameEl" class="var-name">{{ varName }}</span>
    </el-tooltip>
    <el-tooltip :content="hoverText" placement="top-start" :show-after="250"
                :popper-style="tooltipStyle" :disabled="!valueTruncated">
      <div ref="valueWrap" class="var-value-wrap">
        <el-input v-model="model" size="small" :placeholder="placeholder" @input="scheduleMeasure" />
      </div>
    </el-tooltip>
  </div>
</template>

<script setup>
import { computed, nextTick, onBeforeUnmount, onMounted, ref, watch } from 'vue'

const props = defineProps({
  varName: { type: String, required: true },
  // 变量默认值；空串 / null 视为没有默认值
  defaultValue: { type: String, default: '' },
})
const model = defineModel({ type: String, default: '' })

const tooltipStyle = { maxWidth: '520px', overflowWrap: 'anywhere', lineHeight: '1.5' }

const nameEl = ref(null)
const valueWrap = ref(null)
const nameTruncated = ref(false)
const valueTruncated = ref(false)

const hasDefault = computed(() => props.defaultValue != null && String(props.defaultValue) !== '')
const placeholder = computed(() => (hasDefault.value ? String(props.defaultValue) : '无默认'))
// 空输入时展示默认值（无默认则不展示）；已填写时展示填写内容
const hoverText = computed(() => {
  if (model.value !== '' && model.value != null) return String(model.value)
  return hasDefault.value ? String(props.defaultValue) : ''
})

let measureCtx = null
function getMeasureCtx() {
  if (!measureCtx) measureCtx = document.createElement('canvas').getContext('2d')
  return measureCtx
}

// 用 canvas 按输入框实际字体测量文本宽度，判断是否会溢出
function overflowsInput(input, text) {
  if (!input || !text) return false
  const ctx = getMeasureCtx()
  if (!ctx) return false
  const cs = getComputedStyle(input)
  ctx.font = `${cs.fontStyle} ${cs.fontWeight} ${cs.fontSize} ${cs.fontFamily}`
  const pad = (parseFloat(cs.paddingLeft) || 0) + (parseFloat(cs.paddingRight) || 0)
  const available = Math.max(0, input.clientWidth - pad)
  return ctx.measureText(text).width > available + 1
}

function measureName() {
  const el = nameEl.value
  nameTruncated.value = !!el && el.scrollWidth > el.clientWidth + 1
}

function measureValue() {
  valueTruncated.value = overflowsInput(valueWrap.value?.querySelector('input'), hoverText.value)
}

function scheduleMeasure() {
  nextTick(() => { measureName(); measureValue() })
}

watch([model, () => props.defaultValue], scheduleMeasure)

let observer = null
onMounted(() => {
  scheduleMeasure()
  if (typeof ResizeObserver !== 'undefined') {
    observer = new ResizeObserver(scheduleMeasure)
    if (nameEl.value) observer.observe(nameEl.value)
    if (valueWrap.value) observer.observe(valueWrap.value)
  }
})
onBeforeUnmount(() => observer?.disconnect())
</script>

<style scoped>
.var-override-row {
  display: flex;
  align-items: center;
  gap: var(--sd-space-3);
  width: 100%;
}
.var-name {
  flex: 0 0 200px;
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  font-size: 12px;
  color: var(--el-text-color-regular);
}
.var-value-wrap {
  flex: 0 1 420px;
  min-width: 0;
  max-width: 100%;
}
.var-value-wrap :deep(.el-input) { width: 100%; }
</style>
