<script setup lang="ts">
import { ref, computed, watch, onMounted } from 'vue'
import type { SiteConfig } from '../types'
import { SILO_COLORS } from '../domain'

// ── Config ────────────────────────────────────────────────────────────────────

const siteConfig = ref<SiteConfig | null>(null)
const loadError  = ref<string | null>(null)

fetch('/api/config')
  .then(r => { if (!r.ok) throw new Error(`HTTP ${r.status}`); return r.json() })
  .then(d => { siteConfig.value = d as SiteConfig })
  .catch(e => { loadError.value = e instanceof Error ? e.message : String(e) })

// ── Editable machine rates and silo capacities ────────────────────────────────

const machineRates   = ref<Record<string, Record<string, number>>>({})
const siloCapacities = ref<Record<string, number>>({})

watch(siteConfig, cfg => {
  if (!cfg) return
  for (const m of cfg.machines)
    if (!machineRates.value[m.id])
      machineRates.value[m.id] = Object.fromEntries(m.modes.map(md => [md.id, md.rate_kg_per_hour]))
  for (const s of cfg.silos)
    if (siloCapacities.value[s.id] === undefined) siloCapacities.value[s.id] = s.volume_kg
}, { immediate: true })

// ── Y-position overrides (user drag, persisted to localStorage) ───────────────

const LS_KEY     = 'dairy-plant-stream-y'
const streamYPos = ref<Record<string, number>>({})

onMounted(() => {
  try {
    const s = localStorage.getItem(LS_KEY)
    if (s) streamYPos.value = JSON.parse(s)
  } catch {}
})

function saveYPos() {
  try { localStorage.setItem(LS_KEY, JSON.stringify(streamYPos.value)) } catch {}
}

function resetYPos() {
  streamYPos.value = {}
  try { localStorage.removeItem(LS_KEY) } catch {}
}

// ── Drag ──────────────────────────────────────────────────────────────────────

const SVG_W = 1060
const SVG_H = 340
const Y_MIN = 40
const Y_MAX = 300

const svgEl    = ref<SVGSVGElement>()
const dragging = ref<{ id: string; startY: number; startMouseY: number } | null>(null)
let   dragMoved = false

function startDrag(streamId: string, event: MouseEvent) {
  event.preventDefault()
  dragMoved = false
  const startY = streamYPos.value[streamId] ?? (diagram.value?.initialY[streamId] ?? SVG_H / 2)
  dragging.value = { id: streamId, startY, startMouseY: event.clientY }

  function onMove(e: MouseEvent) {
    if (!dragging.value || !svgEl.value) return
    dragMoved = true
    const scale = SVG_H / svgEl.value.getBoundingClientRect().height
    const newY  = dragging.value.startY + (e.clientY - dragging.value.startMouseY) * scale
    streamYPos.value = { ...streamYPos.value, [dragging.value.id]: Math.max(Y_MIN, Math.min(Y_MAX, newY)) }
  }

  function onUp() {
    dragging.value = null
    if (dragMoved) saveYPos()
    document.removeEventListener('mousemove', onMove)
    document.removeEventListener('mouseup', onUp)
  }

  document.addEventListener('mousemove', onMove)
  document.addEventListener('mouseup', onUp)
}

// ── Edit popover ──────────────────────────────────────────────────────────────

interface Popover { type: 'machine' | 'silo'; id: string; x: number; y: number }
const popover = ref<Popover | null>(null)

function svgPt(svgX: number, svgY: number) {
  const r = svgEl.value?.getBoundingClientRect()
  if (!r) return { x: 0, y: 0 }
  return { x: r.left + (svgX / SVG_W) * r.width, y: r.top + (svgY / SVG_H) * r.height }
}

function openMachine(id: string, nx: number, ny: number, nh: number) {
  const { x, y } = svgPt(nx, ny + nh / 2 + 4)
  popover.value = { type: 'machine', id, x, y }
}

function openSilo(id: string, nx: number, ny: number) {
  if (dragMoved) return
  const { x, y } = svgPt(nx, ny + NODE_R + 4)
  popover.value = { type: 'silo', id, x, y }
}

function setRate(machineId: string, modeId: string, tPerHr: number) {
  machineRates.value[machineId] = { ...machineRates.value[machineId], [modeId]: tPerHr * 1000 }
}

function setCapacity(siloId: string, tonnes: number) {
  siloCapacities.value[siloId] = tonnes * 1000
}

// ── Layout constants ──────────────────────────────────────────────────────────

const NODE_R = 22
const RECT_W = 114
const X_BASE = 50
const X_STEP = 120

const STREAM_COLOR: Record<string, string> = {
  ...SILO_COLORS,
  butter: '#fbbf24',
  smp:    '#0d9488',
  bmp:    '#b45309',
}

function rectH(n: number) { return 36 + n * 18 }

// ── Initial Y algorithm ───────────────────────────────────────────────────────
//
// For each operation (processed in topological order), distribute its outputs
// symmetrically around the mean Y of its inputs.  This propagates track
// structure through the graph — no hard-coded Y table required.
//
// Example: separator takes milk (y=170), produces skim and cream.
//   skim  = 170 - 55 = 115   (top track)
//   cream = 170 + 55 = 225   (bottom track)
// Condenser then averages skim(115) and buttermilk(225+55=280) → sits at 197.

interface Op { id: string; inputs: string[]; outputs: string[] }

function computeInitialY(ops: Op[], streamRank: Record<string, number>): Record<string, number> {
  const SPREAD  = 110
  const initial: Record<string, number> = {}

  const produced = new Set(ops.flatMap(op => op.outputs))
  for (const op of ops)
    for (const s of op.inputs)
      if (!produced.has(s) && !(s in initial)) initial[s] = SVG_H / 2

  // Process ops shallowest-first so each op's inputs already have a Y.
  const sorted = [...ops].sort((a, b) =>
    Math.max(...a.inputs.map(s => streamRank[s] ?? 0)) -
    Math.max(...b.inputs.map(s => streamRank[s] ?? 0))
  )

  for (const op of sorted) {
    const meanY = op.inputs.reduce((sum, s) => sum + (initial[s] ?? SVG_H / 2), 0) / op.inputs.length
    const n = op.outputs.length
    op.outputs.forEach((s, i) => { initial[s] = meanY + (i - (n - 1) / 2) * SPREAD })
  }

  return initial
}

// ── Diagram computed ──────────────────────────────────────────────────────────

interface StreamNode {
  id: string; name: string; role: string
  x: number; y: number; color: string
  hasSilo: boolean; capT: number | null
}
interface ModeInfo    { id: string; label: string; rateKgHr: number }
interface MachineNode { id: string; name: string; modes: ModeInfo[]; x: number; y: number; h: number }
interface Edge        { d: string; color: string }

const diagram = computed(() => {
  const cfg = siteConfig.value
  if (!cfg) return null

  const rawOps = ((cfg.process as Record<string, unknown>).operations as Array<Record<string, unknown>>) ?? []
  const ops: Op[] = rawOps.map(o => ({
    id:      String(o.id),
    inputs:  ((o.inputs ?? o.input  ?? []) as unknown[]).map(String),
    outputs: ((o.outputs ?? o.output ?? []) as unknown[]).map(String),
  }))

  const streamName: Record<string, string> = {}
  const streamRole: Record<string, string> = {}
  for (const s of cfg.streams ?? []) { streamName[s.id] = s.name; streamRole[s.id] = s.role }

  const siloCapKg: Record<string, number> = {}
  for (const s of cfg.silos) siloCapKg[s.id] = s.volume_kg

  const opToMachine: Record<string, string> = {}
  for (const m of cfg.machines)
    for (const md of m.modes) opToMachine[md.operation] = m.id

  // ── Three-phase rank computation (same as before) ─────────────────────────

  const produced = new Set<string>()
  for (const op of ops) for (const s of op.outputs) produced.add(s)

  const rank: Record<string, number> = {}
  for (const op of ops) for (const s of op.inputs) if (!produced.has(s)) rank[s] = 0
  for (let p = 0; p < 20; p++)
    for (const op of ops) {
      const r = Math.max(...op.inputs.map(s => rank[s] ?? 0)) + 2
      for (const s of op.outputs) if ((rank[s] ?? -1) < r) rank[s] = r
    }

  const machRank: Record<string, number> = {}
  for (const op of ops) {
    const mid = opToMachine[op.id]; if (!mid) continue
    machRank[mid] = Math.max(machRank[mid] ?? 0, Math.max(...op.inputs.map(s => rank[s] ?? 0)) + 1)
  }

  for (let p = 0; p < 10; p++) {
    let changed = false
    for (const op of ops) {
      const mid = opToMachine[op.id]; if (!mid) continue
      const r = Math.max(...op.inputs.map(s => rank[s] ?? 0)) + 1
      if (r > (machRank[mid] ?? 0)) { machRank[mid] = r; changed = true }
    }
    for (const op of ops) {
      const mid = opToMachine[op.id]; if (!mid) continue
      const r = (machRank[mid] ?? 0) + 1
      for (const s of op.outputs) if ((rank[s] ?? -1) < r) { rank[s] = r; changed = true }
    }
    if (!changed) break
  }

  // ── Y positions ───────────────────────────────────────────────────────────

  const initialY = computeInitialY(ops, rank)
  const streamY  = (id: string) => streamYPos.value[id] ?? initialY[id] ?? SVG_H / 2

  // ── Build nodes ───────────────────────────────────────────────────────────

  const allIds = new Set<string>()
  for (const op of ops) { for (const s of op.inputs) allIds.add(s); for (const s of op.outputs) allIds.add(s) }

  const streamNodes: StreamNode[] = []
  for (const id of allIds) {
    const hasS  = id in siloCapKg
    const capKg = hasS ? (siloCapacities.value[id] ?? siloCapKg[id]) : null
    streamNodes.push({
      id, name: streamName[id] ?? id, role: streamRole[id] ?? 'intermediate',
      x: X_BASE + (rank[id] ?? 0) * X_STEP, y: streamY(id),
      color: STREAM_COLOR[id] ?? '#6b7280',
      hasSilo: hasS, capT: capKg !== null ? capKg / 1000 : null,
    })
  }

  const seen = new Set<string>()
  const machineNodes: MachineNode[] = []
  for (const op of ops) {
    const mid = opToMachine[op.id]; if (!mid || seen.has(mid)) continue
    seen.add(mid)
    const m = cfg.machines.find(m => m.id === mid)!
    const ys: number[] = []
    for (const op2 of ops) if (opToMachine[op2.id] === mid) for (const s of op2.inputs) ys.push(streamY(s))
    machineNodes.push({
      id: mid, name: m.name,
      modes: m.modes.map(md => ({ id: md.id, label: md.label, rateKgHr: machineRates.value[mid]?.[md.id] ?? md.rate_kg_per_hour })),
      x: X_BASE + (machRank[mid] ?? 0) * X_STEP,
      y: ys.reduce((a, b) => a + b, 0) / ys.length,
      h: rectH(m.modes.length),
    })
  }

  // ── Build edges ───────────────────────────────────────────────────────────

  const edges: Edge[] = []
  const sN = (id: string) => streamNodes.find(n => n.id === id)!
  const mN = (id: string) => machineNodes.find(n => n.id === id)!

  for (const op of ops) {
    const mid = opToMachine[op.id]; if (!mid) continue
    const mn = mN(mid)
    for (const inp of op.inputs) {
      const sn = sN(inp)
      const x1 = sn.x + NODE_R, y1 = sn.y, x2 = mn.x - RECT_W / 2, y2 = mn.y, cx = (x1 + x2) / 2
      edges.push({ d: `M ${x1} ${y1} C ${cx} ${y1} ${cx} ${y2} ${x2} ${y2}`, color: STREAM_COLOR[inp] ?? '#6b7280' })
    }
    for (const out of op.outputs) {
      const sn = sN(out)
      const x1 = mn.x + RECT_W / 2, y1 = mn.y, x2 = sn.x - NODE_R, y2 = sn.y, cx = (x1 + x2) / 2
      edges.push({ d: `M ${x1} ${y1} C ${cx} ${y1} ${cx} ${y2} ${x2} ${y2}`, color: STREAM_COLOR[out] ?? '#6b7280' })
    }
  }

  return { streamNodes, machineNodes, edges, initialY }
})
</script>

<template>
  <div class="plant-page" @click.self="popover = null">
    <div v-if="loadError"  class="status error">{{ loadError }}</div>
    <div v-else-if="!siteConfig" class="status">Loading…</div>

    <template v-else>
      <div class="plant-header">
        <h1>{{ siteConfig.site_name }} — Plant Layout</h1>
        <div class="header-actions">
          <span class="hint">Drag stream nodes to reposition · Click to edit parameters</span>
          <button class="reset-btn" @click="resetYPos">Reset layout</button>
        </div>
      </div>

      <div class="plant-diagram">
        <svg ref="svgEl" :viewBox="`0 0 ${SVG_W} ${SVG_H}`" class="plant-svg"
          :class="{ dragging: dragging }" @click.self="popover = null">

          <path v-for="(e, i) in diagram?.edges" :key="i"
            :d="e.d" :stroke="e.color" fill="none" stroke-width="2.5" stroke-opacity="0.65" />

          <!-- Machine nodes (click to edit) -->
          <g v-for="m in diagram?.machineNodes" :key="m.id"
            class="machine-node" tabindex="0" role="button" :aria-label="m.name"
            @click.stop="openMachine(m.id, m.x, m.y, m.h)"
            @keydown.enter.stop="openMachine(m.id, m.x, m.y, m.h)">
            <rect :x="m.x - RECT_W / 2" :y="m.y - m.h / 2" :width="RECT_W" :height="m.h" rx="8" class="machine-rect" />
            <text :x="m.x" :y="m.y - m.h / 2 + 15" text-anchor="middle" class="machine-name">{{ m.name }}</text>
            <text v-for="(mode, i) in m.modes" :key="mode.id"
              :x="m.x" :y="m.y - m.h / 2 + 15 + 16 + i * 16"
              text-anchor="middle" class="mode-rate">
              {{ m.modes.length > 1 ? mode.label + ' · ' : '' }}{{ (mode.rateKgHr / 1000).toFixed(0) }}&thinsp;t/hr
            </text>
          </g>

          <!-- Stream nodes (drag Y · click silo to edit) -->
          <g v-for="s in diagram?.streamNodes" :key="s.id"
            :class="['stream-node', { 'has-silo': s.hasSilo }]"
            @mousedown.stop="startDrag(s.id, $event)"
            @click.stop="s.hasSilo && openSilo(s.id, s.x, s.y)">
            <circle :cx="s.x" :cy="s.y" :r="NODE_R" :fill="s.color" :class="['stream-circle', s.role]" />
            <text :x="s.x" :y="s.y - NODE_R - 6" text-anchor="middle" class="stream-label">{{ s.name }}</text>
            <text v-if="s.capT !== null" :x="s.x" :y="s.y + NODE_R + 13" text-anchor="middle" class="silo-cap">
              {{ s.capT.toFixed(0) }}&thinsp;t
            </text>
          </g>
        </svg>
      </div>
    </template>

    <Teleport to="body">
      <div v-if="popover" class="edit-popover" :style="{ left: popover.x + 'px', top: popover.y + 'px' }" @click.stop>
        <button class="popover-close" @click="popover = null">✕</button>

        <template v-if="popover.type === 'machine'">
          <div class="popover-title">{{ siteConfig!.machines.find(m => m.id === popover!.id)?.name }}</div>
          <div v-for="mode in siteConfig!.machines.find(m => m.id === popover!.id)?.modes ?? []"
            :key="mode.id" class="popover-row">
            <label>{{ mode.label }}</label>
            <input type="number"
              :value="(machineRates[popover.id]?.[mode.id] ?? mode.rate_kg_per_hour) / 1000"
              @change="setRate(popover!.id, mode.id, +($event.target as HTMLInputElement).value)"
              min="0" step="1" class="popover-input" />
            <span class="popover-unit">t/hr</span>
          </div>
        </template>

        <template v-else>
          <div class="popover-title">{{ siteConfig!.silos.find(s => s.id === popover!.id)?.name ?? popover.id }}</div>
          <div class="popover-row">
            <label>Capacity</label>
            <input type="number"
              :value="(siloCapacities[popover.id] ?? 0) / 1000"
              @change="setCapacity(popover!.id, +($event.target as HTMLInputElement).value)"
              min="0" step="10" class="popover-input" />
            <span class="popover-unit">t</span>
          </div>
        </template>
      </div>
    </Teleport>
  </div>
</template>

<style scoped>
.plant-page    { padding: 24px 32px; flex: 1; overflow: auto; }

.plant-header  { margin-bottom: 16px; }
.plant-header h1 { font-size: 1.2rem; font-weight: 600; color: var(--color-text); }

.header-actions {
  display: flex; align-items: center; gap: 16px; margin-top: 6px;
}
.hint      { font-size: 0.8rem; color: var(--color-text-muted); }
.reset-btn {
  font-size: 0.75rem; padding: 3px 10px;
  background: var(--color-surface); border: 1px solid var(--color-border);
  border-radius: 4px; color: var(--color-text-muted); cursor: pointer;
}
.reset-btn:hover { color: var(--color-text); border-color: var(--color-text-muted); }

.plant-diagram {
  background: var(--color-surface); border: 1px solid var(--color-border);
  border-radius: 10px; padding: 16px; overflow-x: auto;
}
.plant-svg {
  width: 100%; min-width: 700px; max-width: 1060px; display: block; user-select: none;
}
.plant-svg.dragging { cursor: grabbing; }

.machine-node  { cursor: pointer; }
.machine-node:hover .machine-rect { fill: #4b5563; }
.machine-rect  { fill: #374151; stroke: #6b7280; stroke-width: 1; }
.machine-name  { fill: #f3f4f6; font-size: 11px; font-weight: 600; }
.mode-rate     { fill: #9ca3af; font-size: 10px; }

.stream-node   { cursor: grab; }
.stream-node:active { cursor: grabbing; }
.stream-circle { opacity: 0.85; }
.stream-circle.output { stroke: rgba(255,255,255,0.5); stroke-width: 2; }
.stream-label  { fill: #d1d5db; font-size: 10px; pointer-events: none; }
.silo-cap      { fill: #9ca3af; font-size: 9px; pointer-events: none; }
</style>

<style>
.edit-popover {
  position: fixed; background: #1f2937; border: 1px solid #374151;
  border-radius: 8px; padding: 12px 14px; min-width: 200px;
  box-shadow: 0 8px 24px rgba(0,0,0,.5); z-index: 9999;
}
.popover-close {
  position: absolute; top: 6px; right: 8px; background: none; border: none;
  color: #9ca3af; cursor: pointer; font-size: 13px; line-height: 1;
}
.popover-close:hover { color: #f3f4f6; }
.popover-title { font-size: 12px; font-weight: 600; color: #f3f4f6; margin-bottom: 10px; }
.popover-row   { display: flex; align-items: center; gap: 8px; margin-bottom: 6px; }
.popover-row label { font-size: 11px; color: #9ca3af; min-width: 60px; }
.popover-input {
  width: 80px; background: #374151; border: 1px solid #4b5563;
  border-radius: 4px; color: #f3f4f6; font-size: 12px; padding: 3px 6px; text-align: right;
}
.popover-input:focus { outline: none; border-color: #6b7280; }
.popover-unit  { font-size: 11px; color: #6b7280; }
</style>
