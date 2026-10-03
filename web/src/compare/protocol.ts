// 对比展示页的计算口径（预计算数据、界面后台计算与 MATLAB tools/compare_scenarios.m 共用）：
// 每个方案 × 场景从静止推进（自动温控），取后半段每一步的均值；再接续推进几个全局手动转速（"同噪音 / 同温度"的公平比较用）。
import type { Layout } from '../model/types';
import { DEFAULT_PROTOCOL, type CompareProtocol } from './scenarios';
import { calculateScores, fanStatusList, totalNoise } from '../solver/diagnostics';
import { Solver } from '../solver/solver';

export { COMPARE_SCENARIOS, DEFAULT_PROTOCOL, interpAt } from './scenarios';
export type { CompareProtocol, ScenarioKey } from './scenarios';

export interface PointMetrics {
  /** 统计窗口内每一步的均值（缺该元件为 NaN） */
  cpu: number;
  gpu: number;
  psu: number;
  interior: number;
  cfm: number;
  /** 阶段末状态 */
  noiseDb: number;
  perfPct: number;
  freqCpu: number;
  freqGpu: number;
  powerCpu: number; // 实际功率 [W]
  powerGpu: number;
  score: number;
  perf: number;
  thermal: number;
  noise: number;
  airflow: number;
  airK: number;
  cls: string;
  /** 统计窗口内最高结温（max(CPU, GPU)）的漂移：后 1/4 均值 − 前 1/4 均值 [°C]（判断是否已稳态） */
  drift: number;
  fans: { name: string; role: string; rpm: number; stopped: boolean }[];
}

export interface SweepPoint extends PointMetrics {
  pct: number;
}

/** 场快照（缩略图用）：格心值，列优先 W×H，与求解器相同 */
export interface FieldSnap {
  W: number;
  H: number;
  T: Float32Array; // 温度（障碍格为固体温度）
  speed: Float32Array; // 风速 [m/s]（障碍格为 0）
  solid: Uint8Array; // 1 = 障碍
}

const COLS = ['cpu', 'gpu', 'psu', 'interior', 'cfm'] as const;

/** 有限值中的最大（都不是有限值时为 NaN；同 MATLAB max 忽略 NaN） */
const fmax = (a: number, b: number) => (Number.isFinite(a) ? (Number.isFinite(b) ? Math.max(a, b) : a) : b);

function readRow(s: Solver): number[] {
  const t = s.lastTemps!;
  const tj = (n: 'cpu' | 'gpu' | 'psu') => s.thermalNetworks[n]?.T_junction ?? NaN;
  return [tj('cpu'), tj('gpu'), tj('psu'), t.internalAmbient, t.totalCFM];
}

function endMetrics(s: Solver, mean: number[], drift: number): PointMetrics {
  const sc = calculateScores(s);
  const net = s.thermalNetworks;
  return {
    cpu: mean[0],
    gpu: mean[1],
    psu: mean[2],
    interior: mean[3],
    cfm: mean[4],
    noiseDb: totalNoise(s).dbTotal,
    perfPct: sc.perfPct,
    freqCpu: sc.freqCpu,
    freqGpu: sc.freqGpu,
    powerCpu: net.cpu?.actualPower ?? 0,
    powerGpu: net.gpu?.actualPower ?? 0,
    score: sc.total,
    perf: sc.perf,
    thermal: sc.thermal,
    noise: sc.noise,
    airflow: sc.airflow,
    airK: sc.airK,
    cls: sc.cls,
    drift,
    fans: fanStatusList(s).map((f) => ({ name: f.name, role: f.role, rpm: f.rpm, stopped: f.stopped })),
  };
}

/** 当前温度、风速与障碍（缩略图用） */
export function fieldSnap(s: Solver): FieldSnap {
  const { uC, vC } = s.getCellVelocity();
  const obs = s.geo.obstacle;
  const T = new Float32Array(s.N);
  const speed = new Float32Array(s.N);
  const solid = new Uint8Array(s.N);
  for (let i = 0; i < s.N; i++) {
    if (obs[i] > 0) {
      T[i] = s.T_solid[i];
      solid[i] = 1;
    } else {
      T[i] = s.T_fluid[i];
      speed[i] = Math.hypot(uC[i], vC[i]) * s.VEL_SCALE;
    }
  }
  return { W: s.W, H: s.H, T, speed, solid };
}

/**
 * 一个方案 × 场景的分段推进：advance(n) 每次至多推进 n 步（Worker 里逐段汇报进度、可中止）。
 * 阶段 0 为自动温控（从静止），之后每个 sweepPct 一个阶段（关闭自动温控、全局手动转速，接续推进）。
 * 统计窗口前按块推进、窗口内逐步推进并累加；分块方式不影响结果（诊断量只读状态）。
 */
export class CompareRunner {
  readonly solver: Solver;
  auto: PointMetrics | null = null;
  autoField: FieldSnap | null = null;
  readonly sweep: SweepPoint[] = [];
  diverged = false;
  aborted = false;
  private phase = 0;
  private stepInPhase = 0;
  private acc = new Array(COLS.length).fill(0);
  private nAcc = 0;
  private tFirst = 0; // 窗口前 1/4 的最高结温之和
  private tLast = 0; // 窗口后 1/4 的最高结温之和

  constructor(
    layout: Layout,
    powers: [number, number, number],
    readonly protocol: CompareProtocol = DEFAULT_PROTOCOL,
  ) {
    this.solver = new Solver(layout, { gridScale: protocol.gridScale, powers: { cpu: powers[0], gpu: powers[1], psu: powers[2] } });
    this.solver.turbUpdateEvery = protocol.turbUpdateEvery;
  }

  get nPhases(): number {
    return 1 + this.protocol.sweepPct.length;
  }

  get totalSteps(): number {
    const p = this.protocol;
    return p.autoSteps + p.sweepPct.length * p.sweepSteps;
  }

  get doneSteps(): number {
    const p = this.protocol;
    return this.phase === 0 ? this.stepInPhase : p.autoSteps + (this.phase - 1) * p.sweepSteps + this.stepInPhase;
  }

  get done(): boolean {
    return this.diverged || this.aborted || this.phase >= this.nPhases;
  }

  abort(): void {
    this.aborted = true;
  }

  private phaseLen(): [number, number] {
    const p = this.protocol;
    return this.phase === 0 ? [p.autoSteps, p.autoAvgFrom] : [p.sweepSteps, p.sweepAvgFrom];
  }

  /** 推进至多 limit 步，返回 done */
  advance(limit = Infinity): boolean {
    const s = this.solver;
    let budget = Math.max(1, Math.floor(limit));
    while (budget > 0 && !this.done) {
      const [len, from] = this.phaseLen();
      if (this.stepInPhase < from) {
        const n = Math.min(budget, from - this.stepInPhase);
        s.stepMultiple(n);
        this.stepInPhase += n;
        budget -= n;
      } else {
        s.stepMultiple(1);
        this.stepInPhase++;
        budget--;
        const row = readRow(s);
        for (let c = 0; c < row.length; c++) this.acc[c] += row[c];
        const q = Math.floor((len - from) / 4);
        const tm = fmax(row[0], row[1]);
        if (this.nAcc < q) this.tFirst += tm;
        if (this.nAcc >= len - from - q) this.tLast += tm;
        this.nAcc++;
      }
      if (!s.T_fluid.every(Number.isFinite)) {
        this.diverged = true;
        break;
      }
      if (this.stepInPhase >= len) this.finishPhase();
    }
    return this.done;
  }

  private finishPhase(): void {
    const s = this.solver;
    const mean = this.acc.map((v) => (this.nAcc ? v / this.nAcc : NaN));
    const q = Math.floor(this.nAcc / 4);
    const m = endMetrics(s, mean, q ? (this.tLast - this.tFirst) / q : NaN);
    if (this.phase === 0) {
      this.auto = m;
      this.autoField = fieldSnap(s);
    } else this.sweep.push({ ...m, pct: this.protocol.sweepPct[this.phase - 1] });
    this.phase++;
    this.stepInPhase = 0;
    this.acc.fill(0);
    this.nAcc = 0;
    this.tFirst = this.tLast = 0;
    if (this.phase < this.nPhases) {
      s.autoFanEnabled = false;
      s.fanSpeedRatio = this.protocol.sweepPct[this.phase - 1];
    }
  }
}
