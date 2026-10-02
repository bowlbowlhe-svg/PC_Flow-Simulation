// 风扇型号库、机箱安装位、布局预设（移植自 fan_catalog.m、fan_slots.m、fan_presets.m、
// layout_slots.m、layout_apply_preset.m）。
import { cloneLayout } from './types';
import type { CaseFan, FanType, Layout, Mount, SpeedMode } from './types';

export interface FanSpec {
  size: number; // mm
  rpm_min: number;
  rpm_max: number;
  cfm_max: number; // 满速自由风量
  noise_idle: number; // dB(A)
  noise_max: number;
  pmax_pa: number; // 满速最大静压
  pq_curve: number[]; // P/Pmax 在 Q/Qmax = 0, 0.2, …, 1.0 处
  price: number;
  label: string;
}

const generic = [1.0, 0.92, 0.79, 0.6, 0.36, 0.0];

function spec(
  size: number,
  rmin: number,
  rmax: number,
  cfm: number,
  nIdle: number,
  nMax: number,
  pmax: number,
  pq: number[],
  price: number,
  label: string,
): FanSpec {
  return {
    size,
    rpm_min: rmin,
    rpm_max: rmax,
    cfm_max: cfm,
    noise_idle: nIdle,
    noise_max: nMax,
    pmax_pa: pmax,
    pq_curve: pq,
    price,
    label,
  };
}

/** 风扇型号库（顺序与 MATLAB struct 字段顺序一致） */
export const FAN_CATALOG: Readonly<Record<string, FanSpec>> = Object.freeze({
  NF_A14: spec(140, 300, 1500, 82.52, 12, 24.6, 20.4, [1.0, 0.91, 0.78, 0.59, 0.34, 0.0], 249, 'Noctua NF-A14'),
  NF_A12: spec(120, 450, 2000, 60.1, 15, 22.6, 22.9, [1.0, 0.93, 0.8, 0.62, 0.36, 0.0], 229, 'Noctua NF-A12x25'),
  NF_A9: spec(92, 400, 2500, 46, 14, 24, 22.4, [1.0, 0.89, 0.74, 0.55, 0.32, 0.0], 129, 'Noctua NF-A9'),
  RX140: spec(140, 300, 1700, 95.7, 10, 36, 20.0, [1.0, 0.95, 0.85, 0.7, 0.45, 0.0], 219, 'Phanteks T30/RX 140'),
  RX120: spec(120, 400, 2100, 74.2, 10, 36, 22.0, [1.0, 0.94, 0.83, 0.67, 0.42, 0.0], 189, 'Phanteks RX 120'),
  P14: spec(140, 200, 1700, 72.8, 12, 22.5, 23.5, [1.0, 0.92, 0.77, 0.57, 0.32, 0.0], 68, 'Arctic P14'),
  P12: spec(120, 200, 1800, 56, 14, 26, 21.6, [1.0, 0.92, 0.77, 0.57, 0.32, 0.0], 55, 'Arctic P12'),
  Stock120: spec(120, 600, 2200, 65, 18, 32, 20.0, generic, 0, '机箱原装 120mm'),
  Tower120: spec(120, 800, 2200, 60, 17, 31, 20.0, generic, 0, 'CPU 塔式散热器风扇'),
  GPU80: spec(80, 800, 2600, 45, 16, 34, 20.0, generic, 0, '显卡 80mm 风扇'),
  PSU120: spec(120, 500, 1800, 50, 15, 30, 20.0, generic, 0, '电源 120mm 风扇'),
});

/** 型号是否在型号库中（只认自有属性：'constructor'、'toString' 等原型链上的键不算，同 MATLAB isfield） */
export function hasModel(model: unknown): model is string {
  return typeof model === 'string' && Object.prototype.hasOwnProperty.call(FAN_CATALOG, model);
}

export interface FanSlot {
  id: string;
  label: string;
  mount: Mount;
  alongMm: number;
}

/** 机箱风扇安装位（默认机箱深 320 × 高 400 mm）：前 3、顶 2、后 1、底 1（电源之后只剩约 150 mm） */
export const FAN_SLOTS: readonly FanSlot[] = Object.freeze([
  { id: 'F1', label: '前上', mount: 'front', alongMm: 100 },
  { id: 'F2', label: '前中', mount: 'front', alongMm: 220 },
  { id: 'F3', label: '前下', mount: 'front', alongMm: 338 },
  { id: 'T1', label: '顶后', mount: 'top', alongMm: 100 },
  { id: 'T2', label: '顶前', mount: 'top', alongMm: 220 },
  { id: 'R1', label: '后部', mount: 'rear', alongMm: 124 },
  { id: 'B1', label: '底部', mount: 'bottom', alongMm: 232 },
] as FanSlot[]);

export interface FanPreset {
  name: string;
  label: string;
  short: string;
  fans: [string, FanType, string][]; // 安装位 id、类型、型号
}

export const FAN_PRESETS: readonly FanPreset[] = Object.freeze([
  { name: 'balanced', short: '双前进', label: '2 前进 · 后顶出（默认）', fans: [['F2', 'intake', 'P12'], ['F3', 'intake', 'P12'], ['R1', 'exhaust', 'P12'], ['T1', 'exhaust', 'Stock120']] },
  { name: 'single_front', short: '单前进', label: '1 前进 · 后顶出', fans: [['F2', 'intake', 'P12'], ['R1', 'exhaust', 'P12'], ['T1', 'exhaust', 'Stock120']] },
  { name: 'front_rear', short: '前进后出', label: '前进后出', fans: [['F2', 'intake', 'P12'], ['R1', 'exhaust', 'P12']] },
  { name: 'front_top', short: '前进顶出', label: '前进顶出', fans: [['F1', 'intake', 'P12'], ['F2', 'intake', 'P12'], ['T1', 'exhaust', 'P12'], ['T2', 'exhaust', 'P12']] },
  { name: 'bottom_top', short: '底进顶出', label: '底进顶出', fans: [['B1', 'intake', 'P12'], ['T1', 'exhaust', 'P12'], ['T2', 'exhaust', 'P12']] },
  { name: 'positive', short: '正压', label: '正压（3 进 1 出）', fans: [['F1', 'intake', 'P12'], ['F2', 'intake', 'P12'], ['F3', 'intake', 'P12'], ['R1', 'exhaust', 'P12']] },
  { name: 'negative', short: '负压', label: '负压（1 进 3 出）', fans: [['F2', 'intake', 'P12'], ['R1', 'exhaust', 'P12'], ['T1', 'exhaust', 'P12'], ['T2', 'exhaust', 'P12']] },
  { name: 'full', short: '全装', label: '全装（3 前进 · 1 底进 · 后顶出）', fans: [['F1', 'intake', 'P12'], ['F2', 'intake', 'P12'], ['F3', 'intake', 'P12'], ['B1', 'intake', 'P12'], ['R1', 'exhaust', 'P12'], ['T1', 'exhaust', 'P12'], ['T2', 'exhaust', 'P12']] },
] as FanPreset[]);

/** 安装位状态（layout_slots 'get' 格式） */
export interface SlotState {
  id: string;
  type: 'none' | FanType;
  model: string;
  speedMode: SpeedMode;
  manualPct: number;
}

function emptyState(id: string): SlotState {
  return { id, type: 'none', model: 'P12', speedMode: 'auto', manualPct: 60 };
}

function findSlot(mount: Mount, alongMm: number): number {
  for (let i = 0; i < FAN_SLOTS.length; i++) {
    if (FAN_SLOTS[i].mount === mount && Math.abs(FAN_SLOTS[i].alongMm - alongMm) < 1) return i;
  }
  return -1;
}

/** 从布局读出各安装位状态（与 FAN_SLOTS 顺序一致）；不在安装位上的机箱风扇忽略 */
export function getSlotStates(L: Layout): SlotState[] {
  const states = FAN_SLOTS.map((s) => emptyState(s.id));
  for (const cf of L.caseFans ?? []) {
    const k = findSlot(cf.mount, cf.alongMm);
    if (k < 0) continue;
    states[k] = { id: FAN_SLOTS[k].id, type: cf.type, model: cf.model, speedMode: cf.speedMode, manualPct: cf.manualPct };
  }
  return states;
}

/** 按安装位状态重写 caseFans：先保留不在安装位上的风扇，再按安装位顺序追加 */
export function setSlotStates(L0: Layout, states: SlotState[]): Layout {
  const L = cloneLayout(L0); // 值语义（同 MATLAB）：返回的新布局与输入不共享嵌套对象
  const keep: CaseFan[] = [];
  for (const cf of L.caseFans ?? []) {
    if (findSlot(cf.mount, cf.alongMm) < 0) keep.push({ ...cf });
  }
  FAN_SLOTS.forEach((slot, k) => {
    const st = states[k];
    if (st.type === 'none') return;
    keep.push({ mount: slot.mount, alongMm: slot.alongMm, type: st.type, model: st.model, speedMode: st.speedMode, manualPct: st.manualPct });
  });
  L.caseFans = keep;
  return L;
}

/** 按预设名重写全部机箱风扇（清空不在安装位上的风扇） */
export function applyPreset(L: Layout, presetName: string): Layout {
  const p = FAN_PRESETS.find((q) => q.name === presetName);
  if (!p) throw new Error(`未知预设：${presetName}`);
  const states = getSlotStates({ ...L, caseFans: [] });
  for (const [id, type, model] of p.fans) {
    const i = states.findIndex((s) => s.id === id);
    states[i] = { ...states[i], type, model, speedMode: 'auto' };
  }
  return setSlotStates({ ...L, caseFans: [] }, states);
}
