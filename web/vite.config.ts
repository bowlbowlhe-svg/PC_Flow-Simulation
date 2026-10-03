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
    // order: 'post'：在 Vite 自己的构建插件之后执行（它在 generateBundle 里替换按需加载的预加载占位符 __VITE_PRELOAD__，
    // 先内联会把占位符原样带进 HTML，对比展示页在 file:// 下打不开）
    generateBundle: {
      order: 'post',
      handler(_, bundle) {
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
    },
  };
}

export default defineConfig(({ mode }) => ({
  base: './',
  plugins: [preact(), ...(mode === 'single' ? [inlineAll()] : [])],
  worker: { format: 'iife' },
  build:
    mode === 'single'
      ? {
          outDir: 'dist-single',
          assetsInlineLimit: 100_000_000,
          cssCodeSplit: false,
          modulePreload: false,
          // 对比展示页在普通构建里按需加载（单独的块）；单文件版要全部内联进一个 HTML
          rollupOptions: { output: { inlineDynamicImports: true } },
        }
      : {
          // 对比展示页的块约 550 KB，其中约 450 KB 是预计算数据（JSON），按需加载，不影响主页面（约 180 KB）
          chunkSizeWarningLimit: 700,
        },
  test: {
    globals: true,
    environment: 'node',
    include: ['test/**/*.test.ts'],
    testTimeout: 600000,
    // 标准答案对照是长时间的同步计算：用子进程池，避免线程池在高负载下 RPC 超时
    pool: 'forks',
  },
}));
