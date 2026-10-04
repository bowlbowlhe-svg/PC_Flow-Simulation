// 诊断量与 Octave 对照（fixtures/diagnostics.json，由 test/gen/gen_diagnostics_fixtures.m 生成）：
// 温度汇总、无量纲数、死区、评分、方案汇总、建议文字、风扇状态表、开口标注、涡量、单格读数、runToSteady。
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { describe, expect, it } from 'vitest';
import { Solver } from '../src/solver/solver';
import { layoutDefault } from '../src/model/layoutDefault';
import { layoutBenchmark } from '../src/model/layoutBenchmark';
import { layoutSetGpuSlots } from '../src/model/gpuSlots';
import {
  calculateScores,
  cellReadout,
  fanPressureLabel,
  fanStatusList,
  getRecommendations,
  openingMarkers,
  pressureFieldPa,
  scenarioSummary,
} from '../src/solver/diagnostics';
import { runToSteady, SteadyRunner } from '../src/solver/steady';
import type { Layout } from '../src/model/types';
import { stepYielding, type Ref } from './refdata';

const here = dirname(fileURLToPath(import.meta.url));
const FX: Ref = JSON.parse(readFileSync(join(here, 'fixtures', 'diagnostics.json'), 'utf8'));

function mk(L: Layout, P: [number, number, number]): Solver {
  const s = new Solver(L, { gridScale: 0.5, powers: { cpu: P[0], gpu: P[1], psu: P[2] } });
  s.turbUpdateEvery = 1;
  return s;
}

/** 数值相对差 ≤ 1e−9（状态与 Octave 只差线性求解舍入）；null ↔ 非有限值（jsonencode 把 NaN、±Inf 都写成 null，如停转风扇的噪音 −Inf） */
function near(a: number, b: number | null, what: string) {
  if (b === null) {
    expect(Number.isFinite(a), `${what}: ${a} 应为非有限值`).toBe(false);
    return;
  }
  expect(Math.abs(a - b), `${what}: ${a} vs ${b}`).toBeLessThanOrEqual(1e-9 * Math.max(1, Math.abs(b)));
}

/** 递归比较对象：数字近似、字符串/布尔相等 */
function deepNear(mine: unknown, ref: unknown, path: string) {
  if (typeof ref === 'number' || ref === null) near(mine as number, ref as number | null, path);
  else if (typeof ref === 'string' || typeof ref === 'boolean') expect(mine, path).toBe(ref);
  else if (Array.isArray(ref)) {
    expect(Array.isArray(mine), path).toBe(true);
    expect((mine as unknown[]).length, `${path}.length`).toBe(ref.length);
    ref.forEach((r, k) => deepNear((mine as unknown[])[k], r, `${path}[${k}]`));
  } else if (ref && typeof ref === 'object') {
    for (const [k, v] of Object.entries(ref)) deepNear((mine as Record<string, unknown>)[k], v, `${path}.${k}`);
  }
}

function checkDump(s: Solver, D: Ref) {
  expect(s.iteration).toBe(D.iteration);
  for (const n of ['cpu', 'gpu', 'psu'] as const) {
    const net = s.thermalNetworks[n];
    if (D[`Tj_${n}`] === undefined) {
      expect(net).toBeUndefined();
      continue;
    }
    near(net!.T_junction, D[`Tj_${n}`], `Tj_${n}`);
    near(net!.freqRatio, D[`freq_${n}`], `freq_${n}`);
    expect(net!.throttled, `throttled_${n}`).toBe(D[`throttled_${n}`]);
    expect(net!.overTemp, `overTemp_${n}`).toBe(D[`overTemp_${n}`]);
  }
  // 温度汇总与诊断（stepMultiple 结束时更新）
  const t = s.lastTemps!;
  for (const k of ['intake', 'internalAmbient', 'topExhaust', 'rearExhaust', 'totalCFM', 'internalAmbientAlg', 'internalDiscrepancy'] as const)
    near(t[k], D.temps[k], `temps.${k}`);
  deepNear(s.lastDiag, D.diag, 'diag');
  near(s.deadZoneRatio, D.deadZoneRatio, 'deadZoneRatio');
  deepNear(calculateScores(s), D.scores, 'scores');
  deepNear(scenarioSummary(s), D.summary, 'summary');
  const recs = getRecommendations(s);
  const refRecs = Array.isArray(D.recs) ? D.recs : [D.recs];
  expect(recs).toEqual(refRecs.map((r: Ref) => ({ title: r.title, desc: r.desc, level: r.level })));
  const fl = fanStatusList(s);
  expect(fl.length).toBe(D.fans.length);
  D.fans.forEach((rf: Ref, k: number) => deepNear(fl[k], rf, `fans[${k}]`));
  const om = openingMarkers(s);
  expect(om.length).toBe(D.markers.length);
  D.markers.forEach((rm: Ref, k: number) => deepNear(om[k], rm, `markers[${k}]`));
  const v = s.latestVorticity!;
  let sa = 0;
  let mx = 0;
  for (const x of v) {
    sa += Math.abs(x);
    mx = Math.max(mx, Math.abs(x));
  }
  near(sa, D.vortAbsSum, 'vortAbsSum');
  near(mx, D.vortMaxAbs, 'vortMaxAbs');
  (D.vortIdx as number[]).forEach((i, k) => expect(Math.abs(v[i - 1] - D.vortSamples[k])).toBeLessThanOrEqual(1e-9 * Math.max(1, mx)));
  const rd = Array.isArray(D.readout) ? D.readout : [D.readout];
  for (const r of rd) {
    const mine = cellReadout(s, r.idx - 1);
    expect(mine.solid).toBe(r.solid);
    for (const k of ['speed', 'T', 'Tsolid', 'P'] as const) near(mine[k], r[k], `readout(${r.idx}).${k}`);
  }
  const P = pressureFieldPa(s);
  let ps = 0;
  for (const x of P) if (Number.isFinite(x)) ps += x;
  near(ps, D.pressureSumFinite, 'pressureSumFinite');
}

describe('诊断量与 Octave 一致', () => {
  it('默认布局 200 步', async () => {
    const s = mk(layoutDefault(), [125, 250, 450]);
    await stepYielding(s, 200);
    checkDump(s, FX.default200);
  });
  it('直风道 13 步（无元件：评分与建议的占位分支）', () => {
    const s = mk(layoutBenchmark('duct', 20), [0, 0, 0]);
    s.stepMultiple(13);
    checkDump(s, FX.duct13);
  });
  it('高功率 120 步（节流、电源超温告警）', async () => {
    const s = mk(layoutDefault(), [300, 500, 1200]);
    await stepYielding(s, 120);
    expect(FX.hot120.throttled_cpu || FX.hot120.throttled_gpu).toBe(true); // 数据确实覆盖了温度墙降频
    expect(Math.min(FX.hot120.freq_cpu, FX.hot120.freq_gpu)).toBeLessThan(1);
    checkDump(s, FX.hot120);
  });
  it('关闭自动温控、全局 70%、1 号机箱风扇手动 30%：40 步', () => {
    const L = layoutDefault();
    L.caseFans![0].speedMode = 'manual';
    L.caseFans![0].manualPct = 30;
    const s = mk(L, [125, 250, 450]);
    s.autoFanEnabled = false;
    s.fanSpeedRatio = 70;
    s.stepMultiple(40);
    checkDump(s, FX.manual40);
  });
  it('v4.8.0 的默认几何（4 槽、无 ioBlock、全宽挡板 + 开孔）：100 步', async () => {
    const L = layoutSetGpuSlots(layoutDefault(), 4);
    delete L.gpu!.ioBlock;
    L.gpu!.pcb = { x: 38, y: 212, w: 216, h: 12 };
    delete L.shroud!.lengthMm;
    L.shroud!.gaps = [{ x0Mm: 280, x1Mm: 318 }];
    const s = mk(L, [125, 250, 450]);
    await stepYielding(s, 100);
    checkDump(s, FX.legacy48);
  });
  it('时转时停：办公功率 40 步后显卡、电源风扇设为窗口内启停 2 次', () => {
    const s = mk(layoutDefault(), [40, 35, 200]);
    s.stepMultiple(40);
    const gf = s.fans.find((f) => f.g.role === 'gpu')!;
    gf.toggleIter = [s.iteration - 50, s.iteration - 10];
    gf.lastRunRpm = 1200;
    const pf = s.fans.find((f) => f.g.role === 'psu')!;
    pf.toggleIter = [s.iteration - 30, s.iteration - 5];
    pf.lastRunRpm = 900;
    const fl = fanStatusList(s);
    expect(fl.filter((f) => f.cycling).map((f) => f.role)).toEqual(['gpu', 'psu']); // 数据确实覆盖了时转时停
    expect(fl.filter((f) => f.cycling).every((f) => f.stopped)).toBe(true); // 停转中：感知噪音按最近转动的转速
    checkDump(s, FX.cycling40);
  });
  it('runToSteady（chunk 25、window 50）的轨迹、判稳步数与窗口均值', async () => {
    const s = mk(layoutDefault(), [125, 250, 450]);
    const opts = { maxSteps: 300, minSteps: 100, chunk: 25, window: 50, tolT: 1.0, tolFlow: 0.05 };
    // 同步版 runToSteady 与分块推进的 SteadyRunner 等价；这里用后者，每块之间让出事件循环
    const runner = new SteadyRunner(s, opts);
    while (!runner.advance()) await new Promise((r) => setImmediate(r));
    const info = runner.info;
    const R = FX.steady;
    expect(info.steps).toBe(R.steps);
    expect(info.converged).toBe(R.converged);
    expect(info.diverged).toBe(R.diverged);
    expect(info.columns).toEqual(R.columns);
    deepNear(info.history, R.history, 'history');
    deepNear(info.final, R.final, 'final');
  });
});

describe('SteadyRunner 与标签', () => {
  it('maxSteps 严格不超过；abort 立即结束', () => {
    const s = mk(layoutBenchmark('duct', 20), [0, 0, 0]);
    const r = new SteadyRunner(s, { maxSteps: 7, chunk: 3, tolT: -1, tolFlow: -1 });
    let n = 0;
    while (!r.advance()) n++;
    expect(s.iteration).toBe(7);
    expect(r.info.history.length).toBe(3); // 3 + 3 + 1
    expect(n).toBe(2);
    const r2 = new SteadyRunner(s, { maxSteps: 100, chunk: 5 });
    r2.abort();
    expect(r2.advance()).toBe(true);
    expect(s.iteration).toBe(7);
  });
  it('fanPressureLabel', () => {
    expect(fanPressureLabel(0, 0)).toBe('无机箱风扇');
    expect(fanPressureLabel(111, 100)).toBe('正压');
    expect(fanPressureLabel(110, 100)).toBe('平衡');
    expect(fanPressureLabel(89, 100)).toBe('负压');
    expect(fanPressureLabel(90, 100)).toBe('平衡');
  });
});

describe('SteadyRunner 分段推进', () => {
  it('同步 runToSteady 与逐块推进结果相同；progress 返回 true 时中止', () => {
    const o = { maxSteps: 30, chunk: 5, window: 10, minSteps: 10, tolT: 1e9, tolFlow: 1e9 };
    const a = mk(layoutBenchmark('duct', 20), [0, 0, 0]);
    const ia = runToSteady(a, o);
    const b = mk(layoutBenchmark('duct', 20), [0, 0, 0]);
    const rb = new SteadyRunner(b, o);
    while (!rb.advance());
    expect(ia).toEqual(rb.info);
    expect(ia.converged).toBe(true);
    expect(ia.steps).toBe(20); // 满 2 个窗口（各 2 块 × 5 步）后第一次判稳
    const c = mk(layoutBenchmark('duct', 20), [0, 0, 0]);
    let calls = 0;
    const ic = runToSteady(c, { ...o, tolT: -1 }, () => ++calls >= 2);
    expect(ic.aborted).toBe(true);
    expect(ic.steps).toBe(10);
  });

  it('块内拆成多次推进与整块推进的轨迹逐位相同', () => {
    const a = mk(layoutBenchmark('duct', 20), [0, 0, 0]);
    const b = mk(layoutBenchmark('duct', 20), [0, 0, 0]);
    const o = { maxSteps: 23, chunk: 5, window: 10, minSteps: 5, tolT: -1, tolFlow: -1 };
    const ra = new SteadyRunner(a, o);
    while (!ra.advance());
    const rb = new SteadyRunner(b, o);
    while (!rb.advance(2));
    expect(rb.info.history).toEqual(ra.info.history);
    expect(rb.info.final).toEqual(ra.info.final);
    expect(b.iteration).toBe(23);
    expect(Array.from(b.T_fluid)).toEqual(Array.from(a.T_fluid));
  });
});
