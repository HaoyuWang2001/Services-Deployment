import { createRouter, createWebHashHistory } from 'vue-router'

const routes = [
  { path: '/', redirect: '/cluster' },
  { path: '/cluster', component: () => import('./views/ClusterView.vue') },
  { path: '/services', component: () => import('./views/ServicesView.vue') },
  { path: '/services/:name', component: () => import('./views/ServiceDetailView.vue') },
  { path: '/instances', component: () => import('./views/InstancesView.vue') },
  { path: '/logs', component: () => import('./views/LogsView.vue') },
  { path: '/monitor', component: () => import('./views/MonitorView.vue') },
  { path: '/tasks', component: () => import('./views/TasksView.vue') },
]

export default createRouter({
  history: createWebHashHistory(),
  routes,
})
