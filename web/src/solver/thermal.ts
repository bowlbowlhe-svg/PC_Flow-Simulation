// 元件热网络（移植自 DetailedThermalNetwork.m；规格 §4）：串联热阻 + 一阶热惯性 + 节流。
import { mmax, mmin } from '../numerics/mathx';
import type { ComponentThermal } from '../model/types';

export class ThermalNetwork {
  power: number; // 名义发热功率 [W]
  actualPower: number; // 节流后发热功率 [W]
  throttlingRatio = 0;
  readonly tjmax: number;
  readonly throttlingTemp: number;
  T_junction = 25;
  T_sink_base = 25;
  h_conv = 50;
  readonly tau = 0.25; // 结温惯性时间常数 [s]
  T_theory_f = 25;
  canThrottle = true;
  overTemp = false;
  R_internal = 0.8;
  R_total = 0;

  constructor(
    readonly name: 'cpu' | 'gpu' | 'psu',
    power: number,
    tjmax: number,
    throttling: number | undefined | null,
    readonly thermal: ComponentThermal | null, // 电源为 null
  ) {
    this.power = power;
    this.actualPower = power;
    this.tjmax = tjmax;
    // 未给或为空（MATLAB isempty）时取 tjmax − 15
    this.throttlingTemp = throttling === undefined || throttling === null ? tjmax - 15 : throttling;
  }

  /** 推进一步：V 为散热体平均风速 [m/s]，Tamb 为进风温度 [°C] */
  solve(V: number, Tamb: number, dt: number): void {
    const v = mmax(0, V);
    let h: number;
    let R_total: number;
    const th = this.thermal;
    if (th) {
      h = 30 + 130 * mmin(v, 6);
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
    const T_theory = Tamb + this.power * R_total;
    const alpha = mmin(1, dt / this.tau);
    this.T_theory_f = this.T_theory_f + alpha * (T_theory - this.T_theory_f);
    const excess = this.T_theory_f - this.throttlingTemp;
    this.R_total = R_total;
    this.overTemp = excess > 0;
    this.throttlingRatio = excess > 0 && this.canThrottle ? mmin(0.35, (excess / 5) * 0.35) : 0;
    this.actualPower = this.power * (1 - this.throttlingRatio);
    const T_ss = Tamb + this.actualPower * R_total;
    this.T_junction = this.T_junction + alpha * (T_ss - this.T_junction);
    this.T_sink_base = th
      ? this.T_junction - this.actualPower * (th.R_junction_to_case + th.R_tim)
      : this.T_junction - this.actualPower * 0.5;
    this.h_conv = h;
  }
}
