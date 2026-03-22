import type { Machine, Block, Delivery, SimBlock, SimIntake } from './types'

// ── Site constants ───────────────────────────────────────────────────────────

export const TRUCK_KG = 30_000

// ── Chart colours (keyed by stream/silo id) ─────────────────────────────────
// Defined here so chart lines and gantt blocks share the same palette.

export const SILO_COLORS: Record<string, string> = {
  'milk':                 '#3b82f6',
  'skim':                 '#0ea5e9',
  'cream':                '#f59e0b',
  'buttermilk':           '#f97316',
  'condensed-skim':       '#0d9488',
  'condensed-buttermilk': '#d97706',
}

// ── Machine helpers (derived from site config) ───────────────────────────────

// Returns the mode's primary input stream (driver), which determines block colour.
export function modeInputSilo(machine: Machine, modeId: string): string {
  // The actual stream graph lives in process.operations; for colouring we need
  // to look that up. Until the diagram feature is built, we keep a compact
  // local mapping: operation id → driver stream. This is the ONLY place the
  // mapping is duplicated — it can be removed once the frontend reads the
  // full process.operations alongside the site config.
  return OPERATION_DRIVER[machine.modes.find(m => m.id === modeId)?.operation ?? ''] ?? ''
}

// Operation id → driver (first input) stream. Mirrors process.operations in site.json.
// When the diagram/editor is built this lookup will be derived from that data instead.
const OPERATION_DRIVER: Record<string, string> = {
  'separate-milk':  'milk',
  'separate-cream': 'cream',
  'condense-skim':  'skim',
  'condense-bm':    'buttermilk',
  'dry-skim':       'condensed-skim',
  'dry-bm':         'condensed-buttermilk',
}

export function blockColor(machine: Machine, modeId: string): string {
  return SILO_COLORS[modeInputSilo(machine, modeId)] ?? '#6b7280'
}

// ── API conversion ───────────────────────────────────────────────────────────

export function blockToApi(b: Block): SimBlock {
  return { machine_id: b.machineId, mode: b.mode, start_hr: b.startHr, end_hr: b.endHr }
}

export function deliveryToIntakes(deliveries: Delivery[], siloId: string): SimIntake[] {
  return deliveries
    .filter(d => d.endHr > d.startHr)
    .map(d => ({
      silo_id:        siloId,
      start_hr:       d.startHr,
      end_hr:         d.endHr,
      rate_kg_per_hr: (d.truckloads * TRUCK_KG) / (d.endHr - d.startHr),
    }))
}

// ── Rate override shape (sent to /simulate) ──────────────────────────────────
// { machineId: { modeId: { rate_kg_per_hour: number } } }

export type MachineRates = Record<string, Record<string, { rate_kg_per_hour: number }>>

export function buildRateOverrides(
  machines: Machine[],
  rates: Record<string, Record<string, number>>,  // machineId → modeId → kg/hr
): MachineRates {
  const overrides: MachineRates = {}
  for (const m of machines) {
    const modeRates = rates[m.id]
    if (!modeRates) continue
    overrides[m.id] = {}
    for (const mode of m.modes) {
      const r = modeRates[mode.id]
      if (r !== undefined) overrides[m.id][mode.id] = { rate_kg_per_hour: r }
    }
  }
  return overrides
}
