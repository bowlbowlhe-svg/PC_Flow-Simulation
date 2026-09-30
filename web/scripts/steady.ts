// 稳态长时对照：按 steady_*.json 的布局、功率与网格固定推进（默认 3000 步），比较 1000 步之后每步值的均值。
// 判据（数据集 README 第 4 级）：结温与内温 ≤ max(0.3°C, 3σ)，风量 ≤ max(2%, 3σ)，噪音 ≤ 0.3 dB。
// 用法：npm run steady -- steady_default [输出 JSON 路径]
import { writeFileSync } from 'node:fs';
import { normalizeLayout } from '../src/model/layoutJson';
import { steadyLongRun } from '../src/solver/steady';
import { totalNoise } from '../src/solver/diagnostics';
import { loadRef } from '../test/refdata';

const name = process.argv[2] ?? 'steady_default';
const outPath = process.argv[3];
const ref = loadRef(name);
const t0 = performance.now();
let last = t0;
const R = steadyLongRun(normalizeLayout(ref.layout), ref.powers, ref.gridScale, {
  steps: ref.steps,
  avgFrom: ref.avgFrom,
  progress: (info) => {
    const now = performance.now();
    if (now - last > 60000) {
      last = now;
      console.log(`${name}: ${info.steps}/${ref.steps} 步，${((now - t0) / info.steps).toFixed(0)} ms/步`);
    }
  },
});
const sec = (performance.now() - t0) / 1000;
let ok = true;
const rows = R.columns.map((c, k) => {
  const m = ref.mean[c];
  const sd = ref.std[c];
  const tol = c === 'cfm' ? Math.max(0.02 * m, 3 * sd) : Math.max(0.3, 3 * sd);
  const d = R.mean[k] - m;
  const pass = Math.abs(d) <= tol;
  ok &&= pass;
  return { col: c, web: R.mean[k], ref: m, diff: d, tol, webStd: R.std[k], refStd: sd, pass };
});
const noise = totalNoise(R.solver).dbTotal;
const noisePass = Math.abs(noise - ref.scalars.noiseDb) <= 0.3;
ok &&= noisePass;
for (const r of rows)
  console.log(`${r.pass ? 'ok ' : 'BAD'} ${r.col.padEnd(9)} 网页 ${r.web.toFixed(3)}  参考 ${r.ref.toFixed(3)}  差 ${r.diff >= 0 ? '+' : ''}${r.diff.toFixed(3)}  容差 ${r.tol.toFixed(3)}  σ ${r.webStd.toFixed(3)}/${r.refStd.toFixed(3)}`);
console.log(`${noisePass ? 'ok ' : 'BAD'} noiseDb   网页 ${noise.toFixed(2)}  参考 ${ref.scalars.noiseDb.toFixed(2)}（第 ${R.steps} 步）`);
console.log(`${name}: ${R.steps} 步，${sec.toFixed(0)} s（${((sec * 1000) / R.steps).toFixed(0)} ms/步），${ok ? '通过' : '未通过'}`);
if (outPath) writeFileSync(outPath, JSON.stringify({ name, rows, noise, refNoise: ref.scalars.noiseDb, seconds: sec, history: R.history, ok }, null, 1));
process.exitCode = ok ? 0 : 1;
