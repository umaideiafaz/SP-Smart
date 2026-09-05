import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import path from 'path';

// https://vitejs.dev/config/
export default defineConfig(async () => ({
  plugins: [react()],
  resolve: {
    alias: { '@': path.resolve(__dirname, './src') },
  },
  // Previne que o Vite use porta 5173 se já ocupada
  server: {
    port:        5173,
    strictPort:  true,
    // Permite que o Tauri WebView acesse o dev server
    host:        '0.0.0.0',
    watch: {
      // Ignora mudanças no Rust para evitar reloads desnecessários
      ignored: ['**/src-tauri/**'],
    },
  },
  // Tauri usa variáveis de ambiente para prod vs dev
  envPrefix: ['VITE_', 'TAURI_'],
  build: {
    target:    'chrome105',
    minify:    !process.env.TAURI_DEBUG ? 'esbuild' : false,
    sourcemap: !!process.env.TAURI_DEBUG,
  },
}));
