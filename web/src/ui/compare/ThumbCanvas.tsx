// 方案缩略图：机箱侧视的温度或风速（预计算数据为 PNG，解码后按色图重画；障碍为深灰）。
import { useEffect, useRef, useState } from 'preact/hooks';
import { thumbFromRgba, thumbSpeed, thumbT, THUMB_SPEED_MAX, THUMB_T_RANGE, type Thumb } from '../../compare/thumb';
import { colormapLUT } from '../colormap';
import type { ThumbSrc } from './schemes';

const cache = new Map<string, Promise<Thumb>>();

/** PNG（base64）解码为缩略图；同一张图只解码一次 */
function decode(src: { w: number; h: number; png: string }): Promise<Thumb> {
  let p = cache.get(src.png);
  if (!p) {
    p = new Promise((resolve, reject) => {
      const img = new Image();
      img.onload = () => {
        const c = document.createElement('canvas');
        c.width = src.w;
        c.height = src.h;
        const g = c.getContext('2d', { willReadFrequently: true })!;
        g.drawImage(img, 0, 0);
        resolve(thumbFromRgba(src.w, src.h, g.getImageData(0, 0, src.w, src.h).data));
      };
      img.onerror = () => reject(new Error('缩略图解码失败'));
      img.src = `data:image/png;base64,${src.png}`;
    });
    cache.set(src.png, p);
  }
  return p;
}

export type ThumbMode = 'temperature' | 'speed';

export function ThumbCanvas({ src, mode, tMax, title }: { src: ThumbSrc; mode: ThumbMode; tMax: number; title?: string }) {
  const ref = useRef<HTMLCanvasElement>(null);
  const [th, setTh] = useState<Thumb | null>('T' in src ? src : null);
  const [failed, setFailed] = useState(false);
  useEffect(() => {
    if ('T' in src) setTh(src);
    else {
      let live = true;
      setFailed(false);
      decode(src).then(
        (t) => live && setTh(t),
        () => {
          if (live) {
            setTh(null);
            setFailed(true);
          }
        },
      );
      return () => {
        live = false;
      };
    }
  }, [src]);
  useEffect(() => {
    const c = ref.current;
    if (!c || !th) return;
    c.width = th.w;
    c.height = th.h;
    const g = c.getContext('2d')!;
    const im = g.createImageData(th.w, th.h);
    const lut = colormapLUT(mode === 'temperature' ? 'heat' : 'speed');
    const lo = mode === 'temperature' ? THUMB_T_RANGE[0] : 0;
    const hi = mode === 'temperature' ? tMax : THUMB_SPEED_MAX;
    for (let k = 0; k < th.w * th.h; k++) {
      let r = 40;
      let gg = 40;
      let b = 52;
      if (!th.solid[k] || mode === 'temperature') {
        const v = mode === 'temperature' ? thumbT(th.T[k]) : thumbSpeed(th.speed[k]);
        const t = Math.max(0, Math.min(1, (v - lo) / (hi - lo)));
        const j = Math.round(t * 255);
        r = lut[3 * j];
        gg = lut[3 * j + 1];
        b = lut[3 * j + 2];
        if (th.solid[k]) {
          // 温度视图里固体按其温度着色并压暗，便于分辨元件
          r = Math.round(r * 0.55);
          gg = Math.round(gg * 0.55);
          b = Math.round(b * 0.55);
        }
      }
      im.data[4 * k] = r;
      im.data[4 * k + 1] = gg;
      im.data[4 * k + 2] = b;
      im.data[4 * k + 3] = 255;
    }
    g.putImageData(im, 0, 0);
  }, [th, mode, tMax]);
  // 宽高比按缩略图本身（机箱尺寸不同的自定义方案不被拉伸）
  const ar = 'T' in src || th ? `${(th ?? (src as Thumb)).w} / ${(th ?? (src as Thumb)).h}` : `${src.w} / ${src.h}`;
  return th ? (
    <canvas ref={ref} class="thumb-canvas" title={title} style={{ aspectRatio: ar }} />
  ) : (
    <div class="thumb-canvas thumb-loading" style={{ aspectRatio: ar }}>
      {failed ? '缩略图无法显示' : '…'}
    </div>
  );
}
