// 模板存储的扩散系统与 CSR 版（pcg + mic0）逐位相同：矩阵、预条件、迭代次数与解。
import { describe, expect, it } from 'vitest';
import { buildGeometry } from '../src/solver/geometry';
import { layoutDefault } from '../src/model/layoutDefault';
import { cellDiffusionMatrix, cellDiffusionStencil, faceDiffusionMatrix, faceDiffusionStencil } from '../src/solver/operators';
import { SPDSolver } from '../src/numerics/pcg';
import { StencilSolver, type StencilMatrix } from '../src/numerics/stencil';
import type { CSR } from '../src/numerics/sparse';

/** 模板矩阵展开为按行的 (列, 值) 表，与 CSR 比较（只比较激活行，映射到压缩索引） */
function expectSameMatrix(S: StencilMatrix, A: CSR, act: Int32Array | null) {
  const n = act ? act.length : S.n;
  const loc = new Int32Array(S.n).fill(-1);
  for (let a = 0; a < n; a++) loc[act ? act[a] : a] = a;
  for (let a = 0; a < n; a++) {
    const i = act ? act[a] : a;
    const entries: [number, number][] = [];
    const nR = S.nR;
    if (i >= nR && S.west[i] !== 0) entries.push([loc[i - nR], S.west[i]]);
    if (i >= 1 && S.south[i] !== 0) entries.push([loc[i - 1], S.south[i]]);
    entries.push([a, S.diag[i]]);
    if (i + 1 < S.n && S.south[i + 1] !== 0) entries.push([loc[i + 1], S.south[i + 1]]);
    if (i + nR < S.n && S.west[i + nR] !== 0) entries.push([loc[i + nR], S.west[i + nR]]);
    const csr: [number, number][] = [];
    for (let p = A.rowPtr[a]; p < A.rowPtr[a + 1]; p++) csr.push([A.colIdx[p], A.values[p]]);
    expect(entries).toEqual(csr);
  }
}

describe('模板存储的扩散系统', () => {
  const g = buildGeometry(layoutDefault(), 0.5);
  const { W, H, N } = g;
  const isObs = new Uint8Array(N);
  for (const i of g.obsIdx) isObs[i] = 1;
  const isDir = new Uint8Array(N);
  for (const i of g.dirichletIdx) isDir[i] = 1;
  // 起伏较大的系数场（类似发展后的 ν_eff）
  const nu = Float64Array.from({ length: N }, (_, i) => 1.56e-5 * (1 + 400 * Math.abs(Math.sin(0.013 * i) * Math.cos(0.0071 * i))));

  for (const isU of [true, false]) {
    it(`${isU ? 'u' : 'v'} 面速度扩散：矩阵逐项相同，PCG 迭代与解逐位相同`, () => {
      const act = isU ? g.uFaceActive : g.vFaceActive;
      const C = faceDiffusionMatrix(nu, isU, W, H, act, 0.005, g.diffScale);
      const S = faceDiffusionStencil(nu, isU, W, H, act, 0.005, g.diffScale);
      expectSameMatrix(S, C.A, C.actIdx);
      const full = Float64Array.from({ length: S.n }, (_, k) => (act[k] ? Math.sin(0.37 * k) + 0.2 : 0));
      const b = full.map((v) => v / 0.005);
      const x0 = full.map((v, k) => (act[k] ? v * 0.97 : 0));
      const rc = new SPDSolver(C.A, { tol: 1e-12, precond: 'mic0' }).solve(
        Float64Array.from(C.actIdx, (k) => b[k]),
        Float64Array.from(C.actIdx, (k) => x0[k]),
      );
      const rs = new StencilSolver(S, 1e-12).solve(b, x0);
      expect(rs.converged).toBe(true);
      expect(rs.iters).toBe(rc.iters);
      expect(rs.iters).toBeGreaterThan(3);
      const xs = Array.from(C.actIdx, (k) => rs.x[k]);
      expect(xs).toEqual(Array.from(rc.x));
      for (let k = 0; k < S.n; k++) if (!act[k]) expect(rs.x[k]).toBe(0);
    });
  }

  it('温度扩散（定温壁）与 k 扩散：矩阵逐项相同，解逐位相同', () => {
    for (const dir of [isDir, null]) {
      const C = cellDiffusionMatrix(nu, W, H, isObs, dir, 0.005, g.diffScale);
      const S = cellDiffusionStencil(nu, W, H, isObs, dir, 0.005, g.diffScale);
      expectSameMatrix(S, C, null);
      const b = Float64Array.from({ length: N }, (_, i) => 25 / 0.005 + Math.cos(0.11 * i));
      const x0 = Float64Array.from({ length: N }, () => 25);
      const rc = new SPDSolver(C, { tol: 1e-12, precond: 'mic0' }).solve(b, x0);
      const rs = new StencilSolver(S, 1e-12).solve(b, x0);
      expect(rs.iters).toBe(rc.iters);
      expect(Array.from(rs.x)).toEqual(Array.from(rc.x));
    }
  });
});
