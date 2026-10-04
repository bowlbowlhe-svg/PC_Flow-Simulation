// 对比展示页流场图的读数与可比性判断。
import { describe, expect, it } from 'vitest';
import { makeFieldThumb, type FieldMean } from '../src/compare/thumb';
import { readout, sameGrid, type FieldStyle } from '../src/ui/compare/fieldMath';

function thumb(T0: number, cellMm = 6) {
  const W = 30;
  const H = 40;
  const N = W * H;
  const f: FieldMean = {
    W,
    H,
    T: new Float32Array(N).fill(T0),
    u: new Float32Array(N).fill(0.3),
    v: new Float32Array(N).fill(0.4),
    solid: new Uint8Array(N).map((_, i) => (i === 14 * W + 11 ? 1 : 0)), // 格 (x = 15, y = 12)
    openings: [],
  };
  return makeFieldThumb(f, { W, H, cellMm, caseOuter: { x: 15, y: 12, w: 10, h: 8 }, ram: [], fans: [] }, 2);
}

const style = (mode: FieldStyle['mode'], ref?: ReturnType<typeof thumb>): FieldStyle => ({ mode, range: [25, 60], ref, stream: true, labels: true });

describe('流场图读数', () => {
  it('温度、风速、距后壁与顶的距离；障碍；温差只在可比时给', () => {
    const a = thumb(40);
    const b = thumb(37);
    const c = 16 - a.crop.x; // 格 (16, 13)：机箱外框后壁起第 2 格、顶起第 2 格
    const r = 13 - a.crop.y;
    expect(readout(a, c, r, style('temperature'))).toBe('距后壁 6 mm、距顶 6 mm：40.0°C，风速 0.50 m/s');
    expect(readout(a, c, r, style('diff', b))).toBe('距后壁 6 mm、距顶 6 mm：40.0°C，风速 0.50 m/s，温差 +3.0°C');
    expect(readout(a, 15 - a.crop.x, 12 - a.crop.y, style('temperature'))).toBe('距后壁 0 mm、距顶 0 mm：障碍');
    expect(readout(a, -1, 0, style('temperature'))).toBe('');
    expect(readout(a, a.crop.w, 0, style('temperature'))).toBe('');
    const coarse = thumb(37, 12);
    expect(sameGrid(a, b)).toBe(true);
    expect(sameGrid(a, coarse)).toBe(false);
    expect(readout(a, c, r, style('diff', coarse))).not.toContain('温差');
  });
});
