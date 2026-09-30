// 推进到稳态（CFDSolverBase.runToSteady）与固定步数长时统计（tools/steady_long_run.m）。
import { mmax, mmin } from '../numerics/mathx';
import type { Layout } from '../model/types';
import { Solver, type SolverOptions } from './solver';

export interface SteadyOptions {
  minSteps?: number; // 最少步数，默认 2 s 物理时间
  maxSteps?: number; // 最多步数，默认 15 s，严格不超过
  chunk?: number; // 每块步数，默认 50
  window?: number; // 窗口步数，默认 1 s（实际取 chunk 的整数倍）
  tolT?: number; // 结温与内温窗口均值变化 [°C]，默认 0.3
  tolFlow?: number; // 风量窗口均值相对变化，默认 0.03
}

export interface SteadyInfo {
  steps: number;
  converged: boolean;
  aborted: boolean;
  diverged: boolean;
  history: number[][]; // 每块一行：各元件结温、interior、cfm
  columns: string[];
  final: number[]; // 最近一个窗口的均值（稳态结果应取它）
  names: string[];
}

/**
 * 分块推进的稳态判别器：每次 advance() 推进一块并更新判据，便于在 Worker 里逐块汇报进度。
 * 判据：最近两个相邻窗口（各约 window 步）的均值，结温与内温变化 < tolT、风量相对变化 < tolFlow。
 */
export class SteadyRunner {
  readonly opts: Required<SteadyOptions>;
  readonly info: SteadyInfo;
  private readonly nWin: number;
  private readonly startIter: number;
  private readonly names: ('cpu' | 'gpu' | 'psu')[];

  constructor(
    readonly solver: Solver,
    opts: SteadyOptions = {},
  ) {
    const DT = solver.DT;
    const mr = (x: number) => (x < 0 ? -Math.round(-x) : Math.round(x));
    this.opts = {
      minSteps: opts.minSteps ?? mr(2 / DT),
      maxSteps: opts.maxSteps ?? mr(15 / DT),
      chunk: opts.chunk ?? 50,
      window: opts.window ?? mr(1 / DT),
      tolT: opts.tolT ?? 0.3,
      tolFlow: opts.tolFlow ?? 0.03,
    };
    this.nWin = mmax(1, mr(this.opts.window / this.opts.chunk));
    // 列顺序同 MATLAB fieldnames(thermalNetworks)：cpu、gpu、psu 中存在者
    this.names = (['cpu', 'gpu', 'psu'] as const).filter((n) => solver.thermalNetworks[n]);
    this.info = {
      steps: 0,
      converged: false,
      aborted: false,
      diverged: false,
      history: [],
      columns: [...this.names, 'interior', 'cfm'],
      final: new Array(this.names.length + 2).fill(NaN),
      names: [...this.names],
    };
    this.startIter = solver.iteration;
  }

  /** 是否已结束（判稳、发散、中止或到最大步数） */
  get done(): boolean {
    const i = this.info;
    return i.converged || i.diverged || i.aborted || this.solver.iteration - this.startIter >= this.opts.maxSteps;
  }

  abort(): void {
    this.info.aborted = true;
  }

  private chunkN = 0; // 当前块的步数（块开始时确定）
  private inChunk = 0; // 当前块已推进的步数

  /** 当前块已推进 / 应推进的步数（界面进度用） */
  get chunkProgress(): { done: number; total: number } {
    return { done: this.inChunk, total: this.chunkN };
  }

  /**
   * 推进至多 limit 步（缺省推进完整一块）；一块推进完才记录一行并判稳。返回 done。
   * 块内拆成几次推进不改变结果（诊断只读状态）。
   */
  advance(limit = Infinity): boolean {
    if (this.done) return true;
    const s = this.solver;
    const info = this.info;
    if (this.inChunk === 0) this.chunkN = mmin(this.opts.chunk, this.opts.maxSteps - (s.iteration - this.startIter));
    const m = mmin(mmax(1, Math.floor(limit)), this.chunkN - this.inChunk);
    const r = s.stepMultiple(m);
    this.inChunk += m;
    if (this.inChunk < this.chunkN) {
      if (!s.T_fluid.every(Number.isFinite)) info.diverged = true;
      return this.done;
    }
    this.inChunk = 0;
    const row = [...this.names.map((nm) => s.thermalNetworks[nm]!.T_junction), r.temps.internalAmbient, r.temps.totalCFM];
    info.history.push(row);
    info.steps = s.iteration - this.startIter;
    const h = info.history;
    info.final = colMean(h, mmax(0, h.length - this.nWin), h.length);
    if (!row.every(Number.isFinite) || !s.T_fluid.every(Number.isFinite)) {
      info.diverged = true;
      return true;
    }
    if (h.length >= 2 * this.nWin && info.steps >= this.opts.minSteps) {
      const a = colMean(h, h.length - 2 * this.nWin, h.length - this.nWin);
      const b = info.final;
      let dT = 0;
      for (let c = 0; c < b.length - 1; c++) dT = mmax(dT, Math.abs(b[c] - a[c]));
      const e = b.length - 1;
      const dQ = Math.abs(b[e] - a[e]) / mmax(b[e], 1);
      info.converged = dT < this.opts.tolT && dQ < this.opts.tolFlow;
    }
    return this.done;
  }
}

function colMean(h: number[][], r0: number, r1: number): number[] {
  const nc = h[0].length;
  const out = new Array(nc).fill(0);
  for (let r = r0; r < r1; r++) for (let c = 0; c < nc; c++) out[c] += h[r][c];
  for (let c = 0; c < nc; c++) out[c] /= r1 - r0;
  return out;
}

/** 同步推进到稳态。progress(info) 返回 true 则中止。 */
export function runToSteady(s: Solver, opts: SteadyOptions = {}, progress?: (info: SteadyInfo) => boolean | void): SteadyInfo {
  const r = new SteadyRunner(s, opts);
  while (!r.done) {
    r.advance();
    if (r.info.diverged) break;
    if (progress && progress(r.info)) {
      r.abort();
      break;
    }
  }
  return r.info;
}

export interface LongRunOptions {
  steps?: number; // 总步数，默认 3000（15 s）
  avgFrom?: number; // 统计起点步数，默认 1000
  turbUpdateEvery?: number; // 默认 1
  progress?: (info: SteadyInfo) => boolean | void;
}

export interface LongRunResult {
  steps: number;
  avgFrom: number;
  columns: string[];
  history: number[][]; // 每 10 步一行：[步数, 各列瞬时值]
  mean: number[];
  std: number[];
  min: number[];
  max: number[];
  diverged: boolean;
  solver: Solver;
}

/**
 * 固定步数长时推进，取 avgFrom 之后**每一步**瞬时值的统计量作为"稳态"结果（steady_long_run）。
 * powers 为 [CPU, GPU, 电源负载] W。
 */
export function steadyLongRun(
  L: Layout,
  powers: [number, number, number],
  gridScale: number,
  opts: LongRunOptions = {},
  solverOpts: SolverOptions = {},
): LongRunResult {
  const steps = opts.steps ?? 3000;
  const avgFrom = opts.avgFrom ?? 1000;
  const s = new Solver(L, { ...solverOpts, gridScale, powers: { cpu: powers[0], gpu: powers[1], psu: powers[2] } });
  s.turbUpdateEvery = opts.turbUpdateEvery ?? 1;
  const info = runToSteady(s, { tolT: -1, tolFlow: -1, maxSteps: steps, chunk: 1 }, opts.progress);
  const hist = info.history;
  const sel = hist.filter((_, r) => r + 1 > avgFrom);
  const nc = info.columns.length;
  const mean = new Array(nc).fill(NaN);
  const std = new Array(nc).fill(NaN);
  const min = new Array(nc).fill(NaN);
  const max = new Array(nc).fill(NaN);
  if (sel.length) {
    for (let c = 0; c < nc; c++) {
      let sum = 0;
      let lo = Infinity;
      let hi = -Infinity;
      for (const r of sel) {
        sum += r[c];
        lo = mmin(lo, r[c]);
        hi = mmax(hi, r[c]);
      }
      const m = sum / sel.length;
      let ss = 0;
      for (const r of sel) ss += (r[c] - m) ** 2;
      mean[c] = m;
      std[c] = sel.length > 1 ? Math.sqrt(ss / (sel.length - 1)) : 0;
      min[c] = lo;
      max[c] = hi;
    }
  }
  const history = hist.map((r, k) => [k + 1, ...r]).filter((r) => r[0] % 10 === 0);
  return { steps: info.steps, avgFrom, columns: info.columns, history, mean, std, min, max, diverged: info.diverged, solver: s };
}
