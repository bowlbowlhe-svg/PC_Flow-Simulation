/// <reference types="vitest/config" />
import { defineConfig } from 'vite';
import preact from '@preact/preset-vite';

export default defineConfig({
  base: './',
  plugins: [preact()],
  test: {
    globals: true,
    environment: 'node',
    include: ['test/**/*.test.ts'],
    testTimeout: 600000,
    // 标准答案对照是长时间的同步计算：用子进程池，避免线程池在高负载下 RPC 超时
    pool: 'forks',
  },
});
