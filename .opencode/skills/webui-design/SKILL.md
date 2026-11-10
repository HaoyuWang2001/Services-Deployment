---
name: webui-design
description: Use when editing, reviewing, or adding any UI in this repo's WebUI (web/src/**, Vue3 + Element Plus). Covers design tokens, Element Plus theming, dark mode, danger/status color semantics, typography, spacing, empty states, copy, and accessibility rules distilled from anthropics/frontend-design, Vercel Web Interface Guidelines, and emilkowalski/design-eng.
---

# WebUI 设计规范（本仓库）

管理台（Operate 模式）：可扫读性、一致性、操作精度优先于表现欲。品牌感只出现在精确的细节里，不靠装饰。

来源：`anthropics/skills` frontend-design · `vercel-labs/web-interface-guidelines` · `emilkowalski/skills` design-eng。冲突时以本文件的本项目规则为准。

## 硬性规则

1. **颜色只用 token**：优先 `var(--el-*)`，其次 `--sd-*`。禁止新增 hex 字面量（终端色板也必须走 `--sd-term-*`）。
2. **亮/暗双主题必须都成立**：用 `html.dark` 作用域适配，**禁止**用 `:plain="isDark"` 之类的 JS/Prop 分支做主题适配。
3. **危险色语义**：`type="danger"` 只用于破坏性操作本身及其确认按钮（删除/清理）。断开、停止、关闭等非破坏操作不得用 danger。
4. **每页至多一个 primary 实心按钮**（页面主动作）。批量/次级操作一律 plain，不给颜色堆叠。
5. **状态色=含义**：成功/警告/危险/进行中保持 Element Plus 语义色，不做品牌化改色。
6. **表格统一 `size="small"`**；数字列（PID/端口/大小/计数）加 `font-variant-numeric: tabular-nums`。
7. **空状态统一 `el-empty`**，必须给出下一步操作（按钮/链接）；禁止把长教程塞进表格 `empty-text`。
8. **无外部字体**（离线局域网）：只用 `--sd-font-ui` / `--sd-font-mono` 本地字体栈。
9. **中文文案**：全角标点（，。：；「」（））；省略号用 `…`；按钮用动词且名称与结果一致（保存→已保存）；错误信息包含下一步。
10. **动效克制**：交互反馈 <300ms、ease-out；高频操作（菜单切换、表格刷新）零动效；`@media (prefers-reduced-motion: reduce)` 关闭位移类动画；禁止 `transition: all`。
11. **无障碍**：仅图标按钮必须有 `aria-label`；可点击卡片/行必须可键盘聚焦（`tabindex="0"` + Enter/Space）；表单必须有 label 或 `aria-label`。
12. **危险操作必须有确认**（`ElMessageBox.confirm`，确认按钮 danger）；批量操作确认框要列出目标。

## Design tokens（style.css）

| Token | 用途 |
|---|---|
| `--sd-space-1..6` | 4/8/12/16/20/24px，所有间距只用这几档 |
| `--sd-font-ui` / `--sd-font-mono` | 字体栈（无外部字体） |
| `--sd-radius` | 面板圆角（4px，与 EP 一致） |
| `--sd-panel-padding` | 卡片内容 padding（16px） |
| `--sd-term-bg/-fg/-muted/-accent/-warn` | 终端配色（亮/暗两套） |
| `--sd-node-1..8` | 节点标识色（唯一来源 `web/src/ui/nodeColors.js`） |

字号层级：12 辅助 / 13 表单标签与说明 / 14 正文基准 / 16 页面标题（600）。不要引入 15px。

## 结构约定

- 每个页面顶部用 `components/PageHeader.vue`（标题 + 说明 + 右侧动作区）。
- 终端类视图（日志/监控）统一使用全局 `.sd-term` 样式（style.css），禁止复制终端配色/字体。
- 节点颜色一律 `nodeColor(name)`，保证同一节点跨页同色。
- 时间显示：相对时间（`fmtTimeRel`）优先，悬停 `title` 给出绝对时间。
- 危险确认：`ui/confirm.js` 的 `confirmDanger()`。

## 自查清单（改完 UI 必过）

- [ ] 无新增 hex 字面量、无内联 `style` 布局属性
- [ ] 亮色、暗色主题下均已检查（文字对比、边框、终端块）
- [ ] 危险操作确认按钮为 danger；非破坏操作未用 danger
- [ ] 每页 primary 实心按钮 ≤ 1
- [ ] 仅图标按钮有 `aria-label`
- [ ] 空状态可操作；错误信息包含下一步
- [ ] 中文全角标点；无 `5m30s` 式英文缩写
- [ ] 长内容有截断（`show-overflow-tooltip` / `text-overflow`）
- [ ] `npm run build` 通过
