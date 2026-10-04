// 时均速度场的等间距流线（Jobard–Lefer 简化版）：按风速从高到低选种子点，沿方向场双向积分（RK2、等弧长步），
// 碰到障碍、出界、风速低于 vmin、离已有流线太近或绕回自身时停止。坐标为流场图的格坐标（格 (c, r) 中心在 (c + 0.5, r + 0.5)）。
import { sampleVel, type FieldThumb } from '../../compare/thumb';

export interface StreamOpts {
  dsep: number; // 种子与流线的间距 [格]
  dtest: number; // 积分时离其它流线的最小距离 [格]
  step: number; // 积分步长 [格]
  vmin: number; // 风速下限 [m/s]：更慢的区域（死区、回流中心）不画
  maxSteps: number; // 单向最多步数
  /** 种子只取这个矩形内（格坐标，x0 ≤ x < x1）；缺省为整幅 */
  seedBox?: Box;
  /** 积分出了这个矩形即停（缺省为整幅） */
  box?: Box;
}

export interface Box {
  x0: number;
  y0: number;
  x1: number;
  y1: number;
}

/** 一条流线：连续的点 (x, y) 与该点风速 [m/s]，按流动方向排列 */
export interface Streamline {
  x: Float32Array;
  y: Float32Array;
  speed: Float32Array;
}

type Field = Pick<FieldThumb, 'crop' | 'T' | 'uvF' | 'uw' | 'uh' | 'u' | 'v'>;

export function traceStreamlines(t: Field, o: StreamOpts): Streamline[] {
  const W = t.crop.w;
  const H = t.crop.h;
  const box = o.box ?? { x0: 0, y0: 0, x1: W, y1: H };
  const seedBox = o.seedBox ?? box;
  const solid = (x: number, y: number) => {
    const c = Math.floor(x);
    const r = Math.floor(y);
    if (x < box.x0 || y < box.y0 || x >= box.x1 || y >= box.y1) return true;
    return c < 0 || r < 0 || c >= W || r >= H || !Number.isFinite(t.T[r * W + c]);
  };
  // 占用格：每格记录 (流线号, 序号, x, y)
  const gs = Math.max(0.5, o.dtest);
  const gw = Math.ceil(W / gs) + 1;
  const gh = Math.ceil(H / gs) + 1;
  const grid: number[][] = Array.from({ length: gw * gh }, () => []);
  const pts: { line: number; idx: number; x: number; y: number }[] = [];
  const own = Math.ceil((3 * o.dtest) / o.step); // 同一条流线上相距这么多步以内的点不算"太近"
  const near = (x: number, y: number, d: number, line: number, idx: number) => {
    const gc = Math.floor(x / gs);
    const gr = Math.floor(y / gs);
    const k = Math.ceil(d / gs);
    for (let r = Math.max(0, gr - k); r <= Math.min(gh - 1, gr + k); r++) {
      for (let c = Math.max(0, gc - k); c <= Math.min(gw - 1, gc + k); c++) {
        for (const p of grid[r * gw + c]) {
          const q = pts[p];
          if (q.line === line && Math.abs(q.idx - idx) <= own) continue;
          if ((q.x - x) ** 2 + (q.y - y) ** 2 < d * d) return true;
        }
      }
    }
    return false;
  };
  const addPt = (line: number, idx: number, x: number, y: number) => {
    const c = Math.min(gw - 1, Math.floor(x / gs));
    const r = Math.min(gh - 1, Math.floor(y / gs));
    grid[r * gw + c].push(pts.length);
    pts.push({ line, idx, x, y });
  };
  const dir = (x: number, y: number): [number, number, number] => {
    const [u, v] = sampleVel(t, x, y);
    const s = Math.hypot(u, v);
    return s > 0 ? [u / s, v / s, s] : [0, 0, 0];
  };
  /** 单向积分（sign = 1 顺流、−1 逆流），返回不含起点的点列 */
  const integrate = (x0: number, y0: number, sign: number, line: number): { x: number; y: number; s: number }[] => {
    const out: { x: number; y: number; s: number }[] = [];
    let x = x0;
    let y = y0;
    for (let k = 1; k <= o.maxSteps; k++) {
      const [d1x, d1y, s1] = dir(x, y);
      if (s1 < o.vmin) break;
      const mx = x + 0.5 * sign * o.step * d1x;
      const my = y + 0.5 * sign * o.step * d1y;
      const [d2x, d2y, s2] = dir(mx, my);
      if (s2 < o.vmin) break;
      const nx = x + sign * o.step * d2x;
      const ny = y + sign * o.step * d2y;
      if (solid(nx, ny) || near(nx, ny, o.dtest, line, sign * k)) break;
      x = nx;
      y = ny;
      out.push({ x, y, s: s2 });
      addPt(line, sign * k, x, y);
    }
    return out;
  };

  // 种子：间距 dsep 的网格点，按风速从高到低
  const seeds: { x: number; y: number; s: number }[] = [];
  for (let y = seedBox.y0 + o.dsep / 2; y < seedBox.y1; y += o.dsep) {
    for (let x = seedBox.x0 + o.dsep / 2; x < seedBox.x1; x += o.dsep) {
      if (solid(x, y)) continue;
      const [, , s] = dir(x, y);
      if (s >= o.vmin) seeds.push({ x, y, s });
    }
  }
  seeds.sort((a, b) => b.s - a.s);

  const lines: Streamline[] = [];
  for (const sd of seeds) {
    const line = lines.length;
    if (near(sd.x, sd.y, o.dsep, -1, 0)) continue;
    addPt(line, 0, sd.x, sd.y);
    const fwd = integrate(sd.x, sd.y, 1, line);
    const bwd = integrate(sd.x, sd.y, -1, line);
    const all = [...bwd.reverse(), { x: sd.x, y: sd.y, s: sd.s }, ...fwd];
    if (all.length < 6) {
      // 太短的不画，但占用格保留，免得在同一处反复起种
      lines.push({ x: new Float32Array(0), y: new Float32Array(0), speed: new Float32Array(0) });
      continue;
    }
    lines.push({ x: Float32Array.from(all, (p) => p.x), y: Float32Array.from(all, (p) => p.y), speed: Float32Array.from(all, (p) => p.s) });
  }
  return lines.filter((l) => l.x.length > 0);
}
