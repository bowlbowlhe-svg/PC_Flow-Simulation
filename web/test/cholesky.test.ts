// 稀疏 Cholesky（嵌套剖分 + 上视分解）：与稠密 Cholesky / PCG 对照，残差达机器精度。
import { describe, expect, it } from 'vitest';
import { cholAnalyze, nestedDissectionGrid, SparseCholesky } from '../src/numerics/cholesky';
import { matvec, type CSR } from '../src/numerics/sparse';
import { SPDSolver } from '../src/numerics/pcg';
import { pressureMatrix, cellDiffusionMatrix } from '../src/solver/operators';
import { buildGeometry } from '../src/solver/geometry';
import { layoutDefault } from '../src/model/layoutDefault';

/** 可复现的伪随机数（LCG） */
function rng(seed: number) {
  let s = seed >>> 0;
  return () => {
    s = (Math.imul(s, 1664525) + 1013904223) >>> 0;
    return s / 4294967296;
  };
}

function relres(A: CSR, x: Float64Array, b: Float64Array): number {
  const r = new Float64Array(b.length);
  matvec(A, x, r);
  let num = 0;
  let den = 0;
  for (let i = 0; i < b.length; i++) {
    num += (b[i] - r[i]) ** 2;
    den += b[i] ** 2;
  }
  return Math.sqrt(num / den);
}

/** 稠密 Cholesky 参考解 */
function denseSolve(A: CSR, b: Float64Array): Float64Array {
  const n = A.nRows;
  const M = new Float64Array(n * n);
  for (let i = 0; i < n; i++) for (let p = A.rowPtr[i]; p < A.rowPtr[i + 1]; p++) M[i * n + A.colIdx[p]] = A.values[p];
  for (let j = 0; j < n; j++) {
    let d = M[j * n + j];
    for (let k = 0; k < j; k++) d -= M[j * n + k] ** 2;
    const ljj = Math.sqrt(d);
    M[j * n + j] = ljj;
    for (let i = j + 1; i < n; i++) {
      let s = M[i * n + j];
      for (let k = 0; k < j; k++) s -= M[i * n + k] * M[j * n + k];
      M[i * n + j] = s / ljj;
    }
  }
  const y = Float64Array.from(b);
  for (let i = 0; i < n; i++) {
    for (let k = 0; k < i; k++) y[i] -= M[i * n + k] * y[k];
    y[i] /= M[i * n + i];
  }
  for (let i = n - 1; i >= 0; i--) {
    for (let k = i + 1; k < n; k++) y[i] -= M[k * n + i] * y[k];
    y[i] /= M[i * n + i];
  }
  return y;
}

/** W×H 网格上的随机正权 5 点矩阵，部分格钉扎（单位行） */
function randomGridMatrix(W: number, H: number, seed: number): CSR {
  const r = rng(seed);
  const N = W * H;
  const uAct = new Uint8Array(W * (H + 1));
  const vAct = new Uint8Array((W + 1) * H);
  const wU = new Float64Array(uAct.length);
  const wV = new Float64Array(vAct.length);
  for (let k = 0; k < uAct.length; k++) {
    uAct[k] = r() < 0.9 ? 1 : 0;
    wU[k] = 0.05 + r();
  }
  for (let k = 0; k < vAct.length; k++) {
    vAct[k] = r() < 0.9 ? 1 : 0;
    wV[k] = 0.05 + r();
  }
  const pin = new Uint8Array(N);
  for (let i = 0; i < N; i++) pin[i] = r() < 0.08 ? 1 : 0;
  pin[0] = 1; // 保证每个连通块都有 Dirichlet 锚点的概率足够；另加对角偏移见下
  const A = pressureMatrix(W, H, uAct, vAct, wU, wV, pin);
  // 对角加小量，保证孤立块也正定
  for (let i = 0; i < N; i++)
    for (let p = A.rowPtr[i]; p < A.rowPtr[i + 1]; p++) if (A.colIdx[p] === i) A.values[p] += 0.01;
  return A;
}

describe('嵌套剖分排序', () => {
  it('是 0..N−1 的一个排列（含非方网格、单行、单列）', () => {
    for (const [W, H] of [
      [1, 1],
      [1, 17],
      [23, 1],
      [7, 13],
      [64, 64],
      [140, 140],
    ]) {
      const p = nestedDissectionGrid(W, H);
      const seen = new Uint8Array(W * H);
      for (const i of p) seen[i]++;
      expect(seen.every((v) => v === 1)).toBe(true);
    }
  });
});

describe('SparseCholesky', () => {
  it('随机 5 点矩阵（含钉扎行）与稠密 Cholesky 一致', () => {
    for (const [W, H, seed] of [
      [5, 7, 1],
      [12, 9, 2],
      [17, 17, 3],
      [30, 11, 4],
    ]) {
      const A = randomGridMatrix(W, H, seed);
      const r = rng(seed + 100);
      const b = Float64Array.from({ length: W * H }, () => r() - 0.5);
      const ch = new SparseCholesky(A, cholAnalyze(A, nestedDissectionGrid(W, H)));
      const x = ch.solve(b);
      const xd = denseSolve(A, b);
      let md = 0;
      let mx = 0;
      for (let i = 0; i < x.length; i++) {
        md = Math.max(md, Math.abs(x[i] - xd[i]));
        mx = Math.max(mx, Math.abs(xd[i]));
      }
      expect(md).toBeLessThan(1e-11 * mx);
      expect(relres(A, x, b)).toBeLessThan(1e-13);
    }
  });

  it('任意排序（自然序、逆序）结果相同到舍入', () => {
    const W = 15;
    const H = 12;
    const A = randomGridMatrix(W, H, 7);
    const b = Float64Array.from({ length: W * H }, (_, i) => Math.sin(i));
    const x1 = new SparseCholesky(A, cholAnalyze(A, nestedDissectionGrid(W, H))).solve(b);
    const nat = Int32Array.from({ length: W * H }, (_, i) => i);
    const rev = Int32Array.from({ length: W * H }, (_, i) => W * H - 1 - i);
    for (const perm of [nat, rev]) {
      const x2 = new SparseCholesky(A, cholAnalyze(A, perm)).solve(b);
      for (let i = 0; i < x1.length; i++) expect(Math.abs(x1[i] - x2[i])).toBeLessThan(1e-12 * (1 + Math.abs(x1[i])));
    }
  });

  it('符号分析可复用于同结构的新数值；结构不同时报错；非正定时报错', () => {
    const W = 10;
    const H = 8;
    const A = randomGridMatrix(W, H, 11);
    const sym = cholAnalyze(A, nestedDissectionGrid(W, H));
    const B: CSR = { ...A, values: A.values.map((v) => v * 2) };
    const b = Float64Array.from({ length: W * H }, (_, i) => (i % 7) - 3);
    const xa = new SparseCholesky(A, sym).solve(b);
    const xb = new SparseCholesky(B, sym).solve(b);
    for (let i = 0; i < xa.length; i++) expect(xb[i]).toBeCloseTo(xa[i] / 2, 12);
    const C = randomGridMatrix(W + 1, H, 11);
    expect(() => new SparseCholesky(C, sym)).toThrow();
    // 非零个数相同但结构不同：同样报结构不符（而不是误导性的"主元非正"）
    const Dp = randomGridMatrix(W, H, 12);
    if (Dp.rowPtr[Dp.nRows] === A.rowPtr[A.nRows]) expect(() => new SparseCholesky(Dp, sym)).toThrow(/结构/);
    const swapped: CSR = { ...A, colIdx: A.colIdx.slice() };
    const r = A.rowPtr.findIndex((v, i) => i < A.nRows && A.rowPtr[i + 1] - v >= 2);
    [swapped.colIdx[A.rowPtr[r]], swapped.colIdx[A.rowPtr[r] + 1]] = [swapped.colIdx[A.rowPtr[r] + 1], swapped.colIdx[A.rowPtr[r]]];
    expect(() => new SparseCholesky(swapped, sym)).toThrow(/结构/);
    const D: CSR = { ...A, values: A.values.slice() };
    // 把一个非钉扎行的对角改成负数
    for (let i = 0; i < A.nRows; i++) {
      if (A.rowPtr[i + 1] - A.rowPtr[i] > 1) {
        for (let p = A.rowPtr[i]; p < A.rowPtr[i + 1]; p++) if (A.colIdx[p] === i) D.values[p] = -1;
        break;
      }
    }
    expect(() => new SparseCholesky(D, sym)).toThrow(/主元非正/);
  });

  it('真实 140² 压力矩阵与温度扩散矩阵：残差达机器精度，与 PCG（1e−12）一致', () => {
    const g = buildGeometry(layoutDefault(), 0.5);
    const { W, H, N } = g;
    const pin = new Uint8Array(N);
    for (const i of g.obsIdx) pin[i] = 1;
    for (const i of g.farFieldPresIdx) pin[i] = 1;
    for (const i of g.presRefIdx) pin[i] = 1;
    const beta = (n: number, c: Float64Array) => Float64Array.from({ length: n }, (_, k) => 1 / (1 + c[k] * 0.7));
    const P = pressureMatrix(W, H, g.uFaceActive, g.vFaceActive, beta(g.uFaceActive.length, g.uDragCoef), beta(g.vFaceActive.length, g.vDragCoef), pin);
    const isObs = new Uint8Array(N);
    for (const i of g.obsIdx) isObs[i] = 1;
    const alpha = Float64Array.from({ length: N }, (_, i) => 2.2e-5 * (1 + (i % 13)));
    const T = cellDiffusionMatrix(alpha, W, H, isObs, null, 0.005, g.diffScale);
    for (const A of [P, T]) {
      const b = Float64Array.from({ length: N }, (_, i) => (pin[i] && A === P ? 0 : Math.cos(0.37 * i)));
      const x = new SparseCholesky(A, cholAnalyze(A, nestedDissectionGrid(W, H))).solve(b);
      expect(relres(A, x, b)).toBeLessThan(1e-13);
      const xp = new SPDSolver(A, { tol: 1e-12 }).solve(b).x;
      let md = 0;
      let mx = 0;
      for (let i = 0; i < N; i++) {
        md = Math.max(md, Math.abs(x[i] - xp[i]));
        mx = Math.max(mx, Math.abs(x[i]));
      }
      expect(md).toBeLessThan(1e-8 * mx);
    }
  });
});
