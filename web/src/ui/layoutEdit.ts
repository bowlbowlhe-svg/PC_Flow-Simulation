// 布局编辑的纯逻辑（界面状态 ↔ 布局），移植自 MATLAB 界面的 pendingLayout / setPendingFromLayout。
import { FAN_SLOTS, getSlotStates, setSlotStates, type SlotState } from '../model/fans';
import { layoutGpuSlots, layoutSetGpuSlots } from '../model/gpuSlots';
import { layoutCpuTower, layoutSetCpuFans } from '../model/cpuTower';
import { chassisSizeMm } from '../model/chassis';
import { layoutDefault } from '../model/layoutDefault';
import type { FanCurves, Layout } from '../model/types';

export type Gaps = { x0Mm: number; x1Mm: number }[];
export type Powers = { cpu: number; gpu: number; psu: number };

/**
 * 待应用布局：基底 + 安装位状态 + 挡板开孔（勾选时用 defaultGaps）+ 显卡厚度 + CPU 塔扇数量 + 当前功率
 * + 当前温控曲线（显卡放不下时抛错；cpuFans 为 null 时不改塔扇；fanCurves 为 null 时沿用基底的曲线）
 */
export function buildPending(
  base: Layout,
  slots: SlotState[],
  gap: boolean,
  gpuSlots: number | null,
  defaultGaps: Gaps,
  powers: Powers,
  cpuFans: number | null = null,
  fanCurves: FanCurves | null = null,
): Layout {
  let L = setSlotStates(base, slots);
  if (L.shroud) L = { ...L, shroud: { ...L.shroud, gaps: gap ? structuredClone(defaultGaps) : [] } };
  if (L.gpu && gpuSlots !== null && gpuSlots !== layoutGpuSlots(L)) L = layoutSetGpuSlots(L, gpuSlots);
  if (L.cpu && L.cpu.fan && cpuFans !== null && cpuFans !== layoutCpuTower(L).fans) L = layoutSetCpuFans(L, cpuFans);
  L = { ...L, power: { cpu: powers.cpu, gpu: powers.gpu, psu: powers.psu } };
  if (fanCurves) L.fanCurves = structuredClone(fanCurves); // 温控曲线档位随求解器（同功率）
  return L;
}

/** 布局的 CPU 塔扇数量；无 CPU 或无塔扇时为 null（界面下拉框禁用） */
export function layoutCpuFans(L: Layout): number | null {
  return L.cpu && L.cpu.fan ? layoutCpuTower(L).fans : null;
}

/** 塔扇数量下拉项（第 k 项 = k 个塔扇，同 MATLAB cpuFanItems） */
export function cpuFanItems(stacks: number): string[] {
  return stacks === 2 ? ['1 个（中间）', '2 个（前 + 中间）'] : ['1 个（前侧）', '2 个（前 + 后）'];
}

/**
 * 布局页的提示（网页版额外提供，MATLAB 版没有）：不在安装位上的机箱风扇（例如 v4.3 之前 400 mm 见方机箱的配置），
 * 以及机箱尺寸与默认不同（安装位按默认机箱定义）。
 */
export function layoutNotes(L: Layout): string[] {
  const out: string[] = [];
  const off = (L.caseFans ?? []).filter((f) => !FAN_SLOTS.some((s) => s.mount === f.mount && Math.abs(s.alongMm - f.alongMm) < 1)).length;
  if (off) out.push(`另有 ${off} 台机箱风扇不在安装位上：照常参与计算，但表格与主视图的安装位不显示它们；载入预设会清除它们`);
  const [w, h] = chassisSizeMm(L);
  const [w0, h0] = chassisSizeMm(layoutDefault());
  if (w !== w0 || h !== h0) out.push(`机箱为 ${w} × ${h} mm：安装位按默认机箱（深 ${w0} × 高 ${h0} mm）定义，位置可能不合适`);
  return out;
}

/**
 * 以布局 L 作为待编辑布局时的界面状态（同 MATLAB setPendingFromLayout）。defaultGaps 为"开孔"勾选时用的缺口：
 * 载入配置或方案（resetGaps）时取 L 的缺口（可为空，此时勾选框禁用）；撤销修改时只在 L 带非空缺口时更新，
 * 免得取消勾选并应用后再也勾不回来。
 */
export function pendingFromLayout(
  L: Layout,
  defaultGaps: Gaps,
  resetGaps = false,
): { slots: SlotState[]; gpuSlots: number | null; cpuFans: number | null; shroudGap: boolean | null; defaultGaps: Gaps } {
  const gaps = L.shroud?.gaps ?? [];
  return {
    slots: getSlotStates(L),
    gpuSlots: L.gpu ? layoutGpuSlots(L) : null,
    cpuFans: layoutCpuFans(L),
    shroudGap: L.shroud ? gaps.length > 0 : null, // null：布局无挡板，勾选框保持原状
    defaultGaps: gaps.length || (resetGaps && L.shroud) ? structuredClone(gaps) : defaultGaps,
  };
}
