import { defineConfig } from 'vitest/config'
import vue from '@vitejs/plugin-vue'

export default defineConfig({
  plugins: [vue()],
  test: {
    environment: 'happy-dom',
    // Watch all src files, not just those directly imported by tests.
    // Without this, changes to e.g. muster.ts don't trigger a rerun because
    // the test files import PlanEditor.vue, not App.vue or muster.ts.
    forceRerunTriggers: ['**/src/**/*.ts', '**/src/**/*.vue'],
  },
})
