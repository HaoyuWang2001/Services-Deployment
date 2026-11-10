<template>
  <el-container class="layout">
    <el-aside width="200px" class="aside">
      <div class="brand">
        <span class="brand-mark" aria-hidden="true"></span>
        <span>Services-Deployment</span>
      </div>
      <el-menu router :default-active="menuActive" class="menu">
        <el-menu-item index="/cluster">
          <el-icon><Odometer /></el-icon><span>集群节点</span>
        </el-menu-item>
        <el-menu-item index="/services">
          <el-icon><Box /></el-icon><span>服务管理</span>
        </el-menu-item>
        <el-menu-item index="/instances">
          <el-icon><List /></el-icon><span>运行实例</span>
        </el-menu-item>
        <el-menu-item index="/logs">
          <el-icon><Document /></el-icon><span>日志查看</span>
        </el-menu-item>
        <el-menu-item index="/monitor">
          <el-icon><DataLine /></el-icon><span>监控指令</span>
        </el-menu-item>
        <el-menu-item index="/tasks">
          <el-icon><Clock /></el-icon><span>任务历史</span>
        </el-menu-item>
      </el-menu>
      <div class="aside-footer">
        <el-tooltip :content="isDark ? '切换到亮色' : '切换到暗色'" placement="top">
          <el-button size="small" circle :icon="isDark ? Sunny : Moon" aria-label="切换主题" @click="toggleDark" />
        </el-tooltip>
        <el-link href="/docs" target="_blank" type="primary" :underline="false">API 文档</el-link>
      </div>
    </el-aside>
    <el-main class="main">
      <router-view v-slot="{ Component }">
        <keep-alive>
          <component :is="Component" />
        </keep-alive>
      </router-view>
    </el-main>
  </el-container>
</template>

<script setup>
import { computed } from 'vue'
import {
  Box, Clock, DataLine, Document, List, Moon, Odometer, Sunny,
} from '@element-plus/icons-vue'
import { useRoute } from 'vue-router'
import { isDark, toggleDark } from './theme'

const route = useRoute()
const menuActive = computed(() => '/' + (route.path.split('/')[1] || ''))
</script>

<style scoped>
.layout { height: 100%; }
.aside {
  border-right: 1px solid var(--el-border-color-light);
  display: flex;
  flex-direction: column;
  background: var(--el-bg-color);
}
.brand {
  display: flex;
  align-items: center;
  gap: var(--sd-space-2);
  font-weight: 600;
  font-size: 14px;
  padding: 18px 20px 14px;
  color: var(--el-text-color-primary);
  border-bottom: 1px solid var(--el-border-color-lighter);
}
.brand-mark {
  width: 8px;
  height: 8px;
  border-radius: 2px;
  background: var(--el-color-primary);
  flex-shrink: 0;
}
.menu { border-right: none; flex: 1; }
.menu :deep(.el-menu-item) { gap: 0; }
.aside-footer {
  padding: 14px 20px;
  border-top: 1px solid var(--el-border-color-lighter);
  display: flex;
  align-items: center;
  gap: var(--sd-space-3);
}
.main { background: var(--el-bg-color-page); padding: var(--sd-space-4); }
</style>
