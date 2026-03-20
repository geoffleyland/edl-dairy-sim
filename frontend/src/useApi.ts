import { ref } from 'vue'
import type { Ref } from 'vue'

// Shared debounce + loading/error wrapper for API calls.
// Usage:
//   const { result, error, loading, schedule } = useApi<MyResult>()
//   schedule(() => postJSON('/api/foo', body), debounceMs)
export function useApi<T>() {
  const result  = ref<T | null>(null) as Ref<T | null>
  const error   = ref<string | null>(null)
  const loading = ref(false)

  let timer: ReturnType<typeof setTimeout> | null = null

  function schedule(fn: () => Promise<T>, debounceMs: number): void {
    if (timer !== null) clearTimeout(timer)
    timer = setTimeout(async () => {
      loading.value = true
      error.value   = null
      try {
        result.value = await fn()
      } catch (e) {
        error.value = e instanceof Error ? e.message : String(e)
      } finally {
        loading.value = false
      }
    }, debounceMs)
  }

  return { result, error, loading, schedule }
}
