// 对比展示页：计算口径（CompareRunner）与 MATLAB tools/compare_scenarios.m 一致、分块方式不影响结果、
// 公平比较的插值、流场图（时均场、裁剪、量化往返）、风扇成本、预计算数据的完整性。
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import { COMPARE_SCENARIOS, CompareRunner, DEFAULT_PROTOCOL, interpAt, type CompareProtocol } from '../src/compare/protocol';
import {
  dequantT,
  dequantV,
  fieldStats,
  makeFieldThumb,
  quantT,
  quantV,
  sampleVel,
  thumbFromPixels,
  thumbPixels,
  THUMB_MARGIN_MM,
  THUMB_T_RANGE,
  type FieldMean,
  type StoredThumb,
} from '../src/compare/thumb';
import { openingMarkers } from '../src/solver/diagnostics';
import { geoOverlay } from '../src/solver/geoOverlay';
import { traceStreamlines } from '../src/ui/compare/streamlines';
import type { GeoOverlay } from '../src/solver/geoOverlay';
import { Solver } from '../src/solver/solver';
import { decodePng } from './pngDecode';
import type { CompareData } from '../src/compare/data';
import { applyPreset, FAN_PRESETS } from '../src/model/fans';
import { layoutDefault } from '../src/model/layoutDefault';
import { normalizeLayout } from '../src/model/layoutJson';
import { buildSchemes, fairCompare, fanCost, metricByKey, rankBy } from '../src/ui/compare/schemes';
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
    expect(b.autoField).toEqual(a.autoField);
  });

  it('时均场：自动温控阶段统计窗口内逐步平均（温度、速度、各开口净风量），只读状态', () => {
    const q: CompareProtocol = { gridScale: 0.5, turbUpdateEvery: 2, autoSteps: 10, autoAvgFrom: 6, sweepPct: [40], sweepSteps: 4, sweepAvgFrom: 2 };
    const L = layoutDefault();
    const r = run(L, [100, 200, 500], q, 3);
    const s = new Solver(L, { gridScale: 0.5, powers: { cpu: 100, gpu: 200, psu: 500 } });
    s.turbUpdateEvery = 2;
    s.stepMultiple(6);
    const T = new Float64Array(s.N);
    const u = new Float64Array(s.N);
    const v = new Float64Array(s.N);
    const cfm = new Float64Array(s.geo.openings.length);
    for (let k = 0; k < 4; k++) {
      s.stepMultiple(1);
      const { uC, vC } = s.getCellVelocity();
      for (let i = 0; i < s.N; i++) {
        T[i] += s.geo.obstacle[i] ? s.T_solid[i] : s.T_fluid[i];
        if (!s.geo.obstacle[i]) {
          u[i] += uC[i] * s.VEL_SCALE;
          v[i] += vC[i] * s.VEL_SCALE;
        }
      }
      openingMarkers(s).forEach((m, j) => (cfm[j] += m.cfm));
    }
    const f = r.autoField!;
    let worst = 0;
    for (let i = 0; i < s.N; i++) {
      worst = Math.max(worst, Math.abs(f.T[i] - T[i] / 4) / Math.max(1, Math.abs(T[i] / 4)));
      worst = Math.max(worst, Math.abs(f.u[i] - u[i] / 4), Math.abs(f.v[i] - v[i] / 4));
      expect(f.solid[i] > 0).toBe(s.geo.obstacle[i] > 0);
    }
    expect(worst).toBeLessThan(1e-5); // Float32 存储
    expect(f.openings.length).toBe(s.geo.openings.length);
    f.openings.forEach((o, j) => expect(o.cfm).toBeCloseTo(cfm[j] / 4, 9));
    // 累加只读状态：推进结果与不累加时相同
    const plain = new Solver(L, { gridScale: 0.5, powers: { cpu: 100, gpu: 200, psu: 500 } });
    plain.turbUpdateEvery = 2;
    plain.stepMultiple(10);
    expect(Array.from(s.T_fluid)).toEqual(Array.from(plain.T_fluid));
    expect(r.solver.iteration).toBe(14);
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
      price: { total: 0, detail: '' },
      cases: { heavy: { auto: pt(0, 30, 90, 100), sweep: [pt(40, 20, 95, 92), pt(70, 30, 95, 98), pt(100, 40, 85, 100)], thumb: {} as StoredThumb } },
    };
    const [r] = fairCompare([s], 'heavy', 'temp', 90);
    expect(r.value).toBeCloseTo(35, 12); // 70% (95°C) 与 100% (85°C) 之间
    expect(r.pct).toBeCloseTo(85, 12);
    const [r2] = fairCompare([s], 'heavy', 'noise', 25);
    expect(r2.value).toBeCloseTo(95, 12);
    expect(r2.perf).toBeCloseTo(95, 12);
  });

  it('流场图：裁到机箱外框外扩一圈、障碍为 NaN、速度块平均、99 百分位', () => {
    const W = 30; // 行
    const H = 40; // 列
    const N = W * H;
    const cellMm = 6;
    const at = (x: number, y: number) => (x - 1) * W + (y - 1); // 1 基
    const T = new Float32Array(N);
    const u = new Float32Array(N);
    const v = new Float32Array(N);
    const solid = new Uint8Array(N);
    for (let x = 1; x <= H; x++)
      for (let y = 1; y <= W; y++) {
        T[at(x, y)] = 30 + x + 0.1 * y;
        u[at(x, y)] = 1;
        v[at(x, y)] = 0.5 * (x / 40);
      }
    for (const x of [15, 16]) {
      solid[at(x, 12)] = 1;
      u[at(x, 12)] = v[at(x, 12)] = 0;
    }
    const caseOuter = { x: 15, y: 12, w: 10, h: 8 };
    const geo: GeoOverlay = { W, H, cellMm, caseOuter, ram: [], fans: [] };
    const f: FieldMean = { W, H, T, u, v, solid, openings: [{ x: 26, y: 15, mount: 'front', kind: 'fan', cfm: -12.345 }] };
    const t = makeFieldThumb(f, geo, 2);
    const m = Math.round(THUMB_MARGIN_MM / cellMm);
    expect(t.crop).toEqual({ x: 15 - m, y: 12 - m, w: 10 + 2 * m, h: 8 + 2 * m });
    const px = (x: number, y: number) => (y - t.crop.y) * t.crop.w + (x - t.crop.x);
    expect(t.T[px(15, 12)]).toBeNaN();
    expect(t.T[px(20, 14)]).toBeCloseTo(30 + 20 + 1.4, 5);
    expect([t.uw, t.uh]).toEqual([Math.ceil(t.crop.w / 2), Math.ceil(t.crop.h / 2)]);
    // 不含障碍的块：u = 1、v 为块内平均；含 2 个障碍格的块按 0 计入
    expect(t.u[0]).toBeCloseTo(1, 6);
    expect(t.v[0]).toBeCloseTo(0.5 * ((t.crop.x + t.crop.x + 1) / 2 / 40), 6);
    const bk = Math.floor((12 - t.crop.y) / 2) * t.uw + Math.floor((15 - t.crop.x) / 2);
    expect(t.u[bk]).toBeCloseTo(0.5, 6);
    // 色标统计：99 百分位只取机箱内流体格，不含电源内部
    const inside: number[] = [];
    for (let x = 15; x < 25; x++) for (let y = 12; y < 20; y++) if (!solid[at(x, y)]) inside.push(T[at(x, y)]);
    inside.sort((a, b) => a - b);
    expect(fieldStats(t).t99).toBeCloseTo(inside[Math.round(0.99 * (inside.length - 1))], 5);
    expect(fieldStats(t).s99).toBeGreaterThan(0.9);
    const psuBody = { x: 21, y: 16, w: 4, h: 4 }; // 机箱右下角（最热的一块）
    const withPsu = makeFieldThumb(f, { ...geo, psu: { body: psuBody } }, 2);
    const noPsu: number[] = [];
    for (let x = 15; x < 25; x++)
      for (let y = 12; y < 20; y++) if (!solid[at(x, y)] && !(x >= 21 && y >= 16)) noPsu.push(T[at(x, y)]);
    noPsu.sort((a, b) => a - b);
    expect(fieldStats(withPsu).t99).toBeCloseTo(noPsu[Math.round(0.99 * (noPsu.length - 1))], 5);
    expect(fieldStats(withPsu).t99).toBeLessThan(fieldStats(t).t99);
    expect(t.openings[0].cfm).toBeCloseTo(-12.345, 9);
    // 双线性插值：块中心处为块值
    const [su, sv] = sampleVel(t, 1, 1);
    expect(su).toBeCloseTo(t.u[0], 6);
    expect(sv).toBeCloseTo(t.v[0], 6);
  });

  it('流场图：8 位量化往返（温度 ≤ 0.16°C；速度平方根压扩，±1 m/s 内误差 ≤ 0.02 m/s）', () => {
    expect(quantT(NaN)).toBe(0);
    expect(dequantT(0)).toBeNaN();
    expect(quantV(0)).toBe(128);
    expect(dequantV(128)).toBe(0);
    for (let k = 0; k <= 200; k++) {
      const tt = THUMB_T_RANGE[0] + (k / 200) * (THUMB_T_RANGE[1] - THUMB_T_RANGE[0]);
      expect(Math.abs(dequantT(quantT(tt)) - tt)).toBeLessThanOrEqual((0.5 * 80) / 254 + 1e-9);
      const vv = -1 + k / 100;
      expect(Math.abs(dequantV(quantV(vv)) - vv)).toBeLessThanOrEqual(0.02);
    }
    expect(Math.abs(dequantV(quantV(0.01)) - 0.01)).toBeLessThan(0.003); // 低速段分辨率高
    // 像素往返（RGBA 同 canvas getImageData）
    const W = 20;
    const H = 24;
    const N = W * H;
    const f: FieldMean = {
      W,
      H,
      T: new Float32Array(N).map((_, i) => 25 + (i % 37)),
      u: new Float32Array(N).map((_, i) => Math.sin(i) * 0.9),
      v: new Float32Array(N).map((_, i) => Math.cos(i) * 0.4),
      solid: new Uint8Array(N).map((_, i) => (i % 53 === 0 ? 1 : 0)),
      openings: [],
    };
    const t = makeFieldThumb(f, { W, H, cellMm: 12, caseOuter: { x: 8, y: 7, w: 6, h: 8 }, ram: [], fans: [] }, 2);
    const { gray, rgb } = thumbPixels(t);
    const rgba = (px: Uint8Array, ch: number, n: number) => {
      const o = new Uint8ClampedArray(4 * n);
      for (let k = 0; k < n; k++) o.set([px[k * ch], px[k * ch + (ch === 3 ? 1 : 0)], px[k * ch + (ch === 3 ? 2 : 0)], 255], 4 * k);
      return o;
    };
    const st = { crop: t.crop, cellMm: t.cellMm, uvF: t.uvF, uw: t.uw, uh: t.uh, geo: t.geo, openings: t.openings } as StoredThumb;
    const back = thumbFromPixels(st, rgba(gray, 1, t.T.length), rgba(rgb, 3, t.uw * t.uh));
    t.T.forEach((x, k) => (Number.isFinite(x) ? expect(Math.abs(back.T[k] - x)).toBeLessThanOrEqual(0.16) : expect(back.T[k]).toBeNaN()));
    t.u.forEach((x, k) => expect(Math.abs(back.u[k] - x)).toBeLessThanOrEqual(0.02));
    t.v.forEach((x, k) => expect(Math.abs(back.v[k] - x)).toBeLessThanOrEqual(0.02));
  });

  it('流场图：机箱贴近计算域边缘时裁剪夹在域内', () => {
    const W = 20;
    const H = 30;
    const N = W * H;
    const f: FieldMean = { W, H, T: new Float32Array(N).fill(30), u: new Float32Array(N), v: new Float32Array(N), solid: new Uint8Array(N), openings: [] };
    const t = makeFieldThumb(f, { W, H, cellMm: 6, caseOuter: { x: 2, y: 3, w: 25, h: 15 }, ram: [], fans: [] }, 2);
    expect(t.crop).toEqual({ x: 1, y: 1, w: 30, h: 20 });
    expect(t.T.length).toBe(600);
    expect([t.uw, t.uh]).toEqual([15, 10]);
  });

  it('界面后台计算的自定义方案（预览 140²、速度不做块平均）：时均场 → 流场图 → 流线', () => {
    const q: CompareProtocol = { gridScale: 0.5, turbUpdateEvery: 2, autoSteps: 40, autoAvgFrom: 20, sweepPct: [], sweepSteps: 0, sweepAvgFrom: 0 };
    const r = run(applyPreset(layoutDefault(), 'positive'), [100, 200, 500], q, 13);
    const t = makeFieldThumb(r.autoField!, geoOverlay(r.solver), 1);
    const co = r.solver.geo.CASE2D.outer;
    const m = Math.round(THUMB_MARGIN_MM / r.solver.geo.cellMm);
    expect(t.cellMm).toBe(4);
    expect([t.crop.w, t.crop.h]).toEqual([co.w + 2 * m, co.h + 2 * m]);
    expect([t.uw, t.uh, t.uvF]).toEqual([t.crop.w, t.crop.h, 1]);
    expect(t.openings.length).toBe(r.solver.geo.openings.length);
    const lines = traceStreamlines(t, { dsep: 3, dtest: 1.5, step: 0.25, vmin: 0.03, maxSteps: 600 });
    expect(lines.length).toBeGreaterThan(10);
  });

  it('风扇成本：按型号库参考价合计（原装风扇 0 元）；可作为排序指标', () => {
    expect(fanCost(['P12', 'P12', 'P12', 'Stock120'])).toEqual({ total: 165, detail: '3×P12 + 原装' });
    expect(fanCost(['NF_A14', 'P12'])).toEqual({ total: 249 + 55, detail: 'NF-A14 + P12' });
    expect(fanCost([])).toEqual({ total: 0, detail: '无机箱风扇' });
    expect(fanCost(['nope']).total).toBeNaN();
    const schemes = buildSchemes(DATA, []);
    const full = schemes.find((s) => s.id === 'full')!;
    expect(full.price.total).toBe(7 * 55);
    const ranked = rankBy(schemes, 'gaming', metricByKey('price'));
    expect(ranked[0].price.total).toBe(Math.min(...schemes.map((s) => s.price.total)));
  });
});

describe('预计算数据', () => {
  it('8 个预设 × 3 个场景齐全，口径与默认一致，可整理成方案列表', () => {
    expect(DATA.version).toBe(2);
    expect(DATA.protocol).toEqual(DEFAULT_PROTOCOL); // 发布门槛：不是快速检查用的占位数据
    for (const p of FAN_PRESETS)
      for (const s of COMPARE_SCENARIOS) {
        const c = DATA.cases.find((x) => x.preset === p.name && x.scenario === s.key);
        expect(c, `${p.name}/${s.key}`).toBeTruthy();
        expect(c!.sweep.map((q) => q.pct)).toEqual(DATA.protocol.sweepPct);
        expect(c!.auto.cls).toBe(s.key);
        // 流场图：PNG 尺寸与记录一致、机箱外框在裁剪范围内、各开口有时均风量、机箱内时均空气温度与内温指标相近
        const th = c!.thumb;
        expect(th.v).toBe(2);
        const tp = decodePng(th.tPng);
        const uv = decodePng(th.uvPng);
        expect([tp.w, tp.h]).toEqual([th.crop.w, th.crop.h]);
        expect([uv.w, uv.h]).toEqual([th.uw, th.uh]);
        const co = th.geo.caseOuter;
        expect(co.x).toBeGreaterThan(th.crop.x);
        expect(co.x + co.w).toBeLessThan(th.crop.x + th.crop.w);
        expect(th.openings.length).toBeGreaterThanOrEqual(p.fans.length);
        const ft = thumbFromPixels(th, tp.rgba, uv.rgba);
        // 色标统计不含电源内部（办公场景电源半被动停转，里面约 90°C）：机箱内空气的 99 百分位在 30–70°C
        const st = fieldStats(ft);
        expect(st.t99, `${p.name}/${s.key} t99`).toBeGreaterThan(30);
        expect(st.t99, `${p.name}/${s.key} t99`).toBeLessThan(70);
        let sum = 0;
        let cnt = 0;
        for (let r = 0; r < ft.crop.h; r++)
          for (let cc = 0; cc < ft.crop.w; cc++) {
            const x = ft.crop.x + cc;
            const y = ft.crop.y + r;
            const tv = ft.T[r * ft.crop.w + cc];
            if (x < co.x || x >= co.x + co.w || y < co.y || y >= co.y + co.h || !Number.isFinite(tv)) continue;
            sum += tv;
            cnt++;
          }
        expect(Math.abs(sum / cnt - (c!.auto.interior as number)), `${p.name}/${s.key} 机箱内均温`).toBeLessThan(1.5);
        // 机箱风扇开口的时均净风量之和（流出为正）与机箱风量同号同量级：流出的开口合计 ≈ 机箱风量（不含电源风道）
        const outCfm = th.openings.filter((o) => !o.kind.startsWith('psu') && o.cfm > 0).reduce((a, o) => a + o.cfm, 0);
        expect(Math.abs(outCfm - (c!.auto.cfm as number)), `${p.name}/${s.key} 出风量`).toBeLessThan(0.05 * (c!.auto.cfm as number) + 0.5);
      }
    const schemes = buildSchemes(DATA, []);
    expect(schemes.length).toBe(FAN_PRESETS.length);
  });

  it('自定义方案的布局可按 JSON 规整读回（在仿真页打开）', () => {
    const L = normalizeLayout(JSON.parse(JSON.stringify(applyPreset(layoutDefault(), 'positive'))));
    expect(L.caseFans!.length).toBe(4);
  });
});
