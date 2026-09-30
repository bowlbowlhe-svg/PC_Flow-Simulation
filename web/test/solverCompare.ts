// 求解器快照与标准答案的逐场对照（测试与诊断共用）。
import { Solver } from '../src/solver/solver';
import { normalizeLayout } from '../src/model/layoutJson';
import { numArr, type Ref } from './refdata';

export interface FieldDiff {
  name: string;
  maxAbs: number; // 最大逐点绝对差
  refMax: number; // 参考场最大绝对值
  at: number; // 最大差的 1 基线性索引
  ok: boolean;
}

/** 按 README 第 2 级判据：温度 ≤ 1e−3°C，其余 ≤ 1e−5 × 场最大绝对值（null/NaN 双方一致视为相等） */
export function diffField(name: string, mine: ArrayLike<number>, refRaw: (number | null)[], isTemp: boolean): FieldDiff {
  const ref = numArr(refRaw);
  if (mine.length !== ref.length) return { name, maxAbs: Infinity, refMax: NaN, at: -1, ok: false };
  let maxAbs = 0;
  let refMax = 0;
  let at = 0;
  for (let i = 0; i < ref.length; i++) {
    const a = mine[i];
    const b = ref[i];
    if (Number.isNaN(b)) {
      if (!Number.isNaN(a)) return { name, maxAbs: Infinity, refMax, at: i + 1, ok: false };
      continue;
    }
    refMax = Math.max(refMax, Math.abs(b));
    const d = Math.abs(a - b);
    if (!(d <= maxAbs)) {
      maxAbs = d;
      at = i + 1;
    }
  }
  const tol = isTemp ? 1e-3 : 1e-5 * refMax;
  return { name, maxAbs, refMax, at, ok: maxAbs <= tol };
}

export function makeSolver(ref: Ref, pressureSolver: 'direct' | 'pcg' = 'direct'): Solver {
  const [cpu, gpu, psu] = ref.powers as number[];
  const s = new Solver(normalizeLayout(ref.layout), { gridScale: ref.gridScale, DT: ref.DT, powers: { cpu, gpu, psu }, pressureSolver });
  s.turbUpdateEvery = ref.turbUpdateEvery;
  return s;
}

/** 与一个快照逐场对照 */
export function compareSnapshot(s: Solver, snap: Ref): FieldDiff[] {
  const out: FieldDiff[] = [];
  out.push(diffField('T', s.T_fluid, snap.T, true));
  out.push(diffField('Tsolid', s.T_solid, snap.Tsolid, true));
  out.push(diffField('uF', s.uF, snap.uF, false));
  out.push(diffField('vF', s.vF, snap.vF, false));
  out.push(diffField('p', s.p, snap.p, false));
  out.push(diffField('pProj1', s.pProj1, snap.pProj1, false));
  out.push(diffField('k', s.turbK, snap.k, false));
  out.push(diffField('omega', s.turbOmega, snap.omega, false));
  out.push(diffField('nuStep', s.nuFieldStep, snap.nuStep, false));
  if (s.nuFieldAssembled) out.push(diffField('nuAssembled', s.nuFieldAssembled, snap.nuAssembled, false));
  if (s.alphaFieldAssembled) out.push(diffField('alphaAssembled', s.alphaFieldAssembled, snap.alphaAssembled, false));
  if (s.nuTAssembled) out.push(diffField('nuTAssembled', s.nuTAssembled, snap.nuTAssembled, false));
  if (s.betaRefU) out.push(diffField('betaRefU', s.betaRefU, snap.betaRefU, false));
  if (s.betaRefV) out.push(diffField('betaRefV', s.betaRefV, snap.betaRefV, false));
  return out;
}

/** 装配步与标量（结温、风扇工作点） */
export function compareScalars(s: Solver, snap: Ref): FieldDiff[] {
  const sc = snap.scalars;
  const out: FieldDiff[] = [];
  const one = (name: string, a: number, b: number, isTemp: boolean) => {
    const d = Math.abs(a - b);
    const tol = isTemp ? 1e-3 : 1e-5 * Math.max(Math.abs(b), 1e-12);
    out.push({ name, maxAbs: d, refMax: Math.abs(b), at: 0, ok: d <= tol });
  };
  one('asmStep.nu', s.nuAsmStep, snap.asmStep.nu, false);
  one('asmStep.alpha', s.alphaAsmStep, snap.asmStep.alpha, false);
  one('asmStep.nuT', s.nuTAsmStep, snap.asmStep.nuT, false);
  one('betaRefStep', s.betaRefStep, snap.betaRefStep, false);
  one('iteration', s.iteration, sc.iteration, false);
  for (const n of ['cpu', 'gpu', 'psu'] as const) {
    const net = s.thermalNetworks[n];
    if (!net) continue;
    one(`Tj_${n}`, net.T_junction, sc[`Tj_${n}`], true);
    one(`Tsink_${n}`, net.T_sink_base, sc[`Tsink_${n}`], true);
    one(`power_${n}`, net.actualPower, sc[`power_${n}`], false);
    one(`hConv_${n}`, net.h_conv, sc[`hConv_${n}`], false);
    one(`Ttheory_${n}`, net.T_theory_f, sc[`Ttheory_${n}`], true);
  }
  (sc.fans as Ref[]).forEach((rf, k) => {
    const f = s.fans[k];
    one(`fan${k + 1}.rpm`, f.getRPM(s), rf.rpm, false);
    one(`fan${k + 1}.dp`, f.lastDp, rf.dp, false);
    one(`fan${k + 1}.lastQ`, f.lastQ, rf.lastQ_m3s, false);
    one(`fan${k + 1}.flowFactor`, f.lastFlowFactor, rf.flowFactor, false);
    one(`fan${k + 1}.noiseQRatio`, f.noiseQRatio, rf.noiseQRatio, false);
  });
  return out;
}

export function fmt(d: FieldDiff): string {
  return `${d.ok ? 'ok ' : 'BAD'} ${d.name.padEnd(16)} max|Δ|=${d.maxAbs.toExponential(3)} ref max=${d.refMax.toExponential(3)} at=${d.at}`;
}
