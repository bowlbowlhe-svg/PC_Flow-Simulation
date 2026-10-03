// 对比展示页：计算口径（CompareRunner）与 MATLAB tools/compare_scenarios.m 一致、分块方式不影响结果、
// 公平比较的插值、缩略图量化往返、预计算数据的完整性。
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import { COMPARE_SCENARIOS, CompareRunner, DEFAULT_PROTOCOL, interpAt, type CompareProtocol } from '../src/compare/protocol';
import { makeThumb, thumbFromRgba, thumbToRgb, thumbT, THUMB_T_RANGE } from '../src/compare/thumb';
import type { CompareData } from '../src/compare/data';
import { applyPreset, FAN_PRESETS } from '../src/model/fans';
import { layoutDefault } from '../src/model/layoutDefault';
import { normalizeLayout } from '../src/model/layoutJson';
import { buildSchemes, fairCompare } from '../src/ui/compare/schemes';
import type { Ref } from './refdata';

const here = dirname(fileURLToPath(import.meta.url));
const FX: Ref = JSON.parse(readFileSync(join(here, 'fixtures', 'compare.json'), 'utf8'));
const DATA: CompareData = JSON.parse(readFileSync(join(here, '..', 'src', 'compare', 'data.json'), 'utf8'));

function run(L: ReturnType<typeof layoutDefault>, powers: [number, number, number], p: CompareProtocol, chunk: number) {
  const r = new CompareRunner(L, powers, p);
  while (!r.advance(chunk));
  return r;
}

const near = (a: number, b: number | null, what: string) => {
  if (b === null) return expect(Number.isNaN(a), what).toBe(true);
  expect(Math.abs(a - b), `${what}: ${a} vs ${b}`).toBeLessThanOrEqual(1e-9 * Math.max(1, Math.abs(b)));
};

describe('对比计算口径与 Octave（compare_scenarios.m）一致', () => {
  for (const c of FX.cases as Ref[]) {
    it(`${c.preset} / ${c.scenario}`, () => {
      const sc = COMPARE_SCENARIOS.find((s) => s.key === c.scenario)!;
      const p = FX.protocol as CompareProtocol;
      const r = run(applyPreset(layoutDefault(), c.preset), sc.powers, { ...p, sweepPct: [...(Array.isArray(p.sweepPct) ? p.sweepPct : [p.sweepPct])] }, 7);
      const pts = [r.auto!, ...r.sweep];
      const refs = [c.auto, ...(Array.isArray(c.sweep) ? c.sweep : [c.sweep])];
      expect(pts.length).toBe(refs.length);
      pts.forEach((m, k) => {
        const rf = refs[k];
        for (const key of ['cpu', 'gpu', 'psu', 'interior', 'cfm', 'noiseDb', 'perfPct', 'freqCpu', 'freqGpu', 'powerCpu', 'powerGpu', 'airK', 'drift'] as const)
          near(m[key], rf[key], `${k}.${key}`);
        for (const key of ['score', 'perf', 'thermal', 'noise', 'airflow'] as const) expect(m[key], `${k}.${key}`).toBe(rf[key]);
        expect(m.cls).toBe(rf.cls);
        const rfans = Array.isArray(rf.fans) ? rf.fans : [rf.fans];
        expect(m.fans.map((f) => [f.name, f.stopped])).toEqual(rfans.map((f: Ref) => [f.name, f.stopped]));
        m.fans.forEach((f, j) => near(f.rpm, rfans[j].rpm, `${k}.fan${j}.rpm`));
      });
    });
  }
});

describe('CompareRunner', () => {
  const p: CompareProtocol = { gridScale: 0.5, turbUpdateEvery: 2, autoSteps: 24, autoAvgFrom: 12, sweepPct: [40, 100], sweepSteps: 10, sweepAvgFrom: 4 };
  it('分块方式不影响结果；阶段与步数', () => {
    const L = layoutDefault();
    const a = run(L, [100, 200, 500], p, 1);
    const b = run(L, [100, 200, 500], p, 50);
    expect(a.doneSteps).toBe(a.totalSteps);
    expect(a.totalSteps).toBe(24 + 2 * 10);
    expect(a.solver.iteration).toBe(44);
    expect(b.auto).toEqual(a.auto);
    expect(b.sweep).toEqual(a.sweep);
    expect(a.sweep.map((q) => q.pct)).toEqual([40, 100]);
    expect(a.solver.autoFanEnabled).toBe(false);
    expect(a.solver.fanSpeedRatio).toBe(100);
    // 扫描阶段全部风扇同一全局转速：转速越高越吵
    expect(a.sweep[1].noiseDb).toBeGreaterThan(a.sweep[0].noiseDb);
    expect(a.autoField!.T.length).toBe(a.solver.N);
  });

  it('abort 立即结束', () => {
    const r = new CompareRunner(layoutDefault(), [40, 35, 200], p);
    r.advance(3);
    r.abort();
    expect(r.done).toBe(true);
    expect(r.advance(10)).toBe(true);
    expect(r.solver.iteration).toBe(3);
  });
});

describe('公平比较与缩略图', () => {
  it('interpAt：范围内线性插值，范围外 NaN', () => {
    expect(interpAt([20, 30, 40], [80, 70, 65], 25)).toBeCloseTo(75, 12);
    expect(interpAt([40, 20, 30], [65, 80, 70], 35)).toBeCloseTo(67.5, 12);
    expect(interpAt([20, 30], [80, 70], 19.9)).toBeNaN();
    expect(interpAt([20, NaN, 30], [80, 1, 70], 30)).toBe(70);
  });

  it('同温度：结温在温度墙处持平时取最低转速满足条件的位置', () => {
    const pt = (pct: number, noiseDb: number, cpu: number, perfPct: number) => ({ pct, noiseDb, cpu, gpu: cpu - 5, perfPct }) as never;
    const s = {
      id: 'x',
      label: 'x',
      short: 'x',
      kind: 'preset' as const,
      fans: '',
      gridScale: 1,
      cases: { heavy: { auto: pt(0, 30, 90, 100), sweep: [pt(40, 20, 95, 92), pt(70, 30, 95, 98), pt(100, 40, 85, 100)], thumb: { w: 1, h: 1, png: '' } } },
    };
    const [r] = fairCompare([s], 'heavy', 'temp', 90);
    expect(r.value).toBeCloseTo(35, 12); // 70% (95°C) 与 100% (85°C) 之间
    expect(r.pct).toBeCloseTo(85, 12);
    const [r2] = fairCompare([s], 'heavy', 'noise', 25);
    expect(r2.value).toBeCloseTo(95, 12);
    expect(r2.perf).toBeCloseTo(95, 12);
  });

  it('缩略图：裁剪、下采样、RGB 往返', () => {
    const W = 6;
    const H = 6;
    const N = W * H;
    const T = new Float32Array(N).map((_, i) => 25 + i);
    const speed = new Float32Array(N).fill(1);
    const solid = new Uint8Array(N);
    solid[0] = solid[1] = solid[W] = 1; // 第 1 列前两行与第 2 列第 1 行
    const th = makeThumb({ W, H, T, speed, solid }, { x: 1, y: 1, w: 4, h: 4 }, 2);
    expect([th.w, th.h]).toEqual([2, 2]);
    expect(th.solid[0]).toBe(1); // 左上块 4 格中 3 格为障碍
    expect(thumbT(th.T[0])).toBeCloseTo(25 + (0 + 1 + 6 + 7) / 4, 0);
    const rgb = thumbToRgb(th);
    const rgba = new Uint8ClampedArray(th.w * th.h * 4);
    for (let k = 0; k < th.w * th.h; k++) rgba.set([rgb[3 * k], rgb[3 * k + 1], rgb[3 * k + 2], 255], 4 * k);
    expect(thumbFromRgba(th.w, th.h, rgba)).toEqual(th);
    expect(THUMB_T_RANGE[0]).toBe(25);
  });
});

describe('预计算数据', () => {
  it('8 个预设 × 3 个场景齐全，口径与默认一致，可整理成方案列表', () => {
    expect(DATA.version).toBe(1);
    expect(DATA.protocol).toEqual(DEFAULT_PROTOCOL); // 发布门槛：不是快速检查用的占位数据
    for (const p of FAN_PRESETS)
      for (const s of COMPARE_SCENARIOS) {
        const c = DATA.cases.find((x) => x.preset === p.name && x.scenario === s.key);
        expect(c, `${p.name}/${s.key}`).toBeTruthy();
        expect(c!.sweep.map((q) => q.pct)).toEqual(DATA.protocol.sweepPct);
        expect(c!.thumb.png.length).toBeGreaterThan(100);
        expect(c!.auto.cls).toBe(s.key);
      }
    const schemes = buildSchemes(DATA, []);
    expect(schemes.length).toBe(FAN_PRESETS.length);
  });

  it('自定义方案的布局可按 JSON 规整读回（在仿真页打开）', () => {
    const L = normalizeLayout(JSON.parse(JSON.stringify(applyPreset(layoutDefault(), 'positive'))));
    expect(L.caseFans!.length).toBe(4);
  });
});
