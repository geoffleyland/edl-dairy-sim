import type { Block, Delivery, SimBlock, SimIntake } from './types'

// ── Site constants ───────────────────────────────────────────────────────────

export const TRUCK_KG = 30_000

// ── Chart colours (keyed by silo id) ────────────────────────────────────────

export const SILO_COLORS: Record<string, string> = {
  'raw-milk':             '#3b82f6',
  'skim':                 '#0ea5e9',
  'cream':                '#f59e0b',
  'buttermilk':           '#f97316',
  'condensed-skim':       '#0d9488',
  'condensed-buttermilk': '#d97706',
}

// ── Machine metadata ─────────────────────────────────────────────────────────

// Primary input silo for each machine type + mode — used for block colouring.
export const INPUT_SILO: Record<string, Record<string, string>> = {
  'separator':    { 'running':    'raw-milk'            },
  'butter-plant': { 'running':    'cream'               },
  'condenser':    { 'skim':       'skim',       'buttermilk': 'buttermilk'           },
  'drier':        { 'smp':        'condensed-skim', 'bmp': 'condensed-buttermilk'  },
}

export const MACHINE_MODES: Record<string, string[]> = {
  'condenser': ['skim', 'buttermilk'],
  'drier':     ['smp',  'bmp'],
}

export function modesForType(type: string): string[] {
  return MACHINE_MODES[type] ?? ['running']
}

export function blockColor(machineType: string, mode: string): string {
  return SILO_COLORS[INPUT_SILO[machineType]?.[mode] ?? ''] ?? '#6b7280'
}

// ── Rate fields (shown in gantt label column) ────────────────────────────────

export interface RateField { key: string; label: string }

export const RATE_FIELDS: Record<string, RateField[]> = {
  'separator':    [{ key: 'rate_kg_per_hour',            label: ''     }],
  'butter-plant': [{ key: 'rate_kg_per_hour',            label: ''     }],
  'condenser':    [{ key: 'skim_rate_kg_per_hour',       label: 'Skim' },
                   { key: 'buttermilk_rate_kg_per_hour', label: 'BM'   }],
  'drier':        [{ key: 'smp_rate_kg_per_hour',        label: 'SMP'  },
                   { key: 'bmp_rate_kg_per_hour',        label: 'BMP'  }],
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
