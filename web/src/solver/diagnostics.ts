// 诊断量（移植自 CFDSolverBase：openingFlux / computeAirflowTemperatures / computeVorticity /
// calculateCFDDiagnostics / totalNoise / fanStatusList / calculateScores / scenarioSummary /
// pressureFieldPa / openingMarkers / cellReadout / getRecommendations）。只读求解器状态，不改变推进结果。
import { mmax, mmin } from '../numerics/mathx';
import type { Mount } from '../model/types';
import { chassisSizeMm } from '../model/chassis';
import type { NoiseParts } from './fan';
import { CFM_PER_M3S } from './fan';
import type { Opening } from './geometry';
import { AIR_CP, AIR_DENSITY, CFM_TO_M3S } from './constants';
import type { Solver } from './solver';

/** 代数轨流量效率缺省值（FLOW_EFFICIENCY） */
export const FLOW_EFFICIENCY = 0.75;

export interface OpeningFlux {
  volM3s: number; // 净体积流量（流出机箱为正）
  heatW: number; // 焓流（相对环境）
  cfm: number;
  Tmean: number; // 出风混合温度
  cfmOut: number;
  cfmIn: number;
}

/** 一组开口格的体积流量与焓流（外向为正），读穿墙外侧 MAC 面；面温取迎风值 */
export function openingFlux(s: Solver, idx: Int32Array, mount: Mount): OpeningFlux {
  const W = s.W;
  const cellM = s.geo.cellMm / 1000;
  const dA = cellM * s.chassisDepthM;
  const rhoCp = AIR_DENSITY * AIR_CP;
  const amb = s.T_amb;
  if (idx.length === 0) return { volM3s: 0, heatW: 0, cfm: 0, Tmean: amb, cfmOut: 0, cfmIn: 0 };
  let vol = 0;
  let volOut = 0;
  let volIn = 0;
  let Q = 0;
  for (const i of idx) {
    const y = i % W;
    const x = Math.floor(i / W);
    let vn: number;
    let outIdx: number;
    switch (mount) {
      case 'top':
        vn = -s.vF[x * (W + 1) + y];
        outIdx = i - 1;
        break;
      case 'rear':
        vn = -s.uF[x * W + y];
        outIdx = i - W;
        break;
      case 'front':
        vn = s.uF[(x + 1) * W + y];
        outIdx = i + W;
        break;
      default: // bottom
        vn = s.vF[x * (W + 1) + y + 1];
        outIdx = i + 1;
    }
    const v = vn * s.VEL_SCALE;
    const Tf = v < 0 ? s.T_fluid[outIdx] : s.T_fluid[i];
    vol += v;
    volOut += mmax(0, v);
    volIn += mmax(0, -v);
    Q += (Tf - amb) * v;
  }
  vol *= dA;
  volOut *= dA;
  volIn *= dA;
  Q = rhoCp * Q * dA;
  let Tmean = amb;
  if (vol > 1e-6) Tmean = mmin(mmax(amb + Q / (rhoCp * vol), amb), 150);
  return { volM3s: vol, heatW: Q, cfm: vol / CFM_TO_M3S, Tmean, cfmOut: volOut / CFM_TO_M3S, cfmIn: volIn / CFM_TO_M3S };
}

/** 每个开口的通量（与 geo.openings 对齐） */
export function openingFluxList(s: Solver): OpeningFlux[] {
  return s.geo.openings.map((op) => openingFlux(s, op.idx, op.mount));
}

export interface AirflowTemps {
  intake: number;
  internalAmbient: number; // 机箱内部流体均温
  topExhaust: number;
  rearExhaust: number;
  totalCFM: number; // 机箱开口（不含电源风道）总出风量
  internalAmbientAlg: number; // 代数热平衡口径
  internalDiscrepancy: number;
}

/** 温度汇总：CFD 口径 + 代数热平衡口径（交叉校验） */
export function computeAirflowTemperatures(s: Solver): AirflowTemps {
  const amb = s.T_amb;
  const fl = openingFluxList(s);
  const outTop = [0, 0];
  const outRear = [0, 0];
  let totalOut = 0;
  s.geo.openings.forEach((op, k) => {
    if (op.kind === 'psu_intake' || op.kind === 'psu_exhaust') return;
    const st = fl[k];
    if (st.volM3s > 0) {
      totalOut += st.volM3s;
      if (op.mount === 'top') {
        outTop[0] += st.heatW;
        outTop[1] += st.volM3s;
      }
      if (op.mount === 'rear') {
        outRear[0] += st.heatW;
        outRear[1] += st.volM3s;
      }
    }
  });
  const rhoCp = AIR_DENSITY * AIR_CP;
  const mixT = (hv: number[]) => amb + (hv[0] / mmax(rhoCp * hv[1], Number.EPSILON)) * (hv[1] > 1e-6 ? 1 : 0);
  const inside = s.geo.insideMask;
  let Tin = amb;
  if (inside.length) {
    let sum = 0;
    for (const i of inside) sum += s.T_fluid[i];
    Tin = sum / inside.length;
  }
  let exhaustCFM = 0;
  for (const f of caseFans(s)) {
    if (f.g.type === 'exhaust') exhaustCFM += f.getCFM(s) * FLOW_EFFICIENCY * f.lastFlowFactor;
  }
  let P = 0;
  if (s.thermalNetworks.cpu) P += s.thermalNetworks.cpu.actualPower;
  if (s.thermalNetworks.gpu) P += s.thermalNetworks.gpu.actualPower;
  let Talg = amb;
  if (exhaustCFM > 0.1) Talg = amb + P / (exhaustCFM * AIR_DENSITY * AIR_CP * CFM_TO_M3S);
  return {
    intake: amb,
    internalAmbient: Tin,
    topExhaust: mixT(outTop),
    rearExhaust: mixT(outRear),
    totalCFM: totalOut / CFM_TO_M3S,
    internalAmbientAlg: Talg,
    internalDiscrepancy: Tin - Talg,
  };
}

/** 机箱风扇（MATLAB obj.fans；allFans 的前 nCaseFans 个） */
export function caseFans(s: Solver) {
  return s.fans.slice(0, s.geo.nCaseFans);
}

/** 涡量 [1/s]（格心中心差分，边界与障碍格为 0） */
export function computeVorticity(s: Solver): Float64Array {
  const { W, H, N } = s;
  const { uC, vC } = s.getCellVelocity();
  const vs = s.VEL_SCALE;
  const invDx = 1 / (s.geo.cellMm / 1000);
  const out = new Float64Array(N);
  for (let x = 1; x < H - 1; x++) {
    for (let y = 1; y < W - 1; y++) {
      const i = x * W + y;
      if (s.geo.obstacle[i] > 0) continue;
      const dvdx = 0.5 * (vC[i + W] * vs - vC[i - W] * vs) * invDx;
      const dudy = 0.5 * (uC[i + 1] * vs - uC[i - 1] * vs) * invDx;
      out[i] = dvdx - dudy;
    }
  }
  return out;
}

export interface CFDDiag {
  Re: number;
  Gr: number;
  Ra: number;
  Nu: number;
  flowRegime: string;
  maxDeltaT: number;
  boussinesqValid: boolean;
}

/** 无量纲数诊断（特征长度 = 机箱截面水力直径 2wh/(w+h)，见方机箱即边长；特征温差 = 最热元件 − 环境） */
export function calculateCFDDiagnostics(s: Solver): CFDDiag {
  const A = s.AIR;
  const [sw, sh] = chassisSizeMm(s.layout).map((v) => v / 1000);
  const L = sw * ((2 * sh) / (sw + sh)); // 见方时括号内恰为 1
  const { uC, vC } = s.getCellVelocity();
  const inside = s.geo.insideMask;
  let sum = 0;
  let n = 0;
  if (inside.length) {
    for (const i of inside) sum += Math.sqrt(uC[i] * uC[i] + vC[i] * vC[i]);
    n = inside.length;
  } else {
    for (let i = 0; i < s.N; i++) {
      if (s.geo.obstacle[i] !== 0) continue;
      sum += Math.sqrt(uC[i] * uC[i] + vC[i] * vC[i]);
      n++;
    }
  }
  const V = (sum / n) * s.VEL_SCALE;
  const deltaT = mmax(5, s.sensorTemp('max') - s.T_amb);
  const Re = (A.rho * V * L) / A.mu;
  const Gr = (A.g * A.beta * deltaT * L ** 3) / A.nu ** 2;
  const Ra = Gr * A.Pr;
  const NuFree = 0.59 * mmax(Ra, 1e-6) ** 0.25;
  const NuForced = 0.023 * mmax(Re, 1) ** 0.8 * A.Pr ** 0.4;
  const Nu = Math.cbrt(NuFree ** 3 + NuForced ** 3);
  let flowRegime = Re < 2300 ? '层流' : Re < 4000 ? '过渡' : '湍流';
  const Ri = Gr / (Re * Re + 1);
  if (Ri > 10) flowRegime += ' | 自然对流主导';
  else if (Ri > 0.1) flowRegime += ' | 混合对流';
  else flowRegime += ' | 强制对流主导';
  let maxT = -Infinity;
  if (inside.length) for (const i of inside) maxT = mmax(maxT, s.T_fluid[i]);
  else for (let i = 0; i < s.N; i++) maxT = mmax(maxT, s.T_fluid[i]);
  const maxDeltaT = maxT - s.T_amb;
  const boussinesqValid = maxDeltaT <= 30;
  if (!boussinesqValid) flowRegime += ' | ⚠ΔT>30K Boussinesq超限';
  return { Re, Gr, Ra, Nu, flowRegime, maxDeltaT, boussinesqValid };
}

/** 机箱内风速 < 0.1 m/s 的滞流区占比 */
export function deadZoneRatio(s: Solver): number {
  const inside = s.geo.insideMask;
  if (!inside.length) return 0;
  const { uC, vC } = s.getCellVelocity();
  let c = 0;
  for (const i of inside) if (Math.sqrt(uC[i] * uC[i] + vC[i] * vC[i]) * s.VEL_SCALE < 0.1) c++;
  return c / inside.length;
}

export interface NoiseTotal {
  dbTotal: number;
  perFan: number[];
  parts: NoiseParts[];
  /** 评分用的感知噪音：时转时停的风扇按转动时的声级 + 间歇性修正 */
  ratingDb: number;
}

/** 听音位置总声压级：各风扇能量叠加 L = 10·log10(Σ 10^(Li/10)) */
export function totalNoise(s: Solver): NoiseTotal {
  const ac = s.geo.acoustics;
  const parts = s.fans.map((f) => f.getNoise(s, ac));
  const perFan = parts.map((p) => p.total);
  // 停转的风扇为 −Inf，不计入
  if (perFan.some((v) => Number.isNaN(v) || v === Infinity)) throw new Error('风扇噪音出现非有限值，检查布局 acoustics 参数');
  let e = 0;
  for (const v of perFan) e += 10 ** (v / 10);
  let er = 0;
  for (const f of s.fans) er += 10 ** (f.ratingNoise(s, ac) / 10);
  return { dbTotal: 10 * Math.log10(mmax(e, 1)), perFan, parts, ratingDb: 10 * Math.log10(mmax(er, 1)) };
}

export interface FanStatus {
  name: string;
  role: string;
  rpm: number;
  cfm: number; // 当前流场穿盘中面的流量绝对值 [CFM]
  freeCfm: number;
  dp: number;
  qRatio: number;
  noiseDb: number;
  noise: NoiseParts;
  sharePct: number;
  stopped: boolean; // 低温停转 / 半被动停转中
  cycling: boolean; // 时转时停（最近 cycleWindowS 秒内启停切换 ≥ 2 次）
}

const MOUNT_CN: Record<string, string> = { front: '前', rear: '后', top: '顶', bottom: '底', internal: '' };
const POS_CN: Record<string, string> = { front: '前', mid: '中', rear: '后' };

/** 全部风扇的实时状态（机箱风扇在前，内置风扇在后） */
export function fanStatusList(s: Solver): FanStatus[] {
  const { perFan, parts } = totalNoise(s);
  let eSum = 0;
  for (const v of perFan) eSum += 10 ** (v / 10);
  let nGpu = 0;
  const nCpu = s.fans.filter((f) => f.g.role === 'cpu').length;
  return s.fans.map((f, k) => {
    const g = f.g;
    let name: string;
    switch (g.role) {
      case 'case':
        name = `${MOUNT_CN[g.mount]}${g.type === 'intake' ? '进气' : '排气'} ${g.model}`;
        break;
      case 'cpu':
        name = nCpu > 1 ? `CPU 塔扇（${POS_CN[g.pos]}）` : 'CPU 塔扇';
        break;
      case 'gpu':
        nGpu++;
        name = `显卡风扇 ${nGpu}`;
        break;
      default:
        name = '电源风扇';
    }
    return {
      name,
      role: g.role,
      rpm: f.getRPM(s),
      cfm: Math.abs(s.diskFlow(g)) * CFM_PER_M3S,
      freeCfm: f.getCFM(s),
      dp: f.lastDp,
      qRatio: f.noiseQRatio,
      noiseDb: perFan[k],
      noise: parts[k],
      sharePct: (100 * 10 ** (perFan[k] / 10)) / mmax(eSum, Number.EPSILON),
      stopped: f.isStopped(s),
      cycling: f.isCycling(s, s.geo.acoustics),
    };
  });
}

/** MATLAB round（0.5 远离零） */
const mr = (x: number) => (x < 0 ? -Math.round(-x) : Math.round(x));

export type ScoreClass = 'office' | 'gaming' | 'heavy';

export interface Scores {
  total: number;
  perf: number; // 性能：频率保持率
  thermal: number; // 温度：距温度墙
  noise: number; // 噪音：响度
  airflow: number; // 风道：机箱热阻
  cls: ScoreClass;
  clsName: string; // 办公 / 游戏 / 满载
  perfPct: number; // 名义功率加权的频率保持率 [%]（0.1 精度）
  freqCpu: number; // 频率比 φ（缺该元件为 NaN）
  freqGpu: number;
  airK: number; // 机箱热阻 K [°C / 100 W]
  cpuTemp: number;
  gpuTemp: number;
  psuTemp: number;
  noiseDb: number;
  /** 评分用的感知噪音（含时转时停修正），取整 */
  noiseRatingDb: number;
  totalPrice: number;
  totalCFM: number;
  intake: number;
  topExhaust: number;
  internalAmbient: number;
  rearExhaust: number;
}

/**
 * 评分（v4.6.0 起，同 CFDSolverBase.calculateScores）：按 CPU+GPU 名义功率归入 办公 / 游戏 / 满载 档，四项 0–100 加权：
 *   性能  频率保持率 φw（按名义功率加权）：90% → 0、100% → 100
 *   温度  (T_limit − Tj)/(T_limit − T_amb)（环境温度 → 100、降频阈 → 0），CPU、GPU 平均；结温超过 tjmax 记 0；电源超过告警温度再 −20
 *   噪音  感知噪音（时转时停的风扇 +intermittentDb）的响度 2^((dB − 40)/10)：10 dB(A) → 100、45 dB(A) → 0
 *   风道  K = ΔT_eff/(P/100 W)，ΔT_eff = ½·箱内温升 + ½·CPU/GPU 进风温升均值；按对数 K ≤ 1 → 100、2 → 75、4 → 50、≥ 16 → 0
 *   权重（性能/温度/噪音/风道）：办公 10/15/60/15，游戏 25/25/35/15，满载 35/30/20/15
 */
export function calculateScores(s: Solver): Scores {
  const temps = computeAirflowTemperatures(s);
  const clamp01 = (x: number) => mmax(0, mmin(1, x));
  const { dbTotal, ratingDb } = totalNoise(s);
  let totalPrice = 0;
  for (const f of caseFans(s)) totalPrice += f.spec.price;
  let pNom = 0;
  let pAct = 0;
  let wPhi = 0;
  const therm: number[] = [];
  const rise: number[] = [];
  const freq = { cpu: NaN, gpu: NaN };
  for (const n of ['cpu', 'gpu'] as const) {
    const net = s.thermalNetworks[n];
    if (!net) continue;
    pNom += net.power;
    pAct += net.actualPower;
    wPhi += net.power * net.freqRatio;
    freq[n] = net.freqRatio;
    if (net.T_junction > net.tjmax) therm.push(0);
    else therm.push(100 * clamp01((net.throttlingTemp - net.T_junction) / mmax(net.throttlingTemp - s.T_amb, 1)));
    const inIdx = n === 'cpu' ? s.geo.cpuInletIdx : s.geo.gpuInletIdx;
    let sum = 0;
    for (const i of inIdx) sum += s.T_fluid[i];
    rise.push(sum / inIdx.length - s.T_amb);
  }
  const mean = (v: number[]) => v.reduce((a, b) => a + b, 0) / v.length;
  const phiW = pNom > 0 ? wPhi / pNom : 1;
  const perf = 100 * clamp01((phiW - 0.9) / 0.1);
  let thermal = therm.length ? mean(therm) : 100;
  if (s.thermalNetworks.psu?.overTemp) thermal = mmax(0, thermal - 20);
  const nl = (db: number) => 2 ** ((db - 40) / 10);
  const noise = 100 * clamp01((nl(45) - nl(ratingDb)) / (nl(45) - nl(10))); // 感知噪音（含时转时停修正）
  const dInt = temps.internalAmbient - s.T_amb;
  const dEff = rise.length ? 0.5 * dInt + 0.5 * mean(rise) : dInt;
  const airK = pAct > 1 ? dEff / (pAct / 100) : 0;
  const airflow = airK <= 1 ? 100 : 100 * clamp01(1 - Math.log2(airK) / 4);
  let cls: ScoreClass;
  let clsName: string;
  let w: number[];
  if (pNom < 187.5) {
    cls = 'office';
    clsName = '办公';
    w = [0.1, 0.15, 0.6, 0.15];
  } else if (pNom < 400) {
    cls = 'gaming';
    clsName = '游戏';
    w = [0.25, 0.25, 0.35, 0.15];
  } else {
    cls = 'heavy';
    clsName = '满载';
    w = [0.35, 0.3, 0.2, 0.15];
  }
  return {
    total: mr(w[0] * perf + w[1] * thermal + w[2] * noise + w[3] * airflow),
    perf: mr(perf),
    thermal: mr(thermal),
    noise: mr(noise),
    airflow: mr(airflow),
    cls,
    clsName,
    perfPct: mr(1000 * phiW) / 10,
    freqCpu: freq.cpu,
    freqGpu: freq.gpu,
    airK,
    cpuTemp: mr(s.junctionOr('cpu')),
    gpuTemp: mr(s.junctionOr('gpu')),
    psuTemp: mr(s.junctionOr('psu')),
    noiseDb: mr(dbTotal),
    noiseRatingDb: mr(ratingDb),
    totalPrice,
    totalCFM: mr(temps.totalCFM),
    intake: temps.intake,
    topExhaust: temps.topExhaust,
    internalAmbient: temps.internalAmbient,
    rearExhaust: temps.rearExhaust,
  };
}

/** 由机箱风扇标称进/排风量判断机箱压力状态（fan_pressure_label） */
export function fanPressureLabel(qin: number, qout: number): string {
  if (qin <= 0 && qout <= 0) return '无机箱风扇';
  if (qin > 1.1 * qout) return '正压';
  if (qin < 0.9 * qout) return '负压';
  return '平衡';
}

export interface ScenarioSummary {
  cpu: number;
  gpu: number;
  psu: number;
  interior: number;
  cfm: number;
  noiseDb: number;
  score: number;
  scoreCls: string; // 评分档：办公 / 游戏 / 满载
  perfPct: number; // 频率保持率 [%]
  intakeCfm: number;
  exhaustCfm: number;
  pressure: string;
  deadZonePct: number;
  nCaseFans: number;
  steps: number;
}

/** 方案对比用的汇总指标（当前时刻；缺的元件为 NaN） */
export function scenarioSummary(s: Solver): ScenarioSummary {
  const sc = calculateScores(s);
  const t = s.lastTemps ?? computeAirflowTemperatures(s);
  const { dbTotal } = totalNoise(s);
  let qin = 0;
  let qout = 0;
  for (const f of caseFans(s)) {
    if (f.g.type === 'intake') qin += f.getCFM(s);
    else qout += f.getCFM(s);
  }
  const tj = (n: 'cpu' | 'gpu' | 'psu') => s.thermalNetworks[n]?.T_junction ?? NaN;
  return {
    cpu: tj('cpu'),
    gpu: tj('gpu'),
    psu: tj('psu'),
    interior: t.internalAmbient,
    cfm: t.totalCFM,
    noiseDb: dbTotal,
    score: sc.total,
    scoreCls: sc.clsName,
    perfPct: sc.perfPct,
    intakeCfm: qin,
    exhaustCfm: qout,
    pressure: fanPressureLabel(qin, qout),
    deadZonePct: 100 * s.deadZoneRatio,
    nCaseFans: s.geo.nCaseFans,
    steps: s.iteration,
  };
}

/** 相对远场的静压 [Pa]（障碍格为 NaN）：P = ρ·VEL_SCALE·Δx·(p + pProj1)/DT */
export function pressureFieldPa(s: Solver): Float64Array {
  const dx = s.geo.cellMm / 1000;
  const k = (s.AIR.rho * s.VEL_SCALE * dx) / s.DT;
  const P = new Float64Array(s.N);
  for (let i = 0; i < s.N; i++) P[i] = s.geo.obstacle[i] > 0 ? NaN : (s.p[i] + s.pProj1[i]) * k;
  return P;
}

export interface OpeningMarker {
  x: number; // 壁外侧的格坐标（1 基，同 MATLAB）
  y: number;
  mount: Mount;
  kind: Opening['kind'];
  fan: number;
  cfm: number; // > 0 为流出机箱
}

/** 各开口的标注位置与净风量 */
export function openingMarkers(s: Solver): OpeningMarker[] {
  const W = s.W;
  const fl = openingFluxList(s);
  const off = 3 + s.geo.fanDiskCells;
  const out: OpeningMarker[] = [];
  s.geo.openings.forEach((op, k) => {
    if (!op.idx.length) return;
    let sx = 0;
    let sy = 0;
    let xMin = Infinity;
    let xMax = -Infinity;
    let yMin = Infinity;
    let yMax = -Infinity;
    for (const i of op.idx) {
      const yy = (i % W) + 1;
      const xx = Math.floor(i / W) + 1;
      sx += xx;
      sy += yy;
      xMin = mmin(xMin, xx);
      xMax = mmax(xMax, xx);
      yMin = mmin(yMin, yy);
      yMax = mmax(yMax, yy);
    }
    let x = sx / op.idx.length;
    let y = sy / op.idx.length;
    switch (op.mount) {
      case 'front':
        x = xMax + off;
        break;
      case 'rear':
        x = xMin - off;
        break;
      case 'top':
        y = yMin - off;
        break;
      case 'bottom':
        y = yMax + off;
        break;
    }
    out.push({ x, y, mount: op.mount, kind: op.kind, fan: op.fan, cfm: fl[k].cfm });
  });
  return out;
}

export interface CellReadout {
  solid: boolean;
  speed: number; // m/s
  T: number;
  Tsolid: number;
  P: number; // Pa
}

/** 单格读数（idx 为 0 基线性索引） */
export function cellReadout(s: Solver, idx: number): CellReadout {
  const W = s.W;
  const y = idx % W;
  const x = Math.floor(idx / W);
  const u = 0.5 * (s.uF[x * W + y] + s.uF[(x + 1) * W + y]);
  const v = 0.5 * (s.vF[x * (W + 1) + y] + s.vF[x * (W + 1) + y + 1]);
  const p = s.p[idx] + s.pProj1[idx];
  return {
    solid: s.geo.obstacle[idx] > 0,
    speed: Math.hypot(u, v) * s.VEL_SCALE,
    T: s.T_fluid[idx],
    Tsolid: s.T_solid[idx],
    P: (p * s.AIR.rho * s.VEL_SCALE * (s.geo.cellMm / 1000)) / s.DT,
  };
}

export interface Recommendation {
  title: string;
  desc: string;
  level: 'warning' | 'good' | 'info';
}

/** MATLAB sprintf('%d', x)：整数值按整数输出，否则按 %e 输出（这里的参数都是已取整的值） */
const d = (x: number) => String(x);
/** MATLAB sprintf('%.nf') */
const f = (x: number, n: number) => x.toFixed(n);
/** MATLAB sprintf('%g')（这里的参数是短小数） */
const g = (x: number) => String(Number(x.toPrecision(6)));
/** MATLAB sprintf('%+.1f') */
const fp = (x: number) => (x >= 0 ? '+' : '') + x.toFixed(1);

/** 智能诊断建议 */
export function getRecommendations(s: Solver): Recommendation[] {
  const sc = calculateScores(s);
  const recs: Recommendation[] = [];
  const chipRec = [
    { n: 'cpu', nm: 'CPU', good: 60, tip: '建议提高 CPU 塔扇/机箱排风' },
    { n: 'gpu', nm: 'GPU', good: 65, tip: '建议改善显卡下方进风或增加机箱排风' },
  ] as const;
  for (const c of chipRec) {
    const net = s.thermalNetworks[c.n];
    if (!net) continue; // 布局中无此元件：不给建议
    const T = mr(net.T_junction);
    const fpct = mr(100 * net.freqRatio);
    if (net.overTemp)
      recs.push({ title: `${c.nm}过热`, desc: `当前${d(T)}°C，超过 ${d(mr(net.tjmax))}°C，降到最低频率仍压不住，${c.tip}`, level: 'warning' });
    else if (net.throttled)
      recs.push({
        title: `${c.nm}触发温度墙降频`,
        desc: `当前${d(T)}°C，频率降到 ${d(fpct)}%（功率 ${f(net.actualPower, 0)} W），${c.tip}`,
        level: 'warning',
      });
    else if (T > net.throttlingTemp - 5)
      recs.push({
        title: `${c.nm}接近温度墙`,
        desc: `当前${d(T)}°C，距降频阈 ${d(mr(net.throttlingTemp))}°C 不到 5°C，${c.tip}`,
        level: 'warning',
      });
    else if (T < c.good)
      recs.push({ title: `${c.nm}散热余量充足`, desc: `当前${d(T)}°C，频率 ${d(fpct)}%，可适当降低风扇转速以减少噪音`, level: 'good' });
  }
  if (s.thermalNetworks.psu?.overTemp)
    recs.push({ title: '电源温度过高', desc: `当前${d(sc.psuTemp)}°C，超过告警阈值，检查电源进风`, level: 'warning' });
  if (s.deadZoneRatio > 0.3)
    recs.push({
      title: '风道存在滞流死区',
      desc: `风速<0.1m/s 区域占比${f(s.deadZoneRatio * 100, 1)}%，建议调整风扇位置避免气流短路`,
      level: 'warning',
    });
  if (sc.noiseRatingDb > 40) recs.push({ title: '噪音水平偏高', desc: `当前约${d(sc.noiseRatingDb)}dB，建议启用自动温控或更换低噪风扇`, level: 'warning' });
  else if (sc.noiseRatingDb < 25) recs.push({ title: '运行安静', desc: `当前约${d(sc.noiseRatingDb)}dB，噪音控制优秀`, level: 'good' });
  if (sc.airK > 3 && sc.cls !== 'office')
    recs.push({
      title: '机箱风道效率偏低',
      desc: `每 100 W 发热，箱内与进风平均升温 ${f(sc.airK, 1)}°C，建议增加进/排风或避免气流短路`,
      level: 'warning',
    });
  // 时转时停（半被动风扇在启停阈值之间反复启停）
  const fl = fanStatusList(s);
  const ac = s.geo.acoustics;
  for (const [role, nm, sensor, tip] of [
    ['gpu', '显卡风扇', '显卡结温', '可换"性能"档温控曲线（停转阈值更低，风扇更早起转、不易停）或改善显卡下方进风'],
    ['psu', '电源风扇', '电源温度', '电源半被动的启停阈值与温控档位无关；可改善电源进风，让电源温度离开启停阈值'],
  ] as const) {
    if (fl.some((x) => x.cycling && x.role === role))
      recs.push({
        title: `${nm}时转时停`,
        desc: `${sensor}在停转/起转阈值之间来回，风扇反复启停：间歇的噪音比同样大小的持续噪音更容易被注意到（评分按 +${g(ac.intermittentDb)} dB 计）。${tip}`,
        level: 'info',
      });
  }
  if (fl.length) {
    let i = 0;
    for (let k = 1; k < fl.length; k++) if (fl[k].sharePct > fl[i].sharePct) i = k;
    const mx = fl[i].sharePct;
    if (mx > 40) {
      const p = fl[i].noise;
      recs.push({
        title: '主要噪音来源',
        desc: `${fl[i].name} 占总噪音能量 ${f(mx, 0)}%（${f(p.total, 1)} dB：转速 ${f(p.base, 1)}、工作点 ${fp(p.op)}、格栅 ${fp(p.grille)}${p.fin !== 0 ? `、鳍片 ${fp(p.fin)}` : ''}${p.floor >= 0.05 ? `、底噪 ${fp(p.floor)}` : ''}、位置 ${fp(p.pos)}）`,
        level: 'info',
      });
    }
  }
  if (!recs.length) recs.push({ title: '散热配置均衡', desc: '当前风道设计合理，无明显瓶颈', level: 'good' });
  return recs;
}
