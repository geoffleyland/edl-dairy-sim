<script setup lang="ts">
import * as echarts from 'echarts'
import { ref, computed, watch, onMounted, onUnmounted } from 'vue'
import { useYield } from '../useYield'
import type { SiteConfig } from '../types'

// ── Site config ────────────────────────────────────────────

const siteConfig  = ref<SiteConfig | null>(null)
const configError = ref<string | null>(null)

onMounted(async () => {
  try {
    const res = await fetch('/api/config')
    if (!res.ok) throw new Error(`HTTP ${res.status}`)
    siteConfig.value = await res.json() as SiteConfig
  } catch (e) {
    configError.value = e instanceof Error ? e.message : String(e)
    return
  }
  // Prime with defaults from site.json
  const milkComp = (siteConfig.value?.process?.compositions as Record<string, Record<string, number>>)?.milk
  if (milkComp) {
    fat.value     = +(milkComp.fat     * 100).toFixed(2)
    protein.value = +(milkComp.protein * 100).toFixed(2)
    lactose.value = +(milkComp.lactose * 100).toFixed(2)
  }
  triggerCompute()
})

// ── Sliders (values in %) ──────────────────────────────────

// Milk composition
const fat     = ref(4.3)
const protein = ref(3.4)
const lactose = ref(4.9)

// Separation targets
const skimFat  = ref(0.1)   // skim fat after separator
const creamFat = ref(40.0)  // cream fat after separator

// Condenser targets (% total solids after evaporation)
const condensedSkimSolids = ref(45.0)
const condensedBmSolids   = ref(40.0)

// Butter plant targets
const butterFat      = ref(82.0)   // butter fat %
const buttermilkFat  = ref(0.5)    // buttermilk fat %

// Drier targets (% total solids in powder)
const smpSolids = ref(96.0)
const bmpSolids = ref(96.0)

// ── Yield ─────────────────────────────────────────────────

const { result, error: yieldError, loading, compute } = useYield()

function triggerCompute(): void {
  const cfg = siteConfig.value
  if (!cfg) return
  const process = {
    ...cfg.process,
    compositions: {
      ...(cfg.process.compositions as Record<string, unknown>),
      milk:                   { fat: fat.value / 100,     protein: protein.value / 100, lactose: lactose.value / 100 },
      skim:                   { fat: skimFat.value / 100 },
      cream:                  { fat: creamFat.value / 100 },
      'condensed-skim':       { 'total-solids': condensedSkimSolids.value / 100 },
      'condensed-buttermilk': { 'total-solids': condensedBmSolids.value / 100 },
      butter:                 { fat: butterFat.value / 100 },
      buttermilk:             { fat: buttermilkFat.value / 100 },
      smp:                    { 'total-solids': smpSolids.value / 100 },
      bmp:                    { 'total-solids': bmpSolids.value / 100 },
    },
  }
  compute(process)
}

watch(
  [fat, protein, lactose, skimFat, creamFat, condensedSkimSolids, condensedBmSolids, butterFat, buttermilkFat, smpSolids, bmpSolids],
  () => triggerCompute(),
)

// ── ECharts Sankey ─────────────────────────────────────────

const chartEl = ref<HTMLDivElement>()
let chart: echarts.ECharts | null = null

onMounted(() => {
  if (chartEl.value) chart = echarts.init(chartEl.value)
})
onUnmounted(() => chart?.dispose())

watch(result, (r) => {
  if (!chart || !r?.sankey) return

  const streams = r.streams

  // Tooltip content for a named stream (used for both terminal nodes and links).
  function streamTooltip(name: string): string {
    const s = streams[name]
    if (!s) return `<b>${name}</b>`
    const ts = derivedTS(s)
    const lines = [`<b>${name}</b>`, `${s.quantity.toFixed(3)} kg`]
    if (s.fat     != null) lines.push(`Fat: ${(s.fat     * 100).toFixed(1)}%`)
    if (s.protein != null) lines.push(`Protein: ${(s.protein * 100).toFixed(1)}%`)
    if (ts        != null) lines.push(`TS: ${(ts * 100).toFixed(1)}%`)
    return lines.join('<br/>')
  }

  chart.setOption({
    tooltip: {
      trigger:   'item',
      triggerOn: 'mousemove',
      formatter: (params: Record<string, unknown>) => {
        const data = params['data'] as Record<string, unknown> | undefined

        if (params['dataType'] === 'node') {
          // Terminal stream nodes (milk, smp, butter, …) are in streams.
          // Process nodes (Separator, Condenser, …) are not — show name only.
          const name = params['name'] as string
          return name in streams ? streamTooltip(name) : `<b>${name}</b>`
        }

        // Edge — the link carries a "stream" field so we can look up composition.
        const streamName = data?.['stream'] as string | undefined
        if (streamName) return streamTooltip(streamName)

        // Fallback: just show the flow value.
        const val = (params['value'] ?? data?.['value']) as number | undefined
        return val != null ? `${val.toFixed(3)} kg` : ''
      },
    },
    series: [{
      type:      'sankey',
      layout:    'none',
      emphasis:  { focus: 'adjacency' },
      data:      r.sankey.nodes,
      links:     r.sankey.links,
      label:     {
        fontSize:  12,
        // Terminal stream nodes get name + quantity; process nodes get name only.
        formatter: (params: Record<string, unknown>) => {
          const name = params['name'] as string
          const s = streams[name]
          return s ? `${name}\n${s.quantity.toFixed(3)} kg` : name
        },
      },
      lineStyle: { color: 'gradient', opacity: 0.4 },
    }],
  })
})

// ── Stream table ───────────────────────────────────────────

// total-solids is a solver constraint, not a tracked component — derive it from the
// returned components (fat + protein + lactose).  Minerals/ash (~0.7%) are excluded
// from the model so this is a slight underestimate, but fine for a demo.
function derivedTS(s: { fat?: number; protein?: number; [k: string]: number | undefined }): number | undefined {
  const f = s.fat     ?? 0
  const p = s.protein ?? 0
  const l = s['lactose'] ?? 0
  const sum = f + p + l
  return sum > 0 ? sum : undefined
}

const streamRows = computed(() => {
  if (!result.value) return []
  return Object.entries(result.value.streams)
    .map(([name, s]) => ({
      name,
      quantity:    s.quantity,
      fat:         s.fat,
      protein:     s.protein,
      totalSolids: derivedTS(s),
    }))
    .sort((a, b) => b.quantity - a.quantity)
})

function pct(v: number | undefined): string {
  return v != null ? (v * 100).toFixed(1) + '%' : '—'
}
function kg(v: number): string {
  return v.toFixed(3)
}
</script>

<template>
  <div class="yield-page">
    <div v-if="configError" class="status error">Failed to load site config: {{ configError }}</div>

    <template v-else>
      <div class="yield-layout">
        <!-- Controls -->
        <aside class="yield-controls">
          <h2>Milk Composition</h2>
          <p class="yield-basis">per 1 kg milk</p>

          <div class="slider-group">
            <label class="slider-label">
              <span>Fat</span>
              <span class="slider-value">{{ fat.toFixed(1) }}%</span>
            </label>
            <input v-model.number="fat" type="range" min="2" max="7" step="0.1" class="slider" />
          </div>

          <div class="slider-group">
            <label class="slider-label">
              <span>Protein</span>
              <span class="slider-value">{{ protein.toFixed(1) }}%</span>
            </label>
            <input v-model.number="protein" type="range" min="2" max="5" step="0.1" class="slider" />
          </div>

          <div class="slider-group">
            <label class="slider-label">
              <span>Lactose</span>
              <span class="slider-value">{{ lactose.toFixed(1) }}%</span>
            </label>
            <input v-model.number="lactose" type="range" min="3.5" max="6.5" step="0.1" class="slider" />
          </div>

          <h2 class="section-head">Separator Targets</h2>

          <div class="slider-group">
            <label class="slider-label">
              <span>Skim fat</span>
              <span class="slider-value">{{ skimFat.toFixed(2) }}%</span>
            </label>
            <input v-model.number="skimFat" type="range" min="0.05" max="0.5" step="0.01" class="slider" />
          </div>

          <div class="slider-group">
            <label class="slider-label">
              <span>Cream fat</span>
              <span class="slider-value">{{ creamFat.toFixed(1) }}%</span>
            </label>
            <input v-model.number="creamFat" type="range" min="30" max="55" step="0.5" class="slider" />
          </div>

          <h2 class="section-head">Butter Plant Targets</h2>

          <div class="slider-group">
            <label class="slider-label">
              <span>Butter fat</span>
              <span class="slider-value">{{ butterFat.toFixed(1) }}%</span>
            </label>
            <input v-model.number="butterFat" type="range" min="75" max="90" step="0.5" class="slider" />
          </div>

          <div class="slider-group">
            <label class="slider-label">
              <span>Buttermilk fat</span>
              <span class="slider-value">{{ buttermilkFat.toFixed(2) }}%</span>
            </label>
            <input v-model.number="buttermilkFat" type="range" min="0.1" max="2" step="0.05" class="slider" />
          </div>

          <h2 class="section-head">Condenser Targets</h2>
          <p class="yield-basis">total solids after evaporation</p>

          <div class="slider-group">
            <label class="slider-label">
              <span>Skim</span>
              <span class="slider-value">{{ condensedSkimSolids.toFixed(0) }}%</span>
            </label>
            <input v-model.number="condensedSkimSolids" type="range" min="20" max="60" step="1" class="slider" />
          </div>

          <div class="slider-group">
            <label class="slider-label">
              <span>Buttermilk</span>
              <span class="slider-value">{{ condensedBmSolids.toFixed(0) }}%</span>
            </label>
            <input v-model.number="condensedBmSolids" type="range" min="20" max="55" step="1" class="slider" />
          </div>

          <h2 class="section-head">Drier Targets</h2>
          <p class="yield-basis">total solids in powder</p>

          <div class="slider-group">
            <label class="slider-label">
              <span>SMP</span>
              <span class="slider-value">{{ smpSolids.toFixed(0) }}%</span>
            </label>
            <input v-model.number="smpSolids" type="range" min="90" max="99" step="0.5" class="slider" />
          </div>

          <div class="slider-group">
            <label class="slider-label">
              <span>BMP</span>
              <span class="slider-value">{{ bmpSolids.toFixed(0) }}%</span>
            </label>
            <input v-model.number="bmpSolids" type="range" min="90" max="99" step="0.5" class="slider" />
          </div>

          <div v-if="yieldError" class="status error">{{ yieldError }}</div>
          <div v-if="loading"    class="status">Computing…</div>

          <!-- Stream results table -->
          <table v-if="streamRows.length" class="stream-table">
            <thead>
              <tr>
                <th>Stream</th>
                <th class="num">kg</th>
                <th class="num">Fat</th>
                <th class="num">Protein</th>
                <th class="num">TS</th>
              </tr>
            </thead>
            <tbody>
              <tr v-for="row in streamRows" :key="row.name">
                <td>{{ row.name }}</td>
                <td class="num">{{ kg(row.quantity) }}</td>
                <td class="num">{{ pct(row.fat) }}</td>
                <td class="num">{{ pct(row.protein) }}</td>
                <td class="num">{{ pct(row.totalSolids) }}</td>
              </tr>
            </tbody>
          </table>
        </aside>

        <!-- Sankey chart -->
        <div class="yield-chart-wrap">
          <div ref="chartEl" class="yield-chart" />
        </div>
      </div>
    </template>
  </div>
</template>

<style scoped>
.yield-page {
  display: flex;
  flex-direction: column;
  height: 100%;
  overflow: hidden;
}

.yield-layout {
  display: flex;
  flex: 1;
  gap: 0;
  overflow: hidden;
}

/* ── Controls panel ── */
.yield-controls {
  width: 340px;
  flex-shrink: 0;
  padding: 20px 16px;
  border-right: 1px solid var(--color-border);
  overflow-y: auto;
  background: var(--color-bg-alt);
}

.yield-controls h2 {
  font-size: 15px;
  font-weight: 600;
  margin-bottom: 2px;
}

.section-head {
  font-size: 13px;
  font-weight: 600;
  margin: 20px 0 2px;
  color: var(--color-text-secondary);
  text-transform: uppercase;
  letter-spacing: 0.04em;
}

.yield-basis {
  font-size: 12px;
  color: var(--color-text-muted);
  margin-bottom: 8px;
}

.slider-group {
  margin-bottom: 16px;
}

.slider-label {
  display: flex;
  justify-content: space-between;
  font-size: 13px;
  margin-bottom: 4px;
}

.slider-value {
  font-variant-numeric: tabular-nums;
  color: var(--color-primary);
  font-weight: 500;
}

.slider {
  width: 100%;
  accent-color: var(--color-primary);
}

/* ── Stream table ── */
.stream-table {
  margin-top: 20px;
  border-collapse: collapse;
  width: 100%;
  font-size: 12px;
}

.stream-table th {
  text-align: left;
  font-weight: 600;
  color: var(--color-text-muted);
  border-bottom: 1px solid var(--color-border);
  padding: 3px 4px;
}

.stream-table th.num {
  text-align: right;
}

.stream-table td {
  padding: 3px 4px;
  border-bottom: 1px solid var(--color-border-subtle);
}

.stream-table td.num {
  text-align: right;
  font-variant-numeric: tabular-nums;
}

/* ── Sankey ── */
.yield-chart-wrap {
  flex: 1;
  padding: 16px;
  overflow: hidden;
}

.yield-chart {
  width: 100%;
  height: 100%;
}
</style>
