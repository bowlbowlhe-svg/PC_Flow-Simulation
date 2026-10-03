// 风扇运行状态（移植自 Fan.m、fan_noise_terms.m；规格 §3.6、§5）。
import { mmax, mmin } from '../numerics/mathx';
import type { Acoustics, FanCurves } from '../model/types';
import { curveDuty } from '../model/fanCurves';
import { pchipEval1 } from '../numerics/pchipEval';
import type { FanGeom } from './geometry';

export const PQ_QGRID = [0, 0.2, 0.4, 0.6, 0.8, 1.0];
export const CFM_PER_M3S = 2118.88;

/** 风扇转速控制所需的求解器上下文 */
export interface FanControl {
  autoFanEnabled: boolean;
  fanSpeedRatio: number; // 全局手动转速 [%]
  fanCurves: FanCurves;
  sensorTemp(sensor: FanGeom['sensor']): number;
  psuLoadRatio(): number;
}

export interface NoiseParts {
  base: number;
  op: number;
  grille: number;
  fin: number;
  pos: number;
  total: number;
}

/** 单扇听音位置声压级分项（fan_noise_terms）：total = base + op + grille + fin + pos（可低于 0；停转 base = −Inf 时为 −Inf） */
export function fanNoiseTerms(base: number, qRatio: number, zeta: number, fin: number, posDb: number, ac: Acoustics): NoiseParts {
  const q = mmin(mmax(qRatio, 0), 2);
  let op = 0;
  if (q < ac.stallQ) op = ac.stallDb * ((ac.stallQ - q) / ac.stallQ) ** 2;
  const grille = 10 * Math.log10(1 + mmax(zeta, 0) / ac.grilleRefZeta);
  const total = base + op + grille + fin + posDb;
  return { base, op, grille, fin, pos: posDb, total };
}

export class FanState {
  lastQ = 0; // 施力前中间流场上的盘流量 [m³/s]
  lastDp = 0; // 工作点静压 [Pa]
  lastQRatio = 0;
  lastFlowFactor = 1;
  noiseQRatio = 1; // 噪音用低通流量比（τ = 0.5 s），初值 1
  stopped = false; // 低温停转（显卡）/ 半被动停转（电源）中；每步由 updateControl 按回差更新
  speedMode: 'auto' | 'manual';
  manualPct: number;

  constructor(readonly g: FanGeom) {
    this.speedMode = g.speedMode;
    this.manualPct = g.manualPct;
  }

  get spec() {
    return this.g.spec;
  }

  /** 转速占空比 ∈ [0, 1]（占满速转速的比例）：本扇固定转速 > 自动温控曲线 > 全局手动转速（同 Fan.duty） */
  duty(c: FanControl): number {
    let d: number;
    if (this.speedMode === 'manual') d = this.manualPct / 100;
    else if (c.autoFanEnabled) d = curveDuty(c.fanCurves[this.curveKey()], c.sensorTemp(this.g.sensor));
    else d = c.fanSpeedRatio / 100;
    return mmin(1, mmax(0, d));
  }

  /** 温控曲线：机箱风扇 caseFan，内置风扇按角色 */
  curveKey(): 'caseFan' | 'cpu' | 'gpu' | 'psu' {
    return this.g.role === 'case' ? 'caseFan' : this.g.role;
  }

  /** 当前是否停转：只在自动温控下、按曲线停转的风扇（显卡低温停转、电源半被动） */
  isStopped(c: FanControl): boolean {
    return this.stopped && this.speedMode === 'auto' && c.autoFanEnabled;
  }

  /** 每步施力前调用一次：按回差更新停转状态（同 Fan.updateControl） */
  updateControl(c: FanControl): void {
    if (!(this.speedMode === 'auto' && c.autoFanEnabled)) {
      this.stopped = false;
      return;
    }
    const cv = c.fanCurves[this.curveKey()];
    const T = c.sensorTemp(this.g.sensor);
    const has = (v: unknown) => v !== undefined && v !== null && v !== '' && !(Array.isArray(v) && v.length === 0); // 同 MATLAB ~isempty
    if (this.g.role === 'gpu' && has(cv.stopBelowC)) {
      this.stopped = this.stopped ? T < cv.startAboveC! : T < cv.stopBelowC!;
    } else if (this.g.role === 'psu' && has(cv.passiveLoad)) {
      if (c.psuLoadRatio() >= cv.passiveLoad!) this.stopped = false;
      else this.stopped = this.stopped ? T < cv.passiveRestartC! : T < cv.passiveMaxC!;
    } else this.stopped = false;
  }

  getRPM(c: FanControl): number {
    const s = this.spec;
    return this.isStopped(c) ? 0 : mmax(s.rpm_min, this.duty(c) * s.rpm_max);
  }

  /** 当前转速下的自由送风量 [CFM]（风扇定律 Q ∝ n） */
  getCFM(c: FanControl): number {
    return this.spec.cfm_max * (this.getRPM(c) / this.spec.rpm_max);
  }

  /** 转速主项：风扇定律 noise_max + 50·log10(n/n_max)；停转为 −Inf */
  baseNoise(c: FanControl): number {
    const rpm = this.getRPM(c);
    return rpm <= 0 ? -Infinity : this.spec.noise_max + 50 * Math.log10(rpm / this.spec.rpm_max);
  }

  getNoise(c: FanControl, ac: Acoustics): NoiseParts {
    const fin = this.g.role === 'cpu' || this.g.role === 'gpu' ? ac.finDb : 0;
    return fanNoiseTerms(this.baseNoise(c), this.noiseQRatio, this.g.grilleZeta, fin, this.g.positionDb, ac);
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
    // 停转期间保持（重新起转时不出现虚假的"近失速"噪音）
    if (!this.isStopped(c)) {
      const aN = mmin(1, DT / 0.5);
      this.noiseQRatio = this.noiseQRatio + aN * (qRatio - this.noiseQRatio);
    }
    return dp;
  }
}
