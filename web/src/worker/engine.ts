// 仿真引擎：持有求解器，处理界面命令，分小段推进并产出帧（与 Worker 全局对象解耦，便于在 Node 下测试）。
import { layoutGpuSlots } from '../model/gpuSlots';
import type { Layout } from '../model/types';
import {
  calculateScores,
  computeAirflowTemperatures,
  fanStatusList,
  getRecommendations,
  openingMarkers,
  pressureFieldPa,
  scenarioSummary,
  totalNoise,
} from '../solver/diagnostics';
import { CFM_PER_M3S, PQ_QGRID } from '../solver/fan';
import { pchipEval } from '../numerics/pchipEval';
import { Solver } from '../solver/solver';
import { SteadyRunner } from '../solver/steady';
import type { Command, ComponentName, FrameFields, StaticInfo, Status, SteadyStatus, WorkerMessage } from './protocol';

export type Post = (m: WorkerMessage, transfer?: Transferable[]) => void;

/** 预览档（140²）湍流隔步更新（同 MATLAB 界面 applyGridMode），精确档逐步更新 */
export function turbUpdateEveryFor(gridScale: number): number {
  return gridScale < 1 ? 2 : 1;
}

export class SimEngine {
  solver: Solver | null = null;
  running = false;
  private steady: SteadyRunner | null = null;
  private steadyStatus: SteadyStatus | null = null;
  private msPerStep = 50;
  private steadyIter = -1; // 判稳时的步数（之后推进或改设置即失效）
  private lastFrameAt = -Infinity;
  /** 帧间隔下限 [ms] */
  frameIntervalMs = 50;
  /** 每次 tick 的推进时间预算 [ms] */
  tickBudgetMs = 30;
  private now: () => number;

  constructor(
    private readonly post: Post,
    now?: () => number,
  ) {
    this.now = now ?? (() => performance.now());
  }

  handle(cmd: Command): void {
    switch (cmd.type) {
      case 'init':
        this.build(cmd.layout, cmd.gridScale, cmd.powers, cmd.autoFan, cmd.fanPct, cmd.id);
        return;
      case 'run':
        if (this.solver && !this.steady) this.running = true;
        this.postFrame();
        return;
      case 'pause':
        this.running = false;
        this.postFrame();
        return;
      case 'step':
        if (this.solver && !this.steady) {
          this.timedSteps(cmd.n);
          this.postFrame();
        }
        return;
      case 'steady':
        if (!this.solver) return;
        this.running = false;
        this.steady = new SteadyRunner(this.solver, cmd.opts);
        this.steadyStatus = { active: true, steps: 0, maxSteps: this.steady.opts.maxSteps, converged: false, diverged: false, aborted: false, message: '正在跑到稳态…' };
        this.postFrame();
        return;
      case 'stopSteady':
        if (this.steady) {
          this.steady.abort();
          this.finishSteady();
        }
        return;
      case 'reset':
        if (!this.solver) return;
        this.running = false;
        this.steady = null;
        this.steadyStatus = null;
        this.steadyIter = -1;
        this.solver.initState();
        this.postFrame();
        return;
      case 'setPower':
        this.solver?.setComponentPower(cmd.name, cmd.watts);
        this.markChanged();
        this.postFrame();
        return;
      case 'setFan':
        if (this.solver) {
          this.solver.autoFanEnabled = cmd.auto;
          this.solver.fanSpeedRatio = cmd.pct;
        }
        this.markChanged();
        this.postFrame();
        return;
      case 'setForceReassemble':
        if (this.solver) this.solver.forceReassemble = cmd.on;
        this.postFrame();
        return;
    }
  }

  /** 功率或风扇设置改变：当前流场不再是稳态结果 */
  private markChanged(): void {
    if (this.steadyStatus && !this.steadyStatus.active) this.steadyStatus = null;
    this.steadyIter = -1;
  }

  /**
   * 按布局重建求解器（同 MATLAB rebuildSolver）：先停止推进；构造、静态信息与首帧状态全部成功后才替换原求解器，
   * 任何一步出错都保留原求解器（已暂停）并回复 buildFailed，界面据此回滚。
   */
  private build(layout: Layout, gridScale: number, powers: Record<ComponentName, number>, autoFan: boolean, fanPct: number, id?: number): void {
    this.running = false;
    if (this.steady) {
      this.steady.abort();
      this.steady = null;
      this.steadyStatus = null;
    }
    let s: Solver;
    let info: StaticInfo;
    try {
      s = new Solver(layout, { gridScale, powers });
      s.turbUpdateEvery = turbUpdateEveryFor(gridScale);
      s.autoFanEnabled = autoFan;
      s.fanSpeedRatio = fanPct;
      info = this.staticInfo(s);
      this.status(s); // 状态量（噪音、评分等）也要能算出，否则不装上
    } catch (e) {
      this.post({ type: 'buildFailed', id, message: e instanceof Error ? e.message : String(e) });
      this.postFrame();
      return;
    }
    this.solver = s;
    this.steadyStatus = null;
    this.steadyIter = -1;
    this.msPerStep = 50;
    this.post({ type: 'static', info, id });
    this.postFrame();
  }

  staticInfo(solver?: Solver): StaticInfo {
    const s = solver ?? this.solver!;
    const g = s.geo;
    const ring = new Uint8Array(s.N);
    for (const i of g.spongeRingIdx) ring[i] = 1;
    const fluid: number[] = [];
    for (let i = 0; i < s.N; i++) if (g.obstacle[i] === 0 && !ring[i]) fluid.push(i);
    const isFluid = new Uint8Array(s.N);
    for (const i of fluid) isFluid[i] = 1;
    const inside = Array.from(g.insideMask).filter((i) => isFluid[i]);
    let gpu: StaticInfo['gpu'];
    if (g.gpu) {
      let fanBottom = g.gpu.heatsink.y + g.gpu.heatsink.h - 1;
      for (const f of g.fans) if (f.role === 'gpu') fanBottom = Math.max(fanBottom, f.rows[1]);
      gpu = { pcb: g.gpu.pcb, heatsink: g.gpu.heatsink, slots: layoutGpuSlots(s.layout), fanBottom };
    }
    return {
      W: s.W,
      H: s.H,
      cellMm: g.cellMm,
      DT: s.DT,
      VEL_SCALE: s.VEL_SCALE,
      gridScale: g.gridScale,
      turbUpdateEvery: s.turbUpdateEvery,
      layoutName: s.layout.name,
      obstacle: g.obstacle.slice(),
      fluidIdx: Int32Array.from(fluid),
      insideIdx: Int32Array.from(inside),
      caseOuter: g.CASE2D.outer,
      motherboardTray: g.CASE2D.motherboardTray,
      cpu: g.cpu,
      gpu,
      psu: g.psu ? { body: g.psu.body } : undefined,
      ram: g.ram,
      vrm: g.vrm,
      chipset: g.chipset,
      fans: g.fans.map((f) => ({ role: f.role, type: f.type, mount: f.mount, model: f.model, rows: f.rows, cols: f.cols, normal: f.normal })),
      markers: openingMarkers(s).map((m) => ({ x: m.x, y: m.y, mount: m.mount, kind: m.kind, fan: m.fan })),
      slots: g.slotSpans,
      fanDiskCells: g.fanDiskCells,
      layout: structuredClone(s.layout),
      powers: { ...s.powerW },
      autoFan: s.autoFanEnabled,
      fanPct: s.fanSpeedRatio,
    };
  }

  /** 推进 n 步并更新每步耗时估计 */
  private timedSteps(n: number): void {
    this.steadyIter = -1;
    const t0 = this.now();
    this.solver!.stepMultiple(n);
    const dt = (this.now() - t0) / n;
    this.msPerStep = 0.7 * this.msPerStep + 0.3 * dt;
  }

  /** 是否还有待推进的工作 */
  get busy(): boolean {
    return !!this.solver && (this.running || !!this.steady);
  }

  /** 推进一小段（约 tickBudgetMs）；到帧间隔时产出一帧。返回是否还有工作。 */
  tick(): boolean {
    const s = this.solver;
    if (!s || !this.busy) return false;
    const n = Math.max(1, Math.floor(this.tickBudgetMs / Math.max(this.msPerStep, 0.1)));
    try {
      if (this.steady) {
        const t0 = this.now();
        const it0 = s.iteration;
        const done = this.steady.advance(n);
        const k = s.iteration - it0;
        if (k > 0) this.msPerStep = 0.7 * this.msPerStep + (0.3 * (this.now() - t0)) / k;
        this.steadyStatus!.steps = this.steady.info.steps + this.steady.chunkProgress.done;
        if (done) {
          this.finishSteady();
          return false;
        }
      } else {
        this.timedSteps(n);
        if (!s.T_fluid.every(Number.isFinite)) {
          this.running = false;
          this.post({ type: 'error', message: '计算发散（出现非有限温度），请重置' });
        }
      }
    } catch (e) {
      this.running = false;
      this.steady = null;
      if (this.steadyStatus) this.steadyStatus = { ...this.steadyStatus, active: false, message: '计算出错' };
      this.post({ type: 'error', message: e instanceof Error ? e.message : String(e) });
      this.postFrame();
      return false;
    }
    if (this.now() - this.lastFrameAt >= this.frameIntervalMs) this.postFrame();
    return this.busy;
  }

  private finishSteady(): void {
    const r = this.steady!;
    const i = r.info;
    const steps = i.steps + r.chunkProgress.done; // 含未满一块的步数（中途停止时）
    let message: string;
    if (i.converged) message = `已稳态（${steps} 步）`;
    else if (i.diverged) message = `计算发散（${steps} 步），请重置`;
    else if (i.aborted) message = `已停止（${steps} 步）`;
    else message = `未完全收敛（${steps} 步）`;
    this.steadyStatus = { active: false, steps, maxSteps: r.opts.maxSteps, converged: i.converged, diverged: i.diverged, aborted: i.aborted, message };
    if (i.converged) this.steadyIter = this.solver!.iteration;
    this.steady = null;
    this.postFrame();
  }

  /** 温度场：流体格取 T_fluid，障碍格取 T_solid（同 MATLAB temperatureField） */
  private frameFields(): FrameFields {
    const s = this.solver!;
    const N = s.N;
    const obs = s.geo.obstacle;
    const T = new Float32Array(N);
    for (let i = 0; i < N; i++) T[i] = obs[i] > 0 ? s.T_solid[i] : s.T_fluid[i];
    const { uC, vC } = s.getCellVelocity();
    for (let i = 0; i < N; i++) if (obs[i] > 0) uC[i] = vC[i] = 0;
    return {
      T,
      Tsolid: Float32Array.from(s.T_solid),
      uC: Float32Array.from(uC),
      vC: Float32Array.from(vC),
      P: Float32Array.from(pressureFieldPa(s)),
      vort: Float32Array.from(s.latestVorticity ?? new Float64Array(N)),
    };
  }

  status(solver?: Solver): Status {
    const s = solver ?? this.solver!;
    const nets = s.thermalNetworks;
    const tj: Status['tj'] = {};
    const throttle: Status['throttle'] = {};
    for (const n of ['cpu', 'gpu', 'psu'] as const) {
      const net = nets[n];
      if (net) {
        tj[n] = net.T_junction;
        throttle[n] = net.throttlingRatio;
      }
    }
    const temps = s.lastTemps ?? computeAirflowTemperatures(s);
    const P = pressureFieldPa(s);
    let ps = 0;
    let pn = 0;
    for (const i of s.geo.insideMask)
      if (Number.isFinite(P[i])) {
        ps += P[i];
        pn++;
      }
    return {
      iteration: s.iteration,
      time: s.iteration * s.DT,
      tj,
      throttle,
      temps,
      scores: calculateScores(s),
      diag: s.lastDiag,
      deadZone: s.deadZoneRatio,
      recs: getRecommendations(s),
      fans: fanStatusList(s),
      noiseDb: totalNoise(s).dbTotal,
      markerCfm: openingMarkers(s).map((m) => m.cfm),
      meanInteriorPa: pn ? ps / pn : 0,
      running: this.running,
      steady: this.steadyStatus ? { ...this.steadyStatus } : null,
      msPerStep: this.msPerStep,
      summary: scenarioSummary(s),
      atSteady: this.steadyIter >= 0 && this.steadyIter === s.iteration,
      forceReassemble: s.forceReassemble,
      pq: this.pqCurves(s),
    };
  }

  /** 机箱风扇与 CPU 塔扇：当前转速下的 P-Q 曲线与实测工作点（同 MATLAB updatePQ） */
  private pqCurves(s: Solver): Status['pq'] {
    const list = fanStatusList(s);
    const out: Status['pq'] = [];
    const q = Array.from({ length: 21 }, (_, k) => k / 20);
    s.fans.forEach((f, k) => {
      if (f.g.role !== 'case' && f.g.role !== 'cpu') return;
      const sp = f.spec;
      const rpm = f.getRPM(s);
      const qFree = (sp.cfm_max * rpm) / sp.rpm_max;
      const shape = pchipEval(PQ_QGRID, sp.pq_curve, q);
      const scale = sp.pmax_pa * (rpm / sp.rpm_max) ** 2;
      out.push({
        name: list[k].name,
        cfm: q.map((x) => x * qFree),
        dp: Array.from(shape, (v) => scale * v),
        opCfm: Math.max(s.diskFlow(f.g), 0) * CFM_PER_M3S,
        opDp: Math.max(f.lastDp, 0),
      });
    });
    return out;
  }

  postFrame(): void {
    if (!this.solver) return;
    let fields: FrameFields;
    let status: Status;
    try {
      fields = this.frameFields();
      status = this.status();
    } catch (e) {
      // 帧内容算不出（例如状态出现非有限值）：停止推进并报告，不让异常中断 Worker 的调度
      this.running = false;
      if (this.steady) {
        this.steady.abort();
        this.steady = null;
      }
      this.post({ type: 'error', message: e instanceof Error ? e.message : String(e) });
      return;
    }
    this.lastFrameAt = this.now();
    this.post({ type: 'frame', fields, status }, [
      fields.T.buffer,
      fields.Tsolid.buffer,
      fields.uC.buffer,
      fields.vC.buffer,
      fields.P.buffer,
      fields.vort.buffer,
    ]);
  }
}
