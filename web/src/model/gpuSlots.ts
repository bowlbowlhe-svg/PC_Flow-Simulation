// 显卡厚度（扩展槽数）：移植自 gpu_fin_area.m、layout_gpu_slots.m、layout_set_gpu_slots.m。
import { cloneLayout, type Layout } from './types';
import { mround } from './mround';

/** 显卡鳍片有效换热面积 [m²]，随散热片高度线性缩放：3.5 槽（散热片 47 mm）为 0.45 m²（与鳍片 h 一起标定的有效值，v4.8.0；之前 0.5 m² 配旧式 h） */
export function gpuFinArea(heatsinkMm: number): number {
  return (0.45 * heatsinkMm) / 47;
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
  // 热参数没有 h 参数的旧模型布局仍按旧标定 0.5·h/47（配旧式 h = 30 + 130·V），不把新旧标定混在一起（同 MATLAB）
  const th = g.thermal;
  const legacy = ([th.h_free, th.h_forced, th.h_exp] as unknown[]).every((v) => v === undefined || v === null);
  g.thermal.A_fin_total_m2 = legacy ? (0.5 * h) / 47 : gpuFinArea(h);
  if (L.shroud) {
    const gap = L.shroud.yMm - (g.heatsink.y + h + L.fanDiskMm);
    if (gap < 10) {
      throw new LayoutError(
        'layout_set_gpu_slots:gap',
        `${slots} 槽显卡的风扇下沿距电源仓挡板只有 ${gap.toFixed(0)} mm（至少 10 mm），放不下`,
      );
    }
  }
  const out = cloneLayout(L); // 值语义：不与输入共享嵌套对象
  out.gpu = g;
  return out;
}
