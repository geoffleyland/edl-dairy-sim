import { ref } from 'vue'
import type { YieldResult } from './types'

export function useYield() {
  const result  = ref<YieldResult | null>(null)
  const error   = ref<string | null>(null)
  const loading = ref(false)

  let timer: ReturnType<typeof setTimeout> | null = null

  function compute(config: Record<string, unknown>, debounceMs = 300): void {
    if (timer !== null) clearTimeout(timer)
    timer = setTimeout(() => _fetch(config), debounceMs)
  }

  async function _fetch(config: Record<string, unknown>): Promise<void> {
    loading.value = true
    error.value   = null
    try {
      const res = await fetch('/api/yield', {
        method:  'POST',
        headers: { 'Content-Type': 'application/json' },
        body:    JSON.stringify(config),
      })
      if (!res.ok) {
        const body = await res.json().catch(() => ({}))
        throw new Error((body as { error?: string }).error ?? `HTTP ${res.status}`)
      }
      result.value = await res.json() as YieldResult
    } catch (e) {
      error.value = e instanceof Error ? e.message : String(e)
    } finally {
      loading.value = false
    }
  }

  return { result, error, loading, compute }
}
