// 默认布局的每步耗时（Node）。用法：npm run bench -- [gridScale=0.5] [步数=20]（0.5 → 140²，1 → 280²，2 → 560²）
import { Solver } from '../src/solver/solver';
import { layoutDefault } from '../src/model/layoutDefault';

const gs = Number(process.argv[2] ?? 0.5);
const n = Number(process.argv[3] ?? 20);
let t = performance.now();
const s = new Solver(layoutDefault(), { gridScale: gs });
console.log(`构建 ${(performance.now() - t).toFixed(0)} ms`);
s.stepMultiple(2);
t = performance.now();
s.stepMultiple(n);
const mu = process.memoryUsage();
console.log(`${s.W}²：${((performance.now() - t) / n).toFixed(1)} ms/步；堆 ${(mu.heapUsed / 1e6).toFixed(0)} MB，类型化数组 ${(mu.arrayBuffers / 1e6).toFixed(0)} MB`);
