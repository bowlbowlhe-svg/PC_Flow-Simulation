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
}

export interface CpuSpec {
  base: Rect;
  fins: Rect;
  porous: Porous;
  thermal: ComponentThermal;
  tjmax: number;
  throttleTemp: number;
  fan: { model: string; side: 'front' | 'rear' };
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
  chassis: { enabled: boolean; originMm: number | number[]; sizeMm: number | number[]; depthM: number; wallTempC: WallTemps };
  power: { cpu: number; gpu: number; psu: number };
  fanDiskMm: number;
  grille: { intakeZeta: number; exhaustZeta: number };
  acoustics?: Acoustics;
  cpu?: CpuSpec;
  gpu?: GpuSpec;
  psu?: PsuSpec;
  ram?: Rect[];
  vrm?: Rect;
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
