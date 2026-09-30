// 风扇运行状态（移植自 Fan.m、fan_noise_terms.m；规格 §3.6、§5）。
import { mmax, mmin } from '../numerics/mathx';
import type { Acoustics } from '../model/types';
import { pchipEval1 } from '../numerics/pchipEval';
import type { FanGeom } from './geometry';

export const PQ_QGRID = [0, 0.2, 0.4, 0.6, 0.8, 1.0];
export const CFM_PER_M3S = 2118.88;

/** 风扇转速控制所需的求解器上下文 */
export interface FanControl {
  autoFanEnabled: boolean;
  fanSpeedRatio: number; // 全局手动转速 [%]
  sensorTemp(sensor: FanGeom['sensor']): number;
}

export interface NoiseParts {
  base: number;
  op: number;
  grille: number;
  pos: number;
  total: number;
}

/** 单扇听音位置声压级分项（fan_noise_terms） */
export function fanNoiseTerms(base: number, qRatio: number, zeta: number, posDb: number, ac: Acoustics): NoiseParts {
  const q = mmin(mmax(qRatio, 0), 2);
  let op = 0;
  if (q < ac.stallQ) op = ac.stallDb * ((ac.stallQ - q) / ac.stallQ) ** 2;
  const grille = 10 * Math.log10(1 + mmax(zeta, 0) / ac.grilleRefZeta);
  return { base, op, grille, pos: posDb, total: base + op + grille + posDb };
}

/** MATLAB interp1(x, v, q, 'linear', 'extrap') */
function interpLinearExtrap(x: number[], v: number[], q: number): number {
  const n = x.length;
  let i = 0;
  if (q >= x[n - 1]) i = n - 2;
  else if (q > x[0]) {
    while (i < n - 2 && q > x[i + 1]) i++;
    // q 恰在节点上时 MATLAB 取该节点所在的区间，值相同
  }
  const t = (q - x[i]) / (x[i + 1] - x[i]);
  return v[i] + t * (v[i + 1] - v[i]);
}

export class FanState {
  lastQ = 0; // 施力前中间流场上的盘流量 [m³/s]
  lastDp = 0; // 工作点静压 [Pa]
  lastQRatio = 0;
  lastFlowFactor = 1;
  noiseQRatio = 1; // 噪音用低通流量比（τ = 0.5 s），初值 1
  speedMode: 'auto' | 'manual';
  manualPct: number;

  constructor(readonly g: FanGeom) {
    this.speedMode = g.speedMode;
    this.manualPct = g.manualPct;
  }

  get spec() {
    return this.g.spec;
  }

  /** 转速比例 ∈ [0, 1]（相对 rpm_min → rpm_max 区间） */
  speedFraction(c: FanControl): number {
    let f: number;
    if (this.speedMode === 'manual') f = this.manualPct / 100;
    else if (c.autoFanEnabled) {
      // 连续温控曲线：55/70/80 °C → 20/50/80%，85 °C 满速，最低 20%
      const T = c.sensorTemp(this.g.sensor);
      const r = interpLinearExtrap([25, 55, 70, 80, 85], [0.2, 0.2, 0.5, 0.8, 1.0], T);
      f = mmin(1.0, mmax(0.2, r));
    } else f = c.fanSpeedRatio / 100;
    return mmin(1, mmax(0, f));
  }

  getRPM(c: FanControl): number {
    const s = this.spec;
    return s.rpm_min + (s.rpm_max - s.rpm_min) * this.speedFraction(c);
  }

  /** 当前转速下的自由送风量 [CFM]（风扇定律 Q ∝ n） */
  getCFM(c: FanControl): number {
    return this.spec.cfm_max * (this.getRPM(c) / this.spec.rpm_max);
  }

  baseNoise(c: FanControl): number {
    const s = this.spec;
    const f = (this.getRPM(c) - s.rpm_min) / mmax(s.rpm_max - s.rpm_min, Number.EPSILON);
    return s.noise_idle + (s.noise_max - s.noise_idle) * f ** 3;
  }

  getNoise(c: FanControl, ac: Acoustics): NoiseParts {
    return fanNoiseTerms(this.baseNoise(c), this.noiseQRatio, this.g.grilleZeta, this.g.positionDb, ac);
  }

  /** 由盘流量 Q [m³/s] 求 P-Q 工作点静压 [Pa] 并更新运行状态 */
  updateOperatingPoint(Q: number, c: FanControl, DT: number): number {
    const s = this.spec;
    const rpm = this.getRPM(c);
    const qFree = (s.cfm_max * (rpm / s.rpm_max)) / CFM_PER_M3S;
    let qRatio = 0;
    if (qFree > 0) qRatio = mmin(2, mmax(0, Q / qFree));
    const pq = s.pq_curve;
    let f: number;
    if (qRatio <= 1) f = pchipEval1(PQ_QGRID, pq, qRatio);
    else {
      const n = pq.length;
      f = pq[n - 1] + ((pq[n - 1] - pq[n - 2]) / (PQ_QGRID[n - 1] - PQ_QGRID[n - 2])) * (qRatio - 1);
    }
    let dp = s.pmax_pa * (rpm / s.rpm_max) ** 2 * f;
    dp = mmax(-s.pmax_pa, mmin(s.pmax_pa, dp));
    this.lastQ = Q;
    this.lastDp = dp;
    this.lastQRatio = qRatio;
    const aFF = mmin(1, DT / 0.15);
    this.lastFlowFactor = this.lastFlowFactor + aFF * (mmin(1, mmax(0.2, qRatio)) - this.lastFlowFactor);
    const aN = mmin(1, DT / 0.5);
    this.noiseQRatio = this.noiseQRatio + aN * (qRatio - this.noiseQRatio);
    return dp;
  }
}
