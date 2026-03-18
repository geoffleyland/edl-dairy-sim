<script setup lang="ts">
import { ref } from 'vue'
import { RouterLink, useRoute } from 'vue-router'

const props = defineProps<{
  links: { to: string; label: string }[]
}>()

const route  = useRoute()
const menuOpen = ref(false)
</script>

<template>
  <header class="app-header">
    <div class="app-left">
      <span class="app-name">Ever.Ag Data Labs</span>
      <span v-if="route.meta.title" class="page-title">{{ route.meta.title }}</span>
    </div>

    <div class="app-right">
      <span class="powered-by">powered by <strong>ScAIapp<sup>®</sup></strong></span>
      <div class="hamburger-wrap">
        <button
          class="hamburger-btn"
          @click="menuOpen = !menuOpen"
          :aria-expanded="menuOpen"
          aria-label="Menu"
        >
          <span></span><span></span><span></span>
        </button>
        <nav v-if="menuOpen" class="hamburger-menu" @click="menuOpen = false">
          <RouterLink
            v-for="link in props.links"
            :key="link.to"
            :to="link.to"
            class="menu-link"
          >{{ link.label }}</RouterLink>
        </nav>
      </div>
    </div>
  </header>
</template>

<style scoped>
.app-header {
  display: flex;
  align-items: center;
  padding: 0 20px;
  height: 48px;
  background: var(--brand-header-gradient);
  color: #fff;
  flex-shrink: 0;
  box-shadow: 0 1px 6px rgba(0, 0, 0, 0.3);
}
.app-left {
  display: flex;
  align-items: center;
  gap: 14px;
  flex: 1;
}
.app-name {
  font-family: var(--brand-font-heading);
  font-weight: 500;
  font-size: 15px;
  letter-spacing: .04em;
}
.page-title {
  font-size: 13px;
  font-weight: 400;
  color: rgba(255,255,255,.65);
}

/* ── Right-hand cluster ──────────────────────────────────── */
.app-right {
  display: flex;
  align-items: center;
  gap: 16px;
}
.powered-by {
  font-family: var(--brand-font-prose);
  font-size: 11px;
  color: rgba(255,255,255,.55);
  font-style: italic;
  white-space: nowrap;
}
.powered-by strong {
  font-style: normal;
  font-weight: 500;
  color: rgba(255,255,255,.8);
}

/* ── Hamburger button ────────────────────────────────────── */
.hamburger-wrap { position: relative; }
.hamburger-btn {
  display: flex;
  flex-direction: column;
  justify-content: center;
  gap: 5px;
  width: 32px;
  height: 32px;
  padding: 4px 6px;
  background: none;
  border: none;
  cursor: pointer;
  border-radius: var(--radius-md);
  transition: background .1s;
}
.hamburger-btn:hover { background: rgba(255,255,255,.12); }
.hamburger-btn span {
  display: block;
  height: 2px;
  background: rgba(255,255,255,.85);
  border-radius: 1px;
}

/* ── Dropdown menu ───────────────────────────────────────── */
.hamburger-menu {
  position: absolute;
  top: calc(100% + 6px);
  right: 0;
  min-width: 140px;
  background: var(--brand-menu-bg);
  border: none;
  border-radius: var(--radius-md);
  box-shadow: 0 4px 12px rgba(0,0,0,.25);
  display: flex;
  flex-direction: column;
  z-index: 100;
  overflow: hidden;
}
.menu-link {
  font-size: 13px;
  font-weight: 500;
  padding: 10px 16px;
  color: rgba(255,255,255,.85);
  text-decoration: none;
  transition: background .1s;
}
.menu-link:hover              { background: rgba(255,255,255,.1); color: #fff; }
.menu-link.router-link-active { background: rgba(255,255,255,.12); color: #fff; }
</style>
