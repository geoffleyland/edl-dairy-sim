import { ref } from 'vue'

export interface SimIntake {
  silo_id:       string
  start_hr:      number
  end_hr:        number
  rate_kg_per_hr: number
}

export interface SimBlock {
  machine_id: string
  mode:       string
  start_hr:   number
  end_hr:     number
}

export interface SimSnapshot {
  time_hr: number
  levels:  Record<string, number>
}

export interface SimResult {
  snapshots: SimSnapshot[]
  log:       Array<{ time_hr: number; event: string; machine_id: string; mode: string }>
}

export function useSimulate() {
  const result  = ref<SimResult | null>(null)
  const error   = ref<string | null>(null)
  const loading = ref(false)

  let timer: ReturnType<typeof setTimeout> | null = null

  function run(
    process:   Record<string, unknown>,
    intakes:   SimIntake[],
    blocks:    SimBlock[],
    horizonHr: number,
    rates:     Record<string, Record<string, number>> = {},
    debounceMs = 400,
  ): void {
    if (timer !== null) clearTimeout(timer)
    timer = setTimeout(() => _fetch(process, intakes, blocks, horizonHr, rates), debounceMs)
  }

  async function _fetch(
    process:   Record<string, unknown>,
    intakes:   SimIntake[],
    blocks:    SimBlock[],
    horizonHr: number,
    rates:     Record<string, Record<string, number>>,
  ): Promise<void> {
    loading.value = true
    error.value   = null
    try {
      const res = await fetch('/api/simulate', {
        method:  'POST',
        headers: { 'Content-Type': 'application/json' },
        body:    JSON.stringify({ process, intakes, blocks, horizon_hr: horizonHr, rates }),
      })
      if (!res.ok) {
        const body = await res.json().catch(() => ({}))
        throw new Error((body as { error?: string }).error ?? `HTTP ${res.status}`)
      }
      result.value = await res.json() as SimResult
    } catch (e) {
      error.value = e instanceof Error ? e.message : String(e)
    } finally {
      loading.value = false
    }
  }

  return { result, error, loading, run }
}
