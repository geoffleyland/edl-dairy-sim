// ── Dairy types ────────────────────────────────────────────

export interface SankeyNode { name: string }
export interface SankeyLink { source: string; target: string; value: number; stream?: string }
export interface SankeyData { nodes: SankeyNode[]; links: SankeyLink[] }

export interface StreamResult {
  quantity: number
  [component: string]: number
}

export interface YieldResult {
  streams: Record<string, StreamResult>
  sankey:  SankeyData
}

export interface SiteConfig {
  site_name:  string
  machines:   unknown[]
  silos:      unknown[]
  exportable: string[]
  process:    Record<string, unknown>
}
