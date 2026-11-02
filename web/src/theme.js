import { ref, watch } from 'vue'

const THEME_KEY = 'sd-theme'

function initialDark() {
  const saved = localStorage.getItem(THEME_KEY)
  if (saved === 'dark') return true
  if (saved === 'light') return false
  return window.matchMedia('(prefers-color-scheme: dark)').matches
}

export const isDark = ref(initialDark())

export function toggleDark() {
  isDark.value = !isDark.value
}

watch(isDark, (v) => {
  document.documentElement.classList.toggle('dark', v)
  localStorage.setItem(THEME_KEY, v ? 'dark' : 'light')
}, { immediate: true })
