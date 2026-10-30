<template>
  <el-container class="layout">
    <el-aside width="200px" class="aside">
      <div class="brand">Services-Deployment</div>
      <el-menu router :default-active="menuActive" class="menu">
        <el-menu-item index="/cluster">集群节点</el-menu-item>
        <el-menu-item index="/services">服务管理</el-menu-item>
        <el-menu-item index="/instances">运行实例</el-menu-item>
        <el-menu-item index="/logs">日志查看</el-menu-item>
        <el-menu-item index="/monitor">监控指令</el-menu-item>
        <el-menu-item index="/tasks">任务历史</el-menu-item>
      </el-menu>
      <div class="aside-footer">
        <el-tooltip :content="isDark ? '切换到亮色' : '切换到暗色'" placement="top">
          <el-button size="small" circle :icon="isDark ? Sunny : Moon" @click="toggleDark" />
        </el-tooltip>
        <el-link href="/docs" target="_blank" type="primary" :underline="false">API 文档 /docs</el-link>
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
import { computed, ref, watch } from 'vue'
import { Moon, Sunny } from '@element-plus/icons-vue'
import { useRoute } from 'vue-router'

const route = useRoute()
const menuActive = computed(() => '/' + (route.path.split('/')[1] || ''))

const THEME_KEY = 'sd-theme'

function initialDark() {
  const saved = localStorage.getItem(THEME_KEY)
  if (saved === 'dark') return true
  if (saved === 'light') return false
  return window.matchMedia('(prefers-color-scheme: dark)').matches  // 首次访问跟随系统
}

const isDark = ref(initialDark())

function applyTheme(dark) {
  document.documentElement.classList.toggle('dark', dark)
}

function toggleDark() {
  isDark.value = !isDark.value
}

watch(isDark, (v) => {
  applyTheme(v)
  localStorage.setItem(THEME_KEY, v ? 'dark' : 'light')
}, { immediate: true })
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
  font-weight: 600;
  font-size: 15px;
  padding: 18px 20px 14px;
  color: var(--el-text-color-primary);
  border-bottom: 1px solid var(--el-border-color-lighter);
}
.menu { border-right: none; flex: 1; }
.aside-footer {
  padding: 14px 20px;
  border-top: 1px solid var(--el-border-color-lighter);
  display: flex;
  align-items: center;
  gap: 12px;
}
.main { background: var(--el-fill-color-lighter); }
</style>
