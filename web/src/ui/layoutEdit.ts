// 布局编辑的纯逻辑（界面状态 ↔ 布局），移植自 MATLAB 界面的 pendingLayout / setPendingFromLayout。
import { getSlotStates, setSlotStates, type SlotState } from '../model/fans';
import { layoutGpuSlots, layoutSetGpuSlots } from '../model/gpuSlots';
import type { Layout } from '../model/types';

export type Gaps = { x0Mm: number; x1Mm: number }[];
export type Powers = { cpu: number; gpu: number; psu: number };

/** 待应用布局：基底 + 安装位状态 + 挡板开孔（勾选时用 defaultGaps）+ 显卡厚度 + 当前功率（显卡放不下时抛错） */
export function buildPending(base: Layout, slots: SlotState[], gap: boolean, gpuSlots: number | null, defaultGaps: Gaps, powers: Powers): Layout {
  let L = setSlotStates(base, slots);
  if (L.shroud) L = { ...L, shroud: { ...L.shroud, gaps: gap ? structuredClone(defaultGaps) : [] } };
  if (L.gpu && gpuSlots !== null && gpuSlots !== layoutGpuSlots(L)) L = layoutSetGpuSlots(L, gpuSlots);
  return { ...L, power: { cpu: powers.cpu, gpu: powers.gpu, psu: powers.psu } };
}

/** 以布局 L 作为待编辑布局时的界面状态；带非空挡板缺口时更新 defaultGaps（同 MATLAB setPendingFromLayout） */
export function pendingFromLayout(L: Layout, defaultGaps: Gaps): { slots: SlotState[]; gpuSlots: number | null; shroudGap: boolean | null; defaultGaps: Gaps } {
  const gaps = L.shroud?.gaps ?? [];
  return {
    slots: getSlotStates(L),
    gpuSlots: L.gpu ? layoutGpuSlots(L) : null,
    shroudGap: L.shroud ? gaps.length > 0 : null, // null：布局无挡板，勾选框保持原状
    defaultGaps: gaps.length ? structuredClone(gaps) : defaultGaps,
  };
}
