// 对比展示页流场图的着色口径与读数（纯函数，单元测试用）。
import { sampleVel, type FieldThumb } from '../../compare/thumb';

export type FieldMode = 'temperature' | 'speed' | 'diff';

export interface FieldStyle {
  mode: FieldMode;
  /** 温度 [lo, hi]（lo 为环境温度）、风速 [0, hi]、温差 [−D, D] */
  range: [number, number];
  /** 温差的参考方案（同尺寸机箱）；null = 没有可比的参考 */
  ref?: FieldThumb | null;
  /** 参考方案还在解码（温差先画成中性色，不提示"不可比"） */
  refLoading?: boolean;
  stream: boolean;
  labels: boolean;
}

/** 两张流场图能否逐格相减（同一机箱尺寸与网格） */
export const sameGrid = (a: FieldThumb, b: FieldThumb) =>
  a.crop.w === b.crop.w && a.crop.h === b.crop.h && a.crop.x === b.crop.x && a.crop.y === b.crop.y && a.cellMm === b.cellMm;

/** 某格的读数（大图悬停） */
export function readout(t: FieldThumb, c: number, r: number, style: FieldStyle): string {
  if (c < 0 || r < 0 || c >= t.crop.w || r >= t.crop.h) return '';
  const k = r * t.crop.w + c;
  const xMm = ((t.crop.x + c - t.geo.caseOuter.x) * t.cellMm).toFixed(0);
  const yMm = ((t.crop.y + r - t.geo.caseOuter.y) * t.cellMm).toFixed(0);
  const pos = `距后壁 ${xMm} mm、距顶 ${yMm} mm`;
  if (!Number.isFinite(t.T[k])) return `${pos}：障碍`;
  const [u, v] = sampleVel(t, c + 0.5, r + 0.5);
  let s = `${pos}：${t.T[k].toFixed(1)}°C，风速 ${Math.hypot(u, v).toFixed(2)} m/s`;
  if (style.mode === 'diff' && style.ref && sameGrid(t, style.ref) && Number.isFinite(style.ref.T[k])) {
    const d = t.T[k] - style.ref.T[k];
    s += `，温差 ${d >= 0 ? '+' : ''}${d.toFixed(1)}°C`;
  }
  return s;
}

