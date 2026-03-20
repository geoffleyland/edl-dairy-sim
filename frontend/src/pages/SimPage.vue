<script setup lang="ts">
import * as echarts from 'echarts'
import { ref, reactive, computed, watch, nextTick, onMounted, onUnmounted } from 'vue'
import { useSimulate } from '../useSimulate'
import type { SiteConfig, Block, Delivery } from '../types'
import { SILO_COLORS, RATE_FIELDS, blockColor, modesForType, blockToApi, deliveryToIntakes } from '../domain'

// ── Constants ───────────────────────────────────────────────────────────────

const HORIZON    = 24
const AXIS_TICKS = [0, 4, 8, 12, 16, 20, 24]

// ── Site config ─────────────────────────────────────────────────────────────

const siteConfig  = ref<SiteConfig | null>(null)
const configError = ref<string | null>(null)

interface MachineDef { id: string; name: string; type: string; modes: string[] }

const machineDefs = computed<MachineDef[]>(() =>
  (siteConfig.value?.machines ?? []).map(m => ({
    id: m.id, name: m.name, type: m.type, modes: modesForType(m.type),
  }))
)

const siloDefs = computed(() => siteConfig.value?.silos ?? [])

onMounted(async () => {
  try {
    const res = await fetch('/api/config')
    if (!res.ok) throw new Error(`HTTP ${res.status}`)
    siteConfig.value = await res.json() as SiteConfig
  } catch (e) {
    configError.value = e instanceof Error ? e.message : String(e)
    return
  }
  for (const m of machineDefs.value) activeMode[m.id] = m.modes[0]
  for (const s of siloDefs.value)    capacities[s.id] = s.volume_kg
  // Init machine rates from site.json
  const machines = (siteConfig.value?.machines ?? []) as Array<Record<string, unknown>>
  for (const m of machines) {
    const id     = String(m.id)
    const fields = RATE_FIELDS[String(m.type)] ?? []
    if (fields.length > 0)
      machineRates[id] = Object.fromEntries(fields.map(f => [f.key, Number(m[f.key] ?? 0)]))
  }
  triggerSim()
})

// ── Mode picker ─────────────────────────────────────────────────────────────

const activeMode = reactive<Record<string, string>>({})

// ── Machine rates (editable, from site.json) ─────────────────────────────────

const machineRates = reactive<Record<string, Record<string, number>>>({})

function setMachineRate(machineId: string, key: string, kg: number) {
  if (!machineRates[machineId]) machineRates[machineId] = {}
  machineRates[machineId][key] = Math.max(0, kg)
}

// ── Schedule blocks ──────────────────────────────────────────────────────────

const blocks = ref<Block[]>([
  { id: '1', machineId: 'separator', mode: 'running', startHr: 0, endHr: 22 },
  { id: '2', machineId: 'condenser', mode: 'skim',    startHr: 2, endHr: 22 },
  { id: '3', machineId: 'drier',     mode: 'smp',     startHr: 4, endHr: 22 },
])

function blocksFor(machineId: string) { return blocks.value.filter(b => b.machineId === machineId) }
function removeBlock(id: string)      { blocks.value = blocks.value.filter(b => b.id !== id) }

// ── Deliveries ───────────────────────────────────────────────────────────────

const rawMilkDeliveries = ref<Delivery[]>([
  { id: 'd1', startHr: 0, endHr: 8, truckloads: 4 },
])
const creamDeliveries = ref<Delivery[]>([])

function removeDelivery(id: string, siloId: string) {
  if (siloId === 'raw-milk') rawMilkDeliveries.value = rawMilkDeliveries.value.filter(d => d.id !== id)
  else                       creamDeliveries.value   = creamDeliveries.value.filter(d => d.id !== id)
}

function deliveryArr(siloId: string) {
  return siloId === 'raw-milk' ? rawMilkDeliveries : creamDeliveries
}

// ── Track DOM refs ───────────────────────────────────────────────────────────

const trackEls: Record<string, HTMLElement> = {}
function setTrackEl(id: string, el: unknown) {
  if (el instanceof HTMLElement) trackEls[id] = el
  else delete trackEls[id]
}

const rawMilkTrackEl = ref<HTMLElement | null>(null)
const creamTrackEl   = ref<HTMLElement | null>(null)

function deliveryTrackEl(siloId: string): HTMLElement | null {
  return siloId === 'raw-milk' ? rawMilkTrackEl.value : creamTrackEl.value
}

// ── Drag state ───────────────────────────────────────────────────────────────

type DragKind =
  | { kind: 'create';          machineId: string; mode: string; startHr: number; currentHr: number }
  | { kind: 'delivery';        siloId: string; startHr: number; currentHr: number }
  | { kind: 'move-block';      blockId: string; grabOffsetHr: number }
  | { kind: 'move-delivery';   deliveryId: string; siloId: string; grabOffsetHr: number }
  | { kind: 'resize-block';    blockId: string; handle: 'start' | 'end' }
  | { kind: 'resize-delivery'; deliveryId: string; siloId: string; handle: 'start' | 'end' }

type DragState = DragKind & { trackEl: HTMLElement }

const drag = ref<DragState | null>(null)

function hrFromEl(e: MouseEvent, el: HTMLElement): number {
  const rect = el.getBoundingClientRect()
  return ((e.clientX - rect.left) / rect.width) * HORIZON
}

function snapHr(hr: number): number {
  return Math.max(0, Math.min(HORIZON, Math.round(hr * 4) / 4))
}

function uid() { return Math.random().toString(36).slice(2) }

// ── Drag initiators ──────────────────────────────────────────────────────────

function onTrackDown(e: MouseEvent, machineId: string) {
  const trackEl = trackEls[machineId]
  if (!trackEl) return
  const hr   = snapHr(hrFromEl(e, trackEl))
  const mode = activeMode[machineId] ?? machineDefs.value.find(m => m.id === machineId)?.modes[0] ?? 'running'
  drag.value = { kind: 'create', machineId, mode, startHr: hr, currentHr: hr, trackEl }
  e.preventDefault()
}

function onDeliveryTrackDown(e: MouseEvent, siloId: string) {
  const el = deliveryTrackEl(siloId)
  if (!el) return
  const hr = snapHr(hrFromEl(e, el))
  drag.value = { kind: 'delivery', siloId, startHr: hr, currentHr: hr, trackEl: el }
  e.preventDefault()
}

function onBlockDown(e: MouseEvent, blockId: string, machineId: string) {
  const trackEl = trackEls[machineId]
  if (!trackEl) return
  const b = blocks.value.find(b => b.id === blockId)
  if (!b) return
  drag.value = { kind: 'move-block', blockId, grabOffsetHr: hrFromEl(e, trackEl) - b.startHr, trackEl }
  e.preventDefault()
}

function onDeliveryBarDown(e: MouseEvent, deliveryId: string, siloId: string) {
  const el = deliveryTrackEl(siloId)
  if (!el) return
  const d = deliveryArr(siloId).value.find(d => d.id === deliveryId)
  if (!d) return
  drag.value = { kind: 'move-delivery', deliveryId, siloId, grabOffsetHr: hrFromEl(e, el) - d.startHr, trackEl: el }
  e.preventDefault()
}

function onResizeBlock(e: MouseEvent, blockId: string, handle: 'start' | 'end') {
  const b = blocks.value.find(b => b.id === blockId)
  const trackEl = b ? trackEls[b.machineId] : null
  if (!trackEl) return
  drag.value = { kind: 'resize-block', blockId, handle, trackEl }
  e.preventDefault()
}

function onResizeDelivery(e: MouseEvent, deliveryId: string, siloId: string, handle: 'start' | 'end') {
  const el = deliveryTrackEl(siloId)
  if (!el) return
  drag.value = { kind: 'resize-delivery', deliveryId, siloId, handle, trackEl: el }
  e.preventDefault()
}

// ── Global drag handlers ─────────────────────────────────────────────────────

function onMouseMove(e: MouseEvent) {
  const d = drag.value
  if (!d) return
  const hr = snapHr(hrFromEl(e, d.trackEl))

  if (d.kind === 'create' || d.kind === 'delivery') {
    d.currentHr = hr
  } else if (d.kind === 'move-block') {
    const b = blocks.value.find(b => b.id === d.blockId)
    if (b) {
      const dur = b.endHr - b.startHr
      b.startHr = Math.max(0, Math.min(HORIZON - dur, snapHr(hr - d.grabOffsetHr)))
      b.endHr   = b.startHr + dur
    }
  } else if (d.kind === 'move-delivery') {
    const del = deliveryArr(d.siloId).value.find(d2 => d2.id === d.deliveryId)
    if (del) {
      const dur = del.endHr - del.startHr
      del.startHr = Math.max(0, Math.min(HORIZON - dur, snapHr(hr - d.grabOffsetHr)))
      del.endHr   = del.startHr + dur
    }
  } else if (d.kind === 'resize-block') {
    const b = blocks.value.find(b => b.id === d.blockId)
    if (b) {
      if (d.handle === 'start') b.startHr = Math.min(hr, b.endHr - 0.5)
      else                      b.endHr   = Math.max(hr, b.startHr + 0.5)
    }
  } else if (d.kind === 'resize-delivery') {
    const del = deliveryArr(d.siloId).value.find(d2 => d2.id === d.deliveryId)
    if (del) {
      if (d.handle === 'start') del.startHr = Math.min(hr, del.endHr - 0.5)
      else                      del.endHr   = Math.max(hr, del.startHr + 0.5)
    }
  }
}

function onMouseUp() {
  const d = drag.value
  if (!d) return
  if (d.kind === 'create') {
    const [a, b] = [Math.min(d.startHr, d.currentHr), Math.max(d.startHr, d.currentHr)]
    if (b - a >= 0.25) blocks.value.push({ id: uid(), machineId: d.machineId, mode: d.mode, startHr: a, endHr: b })
  }
  if (d.kind === 'delivery') {
    const [a, b] = [Math.min(d.startHr, d.currentHr), Math.max(d.startHr, d.currentHr)]
    if (b - a >= 0.25) deliveryArr(d.siloId).value.push({ id: uid(), startHr: a, endHr: b, truckloads: 1 })
  }
  drag.value = null
}

function isCreateGhostFor(machineId: string): boolean {
  const d = drag.value
  return !!d && d.kind === 'create' && d.machineId === machineId
}

function isDeliveryGhostFor(siloId: string): boolean {
  const d = drag.value
  return !!d && d.kind === 'delivery' && d.siloId === siloId
}

// ── Block / ghost styles ─────────────────────────────────────────────────────

function barStyle(startHr: number, endHr: number, color: string) {
  return {
    left:       `${(startHr / HORIZON) * 100}%`,
    width:      `${((endHr - startHr) / HORIZON) * 100}%`,
    background: color,
  }
}

const ghostStyle = computed(() => {
  const d = drag.value
  if (!d || d.kind !== 'create') return {}
  const a = Math.min(d.startHr, d.currentHr)
  const b = Math.max(d.startHr, d.currentHr)
  const type = machineDefs.value.find(m => m.id === d.machineId)?.type ?? ''
  return barStyle(a, Math.max(b, a + 0.25), blockColor(type, d.mode))
})

const deliveryGhostStyle = computed(() => {
  const d = drag.value
  if (!d || d.kind !== 'delivery') return {}
  const a = Math.min(d.startHr, d.currentHr)
  const b = Math.max(d.startHr, d.currentHr)
  return barStyle(a, Math.max(b, a + 0.25), SILO_COLORS[d.siloId] ?? SILO_COLORS['raw-milk'])
})

// ── Simulation ───────────────────────────────────────────────────────────────

const { result: simResult, error: simError, loading: simLoading, run } = useSimulate()

function triggerSim() {
  const cfg = siteConfig.value
  if (!cfg) return

  run(
    cfg.process as Record<string, unknown>,
    [
      ...deliveryToIntakes(rawMilkDeliveries.value, 'raw-milk'),
      ...deliveryToIntakes(creamDeliveries.value,   'cream'),
    ],
    blocks.value.map(blockToApi),
    HORIZON,
    { ...machineRates },
  )
}

watch([blocks, rawMilkDeliveries, creamDeliveries], triggerSim, { deep: true })
watch(machineRates, triggerSim, { deep: true })

// ── Silo capacities (editable, initialised from site.json) ──────────────────

const capacities = reactive<Record<string, number>>({})

function setCapKg(siloId: string, kg: number) {
  capacities[siloId] = Math.max(0, kg)
}

// ── Per-silo ECharts instances ───────────────────────────────────────────────

const siloCharts: Record<string, echarts.ECharts> = {}
let gridResizeObs: ResizeObserver | null = null

function initSiloChart(siloId: string, el: unknown) {
  if (!(el instanceof HTMLElement)) {
    siloCharts[siloId]?.dispose()
    delete siloCharts[siloId]
    return
  }
  if (siloCharts[siloId]) return
  const c = echarts.init(el)
  c.setOption({
    animation: false,
    grid:    { top: 14, right: 13, bottom: 22, left: 50 },
    xAxis:   { type: 'value', min: 0, max: HORIZON, axisLabel: { fontSize: 10, formatter: (v: number) => `${v}h` } },
    yAxis:   { type: 'value', axisLabel: { fontSize: 10, formatter: (v: number) => v >= 1000 ? `${(v / 1000).toFixed(0)}k` : String(v) } },
    tooltip: { trigger: 'axis', confine: true, textStyle: { fontSize: 11 } },
    series:  [],
  })
  siloCharts[siloId] = c
  nextTick(() => {
    c.resize()
    const r = simResult.value
    if (r) updateSiloChart(siloId, r.snapshots)
  })
}

function initChartGrid(el: unknown) {
  gridResizeObs?.disconnect()
  gridResizeObs = null
  if (!(el instanceof HTMLElement)) return
  gridResizeObs = new ResizeObserver(() => Object.values(siloCharts).forEach(c => c.resize()))
  gridResizeObs.observe(el)
}

function updateSiloChart(siloId: string, snapshots: import('../useSimulate').SimSnapshot[]) {
  const c = siloCharts[siloId]
  if (!c) return
  const color = SILO_COLORS[siloId] ?? '#999'
  const cap   = capacities[siloId] ?? 0
  const data   = snapshots.map(s => [s.time_hr, Math.round(s.levels[siloId] ?? 0)])
  const peak   = data.reduce((m, p) => Math.max(m, p[1] as number), 0)
  const trough = data.reduce((m, p) => Math.min(m, p[1] as number), 0)
  c.setOption({
    yAxis: {
      max: cap > 0 ? Math.max(cap, peak) * 1.03 : (peak > 0 ? peak * 1.03 : undefined),
      min: trough < 0 ? trough * 1.03 : 0,
    },
    series: [{
      type:       'line',
      smooth:     false,
      showSymbol: false,
      color,
      data,
      areaStyle: { color, opacity: 0.07 },
      markLine: {
        silent:    true,
        symbol:    'none',
        lineStyle: { type: 'dashed', color: '#ef4444', width: 1.5, opacity: 0.8 },
        label:     { show: false },
        data:      cap > 0 ? [{ yAxis: cap }] : [],
      },
    }],
  })
}

onMounted(() => {
  document.addEventListener('mousemove', onMouseMove)
  document.addEventListener('mouseup',  onMouseUp)
})

onUnmounted(() => {
  gridResizeObs?.disconnect()
  Object.values(siloCharts).forEach(c => c.dispose())
  document.removeEventListener('mousemove', onMouseMove)
  document.removeEventListener('mouseup',  onMouseUp)
})

watch(simResult, async (r) => {
  if (!r) return
  await nextTick()
  for (const silo of siloDefs.value) updateSiloChart(silo.id, r.snapshots)
})
watch(capacities, async () => {
  const r = simResult.value
  if (!r) return
  await nextTick()
  for (const silo of siloDefs.value) updateSiloChart(silo.id, r.snapshots)
}, { deep: true })
</script>

<template>
  <div class="sim-page">
    <div v-if="configError" class="status error">Failed to load config: {{ configError }}</div>

    <template v-else>

      <!-- ── Schedule ─────────────────────────────────────────────────────── -->
      <div class="sim-schedule">

        <!-- Time axis -->
        <div class="sched-row">
          <div class="row-label" />
          <div class="row-track axis-track">
            <div v-for="t in AXIS_TICKS" :key="t" class="axis-tick" :style="{ left: `${(t / HORIZON) * 100}%` }">
              {{ t }}h
            </div>
          </div>
        </div>

        <!-- Raw milk delivery row -->
        <div class="sched-row">
          <div class="row-label">
            <span class="machine-name">Raw Milk</span>
          </div>
          <div class="row-track" ref="rawMilkTrackEl" @mousedown="onDeliveryTrackDown($event, 'raw-milk')">
            <div
              v-for="d in rawMilkDeliveries" :key="d.id"
              class="block"
              :style="barStyle(d.startHr, d.endHr, SILO_COLORS['raw-milk'])"
              @mousedown.stop="onDeliveryBarDown($event, d.id, 'raw-milk')"
            >
              <div class="rh rh-l" @mousedown.stop="onResizeDelivery($event, d.id, 'raw-milk', 'start')" />
              <input type="number" v-model.number="d.truckloads" min="1" max="99" step="1"
                class="truck-input" @mousedown.stop @click.stop />
              <span class="truck-unit" @mousedown.stop @click.stop>loads at 30,000 kg each</span>
              <button class="block-del" @mousedown.stop @click.stop="removeDelivery(d.id, 'raw-milk')">×</button>
              <div class="rh rh-r" @mousedown.stop="onResizeDelivery($event, d.id, 'raw-milk', 'end')" />
            </div>
            <div v-if="isDeliveryGhostFor('raw-milk')" class="block ghost" :style="deliveryGhostStyle" />
          </div>
        </div>

        <!-- Cream delivery row -->
        <div class="sched-row">
          <div class="row-label">
            <span class="machine-name">Cream</span>
          </div>
          <div class="row-track" ref="creamTrackEl" @mousedown="onDeliveryTrackDown($event, 'cream')">
            <div
              v-for="d in creamDeliveries" :key="d.id"
              class="block"
              :style="barStyle(d.startHr, d.endHr, SILO_COLORS['cream'])"
              @mousedown.stop="onDeliveryBarDown($event, d.id, 'cream')"
            >
              <div class="rh rh-l" @mousedown.stop="onResizeDelivery($event, d.id, 'cream', 'start')" />
              <input type="number" v-model.number="d.truckloads" min="1" max="99" step="1"
                class="truck-input" @mousedown.stop @click.stop />
              <span class="truck-unit" @mousedown.stop @click.stop>loads at 30,000 kg each</span>
              <button class="block-del" @mousedown.stop @click.stop="removeDelivery(d.id, 'cream')">×</button>
              <div class="rh rh-r" @mousedown.stop="onResizeDelivery($event, d.id, 'cream', 'end')" />
            </div>
            <div v-if="isDeliveryGhostFor('cream')" class="block ghost" :style="deliveryGhostStyle" />
          </div>
        </div>

        <!-- Machine rows -->
        <div v-for="m in machineDefs" :key="m.id" class="sched-row sched-row--machine">
          <div class="row-label row-label--machine">
            <div class="label-top">
              <span class="machine-name">{{ m.name }}</span>
              <div v-if="m.modes.length > 1" class="mode-btns">
                <button
                  v-for="mode in m.modes" :key="mode"
                  :class="['mode-btn', { active: activeMode[m.id] === mode }]"
                  :style="activeMode[m.id] === mode
                    ? { background: blockColor(m.type, mode), color: 'white', borderColor: 'transparent' }
                    : { borderColor: blockColor(m.type, mode), color: blockColor(m.type, mode) }"
                  @click="activeMode[m.id] = mode"
                >{{ mode }}</button>
              </div>
            </div>
            <div v-if="RATE_FIELDS[m.type]?.length" class="label-rates">
              <template v-for="f in (RATE_FIELDS[m.type] ?? [])" :key="f.key">
                <span v-if="f.label" class="rate-label">{{ f.label }}</span>
                <input
                  type="number" step="0.5" min="0.5"
                  class="rate-input"
                  :value="((machineRates[m.id]?.[f.key] ?? 0) / 1000).toFixed(1)"
                  @change="(e) => setMachineRate(m.id, f.key, +(e.target as HTMLInputElement).value * 1000)"
                  @click.stop @mousedown.stop
                />
              </template>
              <span class="rate-unit">t/hr</span>
            </div>
          </div>

          <div
            class="row-track"
            :ref="(el) => setTrackEl(m.id, el)"
            @mousedown="onTrackDown($event, m.id)"
          >
            <div
              v-for="b in blocksFor(m.id)" :key="b.id"
              class="block"
              :style="barStyle(b.startHr, b.endHr, blockColor(m.type, b.mode))"
              :title="`${b.mode}  ${b.startHr}h – ${b.endHr}h`"
              @mousedown.stop="onBlockDown($event, b.id, m.id)"
            >
              <div class="rh rh-l" @mousedown.stop="onResizeBlock($event, b.id, 'start')" />
              <span class="block-label">{{ b.mode }}</span>
              <button class="block-del" @mousedown.stop @click.stop="removeBlock(b.id)">×</button>
              <div class="rh rh-r" @mousedown.stop="onResizeBlock($event, b.id, 'end')" />
            </div>
            <div v-if="isCreateGhostFor(m.id)" class="block ghost" :style="ghostStyle" />
          </div>
        </div>

      </div><!-- /sim-schedule -->

      <!-- ── Silo charts ──────────────────────────────────────────────────── -->
      <div class="sim-chart-header">
        <span class="chart-label">Silo levels</span>
        <span v-if="simLoading" class="sim-status">Simulating…</span>
        <span v-if="simError"   class="sim-status error">{{ simError }}</span>
      </div>
      <div class="sim-chart-grid" :ref="initChartGrid">
        <div v-for="silo in siloDefs" :key="silo.id" class="silo-panel">
          <div class="panel-left">
            <div class="panel-name-row">
              <span class="panel-dot" :style="{ background: SILO_COLORS[silo.id] ?? '#999' }" />
              <span class="panel-name">{{ silo.name }}</span>
            </div>
            <div class="panel-cap-row">
              <label class="cap-label">Capacity:</label>
              <input
                type="number"
                class="cap-input"
                :value="Math.round((capacities[silo.id] ?? 0) / 1000)"
                @change="(e) => setCapKg(silo.id, +(e.target as HTMLInputElement).value * 1000)"
                min="0" step="10"
              />
              <span class="cap-unit">t</span>
            </div>
          </div>
          <div class="panel-chart" :ref="(el) => initSiloChart(silo.id, el)" />
        </div>
      </div>

    </template>
  </div>
</template>

<style scoped>
.sim-page {
  display: flex;
  flex-direction: column;
  height: 100%;
  overflow-y: auto;
  background: var(--color-bg);
}

/* ── Schedule ── */

.sim-schedule {
  flex-shrink: 0;
  padding: 10px 16px 6px;
  border-bottom: 1px solid var(--color-border);
  background: var(--color-bg-alt);
}

.sched-row {
  display: flex;
  align-items: center;
  height: 36px;
}

.sched-row--machine {
  height: auto;
  min-height: 36px;
  padding: 5px 0;
}

.row-label {
  width: 220px;
  flex-shrink: 0;
  display: flex;
  align-items: center;
  gap: 6px;
  padding-right: 10px;
  overflow: hidden;
}

.row-label--machine {
  flex-direction: column;
  align-items: flex-start;
  gap: 4px;
}

.label-top {
  display: flex;
  align-items: center;
  gap: 6px;
}

.label-rates {
  display: flex;
  align-items: center;
  gap: 4px;
  flex-wrap: nowrap;
}

.machine-name {
  font-size: 13px;
  font-weight: 500;
  white-space: nowrap;
}

.mode-btns { display: flex; gap: 3px; }

.mode-btn {
  font-size: 10px;
  padding: 2px 5px;
  border-radius: 3px;
  border: 1px solid;
  background: transparent;
  cursor: pointer;
  line-height: 1.4;
  transition: background 0.12s, color 0.12s;
  font-weight: 500;
}

/* Track */

.row-track {
  flex: 1;
  position: relative;
  height: 26px;
  background: var(--color-bg);
  border: 1px solid var(--color-border);
  border-radius: 4px;
  cursor: crosshair;
  overflow: visible;
  user-select: none;
}

.axis-track {
  height: 22px;
  background: none;
  border: none;
  cursor: default;
  overflow: visible;
}

.axis-tick {
  position: absolute;
  transform: translateX(-50%);
  font-size: 11px;
  color: var(--color-text-muted);
  white-space: nowrap;
  pointer-events: none;
}

/* Rate inputs (inside left label, below machine name) */

.rate-label {
  font-size: 10px;
  color: var(--color-text-muted);
  flex-shrink: 0;
}

.rate-input {
  width: 56px;
  padding: 2px 5px;
  border: 1px solid var(--color-border);
  border-radius: 3px;
  font-size: 11px;
  text-align: right;
  background: var(--color-bg);
  color: var(--color-text);
}

.rate-unit {
  font-size: 10px;
  color: var(--color-text-muted);
  white-space: nowrap;
  flex-shrink: 0;
}

/* Blocks */

.block {
  position: absolute;
  top: 2px;
  height: calc(100% - 4px);
  border-radius: 3px;
  display: flex;
  align-items: center;
  gap: 3px;
  padding: 0 8px;
  overflow: hidden;
  opacity: 0.88;
  cursor: grab;
}
.block:active { cursor: grabbing; }

.block-label {
  font-size: 11px;
  color: white;
  font-weight: 500;
  white-space: nowrap;
  pointer-events: none;
  flex: 1;
  overflow: hidden;
}

.block-del {
  margin-left: auto;
  font-size: 12px;
  line-height: 1;
  background: rgba(255, 255, 255, 0.15);
  border: none;
  border-radius: 2px;
  color: white;
  opacity: 0;
  cursor: pointer;
  padding: 1px 3px;
  transition: opacity 0.12s;
  flex-shrink: 0;
}
.block:hover .block-del { opacity: 1; }
.block-del:hover         { background: rgba(255, 255, 255, 0.35); }

.block.ghost {
  opacity: 0.35;
  pointer-events: none;
}

/* Resize handles */
.rh {
  position: absolute;
  top: 0;
  bottom: 0;
  width: 7px;
  cursor: ew-resize;
  z-index: 1;
  border-radius: 3px;
  background: rgba(255, 255, 255, 0.15);
  transition: background 0.12s;
}
.rh-l { left: 0; }
.rh-r { right: 0; }
.rh:hover { background: rgba(255, 255, 255, 0.4); }

/* Delivery input */
.truck-input {
  width: 56px;
  background: rgba(255, 255, 255, 0.22);
  border: 1px solid rgba(255, 255, 255, 0.3);
  border-radius: 2px;
  color: white;
  font-size: 11px;
  font-weight: 600;
  text-align: center;
  padding: 1px 2px;
  flex-shrink: 0;
}
.truck-input:focus { outline: 1px solid rgba(255, 255, 255, 0.7); }

.truck-unit {
  font-size: 11px;
  color: rgba(255, 255, 255, 0.85);
  white-space: nowrap;
  pointer-events: none;
}

/* ── Silo charts ── */

.sim-chart-header {
  flex-shrink: 0;
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 5px 16px;
  border-bottom: 1px solid var(--color-border);
  font-size: 12px;
}

.chart-label {
  font-weight: 600;
  color: var(--color-text-secondary);
  font-size: 12px;
}

.sim-status       { font-size: 12px; color: var(--color-text-muted); }
.sim-status.error { color: var(--color-danger); }

.sim-chart-grid {
  flex-shrink: 0;
  display: flex;
  flex-direction: column;
  gap: 1px;
  background: var(--color-border);
  margin-bottom: 24px;
}

.silo-panel {
  background: var(--color-bg);
  display: flex;
  flex-direction: row;
  height: 120px;
  border-bottom: 1px solid var(--color-border);
}

.panel-left {
  width: 200px;
  flex-shrink: 0;
  display: flex;
  flex-direction: column;
  justify-content: center;
  gap: 5px;
  padding: 6px 10px 6px 16px;
  border-right: 1px solid var(--color-border);
}

.panel-name-row {
  display: flex;
  align-items: center;
  gap: 5px;
}

.panel-dot {
  width: 8px;
  height: 8px;
  border-radius: 50%;
  flex-shrink: 0;
}

.panel-name {
  font-weight: 500;
  font-size: 12px;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.panel-cap-row {
  display: flex;
  align-items: center;
  gap: 4px;
}

.cap-label {
  font-size: 11px;
  color: var(--color-text-muted);
  white-space: nowrap;
}

.cap-input {
  width: 52px;
  padding: 2px 4px;
  border: 1px solid var(--color-border);
  border-radius: 3px;
  font-size: 11px;
  text-align: right;
  background: var(--color-bg);
  color: var(--color-text);
}

.cap-unit {
  font-size: 11px;
  color: var(--color-text-muted);
}

.panel-chart {
  flex: 1;
  height: 120px;
}
</style>
