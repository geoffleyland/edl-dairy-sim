import { useApi } from './useApi'
import { postJSON } from './http'
import type { SimIntake, SimBlock, SimResult } from './types'
import type { MachineRates } from './domain'

export type { SimIntake, SimBlock, SimResult }
export type { SimSnapshot } from './types'

export function useSimulate() {
  const { result, error, loading, schedule } = useApi<SimResult>()

  function run(
    process:    Record<string, unknown>,
    intakes:    SimIntake[],
    blocks:     SimBlock[],
    horizonHr:  number,
    rates:      MachineRates = {},
    capacities: Record<string, number> = {},
    debounceMs  = 400,
  ): void {
    schedule(
      () => postJSON<SimResult>('/api/simulate', { process, intakes, blocks, horizon_hr: horizonHr, rates, capacities }),
      debounceMs,
    )
  }

  return { result, error, loading, run }
}
