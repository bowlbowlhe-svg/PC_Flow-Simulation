/**
 * 自带数值例程与 Octave 的逐位对照（ALGORITHM.md §3.11）。
 * 对照数据：web/test/fixtures/numerics.json，由 web/test/gen/gen_numerics_fixtures.m 生成：
 *   cd matlab_app; OMP_NUM_THREADS=1 octave-cli --no-gui --eval "setup_paths(); addpath('../web/test/gen'); gen_numerics_fixtures"
 */
import { describe, expect, it } from 'vitest';
import { gridInterp2, type InterpMethod } from '../src/numerics/gridInterp2';
import { edtNearest } from '../src/numerics/edtNearest';
import { makePchip, pchipEval, pchipEval1 } from '../src/numerics/pchipEval';
import { bitwiseMismatches, hexToF64, loadFixtures, maskFromString } from './numericsTestUtils';

const fx = loadFixtures();

describe('fixtures', () => {
  it('由 Octave 生成且覆盖要求的情形', () => {
    expect(fx.generator.tool).toBe('octave');
    const names = new Set(fx.gridInterp2.map((c) => `${c.name}@${c.o1},${c.o2}`));
    for (const o of ['1,1', '1,0.5', '0.5,1']) {
      for (const g of ['small4x4', 'plateau12x10', 'const5x6', 'advect24x25']) expect(names.has(`${g}@${o}`)).toBe(true);
    }
    expect(fx.edt.some((c) => c.name === 'obstacle140' && c.W === 140 && c.H === 140)).toBe(true);
    expect(fx.pchip.filter((c) => c.name.startsWith('fan_')).length).toBeGreaterThanOrEqual(11);
  });
});

describe('gridInterp2 与 Octave grid_interp2 逐位一致', () => {
  const methods: InterpMethod[] = ['linear', 'cubic', 'makima'];
  for (const c of fx.gridInterp2) {
    for (const m of methods) {
      it(`${c.name} o=(${c.o1},${c.o2}) ${m}`, () => {
        const V = hexToF64(c.V);
        const q1 = hexToF64(c.q1);
        const q2 = hexToF64(c.q2);
        const expected = hexToF64(c[m]);
        expect(V.length).toBe(c.n1 * c.n2);
        expect(q1.length).toBe(c.nq);
        const got = gridInterp2(V, c.n1, c.n2, q1, q2, m, c.o1, c.o2);
        expect(bitwiseMismatches(got, expected)).toEqual([]);
      });
    }
  }

  it('makima 平台区零分母取 0（常值场处处返回常值）', () => {
    const V = new Float64Array(5 * 6).fill(3.7);
    const q1 = Float64Array.from([0, 1, 2.5, 3.25, 7]);
    const q2 = Float64Array.from([1, 6, 2.5, 0.2, 3.3]);
    for (const m of ['cubic', 'makima'] as const) {
      const out = gridInterp2(V, 5, 6, q1, q2, m, 1, 1);
      for (const v of out) expect(v).toBe(3.7);
    }
  });

  it('可复用输出缓冲', () => {
    const c = fx.gridInterp2[0];
    const V = hexToF64(c.V);
    const q1 = hexToF64(c.q1);
    const q2 = hexToF64(c.q2);
    const buf = new Float64Array(c.nq);
    const r = gridInterp2(V, c.n1, c.n2, q1, q2, 'makima', c.o1, c.o2, buf);
    expect(r).toBe(buf);
    expect(bitwiseMismatches(buf, hexToF64(c.makima))).toEqual([]);
  });
});

/** 暴力参照：逐格扫描全部 true 格（线性索引递增），距离平方最小者，平局取先出现者。 */
function edtBrute(mask: Uint8Array, W: number, H: number): { D2: Float64Array; idx: Int32Array } {
  const N = W * H;
  const D2 = new Float64Array(N).fill(Infinity);
  const idx = new Int32Array(N).fill(-1);
  const trues: number[] = [];
  for (let k = 0; k < N; k++) if (mask[k]) trues.push(k);
  for (let k = 0; k < N; k++) {
    const y = k % W;
    const x = (k - y) / W;
    for (const t of trues) {
      const ty = t % W;
      const tx = (t - ty) / W;
      const d2 = (x - tx) * (x - tx) + (y - ty) * (y - ty);
      if (d2 < D2[k]) { D2[k] = d2; idx[k] = t; }
    }
  }
  return { D2, idx };
}

describe('edtNearest 与 Octave edt_nearest 逐位一致', () => {
  for (const c of fx.edt) {
    it(`${c.name} (${c.W}×${c.H})`, () => {
      const mask = maskFromString(c.mask);
      expect(mask.length).toBe(c.W * c.H);
      const { D, idx } = edtNearest(mask, c.W, c.H);
      if (c.allFalse) {
        expect(D.every((v) => v === Infinity)).toBe(true);
        expect(idx.every((v) => v === -1)).toBe(true);
        return;
      }
      // Octave 端已断言 sqrt(D2) 与 D 逐位相同；Math.sqrt 同为正确舍入
      const expD = Float64Array.from(c.D2!, (v) => Math.sqrt(v));
      expect(bitwiseMismatches(D, expD)).toEqual([]);
      const expIdx0 = Int32Array.from(c.idx!, (v) => v - 1); // Octave 1 基 → 0 基
      expect(bitwiseMismatches(idx, expIdx0)).toEqual([]);
      if (c.W * c.H <= 3000) {
        const br = edtBrute(mask, c.W, c.H);
        expect(bitwiseMismatches(D, br.D2.map(Math.sqrt))).toEqual([]);
        expect(bitwiseMismatches(idx, br.idx)).toEqual([]);
      }
    });
  }

  it('boolean 数组输入与 Uint8Array 相同', () => {
    const c = fx.edt.find((e) => e.name === 'rand7x5')!;
    const m8 = maskFromString(c.mask);
    const mb = Array.from(m8, (v) => v === 1);
    const a = edtNearest(m8, c.W, c.H);
    const b = edtNearest(mb, c.W, c.H);
    expect(bitwiseMismatches(a.D, b.D)).toEqual([]);
    expect(Array.from(a.idx)).toEqual(Array.from(b.idx));
  });
});

describe('pchipEval 与 Octave pchip_eval 逐位一致', () => {
  for (const c of fx.pchip) {
    it(c.name, () => {
      const x = hexToF64(c.x);
      const y = hexToF64(c.y);
      const q = hexToF64(c.q);
      const v = hexToF64(c.v);
      expect(x.length).toBe(c.n);
      expect(bitwiseMismatches(pchipEval(x, y, q), v)).toEqual([]);
      const f = makePchip(x, y);
      expect(bitwiseMismatches(Float64Array.from(q, f), v)).toEqual([]);
      expect(bitwiseMismatches(Float64Array.from(q, (qq) => pchipEval1(x, y, qq)), v)).toEqual([]);
    });
  }

  it('风扇曲线用普通数组字面量节点也逐位一致', () => {
    const c = fx.pchip.find((p) => p.name === 'fan_NF_A14')!;
    const xg = [0, 0.2, 0.4, 0.6, 0.8, 1.0];
    expect(bitwiseMismatches(hexToF64(c.x), xg)).toEqual([]);
    const y = [1.0, 0.91, 0.78, 0.59, 0.34, 0.0];
    expect(bitwiseMismatches(hexToF64(c.y), y)).toEqual([]);
    expect(bitwiseMismatches(pchipEval(xg, y, hexToF64(c.q)), hexToF64(c.v))).toEqual([]);
  });
});
