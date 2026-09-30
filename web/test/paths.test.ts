// 求解器分支路径的回归对照（fixtures/paths.json，由 test/gen/gen_paths_fixtures.m 在 Octave 下生成）：
// 方腔、LVEL、层流、湍流隔 3 步、手动转速、环境/壁温/物性覆盖/节流/超温/中途改功率/精确模式、只有电源、无电源、
// 散热体被固体覆盖（NaN 语义）、全装预设、2 槽显卡 + LVEL、空域。比较各场指纹（和、绝对值和、平方和、极值、抽样点）
// 与装配步、热网络、风扇状态；状态与 Octave 只差线性求解舍入（约 1e−10 相对），容差取 1e−8。
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { describe, expect, it } from 'vitest';
import { normalizeLayout } from '../src/model/layoutJson';
import { Solver } from '../src/solver/solver';
import type { Ref } from './refdata';

const here = dirname(fileURLToPath(import.meta.url));
const FX: Ref = JSON.parse(readFileSync(join(here, 'fixtures', 'paths.json'), 'utf8'));
const TOL = 1e-8;
const list = <T,>(v: T | T[] | undefined | null): T[] => (Array.isArray(v) ? v : v === undefined || v === null ? [] : [v]);

function fields(s: Solver): Record<string, Float64Array | null> {
  return {
    T: s.T_fluid,
    Tsolid: s.T_solid,
    uF: s.uF,
    vF: s.vF,
    p: s.p,
    pProj1: s.pProj1,
    k: s.turbK,
    omega: s.turbOmega,
    nuStep: s.nuFieldStep,
    nuAssembled: s.nuFieldAssembled,
    alphaAssembled: s.alphaFieldAssembled,
    nuTAssembled: s.nuTAssembled,
    betaRefU: s.betaRefU,
    betaRefV: s.betaRefV,
  };
}

function checkFingerprint(name: string, x: Float64Array | null, fp: Ref, bad: string[]) {
  if (!x) {
    bad.push(`${name}: 缺失`);
    return;
  }
  if (x.length !== fp.n) {
    bad.push(`${name}: 长度 ${x.length} ≠ ${fp.n}`);
    return;
  }
  let nNaN = 0;
  let sum = 0;
  let sumAbs = 0;
  let sumSq = 0;
  let mx = -Infinity;
  let mn = Infinity;
  for (const v of x) {
    if (Number.isNaN(v)) {
      nNaN++;
      continue;
    }
    if (!Number.isFinite(v)) {
      bad.push(`${name}: 出现 ${v}`);
      return;
    }
    sum += v;
    sumAbs += Math.abs(v);
    sumSq += v * v;
    if (v > mx) mx = v;
    if (v < mn) mn = v;
  }
  if (nNaN !== fp.nNaN) bad.push(`${name}: NaN 个数 ${nNaN} ≠ ${fp.nNaN}`);
  const scale = Math.max(Math.abs(fp.max), Math.abs(fp.min), 1e-300);
  // 相对 TOL，另加绝对下限 ABS（每个值 1e−14，和按元素个数放大）：静止场里的舍入噪声（Octave 约 1e−18，
  // 本实现为精确 0）不算差异
  const ABS = 1e-14;
  const chk = (what: string, a: number, b: number, ref: number, abs: number) => {
    if (!(Math.abs(a - b) <= TOL * ref + abs)) bad.push(`${name}.${what}: ${a} vs ${b}（相对 ${(Math.abs(a - b) / ref).toExponential(2)}）`);
  };
  chk('sum', sum, fp.sum, Math.max(fp.sumAbs, 1e-300), ABS * fp.n);
  chk('sumAbs', sumAbs, fp.sumAbs, Math.max(fp.sumAbs, 1e-300), ABS * fp.n);
  chk('sumSq', sumSq, fp.sumSq, Math.max(fp.sumSq, 1e-300), ABS * ABS * fp.n);
  chk('max', mx, fp.max, scale, ABS);
  chk('min', mn, fp.min, scale, ABS);
  list<number>(fp.idx).forEach((i, k) => {
    const r = list<number | null>(fp.sample)[k];
    const v = x[i - 1];
    if (r === null) {
      if (!Number.isNaN(v)) bad.push(`${name}[${i}]: ${v} vs NaN`);
    } else chk(`[${i}]`, v, r, scale, ABS);
  });
}

const num = (a: number, b: number, what: string, bad: string[]) => {
  if (!(Math.abs(a - b) <= TOL * Math.max(1, Math.abs(b)))) bad.push(`${what}: ${a} vs ${b}`);
};

describe('求解器分支路径与 Octave 一致', () => {
  for (const c of FX.cases as Ref[]) {
    it(c.name, () => {
      const L = normalizeLayout(c.layout);
      const [cpu, gpu, psu] = c.powers as number[];
      const s = new Solver(L, { gridScale: c.gridScale, DT: c.DT, powers: { cpu, gpu, psu } });
      for (const [k, v] of Object.entries(c.props ?? {})) (s as unknown as Record<string, unknown>)[k] = v;
      const actions = list<Ref>(c.actions);
      const bad: string[] = [];
      for (const snap of list<Ref>(c.snaps)) {
        while (s.iteration < snap.iteration) {
          for (const a of actions) if (a.step === s.iteration) s.setComponentPower(a.name, a.watts);
          s.fluidStep();
        }
        const pre = `第 ${snap.iteration} 步 `;
        const F = fields(s);
        for (const [name, fp] of Object.entries(snap.fields as Record<string, Ref>)) checkFingerprint(pre + name, F[name], fp, bad);
        for (const [k, mine] of [
          ['asmNu', s.nuAsmStep],
          ['asmAlpha', s.alphaAsmStep],
          ['asmNuT', s.nuTAsmStep],
          ['betaRefStep', s.betaRefStep],
        ] as [string, number][]) {
          // Octave 的 -Inf 在 JSON 里为 null
          const ref = snap[k] === null ? -Infinity : snap[k];
          if (mine !== ref) bad.push(`${pre}${k}: ${mine} vs ${ref}`);
        }
        const nets = snap.nets ?? {};
        for (const n of ['cpu', 'gpu', 'psu'] as const) {
          const net = s.thermalNetworks[n];
          const r = nets[n];
          if (!r || !net) {
            if (!r !== !net) bad.push(`${pre}net ${n}: ${net ? '多出' : '缺少'}`);
            continue;
          }
          num(net.T_junction, r.Tj, `${pre}${n}.Tj`, bad);
          num(net.T_sink_base, r.Tsink, `${pre}${n}.Tsink`, bad);
          num(net.power, r.power, `${pre}${n}.power`, bad);
          num(net.actualPower, r.actual, `${pre}${n}.actual`, bad);
          num(net.h_conv, r.h, `${pre}${n}.h`, bad);
          num(net.throttlingRatio, r.thr, `${pre}${n}.thr`, bad);
          num(net.T_theory_f, r.Tth, `${pre}${n}.Tth`, bad);
          if (net.overTemp !== r.over) bad.push(`${pre}${n}.overTemp: ${net.overTemp} vs ${r.over}`);
        }
        const fans = list<Ref>(snap.fans);
        if (fans.length !== s.fans.length) bad.push(`${pre}风扇数 ${s.fans.length} ≠ ${fans.length}`);
        fans.forEach((rf, k) => {
          const f = s.fans[k];
          if (!f) return;
          num(f.getRPM(s), rf.rpm, `${pre}fan${k + 1}.rpm`, bad);
          num(f.lastDp, rf.dp, `${pre}fan${k + 1}.dp`, bad);
          num(f.lastQ, rf.Q, `${pre}fan${k + 1}.Q`, bad);
          num(f.lastQRatio, rf.qr, `${pre}fan${k + 1}.qr`, bad);
          num(f.lastFlowFactor, rf.ff, `${pre}fan${k + 1}.ff`, bad);
          num(f.noiseQRatio, rf.nq, `${pre}fan${k + 1}.nq`, bad);
          num(s.diskFlow(f.g), rf.disk, `${pre}fan${k + 1}.disk`, bad);
        });
      }
      expect(bad.slice(0, 20)).toEqual([]);
    });
  }
});
