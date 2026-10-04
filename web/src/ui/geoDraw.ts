// 主视图与对比展示页共用的几何叠加层：机箱、主板区、元件轮廓、风扇与送风方向、方位与尺度条。
import type { Rect } from '../model/types';
import type { GeoOverlay } from '../solver/geoOverlay';

/**
 * 机箱、主板区、元件与风扇（含送风方向箭头）。格坐标 1 基，sc 为每格像素，画布原点在格 (1, 1) 的左上角。
 * halo：线条与文字下垫一道深色描边，叠在亮色场上时更清楚；minorLabels = false 时不标主板区、VRM、芯片组、内存（小图用）。
 */
export function drawGeometry(ctx: CanvasRenderingContext2D, info: GeoOverlay, sc: number, opts: { halo?: boolean; minorLabels?: boolean } = {}): void {
  const minor = opts.minorLabels ?? true;
  const E = (v: number) => (v - 1) * sc; // 格边（左/上边）
  const halo = (lw: number) => {
    if (!opts.halo) return;
    ctx.strokeStyle = 'rgba(0,0,0,0.55)';
    ctx.lineWidth = lw + Math.max(1.5, lw);
    ctx.stroke();
  };
  const rect = (r: Rect, color: string, lw: number, dash: number[] = []) => {
    if (opts.halo) {
      ctx.setLineDash([]);
      ctx.beginPath();
      ctx.rect(E(r.x), E(r.y), r.w * sc, r.h * sc);
      halo(lw);
    }
    ctx.setLineDash(dash);
    ctx.strokeStyle = color;
    ctx.lineWidth = lw;
    ctx.strokeRect(E(r.x), E(r.y), r.w * sc, r.h * sc);
    ctx.setLineDash([]);
  };
  /** 先描深色边（halo）再填色 */
  const fillText = (text: string, x: number, y: number) => {
    if (opts.halo) {
      ctx.lineWidth = 3;
      ctx.lineJoin = 'round';
      ctx.strokeStyle = 'rgba(0,0,0,0.7)';
      ctx.strokeText(text, x, y);
    }
    ctx.fillText(text, x, y);
  };
  /** 先在当前路径下垫深色宽线（halo） */
  const under = (lw: number) => {
    if (!opts.halo) return;
    const dash = ctx.getLineDash();
    ctx.setLineDash([]);
    halo(lw);
    ctx.setLineDash(dash);
  };
  const label = (r: Rect, text: string, color: string, size: number) => {
    ctx.font = `bold ${Math.max(9, Math.round(size * sc * 0.45))}px system-ui, sans-serif`;
    ctx.fillStyle = color;
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';
    fillText(text, E(r.x) + (r.w * sc) / 2, E(r.y) + (r.h * sc) / 2);
  };
  const base = Math.max(1, sc * 0.5);
  rect(info.caseOuter, 'rgba(153,153,184,0.95)', base * 1.6);
  if (info.motherboardTray) {
    rect(info.motherboardTray, 'rgba(51,173,71,0.85)', base * 0.8, [6, 4]);
  }
  if (info.motherboardTray && minor) {
    ctx.font = `bold ${Math.max(9, Math.round(sc * 3))}px system-ui, sans-serif`;
    ctx.fillStyle = 'rgba(64,199,89,0.9)';
    ctx.textAlign = 'left';
    ctx.textBaseline = 'top';
    // 同 MATLAB 放在左上角；VRM 在左上角时移到其右侧，免得被 VRM 框压住
    const mt = info.motherboardTray;
    let lx = mt.x + 5;
    if (info.vrm && info.vrm.x <= lx + 8 && info.vrm.y <= mt.y + 10) lx = Math.max(lx, info.vrm.x + info.vrm.w + 2);
    fillText('主板区', E(lx), E(mt.y) + 5 * sc);
  }
  if (info.vrm) {
    rect(info.vrm, 'rgba(217,217,217,0.9)', base);
    if (minor) label(info.vrm, 'VRM', 'rgb(242,242,242)', 5);
  }
  for (const r of info.ram) rect(r, 'rgba(184,77,255,0.9)', base);
  if (info.ram.length && minor) {
    const r1 = info.ram[0];
    const yb = Math.max(...info.ram.map((r) => r.y + r.h)); // 标签放在内存条下方，不压住内存条、不越出主板区
    ctx.font = `bold ${Math.max(9, Math.round(sc * 2.6))}px system-ui, sans-serif`;
    ctx.fillStyle = 'rgb(204,128,255)';
    ctx.textAlign = 'left';
    ctx.textBaseline = 'top';
    fillText(`RAM×${info.ram.length}`, E(r1.x), E(yb) + sc);
  }
  if (info.chipset) {
    rect(info.chipset, 'rgba(204,204,204,0.8)', base * 0.6);
    if (minor) label(info.chipset, '芯', 'rgb(230,230,230)', 5);
  }
  if (info.cpu) {
    rect(info.cpu.base, 'rgb(0,191,255)', base * 1.2, [5, 3]); // 虚线：只显示、不挡风（底座在鳍片内侧）
    // 标签放在底座下半部：中间塔扇的箭头横穿底座中部
    label({ ...info.cpu.base, y: info.cpu.base.y + info.cpu.base.h / 2, h: info.cpu.base.h / 2 }, 'CPU', 'rgb(102,230,255)', 8);
    // 各组鳍片分别画框（双塔 2 组，中间间隙放塔扇）
    for (const st of info.cpu.stacks) rect({ ...st, w: Math.min(info.H, st.x + st.w - 1) - st.x + 1 }, 'rgb(0,153,255)', base * 1.2);
    const f = info.cpu.finArea;
    const fw: Rect = { ...f, w: Math.min(info.H, f.x + f.w - 1) - f.x + 1 };
    // 标签放在散热器上沿（底座在散热器中部，避免重叠）
    const name = info.cpu.stacks.length === 2 ? '双塔散热器' : '塔式散热器';
    label({ x: fw.x, y: fw.y + 1, w: fw.w, h: Math.max(3, Math.min(6, info.cpu.base.y - fw.y - 1)) }, name, 'rgb(77,204,255)', 6);
  }
  if (info.gpu) {
    const { pcb: gp, heatsink: gh } = info.gpu;
    const x0 = Math.min(gh.x, gp.x);
    const x1 = Math.min(info.H + 1, Math.max(gh.x + gh.w, gp.x + gp.w));
    const y0 = gp.y;
    const y1 = info.gpu.fanBottom + 1;
    ctx.fillStyle = 'rgba(255,115,26,0.16)';
    ctx.fillRect(E(x0), E(y0), (x1 - x0) * sc, (y1 - y0) * sc);
    rect({ x: x0, y: y0, w: x1 - x0, h: y1 - y0 }, 'rgb(255,128,26)', base * 1.3);
    ctx.lineWidth = Math.max(1, base * 0.6);
    ctx.strokeStyle = 'rgba(255,153,64,0.9)';
    ctx.beginPath();
    ctx.moveTo(E(gp.x), E(gp.y + gp.h));
    ctx.lineTo(E(gp.x + gp.w), E(gp.y + gp.h));
    under(Math.max(1, base * 0.6));
    ctx.strokeStyle = 'rgba(255,153,64,0.9)';
    ctx.lineWidth = Math.max(1, base * 0.6);
    ctx.stroke();
    ctx.setLineDash([2, 3]);
    ctx.beginPath();
    ctx.moveTo(E(x0), E(gh.y + gh.h));
    ctx.lineTo(E(x1), E(gh.y + gh.h));
    ctx.stroke();
    ctx.setLineDash([]);
    // 挡板端（仅显示）：PCB 一直延伸到后面板的挡板，散热片后端到后壁之间是接口区；求解器里这段不是障碍
    const xb = info.caseOuter.x + 1; // 后壁内侧所在格
    if (x0 > xb && (x0 - xb) * info.cellMm <= 60) {
      ctx.strokeStyle = 'rgba(255,153,64,0.8)';
      ctx.lineWidth = Math.max(1, base * 0.6);
      ctx.setLineDash([3, 3]);
      ctx.strokeRect(E(xb), E(gp.y), (x0 - xb) * sc, gp.h * sc);
      ctx.setLineDash([]);
      ctx.lineWidth = base * 1.3;
      ctx.strokeStyle = 'rgb(255,128,26)';
      ctx.beginPath();
      ctx.moveTo(E(xb), E(y0));
      ctx.lineTo(E(xb), E(y1));
      ctx.stroke();
    }
    label({ x: x0, y: y0, w: x1 - x0, h: y1 - y0 }, `GPU（${info.gpu.slots} 槽）`, 'rgb(255,204,128)', 9);
  }
  if (info.psu) {
    rect(info.psu.body, 'rgb(224,204,0)', base * 1.2);
    label(info.psu.body, 'PSU', 'rgb(255,242,77)', 8);
  }
  // 风扇：执行盘矩形 + 送风方向箭头。显卡风扇在卡底面朝下，侧视看不到扇叶，执行盘画虚线（同 CPU 底座）
  for (const f of info.fans) {
    let col: string;
    if (f.role === 'case') col = f.type === 'intake' ? 'rgb(0,235,140)' : 'rgb(255,71,71)';
    else if (f.role === 'cpu') col = 'rgb(0,217,217)';
    else if (f.role === 'gpu') col = 'rgb(255,140,38)';
    else col = 'rgb(242,217,51)';
    const r: Rect = { x: f.cols[0], y: f.rows[0], w: f.cols[1] - f.cols[0] + 1, h: f.rows[1] - f.rows[0] + 1 };
    rect(r, col, Math.max(1, base * 0.8), f.role === 'gpu' ? [4, 3] : undefined);
    const cx = E(r.x) + (r.w * sc) / 2;
    const cy = E(r.y) + (r.h * sc) / 2;
    const len = 0.35 * Math.max(r.w, r.h) * sc;
    const [nx, ny] = f.normal;
    const x0 = cx - (nx * len) / 2;
    const y0 = cy - (ny * len) / 2;
    const x1 = cx + (nx * len) / 2;
    const y1 = cy + (ny * len) / 2;
    ctx.beginPath();
    ctx.moveTo(x0, y0);
    ctx.lineTo(x1, y1);
    under(Math.max(1.2, base));
    ctx.strokeStyle = col;
    ctx.fillStyle = col;
    ctx.lineWidth = Math.max(1.2, base);
    ctx.stroke();
    const h = Math.max(4, len * 0.35);
    ctx.beginPath();
    ctx.moveTo(x1, y1);
    ctx.lineTo(x1 - nx * h - ny * h * 0.6, y1 - ny * h + nx * h * 0.6);
    ctx.lineTo(x1 - nx * h + ny * h * 0.6, y1 - ny * h - nx * h * 0.6);
    ctx.closePath();
    if (opts.halo) {
      ctx.lineWidth = 2;
      ctx.strokeStyle = 'rgba(0,0,0,0.55)';
      ctx.stroke();
    }
    ctx.fill();
  }
}

/** 方位文字与 100 mm 尺度条（主视图：整个计算域） */
export function drawOrientation(ctx: CanvasRenderingContext2D, info: GeoOverlay, sc: number): void {
  const W = info.W;
  const H = info.H;
  ctx.font = `${Math.max(9, Math.round(sc * 2.6))}px system-ui, sans-serif`;
  ctx.fillStyle = 'rgb(140,140,166)';
  ctx.textBaseline = 'top';
  ctx.textAlign = 'center';
  ctx.fillText('▲ 顶部', (H / 2) * sc, 2 * sc);
  ctx.textBaseline = 'bottom';
  ctx.textAlign = 'left';
  ctx.fillText('← 后部', 2 * sc, (W - 1) * sc);
  ctx.textAlign = 'right';
  ctx.fillText('前面板 →', (H - 2) * sc, (W - 1) * sc);
  const L100 = (100 / info.cellMm) * sc;
  const bx = 5 * sc;
  const by = (W - 9) * sc;
  ctx.strokeStyle = 'rgb(230,230,230)';
  ctx.lineWidth = Math.max(1.5, sc * 0.5);
  ctx.beginPath();
  ctx.moveTo(bx, by);
  ctx.lineTo(bx + L100, by);
  ctx.moveTo(bx, by - 2 * sc);
  ctx.lineTo(bx, by + 2 * sc);
  ctx.moveTo(bx + L100, by - 2 * sc);
  ctx.lineTo(bx + L100, by + 2 * sc);
  ctx.stroke();
  ctx.fillStyle = 'rgb(230,230,230)';
  ctx.textAlign = 'center';
  ctx.textBaseline = 'top';
  ctx.fillText('100 mm', bx + L100 / 2, by + 3 * sc);
}

/** 流向箭头 + 净风量（CFM）：流出机箱用出向箭头 */
export function flowText(mount: string, cfm: number): string {
  const arrows: Record<string, [string, string]> = { front: ['←', '→'], rear: ['→', '←'], top: ['↓', '↑'], bottom: ['↑', '↓'] };
  const a = arrows[mount];
  return `${cfm > 0 ? a[1] : a[0]}${Math.abs(cfm).toFixed(0)}`;
}
