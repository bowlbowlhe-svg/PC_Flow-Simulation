// 主视图：场着色（速度/温度/压力/涡量/固体温度）、等值线、机箱与元件轮廓、风扇、粒子示踪、开口风量标注、悬停读数。
import { useEffect, useRef } from 'preact/hooks';
import type { FrameFields, StaticInfo, Status } from '../worker/protocol';
import type { Rect } from '../model/types';
import { colormapLUT, type ColormapName } from './colormap';
import { contourSegments } from './contour';
import { ParticleTracer } from './particles';
import { FAN_SLOTS } from '../model/fans';

export type ViewMode = 'velocity' | 'temperature' | 'pressure' | 'vorticity' | 'solid' | 'diff';

/** 温差视图的参考方案 */
export interface DiffRef {
  name: string;
  T: Float32Array | null; // null = 方案未保存
  W: number;
  version: number; // 方案每次保存递增
}

export interface ViewSpec {
  field: Float32Array; // NaN = 不着色（固体）
  cmap: ColormapName;
  clim: [number, number];
  title: string;
  unit: string;
  contours: number[];
  contourColor: string;
  darkParticles: boolean;
}

/** 由帧数据构造当前视图的场与配色（同 MATLAB updateVisualizations） */
export function viewSpec(mode: ViewMode, info: StaticInfo, f: FrameFields, st: Status | null, diff?: DiffRef): ViewSpec {
  const N = info.W * info.H;
  const obs = info.obstacle;
  switch (mode) {
    case 'velocity': {
      const v = new Float32Array(N);
      for (let i = 0; i < N; i++) v[i] = obs[i] ? NaN : Math.hypot(f.uC[i], f.vC[i]) * info.VEL_SCALE;
      return { field: v, cmap: 'speed', clim: [0, 2], title: '速度场 (m/s)', unit: '速度 (m/s)', contours: [], contourColor: '', darkParticles: false };
    }
    case 'temperature':
      return { field: f.T, cmap: 'heat', clim: [20, 100], title: '温度场 (°C)', unit: '温度 (°C)', contours: [30, 40, 50, 60], contourColor: 'rgba(102,230,255,0.9)', darkParticles: false };
    case 'pressure': {
      const abs: number[] = [];
      for (let i = 0; i < N; i++) if (Number.isFinite(f.P[i])) abs.push(Math.abs(f.P[i]));
      abs.sort((a, b) => a - b);
      let lim = 2;
      if (abs.length) lim = Math.max(lim, abs[Math.max(0, Math.round(0.99 * abs.length) - 1)]);
      const pin = st?.meanInteriorPa ?? 0;
      const pst = Math.abs(pin) < 0.05 ? '≈ 机箱外' : pin > 0 ? '正压' : '负压';
      return {
        field: f.P,
        cmap: 'diverging',
        clim: [-lim, lim],
        title: `压力场：机箱内平均 ${pin >= 0 ? '+' : ''}${pin.toFixed(2)} Pa（${pst}）`,
        unit: '静压 (Pa，相对机箱外)',
        contours: [0],
        contourColor: 'rgba(60,60,70,0.9)',
        darkParticles: true,
      };
    }
    case 'vorticity': {
      // 求解器 ω 以 y 向下为正；取 −ω 使屏幕上逆时针为正（红）
      const v = new Float32Array(N);
      for (let i = 0; i < N; i++) v[i] = obs[i] ? NaN : -f.vort[i];
      return { field: v, cmap: 'diverging', clim: [-60, 60], title: '涡量场 (1/s，红 = 逆时针)', unit: '涡量 (1/s)', contours: [], contourColor: '', darkParticles: true };
    }
    case 'solid':
      return { field: f.Tsolid, cmap: 'heat', clim: [20, 90], title: '固体温度 (°C)', unit: '固体温度 (°C)', contours: [40, 60, 80], contourColor: 'rgba(255,255,255,0.85)', darkParticles: false };
    case 'diff': {
      const v = new Float32Array(N);
      let title: string;
      let contours: number[] = [];
      if (diff?.T && diff.W === info.W && diff.T.length === N) {
        for (let i = 0; i < N; i++) v[i] = f.T[i] - diff.T[i];
        title = `温差：当前 − 方案 ${diff.name} (°C)`;
        contours = [-5, 5];
      } else if (!diff?.T) title = `温差：方案 ${diff?.name ?? ''} 尚未保存（在“方案对比”页保存）`;
      else title = `温差：方案 ${diff.name} 的网格精度与当前不同`;
      return { field: v, cmap: 'diverging', clim: [-10, 10], title, unit: '温差 (°C)', contours, contourColor: 'rgba(60,60,70,0.9)', darkParticles: true };
    }
  }
}

const BG = [13, 13, 20];

interface Props {
  info: StaticInfo;
  fields: FrameFields;
  status: Status | null;
  frameNo: number;
  buildNo: number;
  mode: ViewMode;
  particles: boolean;
  labels: boolean;
  running: boolean;
  onHover: (text: string) => void;
  onSpec: (spec: { title: string; unit: string; cmap: ColormapName; clim: [number, number] }) => void;
  /** 待应用的安装位状态（'none' | 'intake' | 'exhaust'），与 info.slots 对齐 */
  slotTypes: string[];
  onSlotClick: (k: number) => void;
  diff: DiffRef;
  onCanvas?: (c: HTMLCanvasElement | null) => void;
}

export function FieldView(p: Props) {
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const wrapRef = useRef<HTMLDivElement>(null);
  const props = useRef(p);
  props.current = p;
  const st = useRef({
    img: null as HTMLCanvasElement | null,
    imgKey: '',
    contours: [] as Float32Array[],
    tracer: new ParticleTracer(1500, 8),
    tracerBuild: -1,
    lastT: 0,
    raf: 0,
    sizePx: 0,
    dirty: true,
    acc: 0, // 粒子推进的时间累积 [s]
    lastFrameNo: -1,
    idleSince: 0, // 最近一次有新帧（或鼠标活动）的时刻 [ms]
  });

  // 画布尺寸跟随容器（正方形）
  useEffect(() => {
    const wrap = wrapRef.current!;
    const ro = new ResizeObserver(() => {
      const c = canvasRef.current;
      if (!c) return; // 已卸载（切到对比展示页）
      const css = Math.floor(wrap.clientWidth);
      const dpr = Math.min(window.devicePixelRatio || 1, 2);
      c.style.width = `${css}px`;
      c.style.height = `${css}px`;
      c.width = Math.round(css * dpr);
      c.height = Math.round(css * dpr);
      st.current.sizePx = c.width;
      st.current.dirty = true;
    });
    ro.observe(wrap);
    return () => ro.disconnect();
  }, []);

  // 渲染循环
  useEffect(() => {
    const s = st.current;
    const loop = (t: number) => {
      s.raf = requestAnimationFrame(loop);
      const P = props.current;
      const dtReal = s.lastT ? Math.min(0.1, (t - s.lastT) / 1000) : 0;
      s.lastT = t;
      const { info, fields } = P;
      const key = `${P.buildNo}:${P.frameNo}:${P.mode}:${P.mode === 'diff' ? `${P.diff.name}#${P.diff.version}` : ''}:${P.slotTypes.join(',')}:${P.labels}`;
      let changed = s.dirty || key !== s.imgKey;
      if (P.particles) {
        if (s.tracerBuild !== P.buildNo || s.tracer.n === 0) {
          s.tracer.reset({ W: info.W, H: info.H, obstacle: info.obstacle, fluidIdx: info.fluidIdx, insideIdx: info.insideIdx }, Math.round(1500 * Math.max(1, info.gridScale)));
          s.tracerBuild = P.buildNo;
        }
        // 同 MATLAB：每 0.05 s 推进一帧（0.02 s 物理时间）；寿命、尾迹、静止判据都按这个帧率计，与屏幕刷新率无关。
        // 流场约 2 分钟没有新帧（暂停且无操作）时粒子也停下，省 CPU（同 MATLAB 粒子定时器 2400 帧后自停）；
        // 有新帧或鼠标移到视图上即恢复
        if (P.frameNo !== s.lastFrameNo) {
          s.lastFrameNo = P.frameNo;
          s.idleSince = t;
        }
        const idle = t - s.idleSince > 120000;
        s.acc = idle ? 0 : Math.min(s.acc + dtReal, 0.2);
        while (s.acc >= 0.05) {
          s.tracer.step(fields.uC, fields.vC, info.VEL_SCALE, info.cellMm / 1000, 0.02);
          s.acc -= 0.05;
          changed = true;
        }
      } else if (s.tracer.n) {
        s.tracer.n = 0;
        s.tracerBuild = -1;
        changed = true;
      }
      if (!changed) return;
      s.dirty = false;
      if (key !== s.imgKey) {
        const spec = viewSpec(P.mode, info, fields, P.status, P.diff);
        renderImage(s, info, spec);
        s.contours = spec.contours.length && fieldRange(spec.field) > 0.5 ? spec.contours.map((lv) => contourSegments(spec.field, info.W, info.H, lv)) : [];
        (s as { contourColor?: string }).contourColor = spec.contourColor;
        (s as { dark?: boolean }).dark = spec.darkParticles;
        s.imgKey = key;
        P.onSpec({ title: spec.title, unit: spec.unit, cmap: spec.cmap, clim: spec.clim });
      }
      if (canvasRef.current) draw(canvasRef.current, s, P);
    };
    s.raf = requestAnimationFrame(loop);
    return () => cancelAnimationFrame(s.raf);
  }, []);

  /** 鼠标所在格（1 基），出界为 null */
  const cellAt = (e: MouseEvent): [number, number] | null => {
    const P = props.current;
    const r = canvasRef.current!.getBoundingClientRect();
    const x = Math.floor(((e.clientX - r.left) / r.width) * P.info.H) + 1;
    const y = Math.floor(((e.clientY - r.top) / r.height) * P.info.W) + 1;
    return x < 1 || x > P.info.H || y < 1 || y > P.info.W ? null : [x, y];
  };
  const slotAt = (e: MouseEvent): number => {
    const c = cellAt(e);
    if (!c) return -1;
    const P = props.current;
    // 角部重叠处取后画的安装位（同 MATLAB：后画的 patch 在上层接收点击）
    for (let k = P.info.slots.length - 1; k >= 0; k--) {
      const b = slotBox(P.info.slots[k], P.info.fanDiskCells);
      if (c[0] >= b.c0 && c[0] <= b.c1 && c[1] >= b.r0 && c[1] <= b.r1) return k;
    }
    return -1;
  };
  const onMove = (e: MouseEvent) => {
    st.current.idleSince = performance.now();
    canvasRef.current!.style.cursor = slotAt(e) >= 0 ? 'pointer' : 'crosshair';
    const P = props.current;
    const c = canvasRef.current!;
    const r = c.getBoundingClientRect();
    const { info, fields } = P;
    const x = Math.floor(((e.clientX - r.left) / r.width) * info.H) + 1;
    const y = Math.floor(((e.clientY - r.top) / r.height) * info.W) + 1;
    if (x < 1 || x > info.H || y < 1 || y > info.W) return;
    const i = (x - 1) * info.W + (y - 1);
    const co = info.caseOuter;
    const xm = (x - co.x + 0.5) * info.cellMm;
    const ym = (y - co.y + 0.5) * info.cellMm;
    let txt: string;
    if (info.obstacle[i]) txt = `x ${xm.toFixed(0)}  y ${ym.toFixed(0)} mm │ 固体 ${fields.Tsolid[i].toFixed(1)}°C`;
    else {
      const sp = Math.hypot(fields.uC[i], fields.vC[i]) * info.VEL_SCALE;
      const pa = fields.P[i];
      txt = `x ${xm.toFixed(0)}  y ${ym.toFixed(0)} mm │ ${sp.toFixed(2)} m/s │ ${fields.T[i].toFixed(1)}°C │ ${pa >= 0 ? '+' : ''}${pa.toFixed(2)} Pa`;
      // 固体温度视图里散热片、CPU 底座等流体格按 T_solid 上色，读数一并给出（同 MATLAB）
      if (P.mode === 'solid') txt += ` │ 固体 ${fields.Tsolid[i].toFixed(1)}°C`;
    }
    P.onHover(txt);
  };

  return (
    <div class="field-wrap" ref={wrapRef}>
      <canvas
        ref={(c) => {
          (canvasRef as { current: HTMLCanvasElement | null }).current = c;
          p.onCanvas?.(c);
        }}
        class="field-canvas"
        onMouseMove={onMove}
        onMouseLeave={() => props.current.onHover('')}
        onClick={(e) => {
          const k = slotAt(e);
          if (k >= 0) props.current.onSlotClick(k);
        }}
      />
    </div>
  );
}

function fieldRange(f: Float32Array): number {
  let lo = Infinity;
  let hi = -Infinity;
  for (const v of f) {
    if (!Number.isFinite(v)) continue;
    if (v < lo) lo = v;
    if (v > hi) hi = v;
  }
  return hi - lo;
}

function renderImage(s: { img: HTMLCanvasElement | null }, info: StaticInfo, spec: ViewSpec): void {
  const { W, H } = info;
  if (!s.img || s.img.width !== H || s.img.height !== W) {
    s.img = document.createElement('canvas');
    s.img.width = H;
    s.img.height = W;
  }
  const ctx = s.img.getContext('2d')!;
  const im = ctx.createImageData(H, W);
  const d = im.data;
  const lut = colormapLUT(spec.cmap);
  const [lo, hi] = spec.clim;
  const k = 255 / (hi - lo);
  for (let x = 0; x < H; x++) {
    for (let y = 0; y < W; y++) {
      const v = spec.field[x * W + y];
      const p = (y * H + x) * 4;
      if (!Number.isFinite(v)) {
        // 固体（NaN）：背景色
        d[p] = BG[0];
        d[p + 1] = BG[1];
        d[p + 2] = BG[2];
      } else {
        const c = Math.max(0, Math.min(255, Math.round((v - lo) * k))) * 3;
        d[p] = lut[c];
        d[p + 1] = lut[c + 1];
        d[p + 2] = lut[c + 2];
      }
      d[p + 3] = 255;
    }
  }
  ctx.putImageData(im, 0, 0);
}

type DrawState = {
  img: HTMLCanvasElement | null;
  contours: Float32Array[];
  tracer: ParticleTracer;
  contourColor?: string;
  dark?: boolean;
};

function draw(c: HTMLCanvasElement, s: DrawState, P: Props): void {
  const ctx = c.getContext('2d')!;
  const { info } = P;
  const px = c.width;
  const sc = px / info.H; // 每格像素
  ctx.setTransform(1, 0, 0, 1, 0, 0);
  ctx.fillStyle = `rgb(${BG.join(',')})`;
  ctx.fillRect(0, 0, px, px);
  if (s.img) {
    ctx.imageSmoothingEnabled = true;
    ctx.imageSmoothingQuality = 'high';
    ctx.drawImage(s.img, 0, 0, px, px);
  }
  // 格坐标 → 像素：格 (x, y) 中心在 ((x − 0.5)·sc, (y − 0.5)·sc)
  const X = (x: number) => (x - 0.5) * sc;
  const lw = Math.max(1, sc * 0.35);
  // 等值线
  if (s.contours.length) {
    ctx.strokeStyle = s.contourColor ?? '#fff';
    ctx.lineWidth = Math.max(1, lw * 0.9);
    ctx.beginPath();
    for (const seg of s.contours) {
      for (let k = 0; k < seg.length; k += 4) {
        ctx.moveTo(X(seg[k]), X(seg[k + 1]));
        ctx.lineTo(X(seg[k + 2]), X(seg[k + 3]));
      }
    }
    ctx.stroke();
  }
  drawGeometry(ctx, info, sc);
  // 粒子
  const tr = s.tracer;
  if (P.particles && tr.n) {
    const m = tr.trail + 1;
    ctx.lineWidth = Math.max(0.8, sc * 0.18);
    ctx.strokeStyle = s.dark ? 'rgba(64,64,82,0.75)' : 'rgba(180,200,220,0.55)';
    ctx.beginPath();
    for (let k = 0; k < tr.n; k++) {
      const o = k * m;
      ctx.moveTo(X(tr.X[o]), X(tr.Y[o]));
      for (let j = 1; j < m; j++) ctx.lineTo(X(tr.X[o + j]), X(tr.Y[o + j]));
    }
    ctx.stroke();
    ctx.fillStyle = s.dark ? 'rgba(25,25,38,0.95)' : 'rgba(235,248,255,0.95)';
    const r = Math.max(1, sc * 0.3);
    for (let k = 0; k < tr.n; k++) ctx.fillRect(X(tr.X[k * m]) - r / 2, X(tr.Y[k * m]) - r / 2, r, r);
  }
  drawSlots(ctx, P, sc);
  // 开口风量标注（机箱风扇开口的风量并入安装位文字，这里只标电源与被动通风口）
  if (P.labels && P.status) {
    ctx.font = `bold ${Math.max(10, Math.round(sc * 3.2))}px system-ui, sans-serif`;
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';
    info.markers.forEach((mk, k) => {
      const cfm = P.status!.markerCfm[k] ?? 0;
      if (mk.kind === 'fan' || Math.abs(cfm) < 0.5) return;
      const out = cfm > 0;
      const txt = flowText(mk.mount, cfm);
      const x = Math.min(Math.max(X(mk.x), 18), px - 18);
      const y = Math.min(Math.max(X(mk.y), 10), px - 10);
      ctx.lineWidth = 3;
      ctx.strokeStyle = 'rgba(0,0,0,0.6)';
      ctx.strokeText(txt, x, y);
      ctx.fillStyle = out ? 'rgb(255,158,77)' : 'rgb(89,230,255)';
      ctx.fillText(txt, x, y);
    });
  }
}

function drawGeometry(ctx: CanvasRenderingContext2D, info: StaticInfo, sc: number): void {
  const E = (v: number) => (v - 1) * sc; // 格边（左/上边）
  const rect = (r: Rect, color: string, lw: number, dash: number[] = []) => {
    ctx.setLineDash(dash);
    ctx.strokeStyle = color;
    ctx.lineWidth = lw;
    ctx.strokeRect(E(r.x), E(r.y), r.w * sc, r.h * sc);
    ctx.setLineDash([]);
  };
  const label = (r: Rect, text: string, color: string, size: number) => {
    ctx.font = `bold ${Math.max(9, Math.round(size * sc * 0.45))}px system-ui, sans-serif`;
    ctx.fillStyle = color;
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';
    ctx.fillText(text, E(r.x) + (r.w * sc) / 2, E(r.y) + (r.h * sc) / 2);
  };
  const base = Math.max(1, sc * 0.5);
  rect(info.caseOuter, 'rgba(153,153,184,0.95)', base * 1.6);
  if (info.motherboardTray) {
    rect(info.motherboardTray, 'rgba(51,173,71,0.85)', base * 0.8, [6, 4]);
    ctx.font = `bold ${Math.max(9, Math.round(sc * 3))}px system-ui, sans-serif`;
    ctx.fillStyle = 'rgba(64,199,89,0.9)';
    ctx.textAlign = 'left';
    ctx.textBaseline = 'top';
    // 同 MATLAB 放在左上角；VRM 在左上角时移到其右侧，免得被 VRM 框压住
    const mt = info.motherboardTray;
    let lx = mt.x + 5;
    if (info.vrm && info.vrm.x <= lx + 8 && info.vrm.y <= mt.y + 10) lx = Math.max(lx, info.vrm.x + info.vrm.w + 2);
    ctx.fillText('主板区', E(lx), E(mt.y) + 5 * sc);
  }
  if (info.vrm) {
    rect(info.vrm, 'rgba(217,217,217,0.9)', base);
    label(info.vrm, 'VRM', 'rgb(242,242,242)', 5);
  }
  for (const r of info.ram) rect(r, 'rgba(184,77,255,0.9)', base);
  if (info.ram.length) {
    const r1 = info.ram[0];
    const yb = Math.max(...info.ram.map((r) => r.y + r.h)); // 标签放在内存条下方，不压住内存条、不越出主板区
    ctx.font = `bold ${Math.max(9, Math.round(sc * 2.6))}px system-ui, sans-serif`;
    ctx.fillStyle = 'rgb(204,128,255)';
    ctx.textAlign = 'left';
    ctx.textBaseline = 'top';
    ctx.fillText(`RAM×${info.ram.length}`, E(r1.x), E(yb) + sc);
  }
  if (info.chipset) {
    rect(info.chipset, 'rgba(204,204,204,0.8)', base * 0.6);
    label(info.chipset, '芯', 'rgb(230,230,230)', 5);
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
    ctx.strokeStyle = 'rgb(255,128,26)';
    ctx.lineWidth = base * 1.3;
    ctx.strokeRect(E(x0), E(y0), (x1 - x0) * sc, (y1 - y0) * sc);
    ctx.lineWidth = Math.max(1, base * 0.6);
    ctx.strokeStyle = 'rgba(255,153,64,0.9)';
    ctx.beginPath();
    ctx.moveTo(E(gp.x), E(gp.y + gp.h));
    ctx.lineTo(E(gp.x + gp.w), E(gp.y + gp.h));
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
    ctx.strokeStyle = col;
    ctx.fillStyle = col;
    ctx.lineWidth = Math.max(1.2, base);
    ctx.beginPath();
    ctx.moveTo(x0, y0);
    ctx.lineTo(x1, y1);
    ctx.stroke();
    const h = Math.max(4, len * 0.35);
    ctx.beginPath();
    ctx.moveTo(x1, y1);
    ctx.lineTo(x1 - nx * h - ny * h * 0.6, y1 - ny * h + nx * h * 0.6);
    ctx.lineTo(x1 - nx * h + ny * h * 0.6, y1 - ny * h - nx * h * 0.6);
    ctx.closePath();
    ctx.fill();
  }
  // 方位与尺度条
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

/** 安装位标记区域：盘区域向壁外延伸几格，便于点击（同 MATLAB drawSlotMarkers） */
function slotBox(sl: StaticInfo['slots'][number], diskCells: number) {
  const pad = Math.max(2, diskCells);
  let [c0, c1] = sl.cols;
  let [r0, r1] = sl.rows;
  if (sl.mount === 'front') c1 = c1 + 1 + pad;
  else if (sl.mount === 'rear') c0 = c0 - 1 - pad;
  else if (sl.mount === 'top') r0 = r0 - 1 - pad;
  else r1 = r1 + 1 + pad;
  return { c0, c1, r0, r1 };
}

/** 安装位 k 上已应用的机箱风扇的开口净风量（CFM，> 0 流出）；没有则 NaN */
function slotFlow(P: Props, k: number): number {
  const sl = P.info.slots[k];
  const cf = P.info.layout.caseFans ?? [];
  const along = FAN_SLOTS[k].alongMm;
  const j = cf.findIndex((f) => f.mount === sl.mount && Math.abs(f.alongMm - along) < 1);
  if (j < 0 || !P.status) return NaN;
  const m = P.info.markers.findIndex((mk) => mk.kind === 'fan' && mk.fan === j + 1);
  return m >= 0 ? P.status.markerCfm[m] : NaN;
}

/** 安装位 k 上已应用（正在计算）的机箱风扇类型：'intake' | 'exhaust' | 'none' */
function slotApplied(P: Props, k: number): string {
  const sl = P.info.slots[k];
  const along = FAN_SLOTS[k].alongMm;
  const f = (P.info.layout.caseFans ?? []).find((c) => c.mount === sl.mount && Math.abs(c.alongMm - along) < 1);
  return f ? f.type : 'none';
}

const SLOT_WORD: Record<string, string> = { intake: '进', exhaust: '出', none: '空' };

/**
 * 安装位标记：颜色为待应用的状态（绿 = 进气，红 = 排气，灰虚线 = 空），文字附已应用风扇的开口净风量。
 * 待应用状态与正在计算的不同时，边框与文字改为琥珀色虚线，文字写成"T1 出 ↑32 → 空（待应用）"：
 * 流场仍按已应用的布局计算，点"应用布局"后才生效。
 */
function drawSlots(ctx: CanvasRenderingContext2D, P: Props, sc: number): void {
  const E = (v: number) => (v - 1) * sc;
  ctx.font = `${Math.max(10, Math.round(sc * 3))}px system-ui, sans-serif`;
  P.info.slots.forEach((sl, k) => {
    const b = slotBox(sl, P.info.fanDiskCells);
    const type = P.slotTypes[k] ?? 'none';
    const applied = slotApplied(P, k);
    const changed = applied !== type;
    let col: string;
    let fill: string;
    let cap: string;
    if (type === 'intake') {
      col = 'rgb(0,235,140)';
      fill = 'rgba(0,235,140,0.22)';
      cap = `${sl.id} 进`;
    } else if (type === 'exhaust') {
      col = 'rgb(255,71,71)';
      fill = 'rgba(255,71,71,0.22)';
      cap = `${sl.id} 出`;
    } else {
      col = 'rgb(140,140,153)';
      fill = 'rgba(140,140,153,0.08)';
      cap = sl.id;
    }
    const x = E(b.c0);
    const y = E(b.r0);
    const w = (b.c1 - b.c0 + 1) * sc;
    const h = (b.r1 - b.r0 + 1) * sc;
    const pendingCol = 'rgb(255,170,0)';
    ctx.fillStyle = fill;
    ctx.fillRect(x, y, w, h);
    ctx.setLineDash(changed ? [5, 3] : type === 'none' ? [4, 3] : []);
    ctx.strokeStyle = changed ? pendingCol : col;
    ctx.lineWidth = changed ? 1.5 : 1;
    ctx.strokeRect(x, y, w, h);
    ctx.setLineDash([]);
    const q = slotFlow(P, k);
    const flow = P.labels && Number.isFinite(q) && Math.abs(q) >= 0.5 ? ` ${flowText(sl.mount, q)}` : '';
    if (changed) cap = `${sl.id} ${SLOT_WORD[applied] ?? applied}${flow} → ${SLOT_WORD[type] ?? type}（待应用）`;
    else cap += flow;
    let tx: number;
    let ty: number;
    if (sl.mount === 'front') {
      ctx.textAlign = 'right';
      ctx.textBaseline = 'middle';
      // 前壁外侧空间有限：文字放在标记左侧（机箱内）会挡住流场，放标记外侧并夹在画布内
      tx = Math.min(E(b.c1 + 1) + ctx.measureText(cap).width + 2, P.info.H * sc - 2);
      ty = y + h / 2;
    } else if (sl.mount === 'rear') {
      ctx.textAlign = 'right';
      ctx.textBaseline = 'middle';
      tx = Math.max(x - 2, ctx.measureText(cap).width + 2);
      ty = y + h / 2;
    } else if (sl.mount === 'top') {
      ctx.textAlign = 'center';
      ctx.textBaseline = 'bottom';
      tx = x + w / 2;
      ty = Math.max(y - 2, 14);
    } else {
      ctx.textAlign = 'center';
      ctx.textBaseline = 'top';
      tx = x + w / 2;
      ty = Math.min(y + h + 2, P.info.W * sc - 14);
    }
    ctx.lineWidth = 3;
    ctx.strokeStyle = 'rgba(0,0,0,0.55)';
    ctx.strokeText(cap, tx, ty);
    ctx.fillStyle = changed ? pendingCol : type === 'none' ? 'rgb(191,191,204)' : col;
    ctx.fillText(cap, tx, ty);
  });
}
