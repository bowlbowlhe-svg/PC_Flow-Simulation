// 元件热网络（移植自 DetailedThermalNetwork.m；规格 §4）：串联热阻 + 一阶热惯性 + 频率与功率控制。
import { mmax, mmin } from '../numerics/mathx';
import type { ComponentThermal, Dvfs } from '../model/types';
import { layoutHeatCoef, type HeatCoef } from '../model/quasi3d';

export class ThermalNetwork {
  power: number; // 名义发热功率 P_nom [W]（电源为损耗）
  actualPower: number; // 实际发热功率 [W]
  freqRatio = 1; // 频率比 φ（CPU/GPU；电源恒为 1）
  throttled = false; // 温度墙在起作用
  readonly tjmax: number;
  readonly throttlingTemp: number; // CPU/GPU 的温度墙；电源为告警温度
  T_junction = 25;
  T_sink_base = 25;
  h_conv = 50;
  readonly tau = 0.25; // 结温惯性时间常数 [s]
  canThrottle = true; // false（电源）：不降频，超温只置 overTemp
  overTemp = false;
  R_internal = 0.8;
  R_total = 0;
  /** 鳍片对流系数参数（CPU/GPU；电源不用） */
  readonly heat: HeatCoef | null;

  constructor(
    readonly name: 'cpu' | 'gpu' | 'psu',
    power: number,
    tjmax: number,
    throttling: number | undefined | null,
    readonly thermal: ComponentThermal | null, // 电源为 null
    readonly dvfs: Dvfs | null = null,
  ) {
    this.power = power;
    this.actualPower = power;
    this.tjmax = tjmax;
    // 未给或为空（MATLAB isempty）时取 tjmax − 15
    this.throttlingTemp = throttling === undefined || throttling === null ? tjmax - 15 : throttling;
    this.heat = thermal ? layoutHeatCoef(thermal, name) : null;
  }

  /** 推进一步：V 为散热体平均风速 [m/s]，Tamb 为进风温度 [°C] */
  solve(V: number, Tamb: number, dt: number): void {
    const v = mmax(0, V);
    let h: number;
    let R_total: number;
    const th = this.thermal;
    if (th) {
      const hc = this.heat!;
      h = hc.h_free + hc.h_forced * mmin(v, 6) ** hc.h_exp;
      const finT = mmax(th.fin_thickness_mm, 0.1) / 1000;
      const m = Math.sqrt((2 * h) / (200 * finT));
      const Lfin = 0.025;
      const etaF = Math.tanh(m * Lfin) / (m * Lfin + 1e-10);
      const etaO = 1 - (1 - etaF) * 0.8;
      const A = th.A_fin_total_m2 ?? (this.name === 'cpu' ? 0.12 : 0.5);
      const R_conv = 1 / mmax(h * A * etaO, Number.EPSILON);
      R_total = th.R_junction_to_case + th.R_tim + th.R_base + R_conv;
    } else {
      h = 15 + 80 * mmin(v, 4);
      const A = 0.08;
      const R_conv = 1 / mmax(h * A, Number.EPSILON);
      R_total = this.R_internal + R_conv;
    }
    const alpha = mmin(1, dt / this.tau);
    this.R_total = R_total;
    const d = this.canThrottle && th ? this.dvfs : null;
    if (!d) {
      this.freqRatio = 1;
      this.throttled = false;
      this.actualPower = this.power;
    } else {
      const lam = d.leakShare;
      const k = d.powerExp;
      // 漏电在 tjmax 以上不再增加（过热保护；否则无风时与结温正反馈发散）
      const leak = (T: number) => 2 ** ((mmin(T, this.tjmax) - d.leakRefC) / d.leakDoubleC);
      const phiSoft = 1 - d.softSlope * mmax(0, this.T_junction - d.softStartC);
      let phiWall: number;
      if (this.power > 0) {
        // 漏电按当前结温计：结温越高温度墙把频率压得越低（负反馈；同 DetailedThermalNetwork）
        const rhs = (this.throttlingTemp - Tamb) / (this.power * R_total) - lam * leak(this.T_junction);
        phiWall = rhs > 0 ? (rhs / (1 - lam)) ** (1 / k) : 0;
      } else phiWall = Infinity;
      const phiT = mmin(1, mmax(d.minFreq, mmin(phiSoft, phiWall)));
      this.freqRatio = this.freqRatio + alpha * (phiT - this.freqRatio);
      this.throttled = phiWall < phiSoft;
      this.actualPower = this.power * ((1 - lam) * this.freqRatio ** k + lam * leak(this.T_junction));
    }
    const T_ss = Tamb + this.actualPower * R_total;
    this.T_junction = this.T_junction + alpha * (T_ss - this.T_junction);
    this.overTemp = this.canThrottle ? this.T_junction > this.tjmax : this.T_junction > this.throttlingTemp;
    this.T_sink_base = th
      ? this.T_junction - this.actualPower * (th.R_junction_to_case + th.R_tim)
      : this.T_junction - this.actualPower * 0.5;
    this.h_conv = h;
  }
}
