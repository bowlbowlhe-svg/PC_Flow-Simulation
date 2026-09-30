// 时间推进求解器（规格 §3–§4；移植自 CFDSolverFEM.m 与 CFDSolverBase.m 的推进部分）。
// 线性系统：压力泊松用稀疏 Cholesky 直接解，扩散系统用修正 IC(0) 预条件 PCG（相对残差 1e−12）；冻结与重装策略与 MATLAB 完全相同（§3.10），
// 因而与标准答案只差线性求解的舍入。
import { mmax, mmin } from '../numerics/mathx';
import type { Layout } from '../model/types';
import { gridInterp2 } from '../numerics/gridInterp2';
import { SPDSolver } from '../numerics/pcg';
import { cholAnalyze, nestedDissectionGrid, SparseCholesky, type CholSymbolic } from '../numerics/cholesky';
import type { CSR } from '../numerics/sparse';
import { buildGeometry, type FanGeom, type Geometry } from './geometry';
import { FanState, type FanControl } from './fan';
import { ThermalNetwork } from './thermal';
import { cellDiffusionMatrix, faceDiffusionMatrix, pressureMatrix } from './operators';

import { AIR_CP, AIR_DENSITY } from './constants';
import { calculateCFDDiagnostics, computeAirflowTemperatures, computeVorticity, deadZoneRatio, type AirflowTemps, type CFDDiag } from './diagnostics';

export { AIR_CP, AIR_DENSITY, CFM_TO_M3S } from './constants';

export interface Air {
  rho: number;
  mu: number;
  nu: number;
  k: number;
  cp: number;
  Pr: number;
  beta: number;
  g: number;
}

export interface SolverOptions {
  gridScale?: number; // 1 = 280²，0.5 = 140²，2 = 560²
  DT?: number;
  powers?: { cpu?: number; gpu?: number; psu?: number }; // psu 为电源输出负载
  /** 压力泊松的解法：'direct'（稀疏 Cholesky，默认）或 'pcg'（IC(0) 预条件，相对残差 1e−12） */
  pressureSolver?: 'direct' | 'pcg';
  /**
   * 扩散系统（速度、温度、k、ω）PCG 的预条件器与相对残差（默认 'mic0'、1e−12）。流场发展后 ν_t 增大、系统变难解：
   * 140² 第 400 步后 IC(0) 平均 24 次迭代，修正 IC(0) 16 次（W0/W1 审计与对比实验）；从静止起的前几十步两者都约 3 次。
   */
  diffusionPrecond?: 'ic0' | 'mic0';
  diffusionTol?: number;
}

const TOL = 1e-12;

/** 冻结矩阵的线性求解器 */
interface LinSolver {
  solve(b: Float64Array, x0?: Float64Array | null): { x: Float64Array; converged: boolean };
}

/** 稀疏 Cholesky 直接解（压力泊松：PCG 需两百多次迭代，直接解每次只需一次前代回代） */
class DirectSolver implements LinSolver {
  private readonly chol: SparseCholesky;
  constructor(A: CSR, sym: CholSymbolic) {
    this.chol = new SparseCholesky(A, sym);
  }
  solve(b: Float64Array): { x: Float64Array; converged: boolean } {
    const x = this.chol.solve(b);
    return { x, converged: x.every(Number.isFinite) };
  }
}

function median(a: Float64Array): number {
  const s = Float64Array.from(a).sort();
  const n = s.length;
  return n % 2 ? s[(n - 1) / 2] : 0.5 * (s[n / 2 - 1] + s[n / 2]);
}

function arraysEqual(a: Float64Array, b: Float64Array): boolean {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
  return true;
}

export class Solver implements FanControl {
  readonly geo: Geometry;
  readonly layout: Layout;
  readonly W: number;
  readonly H: number;
  readonly N: number;
  readonly DT: number;
  readonly VEL_SCALE: number;
  readonly diffScale: number;
  readonly AIR: Air;
  readonly T_amb: number;
  readonly chassisDepthM: number;
  turbulenceModel: Layout['turbulenceModel'];
  turbIntensity = 0.05;
  turbRefVel = 2.0;
  turbUpdateEvery = 1;
  readonly nuTFloor = 1e-10;
  spongeDamping = 0.8;
  nuTCapFactor = 50;
  autoFanEnabled = true;
  fanSpeedRatio = 40;
  reassembleEvery = 5;
  forceReassemble = false;
  powerW: { cpu: number; gpu: number; psu: number };

  // ---- 场 ----
  T_fluid!: Float64Array;
  T_solid!: Float64Array;
  p!: Float64Array;
  pProj1!: Float64Array;
  uF!: Float64Array;
  vF!: Float64Array;
  turbK!: Float64Array;
  turbOmega!: Float64Array;
  iteration = 0;
  nuFieldStep: Float64Array = new Float64Array(0);

  fans: FanState[] = [];
  // ---- 诊断（每次 stepMultiple 结束时更新，同 MATLAB）----
  deadZoneRatio = 0;
  latestVorticity: Float64Array | null = null;
  lastDiag: CFDDiag | null = null;
  lastTemps: AirflowTemps | null = null;
  thermalNetworks: { cpu?: ThermalNetwork; gpu?: ThermalNetwork; psu?: ThermalNetwork } = {};

  // ---- 冻结算子 ----
  private velU: SPDSolver | null = null;
  private velV: SPDSolver | null = null;
  private velUAct: Int32Array = new Int32Array(0);
  private velVAct: Int32Array = new Int32Array(0);
  nuFieldAssembled: Float64Array | null = null;
  nuAsmStep = -Infinity;
  private tempSolver: SPDSolver | null = null;
  alphaFieldAssembled: Float64Array | null = null;
  alphaAsmStep = -Infinity;
  lastAlphaEff = 0;
  private turbKSolver: SPDSolver | null = null;
  private turbWSolver: SPDSolver | null = null;
  nuTAssembled: Float64Array | null = null;
  nuTAsmStep = -Infinity;
  private lastTurbDt = 0;
  private pres0: LinSolver;
  private presDrag: LinSolver | null = null;
  private readonly presSym: CholSymbolic | null;
  private readonly diffOpts: { tol: number; precond: 'ic0' | 'mic0' };
  betaRefU: Float64Array | null = null;
  betaRefV: Float64Array | null = null;
  betaRefStep = -Infinity;

  // ---- 预计算掩码 ----
  private readonly isObs: Uint8Array;
  private readonly isDir: Uint8Array;
  private readonly isPin: Uint8Array;
  private readonly edgeMissing: Uint8Array;
  private readonly wallAdjFluidIdx: Int32Array;
  private readonly wallAdjCaseIdx: Int32Array;
  private readonly buoyV: Uint8Array;
  private readonly dirT: Float64Array; // 按格的定温壁温度（非定温壁为 NaN）

  constructor(layout: Layout, opts: SolverOptions = {}) {
    const gridScale = opts.gridScale ?? 1;
    this.DT = opts.DT ?? 0.005;
    this.layout = layout;
    this.geo = buildGeometry(layout, gridScale, this.DT);
    const g = this.geo;
    this.W = g.W;
    this.H = g.H;
    this.N = g.N;
    this.VEL_SCALE = g.VEL_SCALE;
    this.diffScale = g.diffScale;
    this.T_amb = layout.ambientC ?? 25;
    this.turbulenceModel = layout.turbulenceModel ?? 'komega';
    this.chassisDepthM = layout.chassis.depthM;
    this.AIR = { rho: 1.184, mu: 1.81e-5, nu: 1.56e-5, k: 0.026, cp: 1005, Pr: 0.71, beta: 3.4e-3, g: 9.81, ...(layout.air ?? {}) };
    const pw = layout.power ?? { cpu: 0, gpu: 0, psu: 0 };
    this.powerW = { cpu: opts.powers?.cpu ?? pw.cpu, gpu: opts.powers?.gpu ?? pw.gpu, psu: opts.powers?.psu ?? pw.psu };

    const { W, H, N } = this;
    this.isObs = new Uint8Array(N);
    for (const i of g.obsIdx) this.isObs[i] = 1;
    this.isDir = new Uint8Array(N);
    this.dirT = new Float64Array(N).fill(NaN);
    g.dirichletIdx.forEach((i, k) => {
      this.isDir[i] = 1;
      this.dirT[i] = g.dirichletT[k];
    });
    this.isPin = new Uint8Array(N);
    for (const i of g.obsIdx) this.isPin[i] = 1;
    for (const i of g.farFieldPresIdx) this.isPin[i] = 1;
    for (const i of g.presRefIdx) this.isPin[i] = 1;
    this.edgeMissing = new Uint8Array(N);
    for (let i = 0; i < N; i++) {
      const y = i % W;
      const x = Math.floor(i / W);
      this.edgeMissing[i] = 4 - ((y > 0 ? 1 : 0) + (y < W - 1 ? 1 : 0) + (x > 0 ? 1 : 0) + (x < H - 1 ? 1 : 0));
    }
    const isCaseWall = new Uint8Array(N);
    for (const i of g.caseWallIdx) isCaseWall[i] = 1;
    const adjObs: number[] = [];
    const adjCase: number[] = [];
    for (let i = 0; i < N; i++) {
      if (this.isObs[i]) continue;
      const y = i % W;
      const x = Math.floor(i / W);
      const nb = [x > 0 ? i - W : -1, y > 0 ? i - 1 : -1, y < W - 1 ? i + 1 : -1, x < H - 1 ? i + W : -1];
      let o = false;
      let c = false;
      for (const j of nb) {
        if (j < 0) continue;
        if (this.isObs[j]) o = true;
        if (isCaseWall[j]) c = true;
      }
      if (o) adjObs.push(i);
      if (c) adjCase.push(i);
    }
    this.wallAdjFluidIdx = Int32Array.from(adjObs);
    this.wallAdjCaseIdx = Int32Array.from(adjCase);
    // 浮力作用面：两侧有一侧在机箱内或机箱外真实空气区（海绵环除外）的格间激活 v 面
    const buoyM = new Uint8Array(N);
    for (const i of g.insideMask) buoyM[i] = 1;
    for (const i of g.liveOutsideMask) buoyM[i] = 1;
    this.buoyV = new Uint8Array((W + 1) * H);
    for (let x = 0; x < H; x++) {
      for (let yf = 1; yf < W; yf++) {
        const k = x * (W + 1) + yf;
        if ((buoyM[x * W + yf - 1] || buoyM[x * W + yf]) && g.vFaceActive[k]) this.buoyV[k] = 1;
      }
    }
    this.diffOpts = { tol: opts.diffusionTol ?? TOL, precond: opts.diffusionPrecond ?? 'mic0' };
    const P0 = pressureMatrix(W, H, g.uFaceActive, g.vFaceActive, null, null, this.isPin);
    this.presSym = (opts.pressureSolver ?? 'direct') === 'direct' ? cholAnalyze(P0, nestedDissectionGrid(W, H)) : null;
    this.pres0 = this.pressureSolverFor(P0);
    this.initState();
  }

  private pressureSolverFor(A: CSR): LinSolver {
    return this.presSym ? new DirectSolver(A, this.presSym) : new SPDSolver(A, { tol: TOL });
  }

  /** 场、风扇、热网络与冻结算子回到初始状态（MATLAB reset 的场部分） */
  initState(): void {
    const { N, W, H } = this;
    this.p = new Float64Array(N);
    this.pProj1 = new Float64Array(N);
    this.T_fluid = new Float64Array(N).fill(this.T_amb);
    this.T_solid = new Float64Array(N).fill(this.T_amb);
    this.uF = new Float64Array(W * (H + 1));
    this.vF = new Float64Array((W + 1) * H);
    this.iteration = 0;
    const betaStar = 0.09;
    const k0 = 1.5 * (this.turbIntensity * this.turbRefVel) ** 2;
    const w0 = k0 / (betaStar * this.AIR.nu);
    this.turbK = new Float64Array(N).fill(k0);
    this.turbOmega = new Float64Array(N).fill(w0);
    this.velU = this.velV = null;
    this.nuFieldAssembled = null;
    this.nuAsmStep = -Infinity;
    this.tempSolver = null;
    this.alphaFieldAssembled = null;
    this.alphaAsmStep = -Infinity;
    this.turbKSolver = this.turbWSolver = null;
    this.nuTAssembled = null;
    this.nuTAsmStep = -Infinity;
    this.lastTurbDt = 0;
    this.presDrag = null;
    this.betaRefU = this.betaRefV = null;
    this.betaRefStep = -Infinity;
    this.fans = this.geo.fans.map((f) => new FanState(f));
    this.initHeatSources();
    this.latestVorticity = new Float64Array(N);
    this.deadZoneRatio = 0;
    this.lastDiag = null;
    this.lastTemps = null;
  }

  private initHeatSources(): void {
    const L = this.layout;
    const nets: Solver['thermalNetworks'] = {};
    if (L.cpu) nets.cpu = new ThermalNetwork('cpu', this.powerW.cpu, L.cpu.tjmax, L.cpu.throttleTemp, L.cpu.thermal);
    if (L.gpu) nets.gpu = new ThermalNetwork('gpu', this.powerW.gpu, L.gpu.tjmax, L.gpu.throttleTemp, L.gpu.thermal);
    if (L.psu) {
      const net = new ThermalNetwork('psu', this.psuLossW(this.powerW.psu), L.psu.warnTemp + 15, L.psu.warnTemp, null);
      net.canThrottle = false; // 电源不降频：超温只告警
      net.R_internal = L.psu.R_internal;
      nets.psu = net;
    }
    for (const n of Object.values(nets)) {
      n!.T_junction = this.T_amb;
      n!.T_theory_f = this.T_amb;
    }
    this.thermalNetworks = nets;
  }

  /** 电源损耗 = 负载·(1/η − 1)，η 按负载率在效率曲线上线性插值（两端取端点） */
  psuLossW(loadW: number): number {
    const P = this.layout.psu!;
    const ld = P.effCurve.load;
    const ef = P.effCurve.eff;
    const f = mmin(mmax(loadW / P.ratedW, ld[0]), ld[ld.length - 1]);
    let i = 0;
    while (i < ld.length - 2 && f > ld[i + 1]) i++;
    const eta = ef[i] + ((f - ld[i]) / (ld[i + 1] - ld[i])) * (ef[i + 1] - ef[i]);
    return loadW * (1 / eta - 1);
  }

  /** 修改元件功率（psu 为电源输出负载） */
  setComponentPower(name: 'cpu' | 'gpu' | 'psu', watts: number): void {
    this.powerW[name] = watts;
    const net = this.thermalNetworks[name];
    if (!net) return;
    net.power = name === 'psu' ? this.psuLossW(watts) : watts;
    net.actualPower = net.power;
    net.throttlingRatio = 0;
  }

  junctionOr(name: 'cpu' | 'gpu' | 'psu'): number {
    return this.thermalNetworks[name]?.T_junction ?? this.T_amb;
  }

  sensorTemp(sensor: FanGeom['sensor']): number {
    switch (sensor) {
      case 'cpu':
      case 'gpu':
      case 'psu':
        return this.junctionOr(sensor);
      default:
        return mmax(this.junctionOr('cpu'), this.junctionOr('gpu'));
    }
  }

  // ================= 速度读取 =================
  getCellVelocity(): { uC: Float64Array; vC: Float64Array } {
    const { W, H, N } = this;
    const uC = new Float64Array(N);
    const vC = new Float64Array(N);
    for (let x = 0; x < H; x++) {
      for (let y = 0; y < W; y++) {
        const i = x * W + y;
        uC[i] = 0.5 * (this.uF[x * W + y] + this.uF[(x + 1) * W + y]);
        vC[i] = 0.5 * (this.vF[x * (W + 1) + y] + this.vF[x * (W + 1) + y + 1]);
      }
    }
    return { uC, vC };
  }

  /** 穿过风扇盘中面的体积流量 [m³/s]（送风方向为正） */
  diskFlow(f: FanGeom): number {
    const W = this.W;
    const dA = (this.geo.cellMm / 1000) * this.chassisDepthM;
    let s = 0;
    if (f.normal[0] !== 0) {
      const t = f.cols[1] - f.cols[0] + 1;
      const xf = f.cols[0] + Math.floor(t / 2); // 1 基面列
      const sg = Math.sign(f.normal[0]);
      for (let r = f.rows[0]; r <= f.rows[1]; r++) s += sg * this.uF[(xf - 1) * W + (r - 1)];
    } else {
      const t = f.rows[1] - f.rows[0] + 1;
      const yf = f.rows[0] + Math.floor(t / 2);
      const sg = Math.sign(f.normal[1]);
      for (let c = f.cols[0]; c <= f.cols[1]; c++) s += sg * this.vF[(c - 1) * (W + 1) + (yf - 1)];
    }
    return s * this.VEL_SCALE * dA;
  }

  // ================= 湍流粘性 =================
  /** 应变率模 |S| [1/s]、局部速度 [m/s]、壁面距离 [m] */
  computeStrainRate(): { S: Float64Array; V: Float64Array; yW: Float64Array } {
    const { W, H, N } = this;
    const vs = this.VEL_SCALE;
    const cellM = this.geo.cellMm / 1000;
    const invDx = 1 / cellM;
    const { uC, vC } = this.getCellVelocity();
    const S = new Float64Array(N);
    const V = new Float64Array(N);
    for (let x = 0; x < H; x++) {
      for (let y = 0; y < W; y++) {
        const i = x * W + y;
        const dudx = (this.uF[(x + 1) * W + y] * vs - this.uF[x * W + y] * vs) * invDx;
        const dvdy = (this.vF[x * (W + 1) + y + 1] * vs - this.vF[x * (W + 1) + y] * vs) * invDx;
        let dudy = 0;
        let dvdx = 0;
        if (y > 0 && y < W - 1 && x > 0 && x < H - 1) {
          dudy = 0.5 * (uC[i + 1] * vs - uC[i - 1] * vs) * invDx;
          dvdx = 0.5 * (vC[i + W] * vs - vC[i - W] * vs) * invDx;
        }
        S[i] = Math.sqrt(2 * (dudx * dudx + dvdy * dvdy) + (dudy + dvdx) * (dudy + dvdx));
        const um = uC[i] * vs;
        const vm = vC[i] * vs;
        V[i] = Math.sqrt(um * um + vm * vm);
      }
    }
    return { S, V, yW: this.geo.wallDistanceM };
  }

  /** 有效粘性 ν_eff = ν + ν_t（障碍格取 ν） */
  computeNuEff(sr?: { S: Float64Array; V: Float64Array; yW: Float64Array }): Float64Array {
    const nu = this.AIR.nu;
    const N = this.N;
    const out = new Float64Array(N);
    if (this.turbulenceModel === 'laminar') return out.fill(nu);
    const r = sr ?? this.computeStrainRate();
    if (this.turbulenceModel === 'komega') {
      const a1 = 0.31;
      for (let i = 0; i < N; i++) {
        let nt = (a1 * this.turbK[i]) / mmax(a1 * this.turbOmega[i], r.S[i]);
        nt = mmin(nt, 2000 * nu);
        out[i] = nu + nt;
      }
    } else {
      // LVEL 零方程
      for (let i = 0; i < N; i++) {
        const yp = mmax((r.yW[i] * r.V[i]) / nu, 0);
        const D = 1 - Math.exp(-yp / 26);
        const lm = 0.4 * r.yW[i] * D;
        const nt = mmin(lm * lm * r.S[i], this.nuTCapFactor * nu);
        out[i] = mmin(nu + nt, 30 * nu);
      }
    }
    for (const i of this.geo.obsIdx) out[i] = nu;
    return out;
  }

  turbulenceInletValues(): { kIn: number; wIn: number } {
    const kIn = 1.5 * (this.turbIntensity * this.turbRefVel) ** 2;
    return { kIn, wIn: kIn / (0.09 * 10 * this.AIR.nu) };
  }

  // ================= 单步推进 =================
  fluidStep(): void {
    let sr: ReturnType<Solver['computeStrainRate']> | null = null;
    let nuEff: Float64Array;
    if (this.turbulenceModel === 'laminar') nuEff = this.computeNuEff();
    else {
      sr = this.computeStrainRate();
      nuEff = this.computeNuEff(sr);
    }
    // ---- 动量 ----
    this.diffuseVelocity(nuEff);
    this.project();
    this.advectFaces();
    this.applyBuoyancy();
    const uRef = this.uF.slice();
    const vRef = this.vF.slice();
    this.applyFanForces();
    this.projectWithDrag(uRef, vRef);
    for (let k = 0; k < this.uF.length; k++) if (this.geo.uFaceRing[k]) this.uF[k] = this.uF[k] * this.spongeDamping;
    for (let k = 0; k < this.vF.length; k++) if (this.geo.vFaceRing[k]) this.vF[k] = this.vF[k] * this.spongeDamping;
    // ---- 湍流 ----
    if (this.turbulenceModel === 'komega' && this.iteration % this.turbUpdateEvery === 0) this.stepTurbulence(sr!.S);
    // ---- 温度：扩散 → 平流 → 边界 → 注热 ----
    const alpha = new Float64Array(this.N);
    for (let i = 0; i < this.N; i++) alpha[i] = nuEff[i] / this.AIR.Pr;
    this.diffuseTemperature(alpha);
    const { uC, vC } = this.getCellVelocity();
    this.T_fluid = this.advectScalar(this.T_fluid, uC, vC, this.T_amb, this.DT);
    this.clampMin(this.T_fluid, this.T_amb);
    this.setDisplayObstacleTemps();
    for (const i of this.geo.spongeRingIdx) this.T_fluid[i] = this.T_amb;
    this.solveConjugateHeatTransfer();
    // min(T, 200) 再 max(T, T_amb)（MATLAB 语义：NaN 先变为 200）
    for (let i = 0; i < this.N; i++) this.T_fluid[i] = mmax(mmin(this.T_fluid[i], 200), this.T_amb);
    for (const i of this.geo.spongeRingIdx) this.T_fluid[i] = this.T_amb;
    this.iteration++;
  }

  /** 推进 n 步并更新诊断（死区、涡量、无量纲数、温度汇总） */
  stepMultiple(n: number): { deadRatio: number; diag: CFDDiag; temps: AirflowTemps } {
    for (let s = 0; s < n; s++) this.fluidStep();
    this.latestVorticity = computeVorticity(this);
    this.deadZoneRatio = deadZoneRatio(this);
    this.lastDiag = calculateCFDDiagnostics(this);
    this.lastTemps = computeAirflowTemperatures(this);
    return { deadRatio: this.deadZoneRatio, diag: this.lastDiag, temps: this.lastTemps };
  }

  /** a = max(a, v)（MATLAB 语义：NaN 取 v） */
  private clampMin(a: Float64Array, v: number): void {
    for (let i = 0; i < a.length; i++) if (!(a[i] >= v)) a[i] = v;
  }

  // ---- 速度扩散（§3.2）----
  private diffuseVelocity(nuEff: Float64Array): void {
    const nu = this.AIR.nu;
    const nuField = new Float64Array(this.N);
    for (let i = 0; i < this.N; i++) nuField[i] = mmax(nuEff[i], nu);
    this.nuFieldStep = nuField;
    const g = this.geo;
    if (
      this.forceReassemble ||
      !this.nuFieldAssembled ||
      (this.iteration - this.nuAsmStep >= this.reassembleEvery && !arraysEqual(nuField, this.nuFieldAssembled))
    ) {
      const U = faceDiffusionMatrix(nuField, true, this.W, this.H, g.uFaceActive, this.DT, this.diffScale);
      const V = faceDiffusionMatrix(nuField, false, this.W, this.H, g.vFaceActive, this.DT, this.diffScale);
      this.velU = new SPDSolver(U.A, this.diffOpts);
      this.velV = new SPDSolver(V.A, this.diffOpts);
      this.velUAct = U.actIdx;
      this.velVAct = V.actIdx;
      this.nuFieldAssembled = nuField;
      this.nuAsmStep = this.iteration;
    }
    for (let k = 0; k < this.uF.length; k++) if (!g.uFaceActive[k]) this.uF[k] = 0;
    for (let k = 0; k < this.vF.length; k++) if (!g.vFaceActive[k]) this.vF[k] = 0;
    this.solveFaces(this.velU!, this.velUAct, this.uF);
    this.solveFaces(this.velV!, this.velVAct, this.vF);
  }

  private solveFaces(sol: SPDSolver, act: Int32Array, f: Float64Array): void {
    const n = act.length;
    const b = new Float64Array(n);
    const x0 = new Float64Array(n);
    for (let a = 0; a < n; a++) {
      x0[a] = f[act[a]];
      b[a] = f[act[a]] / this.DT;
    }
    const r = sol.solve(b, x0);
    this.checkSolve(r.converged, 'velocity', r.x);
    for (let a = 0; a < n; a++) f[act[a]] = r.x[a];
  }

  private checkSolve(ok: boolean, what: string, x?: Float64Array): void {
    if (ok) return;
    if (x && !x.every(Number.isFinite)) throw new Error(`计算发散：${what} 求解出现非有限值（第 ${this.iteration + 1} 步）`);
    throw new Error(`线性求解未收敛：${what}（第 ${this.iteration + 1} 步）`);
  }

  // ---- 第一次投影（§3.3）----
  private project(): void {
    const { W, H, N } = this;
    const g = this.geo;
    const uA = g.uFaceActive;
    const vA = g.vFaceActive;
    const rhs = new Float64Array(N);
    for (let x = 0; x < H; x++) {
      for (let y = 0; y < W; y++) {
        const i = x * W + y;
        const uR = (x + 1) * W + y;
        const uL = x * W + y;
        const vD = x * (W + 1) + y + 1;
        const vU = x * (W + 1) + y;
        const div = this.uF[uR] * uA[uR] - this.uF[uL] * uA[uL] + this.vF[vD] * vA[vD] - this.vF[vU] * vA[vU];
        rhs[i] = this.isPin[i] ? 0 : -div;
      }
    }
    const r = this.pres0.solve(rhs, this.pProj1);
    this.checkSolve(r.converged, 'pressure', r.x);
    const p = r.x;
    for (const i of g.obsIdx) p[i] = 0;
    for (const i of g.farFieldPresIdx) p[i] = 0;
    this.p = p;
    this.pProj1 = p.slice();
    const velCap = 6.0 / this.VEL_SCALE;
    for (let xf = 0; xf <= H; xf++) {
      for (let y = 0; y < W; y++) {
        const k = xf * W + y;
        let u = this.uF[k];
        if (xf >= 1 && xf <= H - 1) u = u - 1.0 * (p[xf * W + y] - p[(xf - 1) * W + y]) * uA[k];
        if (!uA[k]) u = 0;
        this.uF[k] = mmax(-velCap, mmin(velCap, u));
      }
    }
    for (let x = 0; x < H; x++) {
      for (let yf = 0; yf <= W; yf++) {
        const k = x * (W + 1) + yf;
        let v = this.vF[k];
        if (yf >= 1 && yf <= W - 1) v = v - 1.0 * (p[x * W + yf] - p[x * W + yf - 1]) * vA[k];
        if (!vA[k]) v = 0;
        this.vF[k] = mmax(-velCap, mmin(velCap, v));
      }
    }
  }

  // ---- 面场半拉格朗日平流（§3.4）----
  private advectFaces(): void {
    const { W, H } = this;
    const g = this.geo;
    const dt0 = this.DT * (W - 2);
    const uM = this.uF;
    const vM = this.vF;
    const nU = W * (H + 1);
    const nV = (W + 1) * H;
    const XqU = new Float64Array(nU);
    const YqU = new Float64Array(nU);
    for (let xf = 0; xf <= H; xf++) {
      for (let y = 0; y < W; y++) {
        const yUp = y < W - 1 ? y + 1 : W - 1;
        let va: number;
        if (xf === 0) va = 0.5 * (vM[y] + vM[yUp]);
        else if (xf === H) va = 0.5 * (vM[(H - 1) * (W + 1) + y] + vM[(H - 1) * (W + 1) + yUp]);
        else {
          const c0 = (xf - 1) * (W + 1);
          const c1 = xf * (W + 1);
          va = 0.25 * (vM[c0 + y] + vM[c0 + yUp] + vM[c1 + y] + vM[c1 + yUp]);
        }
        const k = xf * W + y;
        const xq = xf + 0.5 - dt0 * uM[k]; // XuG = xf0 + 0.5（1 基 0.5:H+0.5）
        const yq = y + 1 - dt0 * va;
        XqU[k] = mmax(1.0, mmin(H, xq));
        YqU[k] = mmax(1.5, mmin(W - 0.5, yq));
      }
    }
    const uNew = gridInterp2(uM, W, H + 1, YqU, XqU, 'cubic', 1, 0.5);
    const XqV = new Float64Array(nV);
    const YqV = new Float64Array(nV);
    for (let x = 0; x < H; x++) {
      for (let yf = 0; yf <= W; yf++) {
        let ua: number;
        if (yf === 0) ua = 0.5 * (uM[x * W] + uM[(x + 1) * W]);
        else if (yf === W) ua = 0.5 * (uM[x * W + W - 1] + uM[(x + 1) * W + W - 1]);
        else ua = 0.25 * (uM[x * W + yf - 1] + uM[(x + 1) * W + yf - 1] + uM[x * W + yf] + uM[(x + 1) * W + yf]);
        const k = x * (W + 1) + yf;
        const xq = x + 1 - dt0 * ua;
        const yq = yf + 0.5 - dt0 * vM[k];
        XqV[k] = mmax(1.5, mmin(H - 0.5, xq));
        YqV[k] = mmax(1.0, mmin(W, yq));
      }
    }
    const vNew = gridInterp2(vM, W + 1, H, YqV, XqV, 'cubic', 0.5, 1);
    for (let k = 0; k < nU; k++) if (!g.uFaceActive[k]) uNew[k] = 0;
    for (let k = 0; k < nV; k++) if (!g.vFaceActive[k]) vNew[k] = 0;
    this.uF = uNew;
    this.vF = vNew;
  }

  /** 格心标量半拉格朗日平流（makima）；回溯点出域取来流值；障碍格值先换为最近流体格值 */
  advectScalar(d0: Float64Array, uvel: Float64Array, vvel: Float64Array, inflow: number, dt: number): Float64Array {
    const { W, H, N } = this;
    const dt0 = dt * (W - 2);
    const Xq = new Float64Array(N);
    const Yq = new Float64Array(N);
    const out = new Uint8Array(N);
    for (let x = 0; x < H; x++) {
      for (let y = 0; y < W; y++) {
        const i = x * W + y;
        const xq = x + 1 - dt0 * uvel[i];
        const yq = y + 1 - dt0 * vvel[i];
        out[i] = xq < 1.5 || xq > W - 0.5 || yq < 1.5 || yq > H - 0.5 ? 1 : 0;
        Xq[i] = mmax(1.5, mmin(W - 0.5, xq));
        Yq[i] = mmax(1.5, mmin(H - 0.5, yq));
      }
    }
    const d = d0.slice();
    const nf = this.geo.nearestFluidIdx;
    if (nf.length) for (const i of this.geo.obsIdx) d[i] = d0[nf[i]];
    const r = gridInterp2(d, W, H, Yq, Xq, 'makima', 1, 1);
    for (let i = 0; i < N; i++) if (out[i]) r[i] = inflow;
    return r;
  }

  // ---- 浮力（§3.5）----
  private applyBuoyancy(): void {
    const { W, H } = this;
    const T = this.T_fluid;
    const { g: grav, beta } = this.AIR;
    for (let x = 0; x < H; x++) {
      for (let yf = 1; yf < W; yf++) {
        const k = x * (W + 1) + yf;
        if (!this.buoyV[k]) continue;
        const Tf = 0.5 * (T[x * W + yf - 1] + T[x * W + yf]);
        const f = (-this.DT * grav * beta * (Tf - this.T_amb)) / this.VEL_SCALE;
        this.vF[k] = this.vF[k] + f * 1;
      }
    }
  }

  // ---- 风扇执行盘（§3.6）----
  private applyFanForces(): void {
    const { W, H } = this;
    const dU = new Float64Array(W * (H + 1));
    const dV = new Float64Array((W + 1) * H);
    for (const fan of this.fans) {
      const f = fan.g;
      const dp = fan.updateOperatingPoint(this.diskFlow(f), this, this.DT);
      const du = ((dp / (AIR_DENSITY * f.thickM)) * this.DT) / this.VEL_SCALE;
      for (let c = f.cols[0]; c <= f.cols[1]; c++) {
        for (let r = f.rows[0]; r <= f.rows[1]; r++) {
          if (r < 1 || r > W || c < 1 || c > H) continue;
          if (this.geo.obstacle[(c - 1) * W + (r - 1)] !== 0) continue;
          if (f.normal[0] !== 0) {
            const val = 0.5 * du * f.normal[0];
            dU[(c - 1) * W + (r - 1)] += val;
            dU[c * W + (r - 1)] += val;
          }
          if (f.normal[1] !== 0) {
            const val = 0.5 * du * f.normal[1];
            dV[(c - 1) * (W + 1) + (r - 1)] += val;
            dV[(c - 1) * (W + 1) + r] += val;
          }
        }
      }
    }
    const g = this.geo;
    for (let k = 0; k < dU.length; k++) this.uF[k] = this.uF[k] + dU[k] * g.uFaceActive[k];
    for (let k = 0; k < dV.length; k++) this.vF[k] = this.vF[k] + dV[k] * g.vFaceActive[k];
  }

  // ---- 阻力耦合投影（§3.3、§3.7）----
  private projectWithDrag(uRef: Float64Array, vRef: Float64Array): void {
    const { W, H, N } = this;
    const g = this.geo;
    const nU = W * (H + 1);
    const nV = (W + 1) * H;
    const bU = new Float64Array(nU);
    const bV = new Float64Array(nV);
    for (let k = 0; k < nU; k++) bU[k] = 1 / (1 + g.uDragCoef[k] * Math.abs(uRef[k]));
    for (let k = 0; k < nV; k++) bV[k] = 1 / (1 + g.vDragCoef[k] * Math.abs(vRef[k]));
    let rebuild = !this.presDrag || this.forceReassemble;
    if (!rebuild && this.iteration - this.betaRefStep >= 5) {
      // 两组：多孔区面、开口格栅面（只计流体激活面）
      for (const grille of [false, true]) {
        let sum = 0;
        let big = 0;
        let n = 0;
        for (let k = 0; k < nU; k++) {
          if (g.uDragCoef[k] > 0 && g.uFaceActive[k] && (g.uGrilleFace[k] === 1) === grille) {
            const rel = Math.abs(bU[k] - this.betaRefU![k]) / this.betaRefU![k];
            sum += rel;
            if (rel > 0.1) big++;
            n++;
          }
        }
        for (let k = 0; k < nV; k++) {
          if (g.vDragCoef[k] > 0 && g.vFaceActive[k] && (g.vGrilleFace[k] === 1) === grille) {
            const rel = Math.abs(bV[k] - this.betaRefV![k]) / this.betaRefV![k];
            sum += rel;
            if (rel > 0.1) big++;
            n++;
          }
        }
        if (n > 0 && (sum / n > 0.03 || big / n > 0.02)) rebuild = true;
      }
    }
    if (rebuild) {
      this.betaRefU = bU;
      this.betaRefV = bV;
      this.betaRefStep = this.iteration;
      this.presDrag = this.pressureSolverFor(pressureMatrix(W, H, g.uFaceActive, g.vFaceActive, bU, bV, this.isPin));
    }
    const BU = this.betaRefU!;
    const BV = this.betaRefV!;
    const us = new Float64Array(nU);
    const vs = new Float64Array(nV);
    for (let k = 0; k < nU; k++) us[k] = this.uF[k] * BU[k] * g.uFaceActive[k];
    for (let k = 0; k < nV; k++) vs[k] = this.vF[k] * BV[k] * g.vFaceActive[k];
    const rhs = new Float64Array(N);
    for (let x = 0; x < H; x++) {
      for (let y = 0; y < W; y++) {
        const i = x * W + y;
        const div = us[(x + 1) * W + y] - us[x * W + y] + vs[x * (W + 1) + y + 1] - vs[x * (W + 1) + y];
        rhs[i] = this.isPin[i] ? 0 : -div;
      }
    }
    const r = this.presDrag!.solve(rhs, this.p);
    this.checkSolve(r.converged, 'drag pressure', r.x);
    const p = r.x;
    for (const i of g.obsIdx) p[i] = 0;
    for (const i of g.farFieldPresIdx) p[i] = 0;
    this.p = p;
    const velCap = 6.0 / this.VEL_SCALE;
    for (let xf = 0; xf <= H; xf++) {
      for (let y = 0; y < W; y++) {
        const k = xf * W + y;
        let u = us[k];
        if (xf >= 1 && xf <= H - 1) u = us[k] - BU[k] * (p[xf * W + y] - p[(xf - 1) * W + y]) * g.uFaceActive[k];
        if (!g.uFaceActive[k]) u = 0;
        this.uF[k] = mmax(-velCap, mmin(velCap, u));
      }
    }
    for (let x = 0; x < H; x++) {
      for (let yf = 0; yf <= W; yf++) {
        const k = x * (W + 1) + yf;
        let v = vs[k];
        if (yf >= 1 && yf <= W - 1) v = vs[k] - BV[k] * (p[x * W + yf] - p[x * W + yf - 1]) * g.vFaceActive[k];
        if (!g.vFaceActive[k]) v = 0;
        this.vF[k] = mmax(-velCap, mmin(velCap, v));
      }
    }
  }

  // ---- k-ω（§3.8）----
  private stepTurbulence(Svec: Float64Array): void {
    const betaS = 0.09;
    const beta1 = 0.0708;
    const alphaW = 5 / 9;
    const sigK = 0.6;
    const sigW = 0.5;
    const nu = this.AIR.nu;
    const dt = this.DT * this.turbUpdateEvery;
    const { N } = this;
    const gs = this.diffScale;
    const { kIn, wIn } = this.turbulenceInletValues();
    const a1 = 0.31;
    const nuT = new Float64Array(N);
    for (let i = 0; i < N; i++) {
      let v = (a1 * this.turbK[i]) / mmax(a1 * this.turbOmega[i], Svec[i]);
      nuT[i] = mmin(v, 2000 * nu);
    }
    for (const i of this.geo.obsIdx) nuT[i] = 0;
    const { uC, vC } = this.getCellVelocity();
    const kA = this.advectScalar(this.turbK, uC, vC, kIn, dt);
    const wA = this.advectScalar(this.turbOmega, uC, vC, wIn, dt);
    for (let i = 0; i < N; i++) {
      kA[i] = mmax(kA[i], this.nuTFloor);
      wA[i] = mmax(wA[i], 1e-6);
    }
    if (
      this.forceReassemble ||
      !this.turbKSolver ||
      this.lastTurbDt !== dt ||
      (this.iteration - this.nuTAsmStep >= this.reassembleEvery && !arraysEqual(nuT, this.nuTAssembled!))
    ) {
      const wK = new Float64Array(N);
      const wW = new Float64Array(N);
      for (let i = 0; i < N; i++) {
        wK[i] = nu + sigK * nuT[i];
        wW[i] = nu + sigW * nuT[i];
      }
      this.turbKSolver = new SPDSolver(cellDiffusionMatrix(wK, this.W, this.H, this.isObs, null, dt, gs), this.diffOpts);
      this.turbWSolver = new SPDSolver(cellDiffusionMatrix(wW, this.W, this.H, this.isObs, null, dt, gs), this.diffOpts);
      this.nuTAssembled = nuT;
      this.nuTAsmStep = this.iteration;
      this.lastTurbDt = dt;
    }
    const rhsK = new Float64Array(N);
    const rhsW = new Float64Array(N);
    for (let i = 0; i < N; i++) {
      if (this.isObs[i]) continue;
      rhsK[i] = kA[i] / dt;
      rhsW[i] = wA[i] / dt;
    }
    const rk = this.turbKSolver!.solve(rhsK, this.turbK);
    const rw = this.turbWSolver!.solve(rhsW, this.turbOmega);
    this.checkSolve(rk.converged, 'k', rk.x);
    this.checkSolve(rw.converged, 'ω', rw.x);
    const kD = rk.x;
    const wD = rw.x;
    const kNew = new Float64Array(N);
    const wNew = new Float64Array(N);
    for (let i = 0; i < N; i++) {
      const k = mmax(kD[i], this.nuTFloor);
      const w = mmax(wD[i], 1e-6);
      let Pk = nuT[i] * Svec[i] * Svec[i];
      Pk = mmin(Pk, 20 * betaS * k * mmax(w, 1e-6));
      const wFl = mmax(w, 1e-6);
      const kEq = Pk / (betaS * wFl);
      const kn = kEq + (k - kEq) * Math.exp(-betaS * wFl * dt);
      const wn = (w + dt * alphaW * (w / k) * Pk) / (1 + dt * beta1 * w);
      kNew[i] = mmax(kn, this.nuTFloor);
      wNew[i] = mmin(mmax(wn, 1e-6), 1e8);
    }
    for (const i of this.geo.obsIdx) {
      kNew[i] = this.nuTFloor;
      wNew[i] = wIn;
    }
    const cellM = this.geo.cellMm / 1000;
    for (const i of this.wallAdjFluidIdx) {
      const yW = mmax(this.geo.wallDistanceM[i], 0.5 * cellM);
      wNew[i] = (6 * nu) / (beta1 * yW * yW);
    }
    for (const i of this.wallAdjCaseIdx) kNew[i] = this.nuTFloor;
    for (const i of this.geo.spongeRingIdx) {
      kNew[i] = kIn;
      wNew[i] = wIn;
    }
    this.turbK = kNew;
    this.turbOmega = wNew;
  }

  // ---- 温度扩散（§3.9）----
  private diffuseTemperature(alphaEff: Float64Array): void {
    const { N } = this;
    const g = this.geo;
    const aMol = this.AIR.nu / this.AIR.Pr;
    const alphaField = new Float64Array(N);
    for (let i = 0; i < N; i++) alphaField[i] = mmax(alphaEff[i], aMol);
    const alphaVal = median(alphaField);
    const stale =
      !this.alphaFieldAssembled ||
      (this.iteration - this.alphaAsmStep >= this.reassembleEvery && !arraysEqual(alphaField, this.alphaFieldAssembled));
    if (this.forceReassemble || stale) {
      this.tempSolver = new SPDSolver(cellDiffusionMatrix(alphaField, this.W, this.H, this.isObs, this.isDir, this.DT, this.diffScale), this.diffOpts);
      this.alphaFieldAssembled = alphaField;
      this.alphaAsmStep = this.iteration;
      this.lastAlphaEff = alphaVal;
    }
    const aA = this.alphaFieldAssembled!;
    const gs = this.diffScale;
    const invDt = 1 / this.DT;
    const T = this.T_fluid;
    const rhs = new Float64Array(N);
    const { W, H } = this;
    for (let i = 0; i < N; i++) {
      if (this.isObs[i]) {
        rhs[i] = this.isDir[i] ? invDt * this.dirT[i] : invDt * T[i];
        continue;
      }
      let r = T[i] / this.DT;
      // 域外 ghost 取环境温度
      r = r + gs * this.edgeMissing[i] * aA[i] * this.T_amb;
      // 定温壁耦合（Dirichlet）
      const y = i % W;
      const x = Math.floor(i / W);
      const nb = [x > 0 ? i - W : -1, y > 0 ? i - 1 : -1, y < W - 1 ? i + 1 : -1, x < H - 1 ? i + W : -1];
      let corr = 0;
      for (const j of nb) if (j >= 0 && this.isDir[j]) corr += 0.5 * (aA[i] + aA[j]) * this.dirT[j];
      rhs[i] = r + gs * corr;
    }
    const res = this.tempSolver!.solve(rhs, T);
    this.checkSolve(res.converged, 'temperature', res.x);
    this.T_fluid = res.x;
    this.clampMin(this.T_fluid, this.T_amb);
    void g;
  }

  /** 障碍格温度只作显示：定温壁取壁温；发热元件固体格取 T_solid；其余绝热障碍取 4 邻域流体格均值 */
  private setDisplayObstacleTemps(): void {
    const { W, H } = this;
    const g = this.geo;
    const T = this.T_fluid;
    for (const i of g.dirichletIdx) T[i] = this.dirT[i];
    if (g.adiabaticObsIdx.length) {
      const src = T.slice();
      for (const i of g.adiabaticObsIdx) {
        const y = i % W;
        const x = Math.floor(i / W);
        let s = 0;
        let c = 0;
        // 与 MATLAB 相同的累加次序：上、下、左、右
        if (y > 0 && g.obstacle[i - 1] === 0) {
          s += src[i - 1];
          c++;
        }
        if (y < W - 1 && g.obstacle[i + 1] === 0) {
          s += src[i + 1];
          c++;
        }
        if (x > 0 && g.obstacle[i - W] === 0) {
          s += src[i - W];
          c++;
        }
        if (x < H - 1 && g.obstacle[i + W] === 0) {
          s += src[i + W];
          c++;
        }
        T[i] = c > 0 ? s / c : this.T_amb;
      }
    }
    for (const i of g.heatObsIdx) T[i] = this.T_solid[i];
  }

  // ---- 共轭传热（§4）----
  private rhoCpCell(): number {
    const cm = this.geo.cellMm / 1000;
    return AIR_DENSITY * AIR_CP * cm * cm * this.chassisDepthM;
  }

  private solveConjugateHeatTransfer(): void {
    const { uC, vC } = this.getCellVelocity();
    const speed = new Float64Array(this.N);
    for (let i = 0; i < this.N; i++) speed[i] = Math.sqrt(uC[i] * uC[i] + vC[i] * vC[i]) * this.VEL_SCALE;
    const rc = this.rhoCpCell();
    const g = this.geo;
    const W = this.W;
    const rectCells = (r: { x: number; y: number; w: number; h: number }) => {
      const out: number[] = [];
      for (let x = mmax(1, r.x); x <= mmin(this.H, r.x + r.w - 1); x++)
        for (let y = mmax(1, r.y); y <= mmin(W, r.y + r.h - 1); y++) out.push((x - 1) * W + (y - 1));
      return out;
    };
    const nets = this.thermalNetworks;
    if (nets.cpu && g.cpu) {
      this.solveComponent(nets.cpu, g.cpuInletIdx, g.cpuFinIdx, speed, rc);
      for (const i of rectCells(g.cpu.base)) this.T_solid[i] = nets.cpu.T_junction;
      for (const i of g.cpuFinIdx) this.T_solid[i] = nets.cpu.T_sink_base;
    }
    if (nets.gpu && g.gpu) {
      this.solveComponent(nets.gpu, g.gpuInletIdx, g.gpuFinIdx, speed, rc);
      for (const i of rectCells(g.gpu.pcb)) this.T_solid[i] = nets.gpu.T_junction;
      for (const i of g.gpuFinIdx) this.T_solid[i] = nets.gpu.T_sink_base;
    }
    if (nets.psu && g.psu) {
      this.solveComponent(nets.psu, g.psuInletIdx, g.psuInteriorIdx, speed, rc);
      for (const i of rectCells(g.psu.body)) this.T_solid[i] = nets.psu.T_junction;
    }
  }

  private solveComponent(net: ThermalNetwork, inlet: Int32Array, body: Int32Array, speed: Float64Array, rc: number): void {
    let sT = 0;
    for (const i of inlet) sT += this.T_fluid[i];
    const Tamb = sT / inlet.length;
    let sV = 0;
    for (const i of body) sV += speed[i];
    const V = sV / body.length;
    net.solve(V, Tamb, this.DT);
    const w = new Float64Array(body.length);
    let sw = 0;
    body.forEach((i, k) => {
      w[k] = 0.25 + 0.75 * mmin(1, speed[i] / 1.5);
      sw += w[k];
    });
    body.forEach((i, k) => {
      const dT = (net.actualPower * (w[k] / sw) * this.DT) / rc;
      this.T_fluid[i] = this.T_fluid[i] + dT;
    });
  }
}
