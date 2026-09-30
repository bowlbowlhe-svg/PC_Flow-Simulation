// 诊断量（移植自 CFDSolverBase：openingFlux / computeAirflowTemperatures / computeVorticity /
// calculateCFDDiagnostics / totalNoise / fanStatusList / calculateScores / scenarioSummary /
// pressureFieldPa / openingMarkers / cellReadout / getRecommendations）。只读求解器状态，不改变推进结果。
import type { Mount } from '../model/types';
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
    volOut += Math.max(0, v);
    volIn += Math.max(0, -v);
    Q += (Tf - amb) * v;
  }
  vol *= dA;
  volOut *= dA;
  volIn *= dA;
  Q = rhoCp * Q * dA;
  let Tmean = amb;
  if (vol > 1e-6) Tmean = Math.min(Math.max(amb + Q / (rhoCp * vol), amb), 150);
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
  const mixT = (hv: number[]) => amb + (hv[0] / Math.max(rhoCp * hv[1], Number.EPSILON)) * (hv[1] > 1e-6 ? 1 : 0);
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

/** 无量纲数诊断（特征长度 = 机箱边长，特征温差 = 最热元件 − 环境） */
export function calculateCFDDiagnostics(s: Solver): CFDDiag {
  const A = s.AIR;
  const L = s.layout.chassis.sizeMm / 1000;
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
  const deltaT = Math.max(5, s.sensorTemp('max') - s.T_amb);
  const Re = (A.rho * V * L) / A.mu;
  const Gr = (A.g * A.beta * deltaT * L ** 3) / A.nu ** 2;
  const Ra = Gr * A.Pr;
  const NuFree = 0.59 * Math.max(Ra, 1e-6) ** 0.25;
  const NuForced = 0.023 * Math.max(Re, 1) ** 0.8 * A.Pr ** 0.4;
  const Nu = Math.cbrt(NuFree ** 3 + NuForced ** 3);
  let flowRegime = Re < 2300 ? '层流' : Re < 4000 ? '过渡' : '湍流';
  const Ri = Gr / (Re * Re + 1);
  if (Ri > 10) flowRegime += ' | 自然对流主导';
  else if (Ri > 0.1) flowRegime += ' | 混合对流';
  else flowRegime += ' | 强制对流主导';
  let maxT = -Infinity;
  if (inside.length) for (const i of inside) maxT = Math.max(maxT, s.T_fluid[i]);
  else for (let i = 0; i < s.N; i++) maxT = Math.max(maxT, s.T_fluid[i]);
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
}

/** 听音位置总声压级：各风扇能量叠加 L = 10·log10(Σ 10^(Li/10)) */
export function totalNoise(s: Solver): NoiseTotal {
  const parts = s.fans.map((f) => f.getNoise(s, s.geo.acoustics));
  const perFan = parts.map((p) => p.total);
  if (perFan.some((v) => !Number.isFinite(v))) throw new Error('风扇噪音出现非有限值，检查布局 acoustics 参数');
  let e = 0;
  for (const v of perFan) e += 10 ** (v / 10);
  return { dbTotal: 10 * Math.log10(Math.max(e, 1)), perFan, parts };
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
}

const MOUNT_CN: Record<string, string> = { front: '前', rear: '后', top: '顶', bottom: '底', internal: '' };

/** 全部风扇的实时状态（机箱风扇在前，内置风扇在后） */
export function fanStatusList(s: Solver): FanStatus[] {
  const { perFan, parts } = totalNoise(s);
  let eSum = 0;
  for (const v of perFan) eSum += 10 ** (v / 10);
  let nGpu = 0;
  return s.fans.map((f, k) => {
    const g = f.g;
    let name: string;
    switch (g.role) {
      case 'case':
        name = `${MOUNT_CN[g.mount]}${g.type === 'intake' ? '进气' : '排气'} ${g.model}`;
        break;
      case 'cpu':
        name = 'CPU 塔扇';
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
      sharePct: (100 * 10 ** (perFan[k] / 10)) / Math.max(eSum, Number.EPSILON),
    };
  });
}

interface NetLike {
  T_junction: number;
  throttlingTemp: number;
  power: number;
  actualPower: number;
}

/** 元件热网络；缺该元件时返回环境温度、零功率的占位 */
function netOrIdle(s: Solver, name: 'cpu' | 'gpu'): NetLike {
  return s.thermalNetworks[name] ?? { T_junction: s.T_amb, throttlingTemp: 95, power: 0, actualPower: 0 };
}

/** MATLAB round（0.5 远离零） */
const mr = (x: number) => (x < 0 ? -Math.round(-x) : Math.round(x));

export interface Scores {
  total: number;
  cooling: number;
  performance: number;
  balance: number;
  margin: number;
  noise: number;
  value: number;
  cpuTemp: number;
  gpuTemp: number;
  psuTemp: number;
  noiseDb: number;
  totalPrice: number;
  totalCFM: number;
  intake: number;
  topExhaust: number;
  internalAmbient: number;
  rearExhaust: number;
}

/** 六维评分（锚定节流阈） */
export function calculateScores(s: Solver): Scores {
  const temps = computeAirflowTemperatures(s);
  const tnC = netOrIdle(s, 'cpu');
  const tnG = netOrIdle(s, 'gpu');
  const cpuT = tnC.T_junction;
  const gpuT = tnG.T_junction;
  const psuT = s.junctionOr('psu');
  const { dbTotal } = totalNoise(s);
  let totalPrice = 0;
  for (const f of caseFans(s)) totalPrice += f.spec.price;
  const clamp = (v: number) => Math.max(0, Math.min(100, v));
  const cpuCool = clamp(((tnC.throttlingTemp - cpuT) / (tnC.throttlingTemp - 60)) * 100);
  const gpuCool = clamp(((tnG.throttlingTemp - gpuT) / (tnG.throttlingTemp - 70)) * 100);
  const cooling = 0.5 * cpuCool + 0.5 * gpuCool;
  const pNom = tnC.power + tnG.power;
  const pAct = tnC.actualPower + tnG.actualPower;
  const performance = clamp(((pAct / Math.max(pNom, Number.EPSILON) - 0.65) / 0.35) * 100);
  const balance = Math.max(0, 100 - Math.abs(cpuT - gpuT) * 2);
  const cpuHead = Math.max(0, (tnC.throttlingTemp - cpuT) / (tnC.throttlingTemp - s.T_amb));
  const gpuHead = Math.max(0, (tnG.throttlingTemp - gpuT) / (tnG.throttlingTemp - s.T_amb));
  const margin = 100 * (0.5 * cpuHead + 0.5 * gpuHead);
  const noise = clamp(100 - (dbTotal - 20) * 3);
  const value = Math.max(0, 100 - totalPrice / 15);
  const total = mr(cooling * 0.25 + performance * 0.2 + balance * 0.1 + margin * 0.15 + noise * 0.2 + value * 0.1);
  return {
    total,
    cooling: mr(cooling),
    performance: mr(performance),
    balance: mr(balance),
    margin: mr(margin),
    noise: mr(noise),
    value: mr(value),
    cpuTemp: mr(cpuT),
    gpuTemp: mr(gpuT),
    psuTemp: mr(psuT),
    noiseDb: mr(dbTotal),
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
      xMin = Math.min(xMin, xx);
      xMax = Math.max(xMax, xx);
      yMin = Math.min(yMin, yy);
      yMax = Math.max(yMax, yy);
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
/** MATLAB sprintf('%+.1f') */
const fp = (x: number) => (x >= 0 ? '+' : '') + x.toFixed(1);

/** 智能诊断建议 */
export function getRecommendations(s: Solver): Recommendation[] {
  const sc = calculateScores(s);
  const recs: Recommendation[] = [];
  const tnC = netOrIdle(s, 'cpu');
  const tnG = netOrIdle(s, 'gpu');
  const hasCpu = !!s.thermalNetworks.cpu;
  const hasGpu = !!s.thermalNetworks.gpu;
  if (hasCpu) {
    if (sc.cpuTemp > tnC.throttlingTemp - 5)
      recs.push({ title: 'CPU温度过高', desc: `当前${d(sc.cpuTemp)}°C，接近降频阈值，建议提高 CPU 风扇/机箱排风`, level: 'warning' });
    else if (sc.cpuTemp < 60) recs.push({ title: 'CPU散热余量充足', desc: `当前${d(sc.cpuTemp)}°C，可适当降低风扇转速以减少噪音`, level: 'good' });
  }
  if (hasGpu) {
    if (sc.gpuTemp > tnG.throttlingTemp - 5)
      recs.push({ title: 'GPU温度过高', desc: `当前${d(sc.gpuTemp)}°C，建议改善显卡下方进风或增加机箱排风`, level: 'warning' });
    else if (sc.gpuTemp < 65) recs.push({ title: 'GPU散热良好', desc: `当前${d(sc.gpuTemp)}°C，散热配置合理`, level: 'good' });
  }
  if (s.thermalNetworks.psu?.overTemp)
    recs.push({ title: '电源温度过高', desc: `当前${d(sc.psuTemp)}°C，超过告警阈值，检查电源进风`, level: 'warning' });
  if (s.deadZoneRatio > 0.3)
    recs.push({
      title: '风道存在滞流死区',
      desc: `风速<0.1m/s 区域占比${f(s.deadZoneRatio * 100, 1)}%，建议调整风扇位置避免气流短路`,
      level: 'warning',
    });
  if (sc.noiseDb > 40) recs.push({ title: '噪音水平偏高', desc: `当前约${d(sc.noiseDb)}dB，建议启用自动温控或更换低噪风扇`, level: 'warning' });
  else if (sc.noiseDb < 25) recs.push({ title: '运行安静', desc: `当前约${d(sc.noiseDb)}dB，噪音控制优秀`, level: 'good' });
  if (sc.balance < 70 && hasCpu && hasGpu)
    recs.push({ title: 'CPU/GPU温度不均衡', desc: '温差较大，建议优化风道使热量均匀排出', level: 'warning' });
  const fl = fanStatusList(s);
  if (fl.length) {
    let i = 0;
    for (let k = 1; k < fl.length; k++) if (fl[k].sharePct > fl[i].sharePct) i = k;
    const mx = fl[i].sharePct;
    if (mx > 40) {
      const p = fl[i].noise;
      recs.push({
        title: '主要噪音来源',
        desc: `${fl[i].name} 占总噪音能量 ${f(mx, 0)}%（${f(p.total, 1)} dB：转速 ${f(p.base, 1)}、工作点 ${fp(p.op)}、格栅 ${fp(p.grille)}、位置 ${fp(p.pos)}）`,
        level: 'info',
      });
    }
  }
  if (!recs.length) recs.push({ title: '散热配置均衡', desc: '当前风道设计合理，无明显瓶颈', level: 'good' });
  return recs;
}
