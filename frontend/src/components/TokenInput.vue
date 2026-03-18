<script setup lang="ts">
import { ref, computed, watch } from 'vue'

interface Item { id: string; name: string }

const props = defineProps<{
  selected:     Item[]
  options:      Item[]   // only the items NOT already selected
  placeholder?: string
}>()

const emit = defineEmits<{
  add:    [id: string]
  remove: [id: string]
}>()

const query       = ref('')
const open        = ref(false)
const highlighted = ref(0)
const inputEl     = ref<HTMLInputElement | null>(null)

const filtered = computed(() => {
  const q = query.value.toLowerCase()
  return q
    ? props.options.filter(o => o.name.toLowerCase().includes(q))
    : props.options
})

// Reset highlight when the filtered list changes
watch(filtered, () => { highlighted.value = 0 })

function focusInput() { inputEl.value?.focus() }

function select(id: string) {
  emit('add', id)
  query.value = ''
  highlighted.value = 0
  open.value = true   // stay open — user probably wants to add another
}

function onKeydown(e: KeyboardEvent) {
  switch (e.key) {
    case 'Enter':
      e.preventDefault()
      if (filtered.value.length > 0) select(filtered.value[highlighted.value].id)
      break
    case 'ArrowDown':
      e.preventDefault()
      highlighted.value = Math.min(highlighted.value + 1, filtered.value.length - 1)
      break
    case 'ArrowUp':
      e.preventDefault()
      highlighted.value = Math.max(highlighted.value - 1, 0)
      break
    case 'Backspace':
      if (query.value === '' && props.selected.length > 0)
        emit('remove', props.selected[props.selected.length - 1].id)
      break
    case 'Escape':
      open.value  = false
      query.value = ''
      break
  }
}

function onFocus() { open.value = true }

function onBlur() {
  // Delay so that mousedown on a dropdown item fires before the dropdown disappears
  setTimeout(() => { open.value = false; query.value = '' }, 150)
}
</script>

<template>
  <div class="token-input" @click="focusInput">
    <span v-for="item in selected" :key="item.id" class="token">
      {{ item.name }}
      <button class="token-remove" @click.stop="emit('remove', item.id)">×</button>
    </span>
    <input
      ref="inputEl"
      class="token-query"
      v-model="query"
      @keydown="onKeydown"
      @focus="onFocus"
      @blur="onBlur"
      :placeholder="selected.length === 0 ? (placeholder ?? 'add…') : ''"
    />
    <div v-if="open && filtered.length > 0" class="token-dropdown">
      <button
        v-for="(opt, i) in filtered"
        :key="opt.id"
        class="dropdown-item"
        :class="{ highlighted: i === highlighted }"
        @mousedown.prevent="select(opt.id)"
      >{{ opt.name }}</button>
    </div>
  </div>
</template>

<style scoped>
.token-input {
  position: relative;
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 4px;
  padding: 4px 6px;
  border: 1px solid var(--color-border);
  border-radius: var(--radius-md);
  background: var(--color-bg);
  cursor: text;
  min-height: 32px;
  transition: border-color .1s, box-shadow .1s;
}
.token-input:focus-within {
  border-color: #86b7fe;
  box-shadow: 0 0 0 2px var(--color-focus-ring);
}

/* ── Tokens (selected items) ──────────────────────────────────────────────── */
.token {
  display: inline-flex;
  align-items: center;
  gap: 3px;
  padding: 2px 5px 2px 8px;
  border-radius: 10px;
  background: var(--color-bg-alt);
  border: 1px solid var(--color-border);
  font-size: 12px;
  line-height: 1.4;
  white-space: nowrap;
}

.token-remove {
  background: none;
  border: none;
  cursor: pointer;
  color: var(--color-text-faint);
  font-size: 13px;
  line-height: 1;
  padding: 0 1px;
  transition: color .1s;
}
.token-remove:hover { color: var(--color-danger); }

/* ── Text input ───────────────────────────────────────────────────────────── */
.token-query {
  flex: 1;
  min-width: 100px;
  border: none;
  outline: none;
  font-size: 13px;
  background: transparent;
  padding: 2px 2px;
}

/* ── Dropdown ─────────────────────────────────────────────────────────────── */
.token-dropdown {
  position: absolute;
  top: calc(100% + 4px);
  left: 0;
  min-width: 180px;
  max-height: 220px;
  overflow-y: auto;
  background: var(--color-bg);
  border: 1px solid var(--color-border);
  border-radius: var(--radius-md);
  box-shadow: 0 4px 12px rgba(0,0,0,.1);
  z-index: 20;
  display: flex;
  flex-direction: column;
}

.dropdown-item {
  text-align: left;
  background: none;
  border: none;
  padding: 7px 12px;
  font-size: 13px;
  cursor: pointer;
  color: var(--color-text);
  transition: background .08s;
}
.dropdown-item:hover,
.dropdown-item.highlighted { background: var(--color-bg-alt); }
</style>
