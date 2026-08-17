import { resolve } from 'node:path'
import { defineConfig, externalizeDepsPlugin } from 'electron-vite'

export default defineConfig({
  main: {
    plugins: [externalizeDepsPlugin()],
    build: {
      lib: { entry: resolve(__dirname, 'src/main/index.ts') }
    }
  },
  preload: {
    plugins: [externalizeDepsPlugin()],
    build: {
      lib: { entry: resolve(__dirname, 'src/preload/index.ts') }
    }
  },
  renderer: {
    root: resolve(__dirname, 'src/renderer'),
    build: {
      rollupOptions: {
        input: {
          index: resolve(__dirname, 'src/renderer/index.html'),
          fx: resolve(__dirname, 'src/renderer/fx.html')
        }
      }
    }
  }
})
