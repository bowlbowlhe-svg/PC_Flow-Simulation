/**
 * CSR 稀疏矩阵与 PCG 的测试 + 140² 基准（基准只打印耗时，不作断言）。
 */
import { describe, expect, it } from 'vitest';
import {
  add, addDiag, diag, diagMatrix, fromDense, fromTriplets, getEntry, identity, isSymmetric, lowerTriangle,
  matvec, nnz, rowSums, scale, setDiag, subMatrix, toDense, toTriplets, transpose, zeroCols, zeroRows, zeroRowsCols,
  type CSR,
} from '../src/numerics/sparse';
import {
  ic0, jacobi, makePreconditioner, mic0, noPrecond, pcg, solveSPD, SPDSolver, type PrecondKind,
} from '../src/numerics/pcg';
import {
  bandCholeskySolve, bitwiseMismatches, hexToF64, loadFixtures, maskFromString, norm2, poisson2d, pressureLike, rng,
} from './numericsTestUtils';

function denseMatvec(D: Float64Array, n: number, m: number, x: ArrayLike<number>): Float64Array {
  const y = new Float64Array(n);
  for (let i = 0; i < n; i++) {
    let s = 0;
    for (let j = 0; j < m; j++) s += D[i + j * n] * x[j];
    y[i] = s;
  }
  return y;
}

function randomSparse(n: number, m: number, density: number, r: () => number): CSR {
  const I: number[] = [];
  const J: number[] = [];
  const V: number[] = [];
  for (let i = 0; i < n; i++) for (let j = 0; j < m; j++) if (r() < density) { I.push(i); J.push(j); V.push(r() * 2 - 1); }
  return fromTriplets(n, m, I, J, V);
}

/** 稠密 Cholesky 直接解（列优先 n×n）。 */
function denseCholSolve(D: Float64Array, n: number, b: ArrayLike<number>): Float64Array {
  const L = new Float64Array(n * n);
  for (let j = 0; j < n; j++) {
    let s = D[j + j * n];
    for (let k = 0; k < j; k++) s -= L[j + k * n] * L[j + k * n];
    if (!(s > 0)) throw new Error('not SPD');
    const ljj = Math.sqrt(s);
    L[j + j * n] = ljj;
    for (let i = j + 1; i < n; i++) {
      let t = D[i + j * n];
      for (let k = 0; k < j; k++) t -= L[i + k * n] * L[j + k * n];
      L[i + j * n] = t / ljj;
    }
  }
  const y = new Float64Array(n);
  for (let i = 0; i < n; i++) {
    let s = b[i];
    for (let k = 0; k < i; k++) s -= L[i + k * n] * y[k];
    y[i] = s / L[i + i * n];
  }
  const x = new Float64Array(n);
  for (let i = n - 1; i >= 0; i--) {
    let s = y[i];
    for (let k = i + 1; k < n; k++) s -= L[k + i * n] * x[k];
    x[i] = s / L[i + i * n];
  }
  return x;
}

function trueRelres(A: CSR, x: Float64Array, b: Float64Array): number {
  const Ax = matvec(A, x);
  let s = 0;
  for (let i = 0; i < b.length; i++) { const d = b[i] - Ax[i]; s += d * d; }
  return Math.sqrt(s) / norm2(b);
}

function relErr(x: Float64Array, ref: Float64Array): number {
  let s = 0;
  for (let i = 0; i < x.length; i++) { const d = x[i] - ref[i]; s += d * d; }
  return Math.sqrt(s) / norm2(ref);
}

describe('sparse: fromTriplets', () => {
  it('重复项按输入顺序累加（与 Octave 8.4 sparse 实测一致）', () => {
    // Octave：sparse([1 1 1 2 2 2],[1 1 1 1 1 1],[1 1 1e16 1e16 1 1]) → (1,1) = 1e16+2，(2,1) = 1e16
    const A = fromTriplets(2, 2, [0, 0, 0, 1, 1, 1], [0, 0, 0, 0, 0, 0], [1, 1, 1e16, 1e16, 1, 1]);
    expect(getEntry(A, 0, 0)).toBe(10000000000000002);
    expect(getEntry(A, 1, 0)).toBe(1e16);
    // 输入交错、顺序不同的行：sparse([2 1 2 1 2 1],[1 1 1 1 1 1],[1e16 1 1 1 1 1e16])
    const B = fromTriplets(2, 2, [1, 0, 1, 0, 1, 0], [0, 0, 0, 0, 0, 0], [1e16, 1, 1, 1, 1, 1e16]);
    expect(getEntry(B, 0, 0)).toBe(10000000000000002);
    expect(getEntry(B, 1, 0)).toBe(1e16);
  });

  it('求和为 0 的项删除（MATLAB 不存 0），可关闭', () => {
    const A = fromTriplets(3, 3, [0, 0, 1, 2], [1, 1, 1, 0], [2, -2, 0, 5]);
    expect(nnz(A)).toBe(1);
    expect(getEntry(A, 2, 0)).toBe(5);
    const B = fromTriplets(3, 3, [0, 0, 1, 2], [1, 1, 1, 0], [2, -2, 0, 5], { dropZeros: false });
    expect(nnz(B)).toBe(3);
  });

  it('行内列号有序、标量 V、越界报错', () => {
    const A = fromTriplets(2, 4, [1, 0, 1, 0], [3, 2, 0, 0], 1.5);
    expect(Array.from(A.rowPtr)).toEqual([0, 2, 4]);
    expect(Array.from(A.colIdx)).toEqual([0, 2, 0, 3]);
    expect(Array.from(A.values)).toEqual([1.5, 1.5, 1.5, 1.5]);
    expect(() => fromTriplets(2, 2, [2], [0], [1])).toThrow();
    expect(() => fromTriplets(2, 2, [0.5], [0], [1])).toThrow();
  });
});

describe('sparse: 与 Octave sparse / A*x / sum(A,2) / A\'*y 逐位一致', () => {
  for (const c of loadFixtures().sparse) {
    it(c.name, () => {
      const A = fromTriplets(c.m, c.n, c.I.map((v) => v - 1), c.J.map((v) => v - 1), hexToF64(c.V));
      expect(nnz(A)).toBe(c.nnz);
      // Octave find() 按列优先给出 (i, j, v)：用转置的行序比较
      const At = transpose(A);
      const t = toTriplets(At);
      expect(Array.from(t.J, (v) => v + 1)).toEqual(c.Ai);
      expect(Array.from(t.I, (v) => v + 1)).toEqual(c.Aj);
      expect(bitwiseMismatches(t.V, hexToF64(c.Av))).toEqual([]);
      expect(bitwiseMismatches(matvec(A, hexToF64(c.x)), hexToF64(c.Ax))).toEqual([]);
      expect(bitwiseMismatches(rowSums(A), hexToF64(c.rowSum))).toEqual([]);
      expect(bitwiseMismatches(matvec(At, hexToF64(c.y)), hexToF64(c.Aty))).toEqual([]);
    });
  }
});

describe('sparse: 基本操作与稠密结果一致', () => {
  const r = rng(7);
  const A = randomSparse(9, 7, 0.35, r);
  const B = randomSparse(9, 7, 0.35, r);
  const DA = toDense(A);
  const DB = toDense(B);

  it('matvec / transpose / toDense / fromDense / toTriplets', () => {
    const x = Float64Array.from({ length: 7 }, () => r() - 0.5);
    expect(bitwiseMismatches(matvec(A, x), denseMatvec(DA, 9, 7, x))).toEqual([]);
    const At = transpose(A);
    expect(At.nRows).toBe(7);
    const DAt = toDense(At);
    for (let i = 0; i < 9; i++) for (let j = 0; j < 7; j++) expect(DAt[j + i * 7]).toBe(DA[i + j * 9]);
    expect(Array.from(toDense(fromDense(DA, 9, 7)))).toEqual(Array.from(DA));
    const t = toTriplets(A);
    expect(Array.from(toDense(fromTriplets(9, 7, t.I, t.J, t.V)))).toEqual(Array.from(DA));
  });

  it('add / scale / addDiag / diag / rowSums', () => {
    const C = toDense(add(A, scale(B, -0.3)));
    for (let k = 0; k < C.length; k++) expect(C[k]).toBe(DA[k] + -0.3 * DB[k]);
    // MATLAB：a − s·b 与 a + (−s·b) 逐位相同
    for (let k = 0; k < C.length; k++) if (DA[k] !== 0 && DB[k] !== 0) expect(C[k]).toBe(DA[k] - 0.3 * DB[k]);
    const S = add(A, scale(A, -1));
    expect(nnz(S)).toBe(0);
    const d = Float64Array.from({ length: 7 }, (_, i) => i - 3);
    const Ad = toDense(addDiag(A, d));
    for (let i = 0; i < 9; i++) for (let j = 0; j < 7; j++) {
      expect(Ad[i + j * 9]).toBe(DA[i + j * 9] + (i === j ? d[i] : 0));
    }
    const dg = diag(A);
    for (let i = 0; i < 7; i++) expect(dg[i]).toBe(DA[i + i * 9]);
    const rs = rowSums(A);
    for (let i = 0; i < 9; i++) {
      let s = 0;
      for (let j = 0; j < 7; j++) if (DA[i + j * 9] !== 0) s += DA[i + j * 9];
      expect(rs[i]).toBe(s);
    }
  });

  it('zeroRowsCols / zeroRows / zeroCols / setDiag / subMatrix / lowerTriangle', () => {
    const Q = randomSparse(8, 8, 0.4, r);
    const DQ = toDense(Q);
    const pin = [1, 5];
    const Z = toDense(setDiag(zeroRowsCols(Q, pin), pin, -1));
    for (let i = 0; i < 8; i++) for (let j = 0; j < 8; j++) {
      const exp = pin.includes(i) || pin.includes(j) ? (i === j ? -1 : 0) : DQ[i + j * 8];
      expect(Z[i + j * 8]).toBe(exp);
    }
    const ZR = toDense(zeroRows(Q, [2]));
    const ZC = toDense(zeroCols(Q, [3]));
    for (let j = 0; j < 8; j++) { expect(ZR[2 + j * 8]).toBe(0); expect(ZC[j + 3 * 8]).toBe(0); }
    const rows = [6, 0, 3];
    const cols = [2, 7, 0, 4];
    const Sm = toDense(subMatrix(Q, rows, cols));
    for (let a = 0; a < 3; a++) for (let b = 0; b < 4; b++) expect(Sm[a + b * 3]).toBe(DQ[rows[a] + cols[b] * 8]);
    const Sc = toDense(subMatrix(Q, null, [5, 1]));
    for (let i = 0; i < 8; i++) { expect(Sc[i]).toBe(DQ[i + 5 * 8]); expect(Sc[i + 8]).toBe(DQ[i + 8]); }
    const Lo = toDense(lowerTriangle(Q));
    for (let i = 0; i < 8; i++) for (let j = 0; j < 8; j++) expect(Lo[i + j * 8]).toBe(j <= i ? DQ[i + j * 8] : 0);
    expect(nnz(identity(4, 2))).toBe(4);
    expect(nnz(diagMatrix([1, 0, 2]))).toBe(2);
  });

  it('isSymmetric', () => {
    expect(isSymmetric(poisson2d(5, 4))).toBe(true);
    expect(isSymmetric(fromTriplets(2, 2, [0, 1], [1, 0], [1, 2]))).toBe(false);
  });
});

/** 随机稀疏 SPD：M 矩阵（图 Laplacian + 正对角）与非 M 矩阵（RᵀR + αI）。 */
function randomSPD(n: number, kind: 'M' | 'general', seed: number): CSR {
  const r = rng(seed);
  if (kind === 'M') {
    const I: number[] = [];
    const J: number[] = [];
    const V: number[] = [];
    const dsum = new Float64Array(n);
    for (let i = 0; i < n; i++) for (let j = i + 1; j < n; j++) if (r() < 0.12) {
      const w = 0.1 + r();
      I.push(i, j); J.push(j, i); V.push(-w, -w);
      dsum[i] += w; dsum[j] += w;
    }
    for (let i = 0; i < n; i++) { I.push(i); J.push(i); V.push(dsum[i] + 0.01 + 0.2 * r()); }
    return fromTriplets(n, n, I, J, V);
  }
  const R = randomSparse(n, n, 0.1, r);
  const DR = toDense(R);
  const D = new Float64Array(n * n);
  for (let i = 0; i < n; i++) for (let j = 0; j < n; j++) {
    let s = 0;
    for (let k = 0; k < n; k++) s += DR[k + i * n] * DR[k + j * n];
    D[i + j * n] = s + (i === j ? 0.05 : 0);
  }
  return fromDense(D, n, n);
}

describe('PCG', () => {
  for (const kind of ['M', 'general'] as const) {
    for (const pk of ['mic0', 'ic0', 'jacobi', 'none'] as PrecondKind[]) {
      it(`随机 SPD（${kind}）n=60，预条件 ${pk}：残差达标且与稠密 Cholesky 一致`, () => {
        const n = 60;
        const A = randomSPD(n, kind, kind === 'M' ? 11 : 12);
        expect(isSymmetric(A)).toBe(true);
        const r = rng(99);
        const b = Float64Array.from({ length: n }, () => r() - 0.5);
        const res = pcg(A, b, null, { tol: 1e-12, precond: pk });
        expect(res.converged).toBe(true);
        expect(res.relres).toBeLessThanOrEqual(1e-12);
        expect(trueRelres(A, res.x, b)).toBeLessThanOrEqual(1e-12);
        const ref = denseCholSolve(toDense(A), n, b);
        expect(relErr(res.x, ref)).toBeLessThan(1e-9);
      });
    }
  }

  it('b = 0 返回零向量；x0 已是解时 0 次迭代；maxIter 不足时 converged = false', () => {
    const A = poisson2d(12, 10);
    const z = pcg(A, new Float64Array(120), Float64Array.from({ length: 120 }, () => 1));
    expect(z.iters).toBe(0);
    expect(z.converged).toBe(true);
    expect(z.x.every((v) => v === 0)).toBe(true);
    const b = Float64Array.from({ length: 120 }, (_, i) => Math.sin(i));
    const s1 = solveSPD(A, b);
    expect(s1.converged).toBe(true);
    const s2 = solveSPD(A, b, { x0: s1.x });
    expect(s2.iters).toBe(0);
    expect(s2.converged).toBe(true);
    const s3 = pcg(A, b, null, { maxIter: 2, precond: 'jacobi' });
    expect(s3.converged).toBe(false);
    expect(s3.iters).toBe(2);
    expect(s3.relres).toBeGreaterThan(1e-12);
  });

  it('容限不可达时有限步停止（真残差停滞检测），热启动减少迭代', () => {
    const A = poisson2d(30, 25);
    const b = Float64Array.from({ length: A.nRows }, (_, i) => Math.sin(0.1 * i) + 0.3);
    const res = pcg(A, b, null, { tol: 1e-18 });
    expect(res.converged).toBe(false);
    expect(res.iters).toBeLessThan(400);
    expect(res.relres).toBeLessThan(1e-14);
    const S = new SPDSolver(A);
    const cold = S.solve(b);
    const b2 = b.map((v, i) => v + 1e-3 * Math.cos(i));
    const warm = S.solve(b2, cold.x);
    const cold2 = S.solve(b2);
    expect(warm.converged && cold2.converged).toBe(true);
    expect(warm.iters).toBeLessThan(cold2.iters);
  });

  it('确定性：同一输入两次求解逐位相同', () => {
    const A = poisson2d(30, 25);
    const r = rng(3);
    const b = Float64Array.from({ length: A.nRows }, () => r() - 0.5);
    for (const pk of ['mic0', 'ic0', 'jacobi'] as PrecondKind[]) {
      const a1 = pcg(A, b, null, { precond: pk });
      const a2 = pcg(A, b, null, { precond: pk });
      expect(bitwiseMismatches(a1.x, a2.x)).toEqual([]);
      expect(a1.iters).toBe(a2.iters);
    }
    const S = new SPDSolver(A, { precond: 'ic0' });
    const s1 = S.solve(b);
    const s2 = S.solve(b);
    expect(bitwiseMismatches(s1.x, s2.x)).toEqual([]);
    expect(bitwiseMismatches(s1.x, pcg(A, b, null, { precond: 'ic0' }).x)).toEqual([]);
  });

  it('IC(0) 在 Kershaw 矩阵上出现非正主元 → 返回 null；solveSPD 退回 Jacobi 仍收敛', () => {
    // Kershaw (1978)：对称正定，但 IC(0) 失败
    const K = fromDense(Float64Array.from([3, -2, 0, 2, -2, 3, -2, 0, 0, -2, 3, -2, 2, 0, -2, 3]), 4, 4);
    expect(isSymmetric(K)).toBe(true);
    expect(ic0(K)).toBeNull();
    const b = Float64Array.from([1, 2, 3, 4]);
    const res = solveSPD(K, b, { precond: 'ic0' });
    expect(res.precondKind).toBe('jacobi');
    expect(res.converged).toBe(true);
    expect(relErr(res.x, denseCholSolve(toDense(K), 4, b))).toBeLessThan(1e-12);
    expect(makePreconditioner(K, 'ic0').kind).toBe('jacobi');
    // 非正对角 → Jacobi 也失败 → 无预条件
    const Nd = fromDense(Float64Array.from([1, 0, 0, -1]), 2, 2);
    expect(jacobi(Nd)).toBeNull();
    expect(makePreconditioner(Nd, 'jacobi')).toBe(noPrecond);
    expect(makePreconditioner(Nd).kind).toBe('none');
    expect(solveSPD(poisson2d(6, 5), Float64Array.from({ length: 30 }, (_, i) => i)).precondKind).toBe('ic0');
    // mic0 在正对角矩阵上总能构建（σ 保护）
    expect(mic0(K)).not.toBeNull();
  });

  it('IC(0) 在五点格式上与 DILU（mic0 ω=0）等价（同样的迭代次数）', () => {
    const A = poisson2d(40, 33);
    const b = Float64Array.from({ length: A.nRows }, (_, i) => Math.cos(0.37 * i));
    const a = pcg(A, b, null, { precond: ic0(A)! });
    const d = pcg(A, b, null, { precond: mic0(A, 0)! });
    expect(Math.abs(a.iters - d.iters)).toBeLessThanOrEqual(1);
    expect(relErr(a.x, d.x)).toBeLessThan(1e-9);
  });

  it('140² 五点泊松：各预条件残差达标，与带状 Cholesky 直接解一致', () => {
    const W = 140;
    const A = poisson2d(W, W);
    const r = rng(2024);
    const b = Float64Array.from({ length: A.nRows }, () => r() - 0.5);
    const ref = bandCholeskySolve(A, b, W);
    for (const pk of ['mic0', 'ic0', 'jacobi'] as PrecondKind[]) {
      const res = solveSPD(A, b, { precond: pk });
      expect(res.precondKind).toBe(pk);
      expect(res.converged).toBe(true);
      expect(trueRelres(A, res.x, b)).toBeLessThanOrEqual(1e-12);
      expect(relErr(res.x, ref)).toBeLessThan(1e-9);
    }
  });

  it('140² 真实障碍掩码的仿压力矩阵（钉扎 + Neumann）：残差达标，与直接解一致', () => {
    const c = loadFixtures().edt.find((e) => e.name === 'obstacle140')!;
    const obs = maskFromString(c.mask);
    const { A, pinned } = pressureLike(obs, c.W, c.H);
    expect(isSymmetric(A)).toBe(true);
    const r = rng(5);
    const b = Float64Array.from({ length: A.nRows }, (_, k) => (pinned[k] ? 0 : r() - 0.5));
    const ref = bandCholeskySolve(A, b, c.W);
    for (const pk of ['mic0', 'ic0'] as PrecondKind[]) {
      const res = solveSPD(A, b, { precond: pk });
      expect(res.converged).toBe(true);
      expect(trueRelres(A, res.x, b)).toBeLessThanOrEqual(1e-12);
      expect(relErr(res.x, ref)).toBeLessThan(1e-8);
    }
  });
});

describe('PCG 基准（只打印，不断言耗时）', () => {
  function bench(label: string, A: CSR, b: Float64Array, pk: PrecondKind, reps = 5): void {
    let best = Infinity;
    let iters = 0;
    let relres = 0;
    let tBuild = Infinity;
    for (let k = 0; k < reps; k++) {
      const t0 = performance.now();
      const P = makePreconditioner(A, pk);
      const t1 = performance.now();
      const res = pcg(A, b, null, { tol: 1e-12, precond: P });
      const t2 = performance.now();
      best = Math.min(best, t2 - t1);
      tBuild = Math.min(tBuild, t1 - t0);
      iters = res.iters;
      relres = res.relres;
      expect(res.converged).toBe(true);
    }
    console.log(`[bench] ${label} ${pk.padEnd(6)} iters=${String(iters).padStart(4)} ` +
      `relres=${relres.toExponential(2)} solve=${best.toFixed(1)} ms (precond build ${tBuild.toFixed(1)} ms)`);
  }

  it('140² 泊松与仿压力矩阵，tol = 1e−12', () => {
    const W = 140;
    const A = poisson2d(W, W);
    const r = rng(1);
    const b = Float64Array.from({ length: A.nRows }, () => r() - 0.5);
    for (const pk of ['mic0', 'ic0', 'jacobi'] as PrecondKind[]) bench('poisson140 random-b', A, b, pk);
    const c = loadFixtures().edt.find((e) => e.name === 'obstacle140')!;
    const { A: P, pinned } = pressureLike(maskFromString(c.mask), c.W, c.H);
    const bp = Float64Array.from({ length: P.nRows }, (_, k) => (pinned[k] ? 0 : r() - 0.5));
    for (const pk of ['mic0', 'ic0', 'jacobi'] as PrecondKind[]) bench('pressure140 random-b', P, bp, pk);
    // 默认 solveSPD 的端到端耗时（含预条件构建）
    const t0 = performance.now();
    const res = solveSPD(A, b);
    console.log(`[bench] solveSPD(poisson140) default precond=${res.precondKind} iters=${res.iters} ` +
      `total=${(performance.now() - t0).toFixed(1)} ms`);
  });
});
