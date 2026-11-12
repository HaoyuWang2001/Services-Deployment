// 节点标识色：按节点名确定性散列到 --sd-node-* 调色板，
// 同一节点在日志页 / 监控页等所有位置颜色一致，且随亮暗主题切换。
const COUNT = 10

export function nodeColor(name) {
  let h = 5381
  for (let i = 0; i < name.length; i += 1) h = ((h << 5) + h + name.charCodeAt(i)) | 0
  return `var(--sd-node-${(Math.abs(h) % COUNT) + 1})`
}
