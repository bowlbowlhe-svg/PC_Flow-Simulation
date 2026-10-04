// 对比展示页的流场图：统计窗口内的时均温度与风速，裁到机箱外框外扩一圈（开口风量标注放得下），
// 附元件轮廓、风扇与各开口的时均净风量。预计算数据里温度存为灰度 PNG（全分辨率），速度两分量存为 RGB PNG（2×2 块平均），
// 都按 8 位量化；界面后台计算的自定义方案直接用浮点数组。
import type { GeoOverlay } from '../solver/geoOverlay';
import type { Mount } from '../model/types';

export interface Rect1 {
  x: number; // 1 基列
  y: number; // 1 基行
  w: number;
  h: number;
}

/** 开口（机箱风扇、电源风道、被动通风口）的标注位置（壁外侧，格坐标 1 基）与时均净风量（> 0 流出） */
export interface OpeningMean {
  x: number;
  y: number;
  mount: Mount;
  kind: string;
  cfm: number;
}

/** 统计窗口内的时均场（列优先 W×H，同求解器；u 沿列号增大、v 沿行号增大 [m/s]） */
export interface FieldMean {
  W: number;
  H: number;
  T: Float32Array; // 流体格为空气温度，障碍格为固体温度
  u: Float32Array;
  v: Float32Array;
  solid: Uint8Array; // 非 0 = 障碍（求解器的障碍类型码）
  openings: OpeningMean[];
}

/** 流场图（行优先：像素 (r, c) 在 r·w + c） */
export interface FieldThumb {
  crop: Rect1; // 在计算域里的位置（1 基格）
  cellMm: number;
  T: Float32Array; // crop.w × crop.h；NaN = 障碍
  /** 速度按 uvF×uvF 块平均：uw × uh */
  uvF: number;
  uw: number;
  uh: number;
  u: Float32Array;
  v: Float32Array;
  geo: GeoOverlay;
  openings: OpeningMean[];
}

/** 流场图来源：预计算数据（PNG，异步解码）或界面后台计算的自定义方案（浮点数组） */
export type ThumbSrc = FieldThumb | StoredThumb;

/** 预计算数据里的存法 */
export interface StoredThumb {
  v: 2;
  crop: Rect1;
  cellMm: number;
  uvF: number;
  uw: number;
  uh: number;
  tPng: string; // 灰度 PNG（base64），0 = 障碍，1–255 → THUMB_T_RANGE
  uvPng: string; // RGB PNG（base64），R = u、G = v（平方根压扩，128 = 0），B = 0
  geo: GeoOverlay;
  openings: OpeningMean[];
}

export const THUMB_T_RANGE: [number, number] = [20, 100];
/** 速度量化上限 [m/s]；平方根压扩：低速段分辨率高（死区、回流看得清） */
export const THUMB_V_MAX = 4;
/** 机箱外框外扩的宽度 [mm]（开口风量标注放在壁外侧） */
export const THUMB_MARGIN_MM = 36;

const clamp = (v: number, lo: number, hi: number) => Math.max(lo, Math.min(hi, v));

export function quantT(t: number): number {
  if (!Number.isFinite(t)) return 0;
  const [lo, hi] = THUMB_T_RANGE;
  return clamp(1 + Math.round(((t - lo) / (hi - lo)) * 254), 1, 255);
}
export const dequantT = (b: number) => (b === 0 ? NaN : THUMB_T_RANGE[0] + ((b - 1) / 254) * (THUMB_T_RANGE[1] - THUMB_T_RANGE[0]));

export function quantV(v: number): number {
  const a = Math.sqrt(Math.min(1, Math.abs(v) / THUMB_V_MAX));
  return clamp(128 + Math.sign(v) * Math.round(127 * a), 1, 255);
}
export function dequantV(b: number): number {
  const a = (b - 128) / 127;
  return Math.sign(a) * a * a * THUMB_V_MAX;
}

/** 百分位（忽略非有限值；空时 NaN） */
export function percentile(vals: number[], p: number): number {
  const f = vals.filter(Number.isFinite).sort((a, b) => a - b);
  if (!f.length) return NaN;
  return f[Math.min(f.length - 1, Math.max(0, Math.round((p / 100) * (f.length - 1))))];
}

/** 由时均场与元件轮廓做流场图：裁到机箱外框外扩 THUMB_MARGIN_MM（不超出计算域），速度按 uvF 块平均 */
export function makeFieldThumb(f: FieldMean, geo: GeoOverlay, uvF = 2): FieldThumb {
  const m = Math.round(THUMB_MARGIN_MM / geo.cellMm);
  const co = geo.caseOuter;
  const x0 = Math.max(1, co.x - m);
  const y0 = Math.max(1, co.y - m);
  const x1 = Math.min(f.H, co.x + co.w - 1 + m);
  const y1 = Math.min(f.W, co.y + co.h - 1 + m);
  const crop: Rect1 = { x: x0, y: y0, w: x1 - x0 + 1, h: y1 - y0 + 1 };
  const T = new Float32Array(crop.w * crop.h);
  for (let r = 0; r < crop.h; r++) {
    for (let c = 0; c < crop.w; c++) {
      const x = crop.x + c; // 1 基
      const y = crop.y + r;
      const i = (x - 1) * f.W + (y - 1);
      T[r * crop.w + c] = f.solid[i] > 0 ? NaN : f.T[i];
    }
  }
  const uw = Math.ceil(crop.w / uvF);
  const uh = Math.ceil(crop.h / uvF);
  const u = new Float32Array(uw * uh);
  const v = new Float32Array(uw * uh);
  for (let r = 0; r < uh; r++) {
    for (let c = 0; c < uw; c++) {
      let su = 0;
      let sv = 0;
      let n = 0;
      for (let dr = 0; dr < uvF; dr++) {
        for (let dc = 0; dc < uvF; dc++) {
          const cc = c * uvF + dc;
          const rr = r * uvF + dr;
          if (cc >= crop.w || rr >= crop.h) continue;
          const i = (crop.x - 1 + cc) * f.W + (crop.y - 1 + rr);
          su += f.u[i]; // 障碍格速度为 0，按 0 计入（块里有障碍时平均速度变小）
          sv += f.v[i];
          n++;
        }
      }
      u[r * uw + c] = n ? su / n : 0;
      v[r * uw + c] = n ? sv / n : 0;
    }
  }
  return {
    crop,
    cellMm: geo.cellMm,
    T,
    uvF,
    uw,
    uh,
    u,
    v,
    geo,
    openings: f.openings.map((o) => ({ ...o })),
  };
}

/** 机箱内流体格（不含电源内部：电源风扇半被动停转时里面可到 90°C，会把色标拉高）的格坐标是否计入色标统计 */
export function inScaleRegion(t: Pick<FieldThumb, 'crop' | 'geo'>, c: number, r: number): boolean {
  const x = t.crop.x + c;
  const y = t.crop.y + r;
  const co = t.geo.caseOuter;
  if (x < co.x || x >= co.x + co.w || y < co.y || y >= co.y + co.h) return false;
  const pb = t.geo.psu?.body;
  return !(pb && x >= pb.x && x < pb.x + pb.w && y >= pb.y && y < pb.y + pb.h);
}

/** 色标统计：机箱内（不含电源内部）流体格的温度、风速 99 百分位（各方案共用色标的上限） */
export function fieldStats(t: FieldThumb): { t99: number; s99: number } {
  const tv: number[] = [];
  const sv: number[] = [];
  for (let r = 0; r < t.crop.h; r++)
    for (let c = 0; c < t.crop.w; c++) {
      const k = r * t.crop.w + c;
      if (!Number.isFinite(t.T[k]) || !inScaleRegion(t, c, r)) continue;
      tv.push(t.T[k]);
      const [u, v] = sampleVel(t, c + 0.5, r + 0.5);
      sv.push(Math.hypot(u, v));
    }
  return { t99: percentile(tv, 99), s99: percentile(sv, 99) };
}

/** 量化为存储用的像素（PNG 编码在 scripts/compareData.ts） */
export function thumbPixels(t: FieldThumb): { gray: Uint8Array; rgb: Uint8Array } {
  const gray = new Uint8Array(t.T.length);
  for (let k = 0; k < t.T.length; k++) gray[k] = quantT(t.T[k]);
  const rgb = new Uint8Array(t.uw * t.uh * 3);
  for (let k = 0; k < t.uw * t.uh; k++) {
    rgb[3 * k] = quantV(t.u[k]);
    rgb[3 * k + 1] = quantV(t.v[k]);
    rgb[3 * k + 2] = 0;
  }
  return { gray, rgb };
}

/** 解码后的像素（canvas getImageData 的 RGBA）还原为流场图 */
export function thumbFromPixels(s: StoredThumb, tRgba: Uint8ClampedArray, uvRgba: Uint8ClampedArray): FieldThumb {
  const n = s.crop.w * s.crop.h;
  const T = new Float32Array(n);
  for (let k = 0; k < n; k++) T[k] = dequantT(tRgba[4 * k]);
  const m = s.uw * s.uh;
  const u = new Float32Array(m);
  const v = new Float32Array(m);
  for (let k = 0; k < m; k++) {
    u[k] = dequantV(uvRgba[4 * k]);
    v[k] = dequantV(uvRgba[4 * k + 1]);
  }
  return { crop: s.crop, cellMm: s.cellMm, T, uvF: s.uvF, uw: s.uw, uh: s.uh, u, v, geo: s.geo, openings: s.openings };
}

/** 双线性插值的速度（流场图格坐标：格 (c, r) 中心在 (c + 0.5, r + 0.5)） */
export function sampleVel(t: Pick<FieldThumb, 'uvF' | 'uw' | 'uh' | 'u' | 'v'>, x: number, y: number): [number, number] {
  const gx = clamp(x / t.uvF - 0.5, 0, t.uw - 1);
  const gy = clamp(y / t.uvF - 0.5, 0, t.uh - 1);
  const c0 = Math.min(t.uw - 2, Math.floor(gx));
  const r0 = Math.min(t.uh - 2, Math.floor(gy));
  if (c0 < 0 || r0 < 0) {
    const k = Math.round(gy) * t.uw + Math.round(gx);
    return [t.u[k], t.v[k]];
  }
  const fx = gx - c0;
  const fy = gy - r0;
  const k = r0 * t.uw + c0;
  const lerp = (a: Float32Array) =>
    (1 - fy) * ((1 - fx) * a[k] + fx * a[k + 1]) + fy * ((1 - fx) * a[k + t.uw] + fx * a[k + t.uw + 1]);
  return [lerp(t.u), lerp(t.v)];
}
