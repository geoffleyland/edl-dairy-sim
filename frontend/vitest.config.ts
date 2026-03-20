import { defineConfig } from 'vitest/config'
import vue from '@vitejs/plugin-vue'

export default defineConfig({
  plugins: [vue()],
  test: {
    environment: 'happy-dom',
    // Watch all src files, not just those directly imported by tests.
    // Without this, changes to e.g. http.ts don't trigger a rerun because
    // the test files import TokenInput.vue, not App.vue or http.ts.
    forceRerunTriggers: ['**/src/**/*.ts', '**/src/**/*.vue'],
  },
})
