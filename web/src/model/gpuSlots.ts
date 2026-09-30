// 显卡厚度（扩展槽数）：移植自 gpu_fin_area.m、layout_gpu_slots.m、layout_set_gpu_slots.m。
import type { Layout } from './types';
import { mround } from './mround';

/** 显卡鳍片总面积 [m²]，随散热片高度线性缩放：3.5 槽（散热片 47 mm）为 0.5 m² */
export function gpuFinArea(heatsinkMm: number): number {
  return (0.5 * heatsinkMm) / 47;
}

/** 布局中显卡占用的扩展槽数；无显卡时为 NaN。无 slots 字段时按整卡厚度折算到 0.5 槽 */
export function layoutGpuSlots(L: Layout): number {
  const g = L.gpu;
  if (!g) return NaN;
  if (g.slots !== undefined && g.slots !== null) return g.slots;
  return mround(((g.pcb.h + g.heatsink.h + L.fanDiskMm) / 20.32) * 2) / 2;
}

export class LayoutError extends Error {
  constructor(
    public readonly id: string,
    message: string,
  ) {
    super(message);
  }
}

/** 按槽数设置显卡厚度（2–4.5 槽）；风扇下沿到电源仓挡板须留 ≥ 10 mm，否则抛错。返回新布局 */
export function layoutSetGpuSlots(L: Layout, slots: number): Layout {
  if (!L.gpu) throw new LayoutError('layout_set_gpu_slots:noGpu', '布局中没有显卡');
  if (!Number.isFinite(slots) || slots < 2 || slots > 4.5) {
    throw new LayoutError('layout_set_gpu_slots:range', '显卡厚度应为 2–4.5 槽');
  }
  const g = structuredClone(L.gpu);
  const h = mround(slots * 20.32 - g.pcb.h - L.fanDiskMm);
  g.heatsink.y = g.pcb.y + g.pcb.h;
  g.heatsink.h = h;
  g.slots = slots;
  g.thermal.A_fin_total_m2 = gpuFinArea(h);
  if (L.shroud) {
    const gap = L.shroud.yMm - (g.heatsink.y + h + L.fanDiskMm);
    if (gap < 10) {
      throw new LayoutError(
        'layout_set_gpu_slots:gap',
        `${slots} 槽显卡的风扇下沿距电源仓挡板只有 ${gap.toFixed(0)} mm（至少 10 mm），放不下`,
      );
    }
  }
  return { ...L, gpu: g };
}
