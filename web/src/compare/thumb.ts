// 对比展示页的缩略图：机箱范围内的温度、风速与障碍，按块下采样后量化为 8 位（预计算数据里存成 RGB PNG）。
import type { FieldSnap } from './protocol';

export interface Rect1 {
  x: number; // 1 基列
  y: number; // 1 基行
  w: number;
  h: number;
}

/** 行优先的小图（像素 (r, c) 在 r·w + c） */
export interface Thumb {
  w: number;
  h: number;
  T: Uint8Array; // 温度量化（THUMB_T_RANGE）
  speed: Uint8Array; // 风速量化（0–THUMB_SPEED_MAX m/s）
  solid: Uint8Array; // 1 = 障碍（块内多数为障碍）
}

export const THUMB_T_RANGE: [number, number] = [25, 85];
export const THUMB_SPEED_MAX = 2;

const q8 = (v: number, lo: number, hi: number) => Math.max(0, Math.min(255, Math.round(((v - lo) / (hi - lo)) * 255)));

/** 裁到 crop（含边界）并按 factor×factor 块平均（温度、风速取块内全部格的均值） */
export function makeThumb(f: FieldSnap, crop: Rect1, factor = 2): Thumb {
  const w = Math.floor(crop.w / factor);
  const h = Math.floor(crop.h / factor);
  const T = new Uint8Array(w * h);
  const speed = new Uint8Array(w * h);
  const solid = new Uint8Array(w * h);
  for (let r = 0; r < h; r++) {
    for (let c = 0; c < w; c++) {
      let st = 0;
      let ss = 0;
      let ns = 0;
      let n = 0;
      for (let dr = 0; dr < factor; dr++) {
        for (let dc = 0; dc < factor; dc++) {
          const y = crop.y - 1 + r * factor + dr; // 0 基行
          const x = crop.x - 1 + c * factor + dc; // 0 基列
          if (x < 0 || y < 0 || x >= f.H || y >= f.W) continue;
          const i = x * f.W + y;
          st += f.T[i];
          ss += f.speed[i];
          ns += f.solid[i];
          n++;
        }
      }
      const k = r * w + c;
      if (!n) continue;
      T[k] = q8(st / n, THUMB_T_RANGE[0], THUMB_T_RANGE[1]);
      speed[k] = q8(ss / n, 0, THUMB_SPEED_MAX);
      solid[k] = 2 * ns >= n ? 1 : 0;
    }
  }
  return { w, h, T, speed, solid };
}

/** 量化值还原为物理量 */
export const thumbT = (b: number) => THUMB_T_RANGE[0] + (b / 255) * (THUMB_T_RANGE[1] - THUMB_T_RANGE[0]);
export const thumbSpeed = (b: number) => (b / 255) * THUMB_SPEED_MAX;

/** 打包为 RGB（R 温度、G 风速、B 障碍 255） */
export function thumbToRgb(t: Thumb): Uint8Array {
  const out = new Uint8Array(t.w * t.h * 3);
  for (let k = 0; k < t.w * t.h; k++) {
    out[3 * k] = t.T[k];
    out[3 * k + 1] = t.speed[k];
    out[3 * k + 2] = t.solid[k] ? 255 : 0;
  }
  return out;
}

/** RGBA 像素（canvas getImageData）还原为缩略图 */
export function thumbFromRgba(w: number, h: number, rgba: Uint8ClampedArray): Thumb {
  const T = new Uint8Array(w * h);
  const speed = new Uint8Array(w * h);
  const solid = new Uint8Array(w * h);
  for (let k = 0; k < w * h; k++) {
    T[k] = rgba[4 * k];
    speed[k] = rgba[4 * k + 1];
    solid[k] = rgba[4 * k + 2] > 127 ? 1 : 0;
  }
  return { w, h, T, speed, solid };
}
