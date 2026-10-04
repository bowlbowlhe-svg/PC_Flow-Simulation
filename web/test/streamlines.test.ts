// 对比展示页流场图的时均流线：方向、间距、障碍与低速区。
import { describe, expect, it } from 'vitest';
import { traceStreamlines, type StreamOpts } from '../src/ui/compare/streamlines';

type F = Parameters<typeof traceStreamlines>[0];

/** w × h 格的流场（速度不做块平均） */
function field(w: number, h: number, vel: (x: number, y: number) => [number, number], solid: (c: number, r: number) => boolean = () => false): F {
  const T = new Float32Array(w * h);
  const u = new Float32Array(w * h);
  const v = new Float32Array(w * h);
  for (let r = 0; r < h; r++)
    for (let c = 0; c < w; c++) {
      const k = r * w + c;
      if (solid(c, r)) {
        T[k] = NaN;
        continue;
      }
      T[k] = 30;
      [u[k], v[k]] = vel(c + 0.5, r + 0.5);
    }
  return { crop: { x: 1, y: 1, w, h }, T, uvF: 1, uw: w, uh: h, u, v };
}

const O: StreamOpts = { dsep: 6, dtest: 3, step: 0.5, vmin: 0.03, maxSteps: 2000 };

describe('时均流线', () => {
  it('均匀流：水平直线、沿流向排列、间距约 dsep', () => {
    const L = traceStreamlines(field(60, 48, () => [0.8, 0]), O);
    expect(L.length).toBeGreaterThanOrEqual(6);
    expect(L.length).toBeLessThanOrEqual(10);
    for (const l of L) {
      const n = l.x.length;
      expect(Math.max(...l.y) - Math.min(...l.y)).toBeLessThan(1e-9);
      expect(l.x[n - 1]).toBeGreaterThan(l.x[0]); // 顺流
      expect(l.x[n - 1] - l.x[0]).toBeGreaterThan(50);
      for (let i = 1; i < n; i++) expect(l.x[i]).toBeGreaterThan(l.x[i - 1]);
      expect(l.speed.every((s) => Math.abs(s - 0.8) < 1e-6)).toBe(true);
    }
    const ys = L.map((l) => l.y[0]).sort((a, b) => a - b);
    for (let i = 1; i < ys.length; i++) expect(ys[i] - ys[i - 1]).toBeGreaterThanOrEqual(O.dtest);
  });

  it('不进入障碍、低速区不画线', () => {
    // 中间一块障碍；右边 1/4 风速低于 vmin
    const F = field(
      60,
      40,
      (x) => (x > 45 ? [0.01, 0] : [0.5, 0]),
      (c, r) => c >= 20 && c < 26 && r >= 10 && r < 30,
    );
    const L = traceStreamlines(F, O);
    expect(L.length).toBeGreaterThan(0);
    for (const l of L)
      for (let i = 0; i < l.x.length; i++) {
        const c = Math.floor(l.x[i]);
        const r = Math.floor(l.y[i]);
        expect(c >= 20 && c < 26 && r >= 10 && r < 30, `(${l.x[i]}, ${l.y[i]}) 在障碍里`).toBe(false);
        expect(l.x[i]).toBeLessThan(46.5);
      }
  });

  it('旋转流：不同流线之间保持 dtest 以上，单条流线不无限绕圈', () => {
    const F = field(50, 50, (x, y) => [-(y - 25) * 0.05, (x - 25) * 0.05]);
    const L = traceStreamlines(F, O);
    expect(L.length).toBeGreaterThan(2);
    for (let a = 0; a < L.length; a++)
      for (let b = a + 1; b < L.length; b++) {
        let dmin = Infinity;
        for (let i = 0; i < L[a].x.length; i += 2)
          for (let j = 0; j < L[b].x.length; j += 2) dmin = Math.min(dmin, Math.hypot(L[a].x[i] - L[b].x[j], L[a].y[i] - L[b].y[j]));
        expect(dmin).toBeGreaterThan(O.dtest - O.step - 1e-9);
      }
    // 绕回自身时停止：每条流线不超过最大半径（到角落约 35 格）一圈的长度（再留 30%）
    const lap = (2 * Math.PI * 25 * Math.SQRT2) / O.step;
    for (const l of L) expect(l.x.length).toBeLessThan(1.3 * lap);
  });
});
