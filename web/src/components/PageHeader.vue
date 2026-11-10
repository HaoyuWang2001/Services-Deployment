<template>
  <div class="sd-page-head">
    <div class="head-main">
      <div class="head-title">
        <el-button v-if="back" link class="back-btn" aria-label="返回" @click="$emit('back')">
          <el-icon><ArrowLeft /></el-icon>
          <span>返回</span>
        </el-button>
        <h1 class="title">{{ title }}</h1>
        <slot name="badge" />
      </div>
      <p v-if="description" class="desc">{{ description }}</p>
    </div>
    <div v-if="$slots.actions" class="head-actions">
      <slot name="actions" />
    </div>
  </div>
</template>

<script setup>
import { ArrowLeft } from '@element-plus/icons-vue'

defineProps({
  title: { type: String, default: '' },
  description: { type: String, default: '' },
  back: { type: Boolean, default: false },
})
defineEmits(['back'])
</script>

<style scoped>
.sd-page-head {
  display: flex;
  align-items: flex-start;
  justify-content: space-between;
  gap: var(--sd-space-4);
  flex-shrink: 0;
}
.head-main { min-width: 0; }
.head-title { display: flex; align-items: center; gap: var(--sd-space-2); }
.title {
  margin: 0;
  font-size: 16px;
  font-weight: 600;
  line-height: 24px;
  color: var(--el-text-color-primary);
}
.desc { margin: var(--sd-space-1) 0 0; font-size: 12px; color: var(--el-text-color-secondary); }
.back-btn { margin-right: 2px; }
.head-actions { display: flex; align-items: center; gap: var(--sd-space-2); flex-shrink: 0; }
</style>
