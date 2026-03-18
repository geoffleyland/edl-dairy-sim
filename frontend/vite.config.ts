import { defineConfig } from 'vite'
import vue from '@vitejs/plugin-vue'

export default defineConfig({
  plugins: [vue()],
  server: {
    proxy: {
      // Strip /api prefix and forward to Julia backend.
      // e.g. fetch('/api/health') → Julia GET /health
      '/api': {
        target:      'http://localhost:8080',
        changeOrigin: true,
        rewrite:     (path) => path.replace(/^\/api/, ''),
      },
    },
  },
})
