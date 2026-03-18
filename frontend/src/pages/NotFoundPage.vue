<script setup lang="ts">
import { useRoute } from 'vue-router'
const route = useRoute()
</script>

<template>
  <p class="status error">404 — {{ route.path }} not found</p>
</template>
