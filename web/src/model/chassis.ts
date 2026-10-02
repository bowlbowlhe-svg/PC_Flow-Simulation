// 机箱尺寸与位置：chassis.sizeMm 为标量（见方）或 [深 高]，chassis.originMm 为标量（x = y）或 [x y]。
// 取值同 MATLAB 的 v(1)、v(end)（JSON 读回的列向量、单元素数组都按此解释）。
import type { Layout } from './types';

/** 标量或数组 → [第一个, 最后一个] */
export function pairMm(v: number | readonly number[]): [number, number] {
  return Array.isArray(v) ? [v[0], v[v.length - 1]] : [v as number, v as number];
}

/** 机箱 [深（x，后 → 前）, 高（y，顶 → 底）] mm */
export const chassisSizeMm = (L: Pick<Layout, 'chassis'>): [number, number] => pairMm(L.chassis.sizeMm);

/** 机箱外沿左上角在计算域中的 [x, y] mm */
export const chassisOriginMm = (L: Pick<Layout, 'chassis'>): [number, number] => pairMm(L.chassis.originMm);
