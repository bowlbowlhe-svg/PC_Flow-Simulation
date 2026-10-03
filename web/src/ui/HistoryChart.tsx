// 温度曲线：CPU / GPU 结温与后侧排气温度随仿真时间变化（同 MATLAB 下方"温度曲线"）。
import { useEffect, useRef } from 'preact/hooks';

export interface HistoryPoint {
  t: number;
  cpu: number;
  gpu: number;
  rear: number;
}

const SERIES: { key: keyof Omit<HistoryPoint, 't'>; name: string; color: string }[] = [
  { key: 'cpu', name: 'CPU', color: 'rgb(255,77,77)' },
  { key: 'gpu', name: 'GPU', color: 'rgb(77,255,77)' },
  { key: 'rear', name: '后侧排气', color: 'rgb(77,153,255)' },
];

export function HistoryChart({ data, note }: { data: HistoryPoint[]; note: string }) {
  const ref = useRef<HTMLCanvasElement>(null);
  useEffect(() => {
    const c = ref.current;
    if (!c) return;
    const css = c.clientWidth;
    const cssH = c.clientHeight;
    const dpr = Math.min(window.devicePixelRatio || 1, 2);
    if (c.width !== Math.round(css * dpr)) c.width = Math.round(css * dpr);
    if (c.height !== Math.round(cssH * dpr)) c.height = Math.round(cssH * dpr);
    const ctx = c.getContext('2d')!;
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.clearRect(0, 0, css, cssH);
    const L = 40;
    const R = 10;
    const T = 22;
    const B = 36;
    const w = css - L - R;
    const h = cssH - T - B;
    // 纵轴 20–110°C（数据超出时扩展）
    let lo = 20;
    let hi = 110;
    for (const d of data) for (const s of SERIES) if (Number.isFinite(d[s.key])) hi = Math.max(hi, d[s.key] + 5);
    const t0 = data.length ? data[0].t : 0;
    const t1 = data.length > 1 ? data[data.length - 1].t : t0 + 1;
    const xs = (t: number) => L + ((t - t0) / Math.max(t1 - t0, 1e-9)) * w;
    const ys = (v: number) => T + (1 - (v - lo) / (hi - lo)) * h;
    ctx.strokeStyle = 'rgba(100,100,128,0.35)';
    ctx.fillStyle = 'rgb(150,150,170)';
    ctx.lineWidth = 1;
    ctx.font = '11px system-ui, sans-serif';
    ctx.textAlign = 'right';
    ctx.textBaseline = 'middle';
    for (let v = 20; v <= hi; v += 20) {
      ctx.beginPath();
      ctx.moveTo(L, ys(v));
      ctx.lineTo(L + w, ys(v));
      ctx.stroke();
      ctx.fillText(`${v}`, L - 5, ys(v));
    }
    ctx.textAlign = 'center';
    ctx.textBaseline = 'top';
    const span = t1 - t0;
    const step = niceStep(span / 6);
    const digits = Math.max(0, -Math.floor(Math.log10(step) + 1e-9));
    for (let k = Math.ceil(t0 / step - 1e-9); k * step <= t1 + 1e-9; k++) ctx.fillText((k * step).toFixed(digits), xs(k * step), T + h + 5);
    ctx.textAlign = 'right';
    ctx.fillText('仿真时间 (s)', L + w, T + h + 20);
    ctx.save();
    ctx.translate(12, T + h / 2);
    ctx.rotate(-Math.PI / 2);
    ctx.textAlign = 'center';
    ctx.fillText('温度 (°C)', 0, -6);
    ctx.restore();
    ctx.lineWidth = 1.6;
    for (const s of SERIES) {
      ctx.strokeStyle = s.color;
      ctx.beginPath();
      let pen = false;
      for (const d of data) {
        const v = d[s.key];
        if (!Number.isFinite(v)) {
          pen = false;
          continue;
        }
        if (pen) ctx.lineTo(xs(d.t), ys(v));
        else ctx.moveTo(xs(d.t), ys(v));
        pen = true;
      }
      ctx.stroke();
    }
    // 图例与标题
    ctx.font = '12px system-ui, sans-serif';
    ctx.textBaseline = 'middle';
    let lx = L + 8;
    for (const s of SERIES) {
      ctx.fillStyle = s.color;
      ctx.fillRect(lx, 10, 14, 3);
      ctx.fillStyle = 'rgb(180,180,200)';
      ctx.textAlign = 'left';
      ctx.fillText(s.name, lx + 18, 11);
      lx += ctx.measureText(s.name).width + 36;
    }
    if (note) {
      ctx.textAlign = 'right';
      ctx.fillStyle = 'rgb(120,200,255)';
      ctx.fillText(note, L + w, 11);
    }
  });
  return <canvas ref={ref} class="history-canvas" />;
}

function niceStep(x: number): number {
  if (!(x > 0)) return 1;
  const p = 10 ** Math.floor(Math.log10(x));
  for (const m of [1, 2, 5, 10]) if (m * p >= x) return m * p;
  return 10 * p;
}
