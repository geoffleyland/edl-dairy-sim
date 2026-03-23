<script setup lang="ts">
import * as echarts from 'echarts'
import { ref, watch, onMounted, onUnmounted, nextTick, computed } from 'vue'
import { postJSON } from '../http'
import type { SiteConfig, SankeyData } from '../types'

// ── Site config ──────────────────────────────────────────────────────────────

const siteConfig  = ref<SiteConfig | null>(null)
const configError = ref<string | null>(null)

onMounted(async () => {
  try {
    const res = await fetch('/api/config')
    if (!res.ok) throw new Error(`HTTP ${res.status}`)
    siteConfig.value = await res.json() as SiteConfig
    // Seed initial silo levels from site.json defaults
    for (const silo of siteConfig.value.silos ?? []) {
      siloInitial.value[silo.id] = silo.initial_kg / 1000   // store as tonnes
    }
    run()   // auto-solve on load
  } catch (e) {
    configError.value = e instanceof Error ? e.message : String(e)
  }
})

onUnmounted(() => chart?.dispose())

// ── Inputs ───────────────────────────────────────────────────────────────────

const milkIn      = ref(0)     // truckloads (1 truckload = 30 000 kg)
const creamIn     = ref(0)     // truckloads
const horizonHr   = ref(24)
const priceButter = ref(5.00)
const priceSmp    = ref(3.50)
const priceBmp    = ref(3.00)

// silo id → initial level in tonnes (populated from site.json on mount)
const siloInitial = ref<Record<string, number>>({})

// ── Result ───────────────────────────────────────────────────────────────────

interface PlanResult {
  status:         string
  flows:          Record<string, Record<string, number>>
  end_levels:     Record<string, number>
  overfull_silos: string[]
  outputs:        Record<string, number>
  revenue:        number
  sankey:         SankeyData
}

const result  = ref<PlanResult | null>(null)
const error   = ref<string | null>(null)
const loading = ref(false)

// Treat blank / NaN inputs as 0 so the solver never receives invalid JSON.
function n(v: number) { return isFinite(v) ? v : 0 }

async function run() {
  const cfg = siteConfig.value
  if (!cfg) return
  error.value   = null
  loading.value = true
  try {
    // Convert siloInitial (tonnes) back to kg for the API
    const initial_levels: Record<string, number> = {}
    for (const [id, t] of Object.entries(siloInitial.value))
      initial_levels[id] = n(t) * 1000

    result.value = await postJSON<PlanResult>('/api/plan', {
      process:        cfg.process,
      milk_in:        n(milkIn.value)  * 30_000,
      cream_in:       n(creamIn.value) * 30_000,
      prices:         { butter: n(priceButter.value), smp: n(priceSmp.value), bmp: n(priceBmp.value) },
      horizon_hr:     n(horizonHr.value) || 24,
      initial_levels,
    })
  } catch (e) {
    error.value  = e instanceof Error ? e.message : String(e)
    result.value = null
  } finally {
    loading.value = false
  }
}

// ── Auto-solve on input change ────────────────────────────────────────────────

let solveTimer: ReturnType<typeof setTimeout> | null = null
function scheduleSolve() {
  if (solveTimer) clearTimeout(solveTimer)
  solveTimer = setTimeout(() => run(), 400)
}

const allInputs = computed(() => [
  milkIn.value, creamIn.value, horizonHr.value,
  priceButter.value, priceSmp.value, priceBmp.value,
  ...Object.values(siloInitial.value),
])
watch(allInputs, scheduleSolve)

// ── ECharts Sankey ───────────────────────────────────────────────────────────

const chartEl = ref<HTMLDivElement>()
let chart: echarts.ECharts | null = null

watch(result, async (r) => {
  if (!r?.sankey) return
  await nextTick()
  if (!chart && chartEl.value) chart = echarts.init(chartEl.value)
  if (!chart) return

  chart.setOption({
    tooltip: {
      trigger:   'item',
      triggerOn: 'mousemove',
      formatter: (params: Record<string, unknown>) => {
        const data = params['data'] as Record<string, unknown> | undefined
        if (params['dataType'] === 'edge') {
          const src = data?.['source'] as string
          const tgt = data?.['target'] as string
          const kg  = params['value'] as number
          return `${src} → ${tgt}<br/><b>${(kg / 1000).toFixed(1)} t</b>`
        }
        const name = params['name'] as string
        if (name.endsWith(' OVERFULL'))
          return `<b>${name}</b><br/><span style="color:#dc3545">Silo over capacity</span>`
        if (name.endsWith(' AT CAPACITY'))
          return `<b>${name}</b><br/><span style="color:#dc3545">Running at full capacity</span>`
        return `<b>${name}</b>`
      },
    },
    series: [{
      type:      'sankey',
      emphasis:  { focus: 'adjacency' },
      data:      r.sankey.nodes,
      links:     r.sankey.links,
      lineStyle: { color: 'gradient', opacity: 0.4 },
      label: {
        fontSize: 12,
        formatter: (params: Record<string, unknown>) => {
          const name = params['name'] as string
          const outgoing = r.sankey.links.filter(l => l.source === name)
          if (outgoing.length === 0) {
            const inflow = r.sankey.links
              .filter(l => l.target === name)
              .reduce((s, l) => s + l.value, 0)
            return `${name}\n${(inflow / 1000).toFixed(1)} t`
          }
          return name
        },
      },
    }],
  })
})

// ── Formatting ───────────────────────────────────────────────────────────────

function fmtT(kg: number) {
  return (kg / 1000).toLocaleString('en', { minimumFractionDigits: 1, maximumFractionDigits: 1 })
}
function fmtMoney(v: number) {
  return '$' + v.toLocaleString('en', { maximumFractionDigits: 0 })
}

const OUTPUT_STREAMS = ['butter', 'smp', 'bmp'] as const
const OUTPUT_LABELS: Record<string, string> = { butter: 'Butter', smp: 'SMP', bmp: 'BMP' }
</script>

<template>
  <div v-if="configError" class="status error">{{ configError }}</div>
  <div v-else class="plan-page">

    <!-- ── Inputs sidebar ───────────────────────────────────── -->
    <aside class="plan-inputs">
      <h2 class="panel-title">Inputs</h2>

      <section class="input-group">
        <h3 class="group-title">Intake (truckloads)</h3>
        <label class="field">
          <span>Raw Milk</span>
          <input class="num-input" type="number" min="0" step="1" v-model.number="milkIn" />
        </label>
        <label class="field">
          <span>Cream</span>
          <input class="num-input" type="number" min="0" step="1" v-model.number="creamIn" />
        </label>
      </section>

      <section class="input-group">
        <h3 class="group-title">Silo levels (tonnes)</h3>
        <label v-for="silo in siteConfig?.silos ?? []" :key="silo.id" class="field">
          <span>{{ silo.name }}</span>
          <input
            class="num-input"
            type="number" min="0" step="1"
            :max="silo.volume_kg / 1000"
            v-model.number="siloInitial[silo.id]"
          />
        </label>
      </section>

      <section class="input-group">
        <h3 class="group-title">Prices ($/kg)</h3>
        <label class="field">
          <span>Butter</span>
          <input class="num-input" type="number" min="0" step="0.1" v-model.number="priceButter" />
        </label>
        <label class="field">
          <span>SMP</span>
          <input class="num-input" type="number" min="0" step="0.1" v-model.number="priceSmp" />
        </label>
        <label class="field">
          <span>BMP</span>
          <input class="num-input" type="number" min="0" step="0.1" v-model.number="priceBmp" />
        </label>
      </section>

      <section class="input-group">
        <h3 class="group-title">Horizon</h3>
        <label class="field">
          <span>Hours</span>
          <input class="num-input" type="number" min="1" max="168" step="1" v-model.number="horizonHr" />
        </label>
      </section>

      <div v-if="loading" class="solving-indicator">Solving…</div>
    </aside>

    <!-- ── Main area ─────────────────────────────────────────── -->
    <main class="plan-main">

      <div v-if="error" class="status error">{{ error }}</div>

      <template v-else-if="result">
        <!-- Summary bar -->
        <div class="summary-bar" :class="{ overfull: result.overfull_silos?.length }">
          <span class="summary-status">{{ result.status }}</span>
          <template v-if="result.status === 'OPTIMAL'">
            <span class="summary-revenue">{{ fmtMoney(result.revenue) }}</span>
            <span v-for="s in OUTPUT_STREAMS" :key="s" class="summary-product">
              {{ OUTPUT_LABELS[s] }}: {{ fmtT(result.outputs[s] ?? 0) }} t
            </span>
            <span v-if="result.overfull_silos?.length" class="summary-warning">
              ⚠ Silo overflow: {{ result.overfull_silos.join(', ') }}
            </span>
          </template>
        </div>

        <!-- Sankey -->
        <div ref="chartEl" class="sankey-chart" />
      </template>

      <div v-else-if="!loading" class="status">Enter inputs and click Solve.</div>
    </main>
  </div>
</template>

<style scoped>
.plan-page {
  display: flex;
  height: 100%;
  overflow: hidden;
}

/* ── Sidebar ────────────────────────────────────────────── */
.plan-inputs {
  width: 220px;
  flex-shrink: 0;
  border-right: 1px solid var(--color-border);
  padding: 16px;
  overflow-y: auto;
  display: flex;
  flex-direction: column;
  gap: 16px;
}

.panel-title {
  font-size: 13px;
  font-weight: 600;
  text-transform: uppercase;
  letter-spacing: .04em;
  color: var(--color-text-muted);
}
.input-group { display: flex; flex-direction: column; gap: 6px; }
.group-title { font-size: 12px; font-weight: 600; color: var(--color-text-secondary); }
.field {
  display: flex;
  justify-content: space-between;
  align-items: center;
  font-size: 13px;
}
.field .num-input { width: 80px; font-size: 13px; }

.solving-indicator {
  margin-top: auto;
  padding: 6px 0;
  font-size: 13px;
  color: var(--color-text-muted);
  text-align: center;
}

/* ── Main ───────────────────────────────────────────────── */
.plan-main {
  flex: 1;
  display: flex;
  flex-direction: column;
  overflow: hidden;
}

.summary-bar {
  display: flex;
  align-items: center;
  gap: 20px;
  padding: 8px 20px;
  border-bottom: 1px solid var(--color-border);
  font-size: 13px;
  flex-shrink: 0;
}
.summary-bar.overfull { background: #fff8f0; }

.summary-status { font-weight: 600; color: #198754; }

.summary-revenue { font-size: 15px; font-weight: 700; color: var(--color-text); }

.summary-product { color: var(--color-text-secondary); }

.summary-warning { color: var(--color-warning); font-weight: 500; margin-left: auto; }

.sankey-chart { flex: 1; min-height: 0; }

.status       { padding: 20px; color: var(--color-text-muted); }
.status.error { color: var(--color-danger); }
</style>
