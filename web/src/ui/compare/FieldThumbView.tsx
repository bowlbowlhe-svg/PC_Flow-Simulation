// 对比展示页的流场图：时均温度 / 风速 / 与参考方案的温差，叠加时均流线（带流向箭头）、元件轮廓与风扇、各开口时均净风量。
// 卡片里是小图；点开为大图（流线更密、标注更全、悬停读数）。
import { useEffect, useRef, useState } from 'preact/hooks';
import { sampleVel, thumbFromPixels, type FieldThumb, type ThumbSrc } from '../../compare/thumb';
import { readout, sameGrid, type FieldStyle } from './fieldMath';
import { colormapLUT } from '../colormap';
import { drawGeometry, flowText } from '../geoDraw';
import { traceStreamlines, type Streamline } from './streamlines';

const BG = [13, 13, 20];
const SOLID = [58, 62, 78];
/** 温度色标下端留出的一段（环境温度不显示成纯黑，与机箱外背景区分开） */
export const HEAT_FLOOR = 0.12;

const cache = new Map<string, Promise<FieldThumb>>();

function loadPng(b64: string): Promise<Uint8ClampedArray> {
  return new Promise((resolve, reject) => {
    const img = new Image();
    img.onload = () => {
      const c = document.createElement('canvas');
      c.width = img.width;
      c.height = img.height;
      const g = c.getContext('2d', { willReadFrequently: true })!;
      g.drawImage(img, 0, 0);
      resolve(g.getImageData(0, 0, img.width, img.height).data);
    };
    img.onerror = () => reject(new Error('流场图解码失败'));
    img.src = `data:image/png;base64,${b64}`;
  });
}

/** 预计算数据的 PNG 解码为流场图（同一数据只解码一次）；自定义方案直接返回 */
export function decodeThumb(src: ThumbSrc): Promise<FieldThumb> {
  if (!('tPng' in src)) return Promise.resolve(src);
  let p = cache.get(src.tPng);
  if (!p) {
    p = Promise.all([loadPng(src.tPng), loadPng(src.uvPng)]).then(([t, uv]) => thumbFromPixels(src, t, uv));
    cache.set(src.tPng, p);
    p.catch(() => cache.delete(src.tPng));
  }
  return p;
}

/** 解码流场图；只返回与当前 src 对应的结果（切换方案或场景时不会短暂用上一张） */
export function useThumb(src: ThumbSrc | undefined): { t: FieldThumb | null; failed: boolean; loading: boolean } {
  const [st, setSt] = useState<{ src: ThumbSrc | undefined; t: FieldThumb | null; failed: boolean }>({
    src,
    t: src && !('tPng' in src) ? src : null,
    failed: false,
  });
  useEffect(() => {
    if (!src) return;
    let live = true;
    decodeThumb(src).then(
      (t) => live && setSt({ src, t, failed: false }),
      () => live && setSt({ src, t: null, failed: true }),
    );
    return () => {
      live = false;
    };
  }, [src]);
  if (!src) return { t: null, failed: false, loading: false };
  if (st.src !== src) return { t: !('tPng' in src) ? src : null, failed: false, loading: 'tPng' in src };
  return { t: st.t, failed: st.failed, loading: !st.t && !st.failed };
}

const streamCache = new WeakMap<FieldThumb, Map<number, Streamline[]>>();
/** 流线间距 [mm]：卡片 12、大图 7 */
const dsepOf = (large: boolean) => (large ? 7 : 12);

/** 已算好的流线（没有则 null） */
function cachedStreams(t: FieldThumb, large: boolean): Streamline[] | null {
  return streamCache.get(t)?.get(dsepOf(large)) ?? null;
}

// 流线逐个排队在后台任务里算（一次一张），先画着色与轮廓，切场景时界面不卡
const queue: (() => void)[] = [];
let pumping = false;
function enqueue(job: () => void): void {
  queue.push(job);
  if (pumping) return;
  pumping = true;
  const pump = () => {
    const j = queue.shift();
    if (!j) {
      pumping = false;
      return;
    }
    j();
    setTimeout(pump, 0);
  };
  setTimeout(pump, 0);
}

/** 流线（按间距缓存）；间距按 mm 给 */
function streamsOf(t: FieldThumb, dsepMm: number): Streamline[] {
  let m = streamCache.get(t);
  if (!m) streamCache.set(t, (m = new Map()));
  let s = m.get(dsepMm);
  if (!s) {
    const dsep = dsepMm / t.cellMm;
    // 种子在机箱内；流线可伸出机箱 10 mm（看得出进、出风方向），机箱外的环境气流不画
    const co = t.geo.caseOuter;
    const seedBox = { x0: co.x - t.crop.x, y0: co.y - t.crop.y, x1: co.x - t.crop.x + co.w, y1: co.y - t.crop.y + co.h };
    const ext = 10 / t.cellMm;
    const box = { x0: seedBox.x0 - ext, y0: seedBox.y0 - ext, x1: seedBox.x1 + ext, y1: seedBox.y1 + ext };
    const step = Math.min(0.5, 1 / t.cellMm); // 格（约 1 mm）
    // 单向最长 600 mm（与网格无关）
    s = traceStreamlines(t, { dsep, dtest: 0.5 * dsep, step, vmin: 0.03, maxSteps: Math.round(600 / (step * t.cellMm)), seedBox, box });
    m.set(dsepMm, s);
  }
  return s;
}

/** 画流场图；cssW 为显示宽度 [CSS px]，large = 大图（流线更密、标注更全）；lines = null 时先不画流线 */
export function drawFieldThumb(c: HTMLCanvasElement, t: FieldThumb, style: FieldStyle, cssW: number, large: boolean, lines: Streamline[] | null = streamsOf(t, dsepOf(large))): void {
  const dpr = Math.min(window.devicePixelRatio || 1, 2);
  const { w, h } = t.crop;
  const cssH = (cssW * h) / w;
  c.width = Math.round(cssW * dpr);
  c.height = Math.round(cssH * dpr);
  c.style.height = `${cssH}px`;
  const ctx = c.getContext('2d')!;
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  const sc = cssW / w; // 每格 CSS px

  // 场着色（机箱外的一圈压暗，突出机箱内部）
  const img = document.createElement('canvas');
  img.width = w;
  img.height = h;
  const g = img.getContext('2d')!;
  const im = g.createImageData(w, h);
  const d = im.data;
  const [lo, hi] = style.range;
  const co = t.geo.caseOuter;
  const ref = style.mode === 'diff' && style.ref && sameGrid(t, style.ref) ? style.ref : null;
  const lut = colormapLUT(style.mode === 'temperature' ? 'heat' : style.mode === 'speed' ? 'speed' : 'diverging');
  for (let r = 0; r < h; r++) {
    for (let cc = 0; cc < w; cc++) {
      const k = r * w + cc;
      let col: number[] | null = null;
      let val = NaN;
      if (Number.isFinite(t.T[k])) {
        if (style.mode === 'temperature') val = HEAT_FLOOR + (1 - HEAT_FLOOR) * ((t.T[k] - lo) / (hi - lo));
        else if (style.mode === 'speed') {
          const [u, v] = sampleVel(t, cc + 0.5, r + 0.5);
          val = Math.hypot(u, v) / hi;
        } else if (ref && Number.isFinite(ref.T[k])) val = 0.5 + (0.5 * (t.T[k] - ref.T[k])) / hi;
        else if (!ref) val = 0.5; // 没有可比的参考（或参考还在解码）：中性色
      }
      if (Number.isFinite(val)) {
        const j = 3 * Math.max(0, Math.min(255, Math.round(val * 255)));
        col = [lut[j], lut[j + 1], lut[j + 2]];
      } else col = SOLID;
      const x = t.crop.x + cc;
      const y = t.crop.y + r;
      const outside = x < co.x || x >= co.x + co.w || y < co.y || y >= co.y + co.h;
      const p = 4 * k;
      for (let q = 0; q < 3; q++) d[p + q] = outside ? Math.round(0.45 * col[q] + 0.55 * BG[q]) : col[q];
      d[p + 3] = 255;
    }
  }
  g.putImageData(im, 0, 0);
  ctx.fillStyle = `rgb(${BG.join(',')})`;
  ctx.fillRect(0, 0, cssW, cssH);
  ctx.imageSmoothingEnabled = true;
  ctx.imageSmoothingQuality = 'high';
  ctx.drawImage(img, 0, 0, cssW, cssH);

  // 时均流线：按风速分 5 档透明度一起描；箭头沿流向等弧长放置
  if (style.stream && lines) {
    const dark = style.mode === 'diff';
    const rgb = dark ? '20,22,32' : '255,255,255';
    const vref = 0.8;
    const levels = 5;
    const paths = Array.from({ length: levels }, () => new Path2D());
    const heads = new Path2D();
    const arrowGap = (large ? 26 : 40) / t.cellMm; // 格
    const ah = large ? 4.2 : 3.2; // 箭头大小 [CSS px]
    for (const L of lines) {
      let acc = arrowGap * 0.5;
      for (let i = 0; i + 1 < L.x.length; i++) {
        const s = 0.5 * (L.speed[i] + L.speed[i + 1]);
        const lv = Math.min(levels - 1, Math.floor((Math.min(1, s / vref) ** 0.7) * levels));
        paths[lv].moveTo(L.x[i] * sc, L.y[i] * sc);
        paths[lv].lineTo(L.x[i + 1] * sc, L.y[i + 1] * sc);
        const dx = L.x[i + 1] - L.x[i];
        const dy = L.y[i + 1] - L.y[i];
        const seg = Math.hypot(dx, dy);
        acc += seg;
        if (acc >= arrowGap && seg > 0) {
          acc = 0;
          const ux = dx / seg;
          const uy = dy / seg;
          const px = L.x[i + 1] * sc;
          const py = L.y[i + 1] * sc;
          heads.moveTo(px - ah * ux - 0.6 * ah * uy, py - ah * uy + 0.6 * ah * ux);
          heads.lineTo(px, py);
          heads.lineTo(px - ah * ux + 0.6 * ah * uy, py - ah * uy - 0.6 * ah * ux);
        }
      }
    }
    ctx.lineCap = 'round';
    ctx.lineJoin = 'round';
    ctx.lineWidth = large ? 1.3 : 1;
    paths.forEach((p, lv) => {
      ctx.strokeStyle = `rgba(${rgb},${(0.12 + (0.58 * (lv + 1)) / levels).toFixed(2)})`;
      ctx.stroke(p);
    });
    ctx.lineWidth = large ? 1.5 : 1.2;
    ctx.strokeStyle = `rgba(${rgb},0.8)`;
    ctx.stroke(heads);
  }

  // 元件轮廓与风扇（几何为计算域的 1 基格坐标，平移到流场图）
  ctx.save();
  ctx.translate(-(t.crop.x - 1) * sc, -(t.crop.y - 1) * sc);
  drawGeometry(ctx, t.geo, sc, { halo: true, minorLabels: large });
  ctx.restore();

  // 各开口的时均净风量（CFM；橙色流出、青色流入）
  if (style.labels) {
    ctx.font = `bold ${large ? 13 : 10}px system-ui, sans-serif`;
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';
    for (const o of t.openings) {
      if (Math.abs(o.cfm) < 0.5) continue;
      const txt = flowText(o.mount, o.cfm);
      const pad = large ? 16 : 12;
      const x = Math.min(Math.max((o.x - t.crop.x + 0.5) * sc, pad), cssW - pad);
      const y = Math.min(Math.max((o.y - t.crop.y + 0.5) * sc, 7), cssH - 7);
      ctx.lineWidth = 3;
      ctx.lineJoin = 'round';
      ctx.strokeStyle = 'rgba(0,0,0,0.75)';
      ctx.strokeText(txt, x, y);
      ctx.fillStyle = o.cfm > 0 ? 'rgb(255,158,77)' : 'rgb(89,230,255)';
      ctx.fillText(txt, x, y);
    }
  }
  if (style.mode === 'diff' && !ref && !style.refLoading) {
    ctx.font = `${large ? 14 : 11}px system-ui, sans-serif`;
    ctx.textAlign = 'center';
    ctx.fillStyle = 'rgb(230,230,230)';
    ctx.fillText('网格或机箱尺寸与参考方案不同，不能逐点相减', cssW / 2, cssH / 2);
  }
}

export function FieldThumbView(p: {
  src: ThumbSrc;
  style: FieldStyle;
  large?: boolean;
  title?: string;
  onClick?: () => void;
  onHover?: (text: string) => void;
}) {
  const ref = useRef<HTMLCanvasElement>(null);
  const wrap = useRef<HTMLDivElement>(null);
  const { t, failed } = useThumb(p.src);
  const [cssW, setCssW] = useState(0);
  useEffect(() => {
    const el = wrap.current;
    if (!el) return;
    const ro = new ResizeObserver(() => setCssW(Math.floor(el.clientWidth)));
    ro.observe(el);
    setCssW(Math.floor(el.clientWidth));
    return () => ro.disconnect();
  }, []);
  const s = p.style;
  useEffect(() => {
    const c = ref.current;
    if (!c || !t || cssW <= 0) return;
    const large = !!p.large;
    const lines = cachedStreams(t, large);
    drawFieldThumb(c, t, s, cssW, large, lines);
    if (!s.stream || lines) return;
    let live = true;
    enqueue(() => {
      if (!live || !ref.current) return;
      drawFieldThumb(ref.current, t, s, cssW, large);
    });
    return () => {
      live = false;
    };
  }, [t, cssW, s.mode, s.range[0], s.range[1], s.ref, s.refLoading, s.stream, s.labels, p.large]);
  const ar = `${p.src.crop.w} / ${p.src.crop.h}`;
  const move = (e: MouseEvent) => {
    if (!p.onHover || !t || cssW <= 0) return;
    const r = (e.currentTarget as HTMLCanvasElement).getBoundingClientRect();
    const sc = r.width / t.crop.w;
    p.onHover(readout(t, Math.floor((e.clientX - r.left) / sc), Math.floor((e.clientY - r.top) / sc), s));
  };
  return (
    <div ref={wrap} class={`field-thumb${p.large ? ' large' : ''}${p.onClick ? ' clickable' : ''}`} style={{ aspectRatio: ar, '--ar': String(p.src.crop.w / p.src.crop.h) }} onClick={p.onClick} title={p.title}>
      {t ? (
        <canvas ref={ref} class="thumb-canvas" onMouseMove={move} onMouseLeave={() => p.onHover?.('')} />
      ) : (
        <div class="thumb-canvas thumb-loading">{failed ? '流场图无法显示' : '…'}</div>
      )}
    </div>
  );
}
