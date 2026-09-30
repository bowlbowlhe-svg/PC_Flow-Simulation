// 性能剖析：统计各类线性求解的次数、迭代数与耗时。
// 用法：npm run profile -- fixed_default 40 [预热步数=2]      （压力用 PCG：PCG=1 npm run profile -- …）
import { SPDSolver } from '../src/numerics/pcg';
import { SparseCholesky } from '../src/numerics/cholesky';
import { StencilSolver } from '../src/numerics/stencil';
import { loadRef } from '../test/refdata';
import { makeSolver } from '../test/solverCompare';

const name = process.argv[2] ?? 'fixed_default';
const steps = Number(process.argv[3] ?? 40);
const direct = !process.env.PCG;
const stats = new Map<string, { n: number; iters: number; ms: number }>();
const add = (k: string, iters: number, ms: number) => {
  const s = stats.get(k) ?? { n: 0, iters: 0, ms: 0 };
  s.n++;
  s.iters += iters;
  s.ms += ms;
  stats.set(k, s);
};
// 按求解器实例归类（求解器的私有字段：velU、velV、tempSolver、turbKSolver、turbWSolver、pres0、presDrag）
const FIELDS: [string, string][] = [
  ['velU', 'velU'],
  ['velV', 'velV'],
  ['tempSolver', 'temp'],
  ['turbKSolver', 'k'],
  ['turbWSolver', 'omega'],
  ['pres0', 'pres0'],
  ['presDrag', 'presDrag'],
];
let current: Record<string, unknown> = {};
const labelOf = (inst: unknown) => FIELDS.find(([f]) => current[f] === inst)?.[1] ?? 'other';
const pcgSolve = SPDSolver.prototype.solve;
SPDSolver.prototype.solve = function (this: SPDSolver, b, x0, o) {
  const t = performance.now();
  const r = pcgSolve.call(this, b, x0, o);
  add(labelOf(this), r.iters, performance.now() - t);
  return r;
};
// 默认的扩散系统求解器是模板存储版 StencilSolver（W5）
const stSolve = StencilSolver.prototype.solve;
StencilSolver.prototype.solve = function (this: StencilSolver, b, x0) {
  const t = performance.now();
  const r = stSolve.call(this, b, x0);
  add(labelOf(this), r.iters, performance.now() - t);
  return r;
};
const cholSolve = SparseCholesky.prototype.solve;
SparseCholesky.prototype.solve = function (this: SparseCholesky, b, out) {
  const t = performance.now();
  const r = cholSolve.call(this, b, out);
  add('cholSolve', 0, performance.now() - t);
  return r;
};
const warm = Number(process.argv[4] ?? 2);
const s = makeSolver(loadRef(name), direct ? 'direct' : 'pcg');
current = s as unknown as Record<string, unknown>;
s.stepMultiple(warm);
stats.clear();
const t0 = performance.now();
s.stepMultiple(steps);
const tot = performance.now() - t0;
console.log(`${name}（${s.W}²，压力${direct ? '直接解' : ' PCG'}）：第 ${warm + 1}–${warm + steps} 步，${(tot / steps).toFixed(1)} ms/步`);
let solveMs = 0;
for (const [k, v] of stats) {
  solveMs += v.ms;
  console.log(`${k.padEnd(10)} 次数=${v.n} 平均迭代=${(v.iters / v.n).toFixed(1)} ms/次=${(v.ms / v.n).toFixed(2)}`);
}
console.log(`线性求解 ${(solveMs / steps).toFixed(1)} ms/步，其余（含矩阵装配与分解）${((tot - solveMs) / steps).toFixed(1)} ms/步`);
