// 布局配置的数据类型（与 MATLAB layout_default 的 struct 一一对应，可直接 JSON 存取）。
// 长度单位 mm，坐标相对机箱原点（机箱左上角外侧），x 向右（后面板 → 前面板），y 向下。

export interface Rect {
  x: number;
  y: number;
  w: number;
  h: number;
}

export type Mount = 'front' | 'rear' | 'top' | 'bottom';
export type FanType = 'intake' | 'exhaust';
export type SpeedMode = 'auto' | 'manual';
export type ThruDir = 'x' | 'y';

export interface Porous {
  zetaThru: number;
  zetaCross: number;
  thru: ThruDir;
}

export interface ComponentThermal {
  R_junction_to_case: number;
  R_tim: number;
  R_base: number;
  fin_thickness_mm: number;
  A_fin_total_m2: number;
  /** 鳍片对流 h = h_free + h_forced·min(V, 6)^h_exp [W/m²K]（v4.8.0 起；缺省为旧式 30 + 130·V，见 quasi3d.ts） */
  h_free?: number;
  h_forced?: number;
  h_exp?: number;
  /** 没有转动的风扇时换热风速的比例（v4.8.0，缺省 1） */
  passiveFlowShare?: number;
}

/** 频率与功率参数（见 dvfs.ts / layout_dvfs.m） */
export interface Dvfs {
  softStartC: number;
  softSlope: number;
  minFreq: number;
  powerExp: number;
  leakShare: number;
  leakRefC: number;
  leakDoubleC: number;
}

/** 温控曲线：T [°C] → duty（占满速转速的比例） */
export interface FanCurve {
  T: number[];
  duty: number[];
  stopBelowC?: number; // 显卡低温停转
  startAboveC?: number;
  passiveLoad?: number; // 电源半被动
  passiveMaxC?: number;
  passiveRestartC?: number;
}

export interface FanCurves {
  profile: string; // 'quiet' | 'standard' | 'performance' | 'custom'
  caseFan: FanCurve;
  cpu: FanCurve;
  gpu: FanCurve;
  psu: FanCurve;
}

export interface CpuSpec {
  base: Rect;
  fins: Rect;
  porous: Porous;
  thermal: ComponentThermal;
  tjmax: number;
  throttleTemp: number;
  /** 塔数与双塔中间间隙（缺省：单塔，见 cpuTower.ts） */
  tower?: { stacks: number; gapMm: number };
  /** count：塔扇数量 1 或 2（缺省 1） */
  fan?: { model: string; count?: number };
  dvfs?: Partial<Dvfs>;
}

export interface GpuSpec {
  slots?: number;
  pcb: Rect;
  heatsink: Rect;
  porous: Porous;
  thermal: ComponentThermal;
  tjmax: number;
  throttleTemp: number;
  fans: { model: string; xs: number[] };
  dvfs?: Partial<Dvfs>;
}

export interface PsuSpec {
  body: Rect;
  ratedW: number;
  effCurve: { load: number[]; eff: number[] };
  porous: Porous;
  fan: { model: string; xMm: number };
  intakeZeta: number;
  exhaustZeta: number;
  R_internal: number;
  warnTemp: number;
}

export interface CaseFan {
  mount: Mount;
  alongMm: number;
  type: FanType;
  model: string;
  speedMode: SpeedMode;
  manualPct: number;
}

export interface Vent {
  mount: Mount;
  alongMm: number;
  lengthMm: number;
  zeta: number;
}

export interface PorousBlock {
  rect: Rect;
  zetaThru: number;
  zetaCross: number;
  thru: ThruDir;
}

export interface Acoustics {
  stallQ: number;
  stallDb: number;
  grilleRefZeta: number;
  finDb: number;
  positionDb: {
    front: number;
    top: number;
    bottom: number;
    rear: number;
    cpu: number;
    gpu: number;
    psu: number;
  };
}

/** 零件占机箱 Z 向深度的比例（准三维修正，v4.8.0 起；缺省为 1 = 整个深度都挡住，见 quasi3d.ts） */
export interface ZShare {
  gpu?: number;
  ram?: number;
  vrm?: number;
}

/** 机箱壁向室内空气的总传热系数 [W/m²K]：edge = 2D 边界上的前/后/顶/底壁，side = 两块侧板（v4.8.0 起，见 quasi3d.ts） */
export interface PanelU {
  edge: number;
  side: number;
}

export interface WallTemps {
  rear: number; // NaN = 绝热
  front: number;
  top: number;
  bottom: number;
}

export interface Layout {
  name: string;
  ambientC: number;
  turbulenceModel: 'komega' | 'lvel' | 'laminar';
  domain: { sizeMm: number; baseCellMm: number };
  /** originMm：标量（x = y）或 [x y]；sizeMm：标量（见方）或 [深 高]（见 chassis.ts） */
  chassis: { enabled: boolean; originMm: number | number[]; sizeMm: number | number[]; depthM: number; wallTempC: WallTemps; panelU?: PanelU };
  power: { cpu: number; gpu: number; psu: number };
  fanDiskMm: number;
  grille: { intakeZeta: number; exhaustZeta: number };
  acoustics?: Acoustics;
  fanCurves?: FanCurves;
  cpu?: CpuSpec;
  gpu?: GpuSpec;
  psu?: PsuSpec;
  ram?: Rect[];
  vrm?: Rect;
  zShare?: ZShare;
  chipset?: Rect; // 仅显示
  motherboardTray?: Rect; // 仅显示
  shroud?: { yMm: number; hMm: number; gaps: { x0Mm: number; x1Mm: number }[] };
  caseFans?: CaseFan[];
  vents?: Vent[];
  solidBlocks?: Rect[];
  porousBlocks?: PorousBlock[];
  air?: { nu?: number; Pr?: number; rho?: number; cp?: number; beta?: number };
  benchmark?: Record<string, number>;
}

/** 深拷贝布局（布局只含 JSON 可表示的数据；NaN 需单独保留，故不用 JSON 往返） */
export function cloneLayout(L: Layout): Layout {
  return structuredClone(L);
}
