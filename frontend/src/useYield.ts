import { useApi } from './useApi'
import { postJSON } from './http'
import type { YieldResult } from './types'

export function useYield() {
  const { result, error, loading, schedule } = useApi<YieldResult>()

  function compute(config: Record<string, unknown>, debounceMs = 300): void {
    schedule(() => postJSON<YieldResult>('/api/yield', config), debounceMs)
  }

  return { result, error, loading, compute }
}
