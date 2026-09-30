/**
 * 稀疏 Cholesky 直接分解 A = P'·L·Lᵀ·P（A 对称正定），用于压力泊松这类 PCG 迭代次数多的冻结矩阵。
 *
 * - 排序：规则网格的几何嵌套剖分（格 i = x·W + y，5 点模板）：沿长边取一条格线作分隔，
 *   先排两半（递归），分隔线排最后；小块按自然次序。对 5 点模板，一格宽的分隔线即可把两半隔开。
 * - 分解：上视（up-looking）列存储算法（与 CSparse 的 cs_chol 相同）：逐行用消去树求 L 的行模式，
 *   稀疏三角求解得到该行。符号分析（排序、消去树、列计数）只依赖稀疏结构，可在结构相同的矩阵间复用。
 * - 求解：前代 L·y = P·b，回代 Lᵀ·z = y，x = Pᵀ·z。运算次序固定，同一输入逐位可复现。
 */
import type { CSR } from './sparse';

/** 规则网格（W 行 × H 列，列优先）的嵌套剖分排序：返回 perm（新序 → 旧索引） */
export function nestedDissectionGrid(W: number, H: number, leaf = 32): Int32Array {
  const perm = new Int32Array(W * H);
  let n = 0;
  const emit = (y0: number, y1: number, x0: number, x1: number) => {
    for (let x = x0; x < x1; x++) for (let y = y0; y < y1; y++) perm[n++] = x * W + y;
  };
  const rec = (y0: number, y1: number, x0: number, x1: number) => {
    const h = y1 - y0;
    const w = x1 - x0;
    if (h <= 0 || w <= 0) return;
    if (h * w <= leaf || (h <= 2 && w <= 2)) {
      emit(y0, y1, x0, x1);
      return;
    }
    if (w >= h) {
      const xm = (x0 + x1) >> 1;
      rec(y0, y1, x0, xm);
      rec(y0, y1, xm + 1, x1);
      emit(y0, y1, xm, xm + 1);
    } else {
      const ym = (y0 + y1) >> 1;
      rec(y0, ym, x0, x1);
      rec(ym + 1, y1, x0, x1);
      emit(ym, ym + 1, x0, x1);
    }
  };
  rec(0, W, 0, H);
  if (n !== W * H) throw new Error('nestedDissectionGrid: 排序不完整');
  return perm;
}

/** 置换后矩阵 C = P·A·Pᵀ 的下三角（含对角），按行存储、行内列号递增 */
interface LowerCSR {
  ptr: Int32Array;
  col: Int32Array;
  val: Float64Array;
}

function permutedLower(A: CSR, perm: Int32Array, pinv: Int32Array): LowerCSR {
  const n = A.nRows;
  const rp = A.rowPtr;
  const ci = A.colIdx;
  const va = A.values;
  const ptr = new Int32Array(n + 1);
  for (let k = 0; k < n; k++) {
    const i = perm[k];
    let c = 0;
    for (let p = rp[i]; p < rp[i + 1]; p++) if (pinv[ci[p]] <= k) c++;
    ptr[k + 1] = ptr[k] + c;
  }
  const col = new Int32Array(ptr[n]);
  const val = new Float64Array(ptr[n]);
  for (let k = 0; k < n; k++) {
    const i = perm[k];
    let w = ptr[k];
    const s = w;
    for (let p = rp[i]; p < rp[i + 1]; p++) {
      const j = pinv[ci[p]];
      if (j > k) continue;
      // 插入排序（每行至多几项）
      let q = w++;
      while (q > s && col[q - 1] > j) {
        col[q] = col[q - 1];
        val[q] = val[q - 1];
        q--;
      }
      col[q] = j;
      val[q] = va[p];
    }
  }
  return { ptr, col, val };
}

/** 符号分析结果（只依赖稀疏结构） */
export interface CholSymbolic {
  n: number;
  perm: Int32Array;
  pinv: Int32Array;
  parent: Int32Array;
  Lp: Int32Array; // 列指针（每列第一项为对角元）
  nnzA: number;
  /** 分析时 A 的稀疏结构（复用前逐项核对） */
  rowPtr: Int32Array;
  colIdx: Int32Array;
}

/** 消去树（下三角按行：行 k 的非对角项 i < k） */
function etree(C: LowerCSR, n: number): Int32Array {
  const parent = new Int32Array(n).fill(-1);
  const ancestor = new Int32Array(n).fill(-1);
  for (let k = 0; k < n; k++) {
    for (let p = C.ptr[k]; p < C.ptr[k + 1]; p++) {
      let i = C.col[p];
      while (i !== -1 && i < k) {
        const inext = ancestor[i];
        ancestor[i] = k;
        if (inext === -1) parent[i] = k;
        i = inext;
      }
    }
  }
  return parent;
}

/** L 第 k 行的非零模式（不含对角），按拓扑序放在 s[top..n−1]，返回 top。w 为时间戳标记。 */
function ereach(C: LowerCSR, k: number, parent: Int32Array, s: Int32Array, w: Int32Array): number {
  const n = parent.length;
  let top = n;
  w[k] = k;
  for (let p = C.ptr[k]; p < C.ptr[k + 1]; p++) {
    let i = C.col[p];
    if (i >= k) continue;
    let len = 0;
    while (w[i] !== k) {
      s[len++] = i;
      w[i] = k;
      i = parent[i];
    }
    while (len > 0) s[--top] = s[--len];
  }
  return top;
}

/** 符号分析：排序、消去树、列计数 */
export function cholAnalyze(A: CSR, perm: Int32Array): CholSymbolic {
  const n = A.nRows;
  if (A.nCols !== n || perm.length !== n) throw new Error('cholAnalyze: 维数不符');
  const pinv = new Int32Array(n);
  for (let k = 0; k < n; k++) pinv[perm[k]] = k;
  const C = permutedLower(A, perm, pinv);
  const parent = etree(C, n);
  const cnt = new Int32Array(n);
  const s = new Int32Array(n);
  const w = new Int32Array(n).fill(-1);
  for (let k = 0; k < n; k++) {
    const top = ereach(C, k, parent, s, w);
    for (let t = top; t < n; t++) cnt[s[t]]++;
    cnt[k]++;
  }
  const Lp = new Int32Array(n + 1);
  for (let j = 0; j < n; j++) Lp[j + 1] = Lp[j] + cnt[j];
  return { n, perm, pinv, parent, Lp, nnzA: A.rowPtr[n], rowPtr: A.rowPtr.slice(), colIdx: A.colIdx.slice(0, A.rowPtr[n]) };
}

export class SparseCholesky {
  readonly Li: Int32Array;
  readonly Lx: Float64Array;
  private readonly y: Float64Array;

  /** 数值分解；A 的稀疏结构须与 sym 分析时相同。非正主元时抛错。 */
  constructor(
    A: CSR,
    readonly sym: CholSymbolic,
  ) {
    const { n, perm, pinv, parent, Lp } = sym;
    if (A.nRows !== n || A.rowPtr[n] !== sym.nnzA || !samePattern(A, sym)) throw new Error('SparseCholesky: 稀疏结构与符号分析不符');
    const C = permutedLower(A, perm, pinv);
    const nnz = Lp[n];
    const Li = new Int32Array(nnz);
    const Lx = new Float64Array(nnz);
    const c = Lp.slice(0, n); // 各列下一个空位
    const x = new Float64Array(n);
    const s = new Int32Array(n);
    const w = new Int32Array(n).fill(-1);
    for (let k = 0; k < n; k++) {
      const top = ereach(C, k, parent, s, w);
      x[k] = 0;
      for (let p = C.ptr[k]; p < C.ptr[k + 1]; p++) x[C.col[p]] = C.val[p];
      let d = x[k];
      x[k] = 0;
      for (let t = top; t < n; t++) {
        const i = s[t];
        const lki = x[i] / Lx[Lp[i]];
        x[i] = 0;
        const e = c[i];
        for (let p = Lp[i] + 1; p < e; p++) x[Li[p]] -= Lx[p] * lki;
        d -= lki * lki;
        const q = c[i]++;
        Li[q] = k;
        Lx[q] = lki;
      }
      if (!(d > 0)) throw new Error(`SparseCholesky: 第 ${k} 个主元非正（${d}）`);
      const q = c[k]++;
      Li[q] = k;
      Lx[q] = Math.sqrt(d);
    }
    this.Li = Li;
    this.Lx = Lx;
    this.y = new Float64Array(n);
  }

  get nnzL(): number {
    return this.sym.Lp[this.sym.n];
  }

  /** 解 A·x = b（x 可省略，返回新数组） */
  solve(b: ArrayLike<number>, out?: Float64Array): Float64Array {
    const { n, perm, Lp } = this.sym;
    const Li = this.Li;
    const Lx = this.Lx;
    const y = this.y;
    for (let k = 0; k < n; k++) y[k] = b[perm[k]];
    // 前代 L·y = b'（按列）
    for (let j = 0; j < n; j++) {
      const p0 = Lp[j];
      const yj = y[j] / Lx[p0];
      y[j] = yj;
      const e = Lp[j + 1];
      for (let p = p0 + 1; p < e; p++) y[Li[p]] -= Lx[p] * yj;
    }
    // 回代 Lᵀ·z = y（按列即 Lᵀ 按行）
    for (let j = n - 1; j >= 0; j--) {
      const p0 = Lp[j];
      let sj = y[j];
      const e = Lp[j + 1];
      for (let p = p0 + 1; p < e; p++) sj -= Lx[p] * y[Li[p]];
      y[j] = sj / Lx[p0];
    }
    const x = out ?? new Float64Array(n);
    for (let k = 0; k < n; k++) x[perm[k]] = y[k];
    return x;
  }
}

function samePattern(A: CSR, sym: CholSymbolic): boolean {
  const n = sym.n;
  for (let i = 0; i <= n; i++) if (A.rowPtr[i] !== sym.rowPtr[i]) return false;
  const nnz = sym.nnzA;
  for (let p = 0; p < nnz; p++) if (A.colIdx[p] !== sym.colIdx[p]) return false;
  return true;
}
