// 性能剖析：统计各类线性求解的次数、迭代数与耗时。
// 用法：npm run profile -- fixed_default 40      （压力用 PCG：PCG=1 npm run profile -- …）
import { SPDSolver } from '../src/numerics/pcg';
import { SparseCholesky } from '../src/numerics/cholesky';
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
// SPDSolver 的调用次序（每步）：速度 u、v，[压力 1、压力 2]，k、ω（湍流逐步更新时），温度
const order = direct ? ['velU', 'velV', 'k', 'omega', 'temp'] : ['velU', 'velV', 'pres0', 'presDrag', 'k', 'omega', 'temp'];
let call = 0;
const pcgSolve = SPDSolver.prototype.solve;
SPDSolver.prototype.solve = function (this: SPDSolver, b, x0, o) {
  const t = performance.now();
  const r = pcgSolve.call(this, b, x0, o);
  add(order[call++ % order.length], r.iters, performance.now() - t);
  return r;
};
const cholSolve = SparseCholesky.prototype.solve;
SparseCholesky.prototype.solve = function (this: SparseCholesky, b, out) {
  const t = performance.now();
  const r = cholSolve.call(this, b, out);
  add('cholSolve', 0, performance.now() - t);
  return r;
};
const s = makeSolver(loadRef(name), direct ? 'direct' : 'pcg');
s.stepMultiple(2);
stats.clear();
call = 0;
const t0 = performance.now();
s.stepMultiple(steps);
const tot = performance.now() - t0;
console.log(`${name}（${s.W}²，压力${direct ? '直接解' : ' PCG'}）：${steps} 步，${(tot / steps).toFixed(1)} ms/步`);
let solveMs = 0;
for (const [k, v] of stats) {
  solveMs += v.ms;
  console.log(`${k.padEnd(10)} 次数=${v.n} 平均迭代=${(v.iters / v.n).toFixed(1)} ms/次=${(v.ms / v.n).toFixed(2)}`);
}
console.log(`线性求解 ${(solveMs / steps).toFixed(1)} ms/步，其余（含矩阵装配与分解）${((tot - solveMs) / steps).toFixed(1)} ms/步`);
