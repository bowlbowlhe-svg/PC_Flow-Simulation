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
  iteration: number; // 已推进的步数（时转时停判定用）
  DT: number;
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
  floor: number; // 底噪与气动噪音按能量相加后多出的部分
  pos: number;
  total: number;
}

/**
 * 单扇听音位置声压级分项（fan_noise_terms）：aero = base + op + grille + fin，total = 10·log10(10^(aero/10) + 10^(floorDb/10)) + pos，
 * floor = total − aero − pos（可低于 0；停转 base = −Inf 时 total = −Inf、floor = 0）
 */
export function fanNoiseTerms(base: number, qRatio: number, zeta: number, fin: number, posDb: number, ac: Acoustics): NoiseParts {
  const q = mmin(mmax(qRatio, 0), 2);
  let op = 0;
  if (q < ac.stallQ) op = ac.stallDb * ((ac.stallQ - q) / ac.stallQ) ** 2;
  const grille = 10 * Math.log10(1 + mmax(zeta, 0) / ac.grilleRefZeta);
  const aero = base + op + grille + fin;
  if (base === -Infinity) return { base, op, grille, fin, pos: posDb, floor: 0, total: -Infinity };
  const withFloor = 10 * Math.log10(10 ** (aero / 10) + 10 ** (ac.floorDb / 10));
  return { base, op, grille, fin, pos: posDb, floor: withFloor - aero, total: withFloor + posDb };
}

export class FanState {
  lastQ = 0; // 施力前中间流场上的盘流量 [m³/s]
  lastDp = 0; // 工作点静压 [Pa]
  lastQRatio = 0;
  lastFlowFactor = 1;
  noiseQRatio = 1; // 噪音用低通流量比（τ = 0.5 s），初值 1
  stopped = false; // 低温停转（显卡）/ 半被动停转（电源）中；每步由 updateControl 按回差更新
  toggleIter: number[] = []; // 自动温控下启停切换发生的步号（最近 4 次；时转时停判定用）
  lastRunRpm = 0; // 最近一次转动时的转速
  autoResumed = false; // 刚从手动 / 关闭自动温控回到自动温控：这一次判定不记切换
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

  /** 每步施力前调用一次：按回差更新停转状态（同 Fan.updateControl）；record = false 时不记启停（初始化时的首次判定） */
  updateControl(c: FanControl, record = true): void {
    if (!(this.speedMode === 'auto' && c.autoFanEnabled)) {
      // 手动时风扇一直转，不算启停；切换记录清空，回到自动温控后的首次判定也不记（那是模式切换，不是时转时停；同 Fan.m）
      this.stopped = false;
      this.toggleIter = [];
      this.autoResumed = true;
      return;
    }
    if (this.autoResumed) {
      record = false;
      this.autoResumed = false;
    }
    const was = this.stopped;
    const cv = c.fanCurves[this.curveKey()];
    const T = c.sensorTemp(this.g.sensor);
    const has = (v: unknown) => v !== undefined && v !== null && v !== '' && !(Array.isArray(v) && v.length === 0); // 同 MATLAB ~isempty
    if (this.g.role === 'gpu' && has(cv.stopBelowC)) {
      this.stopped = this.stopped ? T < cv.startAboveC! : T < cv.stopBelowC!;
    } else if (this.g.role === 'psu' && has(cv.passiveLoad)) {
      if (c.psuLoadRatio() >= cv.passiveLoad!) this.stopped = false;
      else this.stopped = this.stopped ? T < cv.passiveRestartC! : T < cv.passiveMaxC!;
    } else this.stopped = false;
    if (record && this.stopped !== was) this.toggleIter = [...this.toggleIter.slice(-3), c.iteration];
  }

  /** 时转时停：自动温控下、最近 cycleWindowS 秒（仿真时间）内启停切换 ≥ 2 次（手动转速或关闭自动温控时不算；同 Fan.isCycling） */
  isCycling(c: FanControl, ac: Acoustics): boolean {
    if (!(this.speedMode === 'auto' && c.autoFanEnabled)) return false;
    const w = Math.round(ac.cycleWindowS / c.DT);
    return this.toggleIter.filter((it) => it > c.iteration - w).length >= 2;
  }

  /** 评分用的感知噪音：时转时停的风扇按转动时的声级（停转中取最近一次转动的转速）+ 间歇性修正（同 Fan.ratingNoise） */
  ratingNoise(c: FanControl, ac: Acoustics): number {
    const L = this.getNoise(c, ac).total;
    if (!this.isCycling(c, ac)) return L;
    let rpm = this.getRPM(c);
    if (rpm <= 0) rpm = this.lastRunRpm;
    if (rpm <= 0) return L;
    const fin = this.g.role === 'cpu' || this.g.role === 'gpu' ? ac.finDb : 0;
    const p = fanNoiseTerms(this.spec.noise_max + 50 * Math.log10(rpm / this.spec.rpm_max), this.noiseQRatio, this.g.grilleZeta, fin, this.g.positionDb, ac);
    return p.total + ac.intermittentDb;
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
    if (rpm > 0) this.lastRunRpm = rpm;
    return dp;
  }
}
