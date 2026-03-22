// ── Site config ──────────────────────────────────────────────────────────────

export interface MachineMode {
  id:               string
  label:            string
  operation:        string
  rate_kg_per_hour: number
}

export interface Machine {
  id:        string
  name:      string
  type:      string
  resources: string[]
  modes:     MachineMode[]
}

export interface Stream {
  id:   string
  name: string
  role: 'input' | 'intermediate' | 'output'
}

export interface Silo {
  id:         string
  name:       string
  volume_kg:  number
  initial_kg: number
}

export interface SiteConfig {
  site_name:  string
  machines:   Machine[]
  silos:      Silo[]
  exportable: string[]
  process:    Record<string, unknown>
}

// ── Yield ────────────────────────────────────────────────────────────────────

export interface SankeyNode { name: string }
export interface SankeyLink { source: string; target: string; value: number; stream?: string }
export interface SankeyData  { nodes: SankeyNode[]; links: SankeyLink[] }

export interface StreamResult {
  quantity: number
  [component: string]: number
}

export interface YieldResult {
  streams: Record<string, StreamResult>
  sankey:  SankeyData
}

// ── Simulation ───────────────────────────────────────────────────────────────

export interface Block {
  id:        string
  machineId: string
  mode:      string
  startHr:   number
  endHr:     number
}

export interface Delivery {
  id:         string
  startHr:    number
  endHr:      number
  truckloads: number
}

export interface SimIntake {
  silo_id:        string
  start_hr:       number
  end_hr:         number
  rate_kg_per_hr: number
}

export interface SimBlock {
  machine_id: string
  mode:       string
  start_hr:   number
  end_hr:     number
}

export interface SimSnapshot {
  time_hr:      number
  levels:       Record<string, number>
  label:        string
  equipment_id: string
  mode:         string
}

export interface SimResult {
  snapshots: SimSnapshot[]
}
