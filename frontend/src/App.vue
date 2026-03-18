<script setup lang="ts">
import AppHeader from './components/AppHeader.vue'

const navLinks = [
  { to: '/simulate', label: 'Simulate' },
  { to: '/yield',    label: 'Yield' },
]
</script>

<template>
  <div class="app">
    <AppHeader :links="navLinks" />
    <main class="app-main">
      <RouterView />
    </main>
  </div>
</template>

<style>
/* Reset and tokens come from style.css — only app shell here */
.app {
  display: flex;
  flex-direction: column;
  height: 100%;
}
.app-main {
  flex: 1;
  overflow: hidden;
  display: flex;
  flex-direction: column;
}
.status       { padding: 20px; color: var(--color-text-muted); }
.status.error { color: var(--color-danger); }
</style>
