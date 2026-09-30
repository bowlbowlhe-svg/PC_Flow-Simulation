/// <reference types="vitest/config" />
import { defineConfig, type Plugin } from 'vite';
import preact from '@preact/preset-vite';

/**
 * 单文件版（npm run build:single）：把入口 JS 与 CSS 内联进 index.html，Worker 已以 Blob 内联，
 * 得到一个可直接双击打开（file://）的 HTML。
 */
function inlineAll(): Plugin {
  return {
    name: 'pcflow-inline-all',
    enforce: 'post',
    generateBundle(_, bundle) {
      const html = bundle['index.html'];
      if (!html || html.type !== 'asset') return;
      let text = String(html.source);
      for (const [name, item] of Object.entries(bundle)) {
        if (item.type === 'chunk' && item.isEntry) {
          const code = item.code.replace(/<\/script/gi, '<\\/script');
          text = text.replace(new RegExp(`<script[^>]*src="\\.?/?${name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}"[^>]*></script>`), () => `<script type="module">${code}</script>`);
          delete bundle[name];
        } else if (item.type === 'asset' && name.endsWith('.css')) {
          const css = String(item.source);
          text = text.replace(new RegExp(`<link[^>]*href="\\.?/?${name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}"[^>]*>`), () => `<style>${css}</style>`);
          delete bundle[name];
        }
      }
      html.source = text;
    },
  };
}

export default defineConfig(({ mode }) => ({
  base: './',
  plugins: [preact(), ...(mode === 'single' ? [inlineAll()] : [])],
  worker: { format: 'iife' },
  build:
    mode === 'single'
      ? { outDir: 'dist-single', assetsInlineLimit: 100_000_000, cssCodeSplit: false, modulePreload: false }
      : {},
  test: {
    globals: true,
    environment: 'node',
    include: ['test/**/*.test.ts'],
    testTimeout: 600000,
    // 标准答案对照是长时间的同步计算：用子进程池，避免线程池在高负载下 RPC 超时
    pool: 'forks',
  },
}));
