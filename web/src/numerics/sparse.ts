/**
 * CSR 稀疏矩阵与装配用的基本操作（纯 TypeScript，Float64Array/Int32Array）。
 *
 * 约定：
 *   - 行列索引一律 **0 基**；每行内列号严格递增（无重复）。
 *   - fromTriplets 复刻 MATLAB/Octave `sparse(I, J, V, m, n)`：重复 (i, j) 按**输入顺序**依次相加
 *     （已在 Octave 8.4 上验证：稳定排序后顺序累加），求和结果为 0 的项默认删除（MATLAB 不存 0）。
 *   - matvec 每行从 0 起按列号递增累加 a_ij·x_j，与 Octave 稀疏×稠密（CSC 按列累加）的逐行次序相同。
 *   - 所有操作返回新矩阵，不修改输入（名字带 InPlace 的除外）。
 */
export interface CSR {
  readonly nRows: number;
  readonly nCols: number;
  /** 长度 nRows+1；第 i 行的项位于 [rowPtr[i], rowPtr[i+1]) */
  readonly rowPtr: Int32Array;
  readonly colIdx: Int32Array;
  readonly values: Float64Array;
}

export interface FromTripletsOptions {
  /** 删除求和后为 0 的项（MATLAB 行为），默认 true */
  dropZeros?: boolean;
}

/** 非零项个数。 */
export function nnz(A: CSR): number {
  return A.rowPtr[A.nRows];
}

/**
 * 由三元组构建（MATLAB `sparse(I+1, J+1, V, nRows, nCols)`）。
 * V 可为标量（所有项同值）。重复项按输入顺序相加。
 */
export function fromTriplets(
  nRows: number,
  nCols: number,
  I: ArrayLike<number>,
  J: ArrayLike<number>,
  V: ArrayLike<number> | number,
  opts: FromTripletsOptions = {},
): CSR {
  const dropZeros = opts.dropZeros ?? true;
  const nz = I.length;
  if (J.length !== nz) throw new Error('fromTriplets: I 与 J 长度不同');
  const scalarV = typeof V === 'number';
  if (!scalarV && (V as ArrayLike<number>).length !== nz) {
    throw new Error('fromTriplets: V 长度与 I 不同');
  }
  for (let k = 0; k < nz; k++) {
    const i = I[k];
    const j = J[k];
    if (!(i >= 0 && i < nRows && j >= 0 && j < nCols) || i !== Math.floor(i) || j !== Math.floor(j)) {
      throw new Error(`fromTriplets: 索引越界或非整数 (${i}, ${j})`);
    }
  }
  // 两遍稳定计数排序：先按列、再按行 → 按 (行, 列) 有序且同 (行, 列) 保持输入顺序
  const colCount = new Int32Array(nCols + 1);
  for (let k = 0; k < nz; k++) colCount[J[k] + 1]++;
  for (let j = 0; j < nCols; j++) colCount[j + 1] += colCount[j];
  const byCol = new Int32Array(nz);
  for (let k = 0; k < nz; k++) byCol[colCount[J[k]]++] = k;
  const rowStart = new Int32Array(nRows + 1);
  for (let k = 0; k < nz; k++) rowStart[I[k] + 1]++;
  for (let i = 0; i < nRows; i++) rowStart[i + 1] += rowStart[i];
  const fill = rowStart.slice(0, nRows);
  const order = new Int32Array(nz);
  for (let p = 0; p < nz; p++) {
    const k = byCol[p];
    order[fill[I[k]]++] = k;
  }
  // 合并重复并（可选）删除 0
  const rowPtr = new Int32Array(nRows + 1);
  const colTmp = new Int32Array(nz);
  const valTmp = new Float64Array(nz);
  let w = 0;
  for (let i = 0; i < nRows; i++) {
    let p = rowStart[i];
    const end = rowStart[i + 1];
    while (p < end) {
      const k0 = order[p];
      const j = J[k0];
      let acc = scalarV ? (V as number) : (V as ArrayLike<number>)[k0];
      p++;
      while (p < end && J[order[p]] === j) {
        acc += scalarV ? (V as number) : (V as ArrayLike<number>)[order[p]];
        p++;
      }
      if (!(dropZeros && acc === 0)) {
        colTmp[w] = j;
        valTmp[w] = acc;
        w++;
      }
    }
    rowPtr[i + 1] = w;
  }
  return { nRows, nCols, rowPtr, colIdx: colTmp.slice(0, w), values: valTmp.slice(0, w) };
}

/** 由稠密矩阵（列优先 nRows×nCols）构建，跳过 0。 */
export function fromDense(D: ArrayLike<number>, nRows: number, nCols: number): CSR {
  const I: number[] = [];
  const J: number[] = [];
  const V: number[] = [];
  for (let i = 0; i < nRows; i++) {
    for (let j = 0; j < nCols; j++) {
      const v = D[i + j * nRows];
      if (v !== 0) { I.push(i); J.push(j); V.push(v); }
    }
  }
  return fromTriplets(nRows, nCols, I, J, V);
}

/** 稠密（列优先 nRows×nCols），测试用。 */
export function toDense(A: CSR): Float64Array {
  const D = new Float64Array(A.nRows * A.nCols);
  for (let i = 0; i < A.nRows; i++) {
    for (let p = A.rowPtr[i]; p < A.rowPtr[i + 1]; p++) D[i + A.colIdx[p] * A.nRows] = A.values[p];
  }
  return D;
}

/** 单位阵乘标量：s·I（n×n）。 */
export function identity(n: number, s = 1): CSR {
  return diagMatrix(new Float64Array(n).fill(s));
}

/** 对角阵 diag(d)（MATLAB spdiags(d, 0, n, n)；d 中的 0 不存）。 */
export function diagMatrix(d: ArrayLike<number>): CSR {
  const n = d.length;
  const rowPtr = new Int32Array(n + 1);
  const col: number[] = [];
  const val: number[] = [];
  for (let i = 0; i < n; i++) {
    if (d[i] !== 0) { col.push(i); val.push(d[i]); }
    rowPtr[i + 1] = col.length;
  }
  return { nRows: n, nCols: n, rowPtr, colIdx: Int32Array.from(col), values: Float64Array.from(val) };
}

/** y = A·x（每行从 0 起按列号递增累加）。 */
export function matvec(A: CSR, x: ArrayLike<number>, y?: Float64Array): Float64Array {
  if (x.length !== A.nCols) throw new Error('matvec: 维数不符');
  const out = y ?? new Float64Array(A.nRows);
  const rp = A.rowPtr;
  const ci = A.colIdx;
  const va = A.values;
  for (let i = 0; i < A.nRows; i++) {
    let s = 0;
    const end = rp[i + 1];
    for (let p = rp[i]; p < end; p++) s += va[p] * x[ci[p]];
    out[i] = s;
  }
  return out;
}

/** 对角元（长度 min(nRows, nCols)，缺项为 0）。 */
export function diag(A: CSR): Float64Array {
  const n = Math.min(A.nRows, A.nCols);
  const d = new Float64Array(n);
  for (let i = 0; i < n; i++) {
    for (let p = A.rowPtr[i]; p < A.rowPtr[i + 1]; p++) {
      const j = A.colIdx[p];
      if (j === i) { d[i] = A.values[p]; break; }
      if (j > i) break;
    }
  }
  return d;
}

/** 转置（结果每行列号仍递增）。 */
export function transpose(A: CSR): CSR {
  const nz = nnz(A);
  const rowPtr = new Int32Array(A.nCols + 1);
  for (let p = 0; p < nz; p++) rowPtr[A.colIdx[p] + 1]++;
  for (let j = 0; j < A.nCols; j++) rowPtr[j + 1] += rowPtr[j];
  const next = rowPtr.slice(0, A.nCols);
  const colIdx = new Int32Array(nz);
  const values = new Float64Array(nz);
  for (let i = 0; i < A.nRows; i++) {
    for (let p = A.rowPtr[i]; p < A.rowPtr[i + 1]; p++) {
      const q = next[A.colIdx[p]]++;
      colIdx[q] = i;
      values[q] = A.values[p];
    }
  }
  return { nRows: A.nCols, nCols: A.nRows, rowPtr, colIdx, values };
}

/** s·A（MATLAB s*A；s = 0 时得空矩阵）。 */
export function scale(A: CSR, s: number): CSR {
  if (s === 0) return fromTriplets(A.nRows, A.nCols, [], [], []);
  const values = new Float64Array(A.values.length);
  for (let p = 0; p < values.length; p++) values[p] = s * A.values[p];
  return { nRows: A.nRows, nCols: A.nCols, rowPtr: A.rowPtr.slice(), colIdx: A.colIdx.slice(), values };
}

/**
 * C = A + B（MATLAB 稀疏加法：只在一方有项时取该项本身，两方都有时 a + b，结果为 0 的项删除）。
 * 需要 A − s·B 时写 add(A, scale(B, -s))：a + (−s·b) 与 MATLAB 的 a − s·b 逐位相同。
 */
export function add(A: CSR, B: CSR): CSR {
  if (A.nRows !== B.nRows || A.nCols !== B.nCols) throw new Error('add: 维数不符');
  const n = A.nRows;
  const rowPtr = new Int32Array(n + 1);
  const maxNz = nnz(A) + nnz(B);
  const colIdx = new Int32Array(maxNz);
  const values = new Float64Array(maxNz);
  let w = 0;
  for (let i = 0; i < n; i++) {
    let pa = A.rowPtr[i];
    const ea = A.rowPtr[i + 1];
    let pb = B.rowPtr[i];
    const eb = B.rowPtr[i + 1];
    while (pa < ea || pb < eb) {
      const ja = pa < ea ? A.colIdx[pa] : Infinity;
      const jb = pb < eb ? B.colIdx[pb] : Infinity;
      let j: number;
      let v: number;
      if (ja === jb) { j = ja; v = A.values[pa++] + B.values[pb++]; }
      else if (ja < jb) { j = ja; v = A.values[pa++]; }
      else { j = jb; v = B.values[pb++]; }
      if (v !== 0) { colIdx[w] = j; values[w] = v; w++; }
    }
    rowPtr[i + 1] = w;
  }
  return { nRows: n, nCols: A.nCols, rowPtr, colIdx: colIdx.slice(0, w), values: values.slice(0, w) };
}

/** A + diag(d)（MATLAB A + spdiags(d, 0, n, n)）；d 可为标量。 */
export function addDiag(A: CSR, d: ArrayLike<number> | number): CSR {
  const n = Math.min(A.nRows, A.nCols);
  const dv = typeof d === 'number' ? new Float64Array(n).fill(d) : d;
  if (dv.length !== n) throw new Error('addDiag: 长度不符');
  if (A.nRows === A.nCols) return add(A, diagMatrix(dv));
  const I: number[] = [];
  const V: number[] = [];
  for (let i = 0; i < n; i++) if (dv[i] !== 0) { I.push(i); V.push(dv[i]); }
  return add(A, fromTriplets(A.nRows, A.nCols, I, I, V));
}

/** 每行元素和（MATLAB full(sum(A, 2))：每行从 0 起按列号递增累加）。 */
export function rowSums(A: CSR): Float64Array {
  const s = new Float64Array(A.nRows);
  for (let i = 0; i < A.nRows; i++) {
    let acc = 0;
    for (let p = A.rowPtr[i]; p < A.rowPtr[i + 1]; p++) acc += A.values[p];
    s[i] = acc;
  }
  return s;
}

/** 按谓词保留项（内部工具）。 */
export function filterEntries(A: CSR, keep: (i: number, j: number, v: number) => boolean): CSR {
  const rowPtr = new Int32Array(A.nRows + 1);
  const colIdx = new Int32Array(nnz(A));
  const values = new Float64Array(nnz(A));
  let w = 0;
  for (let i = 0; i < A.nRows; i++) {
    for (let p = A.rowPtr[i]; p < A.rowPtr[i + 1]; p++) {
      const j = A.colIdx[p];
      const v = A.values[p];
      if (keep(i, j, v)) { colIdx[w] = j; values[w] = v; w++; }
    }
    rowPtr[i + 1] = w;
  }
  return { nRows: A.nRows, nCols: A.nCols, rowPtr, colIdx: colIdx.slice(0, w), values: values.slice(0, w) };
}

function flagSet(n: number, idx: ArrayLike<number>): Uint8Array {
  const f = new Uint8Array(n);
  for (let k = 0; k < idx.length; k++) f[idx[k]] = 1;
  return f;
}

/** A(idx, :) = 0 且 A(:, idx) = 0（删除这些行列上的项，尺寸不变）。 */
export function zeroRowsCols(A: CSR, idx: ArrayLike<number>): CSR {
  const fr = flagSet(A.nRows, idx);
  const fc = A.nCols === A.nRows ? fr : flagSet(A.nCols, idx);
  return filterEntries(A, (i, j) => fr[i] === 0 && fc[j] === 0);
}

/** A(rows, :) = 0。 */
export function zeroRows(A: CSR, rows: ArrayLike<number>): CSR {
  const fr = flagSet(A.nRows, rows);
  return filterEntries(A, (i) => fr[i] === 0);
}

/** A(:, cols) = 0。 */
export function zeroCols(A: CSR, cols: ArrayLike<number>): CSR {
  const fc = flagSet(A.nCols, cols);
  return filterEntries(A, (_i, j) => fc[j] === 0);
}

/**
 * 把 idx 中各 i 的对角元置为 value（不存在则插入；value = 0 则删除）。
 * 例：压力钉扎 `Lp(pin,:)=0; Lp(:,pin)=0; Lp = Lp − sparse(pin,pin,1)` ≡
 *     `setDiag(zeroRowsCols(Lp, pin), pin, -1)`。
 */
export function setDiag(A: CSR, idx: ArrayLike<number>, value: number): CSR {
  const f = flagSet(Math.min(A.nRows, A.nCols), idx);
  const B = filterEntries(A, (i, j) => !(i === j && f[i] === 1));
  if (value === 0) return B;
  const I: number[] = [];
  for (let i = 0; i < f.length; i++) if (f[i]) I.push(i);
  return add(B, fromTriplets(A.nRows, A.nCols, I, I, value));
}

/**
 * 子矩阵 A(rows, cols)（rows、cols 为 0 基索引列表，结果按给定次序编号；cols 不可重复）。
 * 例：激活面子系统 A(af, af)、耦合块 Lfull(:, oi)（rows 传 null 表示全部行）。
 */
export function subMatrix(A: CSR, rows: ArrayLike<number> | null, cols: ArrayLike<number> | null): CSR {
  const rList = rows ?? Int32Array.from({ length: A.nRows }, (_, i) => i);
  let colMap: Int32Array | null = null;
  let nC = A.nCols;
  if (cols) {
    colMap = new Int32Array(A.nCols).fill(-1);
    for (let k = 0; k < cols.length; k++) {
      if (colMap[cols[k]] !== -1) throw new Error('subMatrix: cols 不可重复');
      colMap[cols[k]] = k;
    }
    nC = cols.length;
  }
  const nR = rList.length;
  const rowPtr = new Int32Array(nR + 1);
  const cOut: number[] = [];
  const vOut: number[] = [];
  const pairs: Array<[number, number]> = [];
  for (let r = 0; r < nR; r++) {
    const i = rList[r];
    pairs.length = 0;
    for (let p = A.rowPtr[i]; p < A.rowPtr[i + 1]; p++) {
      const j = colMap ? colMap[A.colIdx[p]] : A.colIdx[p];
      if (j >= 0) pairs.push([j, A.values[p]]);
    }
    if (colMap) pairs.sort((a, b) => a[0] - b[0]);
    for (const [j, v] of pairs) { cOut.push(j); vOut.push(v); }
    rowPtr[r + 1] = cOut.length;
  }
  return { nRows: nR, nCols: nC, rowPtr, colIdx: Int32Array.from(cOut), values: Float64Array.from(vOut) };
}

/** 下三角部分（含对角；k = −1 时不含对角）。 */
export function lowerTriangle(A: CSR, k = 0): CSR {
  return filterEntries(A, (i, j) => j <= i + k);
}

/** 取 (i, j) 元（不存在为 0）。二分查找。 */
export function getEntry(A: CSR, i: number, j: number): number {
  let lo = A.rowPtr[i];
  let hi = A.rowPtr[i + 1] - 1;
  while (lo <= hi) {
    const mid = (lo + hi) >> 1;
    const c = A.colIdx[mid];
    if (c === j) return A.values[mid];
    if (c < j) lo = mid + 1; else hi = mid - 1;
  }
  return 0;
}

/** 是否对称：|a_ij − a_ji| ≤ tol·max(|a_ij|, |a_ji|)（tol = 0 为逐位对称）。 */
export function isSymmetric(A: CSR, tol = 0): boolean {
  if (A.nRows !== A.nCols) return false;
  for (let i = 0; i < A.nRows; i++) {
    for (let p = A.rowPtr[i]; p < A.rowPtr[i + 1]; p++) {
      const j = A.colIdx[p];
      const a = A.values[p];
      const b = getEntry(A, j, i);
      if (Math.abs(a - b) > tol * Math.max(Math.abs(a), Math.abs(b))) return false;
    }
  }
  return true;
}

/** 三元组（0 基，按行、列有序），调试/导出用。 */
export function toTriplets(A: CSR): { I: Int32Array; J: Int32Array; V: Float64Array } {
  const nz = nnz(A);
  const I = new Int32Array(nz);
  for (let i = 0; i < A.nRows; i++) I.fill(i, A.rowPtr[i], A.rowPtr[i + 1]);
  return { I, J: A.colIdx.slice(), V: A.values.slice() };
}
