// 求解器快照与标准答案的逐场对照（测试与诊断共用）。
import { Solver } from '../src/solver/solver';
import { normalizeLayout } from '../src/model/layoutJson';
import { numArr, type Ref } from './refdata';
import { computeAirflowTemperatures, fanStatusList, openingMarkers, pressureFieldPa, totalNoise } from '../src/solver/diagnostics';

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
    // 参考有值而本实现为 NaN/Inf：直接判失败（否则 NaN 会被后面的点覆盖而漏检）
    if (!Number.isFinite(a)) return { name, maxAbs: Infinity, refMax, at: i + 1, ok: false };
    refMax = Math.max(refMax, Math.abs(b));
    const d = Math.abs(a - b);
    if (d > maxAbs) {
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
  // 装配场：参考有而本实现缺（null）判失败
  const opt = (name: string, mine: Float64Array | null, ref: (number | null)[] | undefined) => {
    if (ref === undefined || ref === null) return;
    out.push(mine ? diffField(name, mine, ref, false) : { name: `${name}（缺失）`, maxAbs: Infinity, refMax: NaN, at: 0, ok: false });
  };
  opt('nuAssembled', s.nuFieldAssembled, snap.nuAssembled);
  opt('alphaAssembled', s.alphaFieldAssembled, snap.alphaAssembled);
  opt('nuTAssembled', s.nuTAssembled, snap.nuTAssembled);
  opt('betaRefU', s.betaRefU, snap.betaRefU);
  opt('betaRefV', s.betaRefV, snap.betaRefV);
  return out;
}

/** 装配步与标量（结温、风扇工作点） */
export function compareScalars(s: Solver, snap: Ref): FieldDiff[] {
  const sc = snap.scalars;
  const out: FieldDiff[] = [];
  const one = (name: string, a: number, b: number, isTemp: boolean) => {
    const d = Math.abs(a - b);
    const tol = isTemp ? 1e-3 : 1e-5 * Math.max(Math.abs(b), 1e-12);
    out.push({ name, maxAbs: d, refMax: Math.abs(b), at: 0, ok: d <= tol }); // NaN 时 d <= tol 为 false
  };
  one('asmStep.nu', s.nuAsmStep, snap.asmStep.nu, false);
  one('asmStep.alpha', s.alphaAsmStep, snap.asmStep.alpha, false);
  one('asmStep.nuT', s.nuTAsmStep, snap.asmStep.nuT, false);
  one('betaRefStep', s.betaRefStep, snap.betaRefStep, false);
  one('iteration', s.iteration, sc.iteration, false);
  for (const n of ['cpu', 'gpu', 'psu'] as const) {
    const net = s.thermalNetworks[n];
    const inRef = sc[`Tj_${n}`] !== undefined;
    if (!net || !inRef) {
      // 两边都没有该元件才算一致
      out.push({ name: `net ${n}`, maxAbs: !net === !inRef ? 0 : Infinity, refMax: 0, at: 0, ok: !net === !inRef });
      continue;
    }
    one(`Tj_${n}`, net.T_junction, sc[`Tj_${n}`], true);
    one(`Tsink_${n}`, net.T_sink_base, sc[`Tsink_${n}`], true);
    one(`power_${n}`, net.actualPower, sc[`power_${n}`], false);
    one(`hConv_${n}`, net.h_conv, sc[`hConv_${n}`], false);
    one(`Ttheory_${n}`, net.T_theory_f, sc[`Ttheory_${n}`], true);
  }
  out.push({ name: 'fans.length', maxAbs: s.fans.length === sc.fans.length ? 0 : Infinity, refMax: sc.fans.length, at: 0, ok: s.fans.length === sc.fans.length });
  (sc.fans as Ref[]).forEach((rf, k) => {
    const f = s.fans[k];
    if (!f) return;
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

/** 诊断标量（W2）：内温、风量、噪音、节流、各风扇与开口、机箱内平均静压。相对差 ≤ 1e−6（参考为全精度） */
export function compareDiagnostics(s: Solver, snap: Ref): FieldDiff[] {
  const sc = snap.scalars;
  const out: FieldDiff[] = [];
  const one = (name: string, a: number, b: number) => {
    const d = Math.abs(a - b);
    out.push({ name, maxAbs: d, refMax: Math.abs(b), at: 0, ok: d <= 1e-6 * Math.abs(b) + 1e-9 });
  };
  const same = (name: string, a: unknown, b: unknown) => out.push({ name: `${name}=${String(a)}`, maxAbs: a === b ? 0 : Infinity, refMax: 0, at: 0, ok: a === b });
  const t = computeAirflowTemperatures(s);
  one('internalAmbient', t.internalAmbient, sc.internalAmbient);
  one('totalCFM', t.totalCFM, sc.totalCFM);
  one('noiseDb', totalNoise(s).dbTotal, sc.noiseDb);
  for (const n of ['cpu', 'gpu', 'psu'] as const) {
    const net = s.thermalNetworks[n];
    if (net) one(`throttle_${n}`, net.throttlingRatio, sc[`throttle_${n}`]);
  }
  const fl = fanStatusList(s);
  same('fans.length', fl.length, sc.fans.length);
  (sc.fans as Ref[]).forEach((rf, k) => {
    same(`fan${k + 1}.name`, fl[k]?.name, rf.name);
    one(`fan${k + 1}.cfm`, fl[k]?.cfm, rf.cfm);
    one(`fan${k + 1}.noiseDb`, fl[k]?.noiseDb, rf.noiseDb);
    one(`fan${k + 1}.lastQRatio`, s.fans[k]?.lastQRatio, rf.lastQRatio);
  });
  const om = openingMarkers(s);
  same('openings.length', om.length, sc.openings.length);
  (sc.openings as Ref[]).forEach((ro, k) => {
    same(`opening${k + 1}.mount`, om[k]?.mount, ro.mount);
    same(`opening${k + 1}.kind`, om[k]?.kind, ro.kind);
    one(`opening${k + 1}.cfm`, om[k]?.cfm, ro.cfm);
  });
  const P = pressureFieldPa(s);
  let sum = 0;
  let n = 0;
  for (const i of s.geo.insideMask) {
    if (Number.isFinite(P[i])) {
      sum += P[i];
      n++;
    }
  }
  one('meanInteriorPressurePa', sum / n, sc.meanInteriorPressurePa);
  return out;
}

/** 第 steps 步的显示量（fields）：温度、格心速度 m/s、静压 Pa、障碍 0/1 */
export function compareDisplayFields(s: Solver, fields: Ref): FieldDiff[] {
  const { uC, vC } = s.getCellVelocity();
  const u = uC.map((v, i) => (s.geo.obstacle[i] > 0 ? 0 : v * s.VEL_SCALE));
  const v = vC.map((w, i) => (s.geo.obstacle[i] > 0 ? 0 : w * s.VEL_SCALE));
  const obs = Array.from(s.geo.obstacle, (o) => (o > 0 ? 1 : 0));
  return [
    diffField('fields.T', s.T_fluid, fields.T, true),
    diffField('fields.u', u, fields.u, false),
    diffField('fields.v', v, fields.v, false),
    diffField('fields.P', pressureFieldPa(s), fields.P, false),
    { name: 'fields.obstacle', maxAbs: obs.every((o, i) => o === fields.obstacle[i]) ? 0 : 1, refMax: 1, at: 0, ok: obs.every((o, i) => o === fields.obstacle[i]) },
  ];
}
