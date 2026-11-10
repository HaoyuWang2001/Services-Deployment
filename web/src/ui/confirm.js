import { ElMessageBox } from 'element-plus'

// 危险操作确认：确认按钮强制 danger 色（webui-design skill 硬性规则）。
export function confirmDanger(message, { title = '危险操作确认', confirmText = '确认', ...rest } = {}) {
  return ElMessageBox.confirm(message, title, {
    type: 'warning',
    confirmButtonText: confirmText,
    cancelButtonText: '取消',
    confirmButtonClass: 'el-button--danger',
    ...rest,
  })
}
