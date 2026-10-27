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
import { computed } from 'vue'
import { useRoute } from 'vue-router'

const route = useRoute()
const menuActive = computed(() => '/' + (route.path.split('/')[1] || ''))
</script>

<style scoped>
.layout { height: 100%; }
.aside {
  border-right: 1px solid var(--el-border-color-light);
  display: flex;
  flex-direction: column;
  background: #fff;
}
.brand {
  font-weight: 600;
  font-size: 15px;
  padding: 18px 20px 14px;
  color: var(--el-text-color-primary);
  border-bottom: 1px solid var(--el-border-color-lighter);
}
.menu { border-right: none; flex: 1; }
.aside-footer { padding: 14px 20px; border-top: 1px solid var(--el-border-color-lighter); }
.main { background: var(--el-fill-color-lighter); }
</style>
