// 风扇工作点图：机箱风扇与 CPU 塔扇当前转速下的 P-Q 曲线（实线）与实测工作点（圆点）。
import { useEffect, useRef } from 'preact/hooks';
import type { Status } from '../worker/protocol';

const PAL = ['rgb(89,204,255)', 'rgb(255,153,64)', 'rgb(128,255,128)', 'rgb(255,115,191)', 'rgb(242,230,77)', 'rgb(191,166,255)', 'rgb(77,255,217)', 'rgb(255,128,102)'];

export function PQChart({ pq, note }: { pq: Status['pq']; note: string }) {
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
    const L = 44;
    const narrow = css < 560; // 窄屏：图例画在绘图区内右上角，不另留右侧空白
    const R = narrow ? 10 : 150;
    const T = 22;
    const B = 28;
    const w = css - L - R;
    const h = cssH - T - B;
    let xmax = 10;
    let ymax = 1;
    for (const f of pq) {
      xmax = Math.max(xmax, ...f.cfm, f.opCfm);
      ymax = Math.max(ymax, ...f.dp, f.opDp);
    }
    xmax = niceCeil(xmax * 1.05);
    ymax = niceCeil(ymax * 1.1);
    const xs = (v: number) => L + (v / xmax) * w;
    const ys = (v: number) => T + (1 - v / ymax) * h;
    ctx.font = '11px system-ui, sans-serif';
    ctx.strokeStyle = 'rgba(100,100,128,0.35)';
    ctx.fillStyle = 'rgb(150,150,170)';
    ctx.lineWidth = 1;
    const xstep = niceCeil(xmax / 6);
    const ystep = niceCeil(ymax / 5);
    ctx.textAlign = 'center';
    ctx.textBaseline = 'top';
    for (let v = 0; v <= xmax + 1e-9; v += xstep) {
      ctx.beginPath();
      ctx.moveTo(xs(v), T);
      ctx.lineTo(xs(v), T + h);
      ctx.stroke();
      ctx.fillText(fmt(v), xs(v), T + h + 4);
    }
    ctx.textAlign = 'right';
    ctx.textBaseline = 'middle';
    for (let v = 0; v <= ymax + 1e-9; v += ystep) {
      ctx.beginPath();
      ctx.moveTo(L, ys(v));
      ctx.lineTo(L + w, ys(v));
      ctx.stroke();
      ctx.fillText(fmt(v), L - 5, ys(v));
    }
    ctx.textAlign = 'center';
    ctx.textBaseline = 'bottom';
    ctx.fillText('风量 (CFM)', L + w / 2, cssH - 1);
    ctx.save();
    ctx.translate(12, T + h / 2);
    ctx.rotate(-Math.PI / 2);
    ctx.fillText('静压 (Pa)', 0, 6);
    ctx.restore();
    pq.forEach((f, k) => {
      const col = PAL[k % PAL.length];
      ctx.strokeStyle = col;
      ctx.fillStyle = col;
      ctx.lineWidth = 1.5;
      ctx.beginPath();
      f.cfm.forEach((x, i) => (i ? ctx.lineTo(xs(x), ys(Math.max(0, f.dp[i]))) : ctx.moveTo(xs(x), ys(Math.max(0, f.dp[i])))));
      ctx.stroke();
      ctx.beginPath();
      ctx.arc(xs(f.opCfm), ys(f.opDp), 4, 0, 2 * Math.PI);
      ctx.fill();
      // 图例
      const ly = T + 6 + k * (narrow ? 13 : 16);
      const lx = narrow ? L + w - 118 : L + w + 12;
      ctx.fillRect(lx, ly - 1, 14, 3);
      ctx.fillStyle = 'rgb(180,180,200)';
      ctx.textAlign = 'left';
      ctx.textBaseline = 'middle';
      if (narrow) ctx.font = '10px system-ui, sans-serif';
      ctx.fillText(f.name, lx + 18, ly);
      ctx.font = '11px system-ui, sans-serif';
    });
    ctx.fillStyle = 'rgb(120,200,255)';
    ctx.textAlign = 'left';
    ctx.textBaseline = 'middle';
    ctx.font = '12px system-ui, sans-serif';
    ctx.fillText(`风扇工作点（曲线 = 当前转速 P-Q，圆点 = 实测）${note ? ' — ' + note : ''}`, L, 10);
  });
  return <canvas ref={ref} class="history-canvas" />;
}

function niceCeil(x: number): number {
  if (!(x > 0)) return 1;
  const p = 10 ** Math.floor(Math.log10(x));
  for (const m of [1, 2, 2.5, 5, 10]) if (m * p >= x) return m * p;
  return 10 * p;
}

const fmt = (v: number) => (Math.abs(v - Math.round(v)) < 1e-9 ? v.toFixed(0) : v.toFixed(1));
