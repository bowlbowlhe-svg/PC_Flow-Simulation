// 主线程 ↔ 仿真 Worker 的消息格式。
import type { Layout, Mount, Rect } from '../model/types';
import type { AirflowTemps, CFDDiag, FanStatus, Recommendation, ScenarioSummary, Scores } from '../solver/diagnostics';
import type { SteadyOptions } from '../solver/steady';

export type ComponentName = 'cpu' | 'gpu' | 'psu';

export type Command =
  | { type: 'init'; id?: number; layout: Layout; gridScale: number; powers: Record<ComponentName, number>; autoFan: boolean; fanPct: number }
  | { type: 'run' }
  | { type: 'pause' }
  | { type: 'step'; n: number }
  | { type: 'steady'; opts?: SteadyOptions }
  | { type: 'stopSteady' }
  | { type: 'reset' }
  | { type: 'setPower'; name: ComponentName; watts: number }
  | { type: 'setFan'; auto: boolean; pct: number }
  | { type: 'setForceReassemble'; on: boolean };

/** 画静态几何与粒子重生所需的信息（每次重建求解器发送一次） */
export interface StaticInfo {
  W: number;
  H: number;
  cellMm: number;
  DT: number;
  VEL_SCALE: number;
  gridScale: number;
  turbUpdateEvery: number;
  layoutName: string;
  obstacle: Uint8Array;
  fluidIdx: Int32Array; // 可重生粒子的流体格（不含海绵环），0 基
  insideIdx: Int32Array;
  caseOuter: Rect; // 1 基格坐标
  motherboardTray?: Rect;
  cpu?: { base: Rect; finArea: Rect };
  gpu?: { pcb: Rect; heatsink: Rect; slots: number; fanBottom: number };
  psu?: { body: Rect };
  ram: Rect[];
  vrm?: Rect;
  chipset?: Rect;
  fans: { role: string; type: string; mount: string; model: string; rows: [number, number]; cols: [number, number]; normal: [number, number] }[];
  markers: { x: number; y: number; mount: Mount; kind: string; fan: number }[];
  /** 机箱风扇安装位（FAN_SLOTS 顺序）的执行盘格范围（120 mm），界面标记用 */
  slots: { id: string; mount: Mount; cols: [number, number]; rows: [number, number] }[];
  fanDiskCells: number;
  layout: Layout; // 当前求解器所用布局
  powers: Record<ComponentName, number>;
  autoFan: boolean;
  fanPct: number;
}

export interface Status {
  iteration: number;
  time: number; // 仿真时间 [s]
  tj: Partial<Record<ComponentName, number>>;
  throttle: Partial<Record<ComponentName, number>>;
  temps: AirflowTemps;
  scores: Scores;
  diag: CFDDiag | null;
  deadZone: number;
  recs: Recommendation[];
  fans: FanStatus[];
  noiseDb: number;
  markerCfm: number[]; // 与 StaticInfo.markers 对齐
  meanInteriorPa: number;
  running: boolean;
  steady: SteadyStatus | null;
  msPerStep: number;
  summary: ScenarioSummary;
  /** 当前状态即判稳时的状态（之后未推进、未改功率/风扇） */
  atSteady: boolean;
  forceReassemble: boolean;
  /** 风扇工作点图：机箱风扇与 CPU 塔扇当前转速下的 P-Q 曲线（21 点）与实测工作点 */
  pq: { name: string; cfm: number[]; dp: number[]; opCfm: number; opDp: number }[];
}

export interface SteadyStatus {
  active: boolean;
  steps: number;
  maxSteps: number;
  converged: boolean;
  diverged: boolean;
  aborted: boolean;
  message: string;
}

/** 一帧场数据（Float32，可转移）：格心量，列优先 W×H */
export interface FrameFields {
  T: Float32Array; // 温度场（障碍格为元件/显示温度，见 temperatureField）
  Tsolid: Float32Array;
  uC: Float32Array; // 格心网格速度（× VEL_SCALE = m/s）
  vC: Float32Array;
  P: Float32Array; // 静压 [Pa]，障碍格 NaN
  vort: Float32Array; // 涡量 [1/s]
}

export type WorkerMessage =
  | { type: 'static'; info: StaticInfo; id?: number }
  /** 重建失败：原求解器保留（已暂停），界面应回滚 */
  | { type: 'buildFailed'; id?: number; message: string }
  | { type: 'frame'; fields: FrameFields; status: Status }
  | { type: 'error'; message: string };
