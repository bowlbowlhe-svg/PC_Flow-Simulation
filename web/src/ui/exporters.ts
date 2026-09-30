// 导出：主视图 PNG（含标题与色标）与 GIF 录制（gifenc 编码）。
import { applyPalette, GIFEncoder, quantize } from 'gifenc';
import { colormapLUT, type ColormapName } from './colormap';

export interface ViewCaption {
  title: string;
  unit: string;
  cmap: ColormapName;
  clim: [number, number];
}

/** 主视图 + 标题 + 色标合成一张图；scale 为输出相对主视图画布的缩放 */
export function compositeImage(field: HTMLCanvasElement, cap: ViewCaption, scale = 1): HTMLCanvasElement {
  const fw = Math.round(field.width * scale);
  const fh = Math.round(field.height * scale);
  const pad = Math.round(8 * Math.max(scale, 0.6) * (field.width > 900 ? 1.5 : 1));
  const top = pad * 4;
  const barW = pad * 2;
  const right = barW + pad * 7;
  const c = document.createElement('canvas');
  c.width = fw + right + pad;
  c.height = fh + top + pad;
  const ctx = c.getContext('2d')!;
  ctx.fillStyle = '#0d0d14';
  ctx.fillRect(0, 0, c.width, c.height);
  ctx.drawImage(field, pad, top, fw, fh);
  ctx.fillStyle = '#ccccff';
  ctx.font = `${Math.round(pad * 1.8)}px system-ui, sans-serif`;
  ctx.textAlign = 'center';
  ctx.textBaseline = 'middle';
  ctx.fillText(cap.title, pad + fw / 2, top / 2);
  // 色标
  const lut = colormapLUT(cap.cmap);
  const x0 = pad + fw + pad * 2;
  for (let y = 0; y < fh; y++) {
    const i = Math.round((1 - y / Math.max(fh - 1, 1)) * 255) * 3;
    ctx.fillStyle = `rgb(${lut[i]},${lut[i + 1]},${lut[i + 2]})`;
    ctx.fillRect(x0, top + y, barW, 1);
  }
  ctx.fillStyle = '#b3b3cc';
  ctx.font = `${Math.round(pad * 1.4)}px system-ui, sans-serif`;
  ctx.textAlign = 'left';
  ctx.textBaseline = 'top';
  ctx.fillText(fmt(cap.clim[1]), x0 + barW + pad / 2, top);
  ctx.textBaseline = 'bottom';
  ctx.fillText(fmt(cap.clim[0]), x0 + barW + pad / 2, top + fh);
  ctx.save();
  ctx.translate(x0 + barW + pad * 3.5, top + fh / 2);
  ctx.rotate(-Math.PI / 2);
  ctx.textAlign = 'center';
  ctx.textBaseline = 'middle';
  ctx.fillText(cap.unit, 0, 0);
  ctx.restore();
  return c;
}

const fmt = (v: number) => (Math.abs(v) >= 10 || Number.isInteger(v) ? v.toFixed(0) : v.toFixed(1));

export function downloadBlob(blob: Blob, name: string): void {
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = name;
  document.body.appendChild(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 5000);
}

export function timestamp(): string {
  const d = new Date();
  const p = (n: number) => String(n).padStart(2, '0');
  return `${d.getFullYear()}${p(d.getMonth() + 1)}${p(d.getDate())}_${p(d.getHours())}${p(d.getMinutes())}${p(d.getSeconds())}`;
}

/** GIF 录制：逐帧量化到 256 色，结束时生成 Blob */
export class GifRecorder {
  private enc = GIFEncoder();
  frames = 0;
  constructor(
    readonly maxFrames = 300,
    readonly delayMs = 150,
  ) {}

  private pending: { index: Uint8Array; palette: number[][]; w: number; h: number; t: number } | null = null;

  /**
   * 加一帧。帧的延时按实际取帧间隔写（浏览器忙时定时器会变慢，固定写 150 ms 回放会偏快）：
   * 上一帧在拿到下一帧的时间戳后才写出。
   */
  addFrame(img: HTMLCanvasElement, now = performance.now()): boolean {
    if (this.frames >= this.maxFrames) return false;
    const ctx = img.getContext('2d')!;
    const { data } = ctx.getImageData(0, 0, img.width, img.height);
    const palette = quantize(data, 256);
    const index = applyPalette(data, palette);
    this.flush(now);
    this.pending = { index, palette, w: img.width, h: img.height, t: now };
    this.frames++;
    return this.frames < this.maxFrames;
  }

  private flush(now: number): void {
    const p = this.pending;
    if (!p) return;
    const delay = Math.max(20, Math.round((now - p.t) / 10) * 10);
    this.enc.writeFrame(p.index, p.w, p.h, { palette: p.palette, delay });
    this.pending = null;
  }

  finish(): Blob {
    this.flush((this.pending?.t ?? 0) + this.delayMs);
    this.enc.finish();
    return new Blob([this.enc.bytes() as BlobPart], { type: 'image/gif' });
  }
}
