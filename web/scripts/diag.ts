// 诊断脚本：逐快照打印与标准答案的差异。用法：npm run diag -- fixed_default [最大步]
import { loadRef } from '../test/refdata';
import { compareDiagnostics, compareDisplayFields, compareScalars, compareSnapshot, fmt, makeSolver } from '../test/solverCompare';

const name = process.argv[2] ?? 'fixed_default';
const maxStep = Number(process.argv[3] ?? 200);
const ref = loadRef(name);
const s = makeSolver(ref);
let t0 = performance.now();
for (const snap of ref.snapshots) {
  if (snap.step > maxStep) break;
  s.stepMultiple(snap.step - s.iteration);
  const t1 = performance.now();
  console.log(`--- ${name} step ${snap.step}（${((t1 - t0) / 1000).toFixed(2)} s）`);
  t0 = t1;
  const extra = snap.step === ref.steps ? compareDisplayFields(s, ref.fields) : [];
  for (const d of [...compareSnapshot(s, snap), ...compareScalars(s, snap), ...compareDiagnostics(s, snap), ...extra]) if (!d.ok || process.env.ALL) console.log(fmt(d));
}
