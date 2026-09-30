// 默认布局的每步耗时（Node）。用法：npm run bench -- [gridScale=0.5] [步数=20] [预热步数=400]（0.5 → 140²，1 → 280²，2 → 560²）
// 从静止起的前几十步流场尚未发展、扩散系统的 PCG 只要约 3 次迭代，耗时偏低；预热后（约 2 s 物理时间）才是常态。
import { Solver } from '../src/solver/solver';
import { layoutDefault } from '../src/model/layoutDefault';

const gs = Number(process.argv[2] ?? 0.5);
const n = Number(process.argv[3] ?? 20);
let t = performance.now();
const s = new Solver(layoutDefault(), { gridScale: gs });
console.log(`构建 ${(performance.now() - t).toFixed(0)} ms`);
const warm = Number(process.argv[4] ?? 400);
t = performance.now();
s.stepMultiple(warm);
const tw = (performance.now() - t) / Math.max(warm, 1);
t = performance.now();
s.stepMultiple(n);
const mu = process.memoryUsage();
console.log(`${s.W}²：预热 ${warm} 步 ${tw.toFixed(1)} ms/步，其后 ${n} 步 ${((performance.now() - t) / n).toFixed(1)} ms/步；堆 ${(mu.heapUsed / 1e6).toFixed(0)} MB，类型化数组 ${(mu.arrayBuffers / 1e6).toFixed(0)} MB`);
