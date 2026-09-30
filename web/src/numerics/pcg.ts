/**
 * 对称正定系统的预条件共轭梯度（PCG）与预条件器（IC(0)、修正 IC(0)、Jacobi）。
 *
 * - 收敛判据：真残差 ‖b − A·x‖₂ ≤ tol·‖b‖₂。迭代中用递推残差判断，递推残差达标后再算一次真残差确认；
 *   真残差未达标则以真残差重启（至多 maxRestarts 次，且真残差不再明显下降时判为停滞）。
 * - b = 0 时直接返回零向量（iters = 0、relres = 0、converged = true）。
 * - 全部运算次序固定（顺序求和、无并行），同一输入逐位可复现。
 * - 矩阵只读 CSR 的全部项（上下三角都要存）；IC(0)/MIC(0) 只用下三角（含对角），要求 A 对称。
 *
 * 用法：
 *   solveSPD(A, b)                          一次性求解（默认 tol 1e−12、ic0 预条件、失败逐级退回）；
 *   const S = new SPDSolver(A); S.solve(b, x0)   冻结矩阵反复求解（预条件器与工作区只建一次，x0 可传上一步解热启动）；
 *   pcg(A, b, x0, { tol, maxIter, precond })     底层接口，precond 可为 'mic0' | 'ic0' | 'jacobi' | 'none' 或预条件器对象。
 * 140² 五点泊松、随机右端、tol 1e−12（本机 Node 22）：mic0 85 次约 50 ms，ic0 179 次约 110 ms，jacobi 542 次约 180 ms。
 */
import { type CSR, diag as csrDiag, matvec } from './sparse';

export type PrecondKind = 'mic0' | 'ic0' | 'jacobi' | 'none';

/**
 * 默认预条件：ic0（IC(0) 出现非正主元时退回 jacobi，再失败退回 none，见 makePreconditioner）。
 * 隐式扩散矩阵（强对角占优）上 IC(0) 约 3 次迭代即达 1e−12，mic0 并不更快；
 * 对泊松类矩阵可显式传 precond: 'mic0'（140² 五点泊松迭代次数约为 IC(0) 的一半：85 vs 179）。
 */
export const DEFAULT_PRECOND: PrecondKind = 'ic0';

export interface Preconditioner {
  readonly kind: PrecondKind;
  /** z = M⁻¹·r（z 与 r 可以是不同数组；不修改 r） */
  apply(r: Float64Array, z: Float64Array): void;
}

/**
 * 三角因子预条件 M = L·Lᵀ（L 以严格下三角 CSR + 对角给出）。ic0 与 mic0 共用（同一个类，JIT 单态）。
 * apply：前代 L·y = r，回代 Lᵀ·z = y；Lᵀ 预先转成按行存储，两遍都是按行的连续访问。
 */
class CholFactorPrecond implements Preconditioner {
  private readonly invD: Float64Array;
  private readonly uPtr: Int32Array;
  private readonly uCol: Int32Array;
  private readonly uVal: Float64Array;
  constructor(
    readonly kind: PrecondKind,
    private readonly n: number,
    private readonly lPtr: Int32Array,
    private readonly lCol: Int32Array,
    private readonly lVal: Float64Array,
    dL: Float64Array,
  ) {
    const nl = lPtr[n];
    this.invD = new Float64Array(n);
    for (let i = 0; i < n; i++) this.invD[i] = 1 / dL[i];
    const uPtr = new Int32Array(n + 1);
    for (let p = 0; p < nl; p++) uPtr[lCol[p] + 1]++;
    for (let i = 0; i < n; i++) uPtr[i + 1] += uPtr[i];
    const uCol = new Int32Array(nl);
    const uVal = new Float64Array(nl);
    const next = uPtr.slice(0, n);
    for (let i = 0; i < n; i++) {
      for (let p = lPtr[i]; p < lPtr[i + 1]; p++) {
        const q = next[lCol[p]]++;
        uCol[q] = i;
        uVal[q] = lVal[p];
      }
    }
    this.uPtr = uPtr;
    this.uCol = uCol;
    this.uVal = uVal;
  }

  apply(r: Float64Array, z: Float64Array): void {
    const n = this.n;
    const lPtr = this.lPtr;
    const lCol = this.lCol;
    const lVal = this.lVal;
    const invD = this.invD;
    let start = lPtr[0];
    for (let i = 0; i < n; i++) {
      let s = r[i];
      const e = lPtr[i + 1];
      for (let p = start; p < e; p++) s -= lVal[p] * z[lCol[p]];
      z[i] = s * invD[i];
      start = e;
    }
    const uPtr = this.uPtr;
    const uCol = this.uCol;
    const uVal = this.uVal;
    let end = uPtr[n];
    for (let i = n - 1; i >= 0; i--) {
      let s = z[i];
      const b = uPtr[i];
      for (let p = b; p < end; p++) s -= uVal[p] * z[uCol[p]];
      z[i] = s * invD[i];
      end = b;
    }
  }
}

/** 拆出严格下三角（按行、列递增）与对角；缺对角元时返回 null。 */
function splitLower(A: CSR): { lPtr: Int32Array; lCol: Int32Array; lVal: Float64Array; aDiag: Float64Array } | null {
  const n = A.nRows;
  if (A.nCols !== n) throw new Error('需要方阵');
  const rp = A.rowPtr;
  const ci = A.colIdx;
  const va = A.values;
  const lPtr = new Int32Array(n + 1);
  for (let i = 0; i < n; i++) {
    let c = 0;
    for (let p = rp[i]; p < rp[i + 1]; p++) if (ci[p] < i) c++;
    lPtr[i + 1] = lPtr[i] + c;
  }
  const nl = lPtr[n];
  const lCol = new Int32Array(nl);
  const lVal = new Float64Array(nl);
  const aDiag = new Float64Array(n);
  let w = 0;
  for (let i = 0; i < n; i++) {
    let hasDiag = false;
    for (let p = rp[i]; p < rp[i + 1]; p++) {
      const j = ci[p];
      if (j < i) { lCol[w] = j; lVal[w] = va[p]; w++; }
      else if (j === i) { aDiag[i] = va[p]; hasDiag = true; }
    }
    if (!hasDiag) return null;
  }
  return { lPtr, lCol, lVal, aDiag };
}

/**
 * 不完全 Cholesky IC(0)：A ≈ L·Lᵀ，L 的稀疏结构 = A 的下三角结构（零填充）。
 * 出现非正（或 NaN）主元、或缺对角元时返回 null。
 */
export function ic0(A: CSR): Preconditioner | null {
  const sp = splitLower(A);
  if (!sp) return null;
  const { lPtr, lCol, lVal, aDiag } = sp;
  const n = A.nRows;
  const dL = new Float64Array(n); // L 的对角元
  for (let i = 0; i < n; i++) {
    const si = lPtr[i];
    const ei = lPtr[i + 1];
    for (let p = si; p < ei; p++) {
      const k = lCol[p];
      let s = lVal[p];
      // s −= Σ_{j<k} l_ij·l_kj（两行有序归并）
      let pa = si;
      let pb = lPtr[k];
      const eb = lPtr[k + 1];
      while (pa < p && pb < eb) {
        const ca = lCol[pa];
        const cb = lCol[pb];
        if (ca === cb) { s -= lVal[pa] * lVal[pb]; pa++; pb++; }
        else if (ca < cb) pa++;
        else pb++;
      }
      lVal[p] = s / dL[k];
    }
    let s = aDiag[i];
    for (let p = si; p < ei; p++) s -= lVal[p] * lVal[p];
    if (!(s > 0)) return null;
    dL[i] = Math.sqrt(s);
  }
  return new CholFactorPrecond('ic0', n, lPtr, lCol, lVal, dL);
}

/**
 * 修正不完全 Cholesky（DILU 形式）：M = (D + L_A)·D⁻¹·(D + L_Aᵀ)，L_A 为 A 的严格下三角（直接用 A 的项），
 *   d_i = a_ii − Σ_{j<i, a_ij≠0} (a_ij/d_j)·(a_ji + ω·Σ_{k>j, k≠i} a_jk)。
 * ω = 0 为 DILU（五点格式上与 IC(0) 数学上相同），ω = 1 为 MIC(0)（保持行和，M·1 = A·1）。
 * 默认 ω = 0.97；若 d_i < σ·a_ii（σ = 0.25）则取 d_i = a_ii（常用保护，避免近奇异主元），
 * 因此 a_ii > 0 时总能构建成功。对 Stieltjes 矩阵（对称、正对角、非正非对角：压力泊松、隐式扩散）
 * 迭代次数通常约为 IC(0) 的一半。只要求 A 对称（用 a_ij 代 a_ji）。
 * 以 L = (D + L_A)·D^{−1/2} 存成 L·Lᵀ 形式。出现非正对角元时返回 null。
 */
export function mic0(A: CSR, omega = 0.97, sigma = 0.25): Preconditioner | null {
  const sp = splitLower(A);
  if (!sp) return null;
  const { lPtr, lCol, lVal, aDiag } = sp;
  const n = A.nRows;
  const rp = A.rowPtr;
  const ci = A.colIdx;
  const va = A.values;
  const upSum = new Float64Array(n); // Σ_{k>i} a_ik
  for (let i = 0; i < n; i++) {
    let s = 0;
    for (let p = rp[i]; p < rp[i + 1]; p++) if (ci[p] > i) s += va[p];
    upSum[i] = s;
  }
  const d = new Float64Array(n);
  const invD = new Float64Array(n);
  for (let i = 0; i < n; i++) {
    const aii = aDiag[i];
    if (!(aii > 0)) return null;
    let s = aii;
    for (let p = lPtr[i]; p < lPtr[i + 1]; p++) {
      const j = lCol[p];
      const aij = lVal[p];
      s -= (aij * invD[j]) * (aij + omega * (upSum[j] - aij));
    }
    if (!(s >= sigma * aii)) s = aii;
    d[i] = s;
    invD[i] = 1 / s;
  }
  const sq = new Float64Array(n);
  for (let i = 0; i < n; i++) sq[i] = Math.sqrt(d[i]);
  for (let i = 0; i < n; i++) {
    for (let p = lPtr[i]; p < lPtr[i + 1]; p++) lVal[p] = lVal[p] / sq[lCol[p]];
  }
  return new CholFactorPrecond('mic0', n, lPtr, lCol, lVal, sq);
}

/** Jacobi（对角）预条件；有非正或 NaN 对角元时返回 null。 */
export function jacobi(A: CSR): Preconditioner | null {
  const d = csrDiag(A);
  const n = d.length;
  const inv = new Float64Array(n);
  for (let i = 0; i < n; i++) {
    if (!(d[i] > 0)) return null;
    inv[i] = 1 / d[i];
  }
  return {
    kind: 'jacobi',
    apply(r: Float64Array, z: Float64Array): void {
      for (let i = 0; i < n; i++) z[i] = r[i] * inv[i];
    },
  };
}

/** 无预条件（z = r）。 */
export const noPrecond: Preconditioner = {
  kind: 'none',
  apply(r: Float64Array, z: Float64Array): void {
    z.set(r);
  },
};

/** 按种类构建预条件器，失败时依次退回：mic0 → ic0 → jacobi → none。 */
export function makePreconditioner(A: CSR, kind: PrecondKind = DEFAULT_PRECOND): Preconditioner {
  if (kind === 'mic0') {
    const P = mic0(A);
    if (P) return P;
    kind = 'ic0';
  }
  if (kind === 'ic0') {
    const P = ic0(A);
    if (P) return P;
    kind = 'jacobi';
  }
  if (kind === 'jacobi') {
    const P = jacobi(A);
    if (P) return P;
  }
  return noPrecond;
}

export interface PcgOptions {
  /** 相对残差容限，默认 1e−12 */
  tol?: number;
  /** 最大迭代次数，默认 max(200, min(n, 10000)) */
  maxIter?: number;
  /** 预条件器（对象或种类名，种类名按 makePreconditioner 构建并自动退回），默认 DEFAULT_PRECOND = 'ic0' */
  precond?: Preconditioner | PrecondKind;
  /** 递推残差达标而真残差未达标时的最大重启次数，默认 10 */
  maxRestarts?: number;
}

export interface PcgResult {
  x: Float64Array;
  /** 迭代次数（A·p 乘法次数，不计初始/确认残差） */
  iters: number;
  /** 最终真残差 ‖b − A·x‖₂ / ‖b‖₂ */
  relres: number;
  converged: boolean;
  /** 实际使用的预条件器种类 */
  precondKind: PrecondKind;
}

function dot(a: Float64Array, b: Float64Array, n: number): number {
  let s = 0;
  for (let i = 0; i < n; i++) s += a[i] * b[i];
  return s;
}

/** q = A·p，同时返回 pᵀq（融合一遍，顺序累加）。 */
function matvecDot(A: CSR, p: Float64Array, q: Float64Array): number {
  const n = A.nRows;
  const rp = A.rowPtr;
  const ci = A.colIdx;
  const va = A.values;
  let pq = 0;
  let start = rp[0];
  for (let i = 0; i < n; i++) {
    const end = rp[i + 1];
    let s = 0;
    for (let k = start; k < end; k++) s += va[k] * p[ci[k]];
    q[i] = s;
    pq += p[i] * s;
    start = end;
  }
  return pq;
}

/** 可复用工作区（避免反复分配）。 */
export class PcgWorkspace {
  readonly r: Float64Array;
  readonly z: Float64Array;
  readonly p: Float64Array;
  readonly q: Float64Array;
  constructor(readonly n: number) {
    this.r = new Float64Array(n);
    this.z = new Float64Array(n);
    this.p = new Float64Array(n);
    this.q = new Float64Array(n);
  }
}

/**
 * PCG 求解 A·x = b（A 对称正定）。
 * @param x0 初值（不修改；缺省为 0）
 */
export function pcg(
  A: CSR,
  b: ArrayLike<number>,
  x0?: ArrayLike<number> | null,
  opts: PcgOptions = {},
  ws?: PcgWorkspace,
): PcgResult {
  const n = A.nRows;
  if (A.nCols !== n || b.length !== n) throw new Error('pcg: 维数不符');
  const tol = opts.tol ?? 1e-12;
  const maxIter = opts.maxIter ?? Math.max(200, Math.min(n, 10000));
  const maxRestarts = opts.maxRestarts ?? 10;
  const given = typeof opts.precond === 'object' && opts.precond !== null ? opts.precond : null;
  const x = new Float64Array(n);
  const bb = b instanceof Float64Array ? b : Float64Array.from(b);
  const normb = Math.sqrt(dot(bb, bb, n));
  if (normb === 0) {
    const kind = given ? given.kind : ((opts.precond as PrecondKind | undefined) ?? DEFAULT_PRECOND);
    return { x, iters: 0, relres: 0, converged: true, precondKind: kind };
  }
  const M: Preconditioner = given
    ?? makePreconditioner(A, (opts.precond as PrecondKind | undefined) ?? DEFAULT_PRECOND);
  const w = ws && ws.n === n ? ws : new PcgWorkspace(n);
  const { r, z, p, q } = w;
  const thresh = tol * normb;

  if (x0) {
    if (x0.length !== n) throw new Error('pcg: x0 维数不符');
    for (let i = 0; i < n; i++) x[i] = x0[i];
    matvec(A, x, q);
    for (let i = 0; i < n; i++) r[i] = bb[i] - q[i];
  } else {
    r.set(bb);
  }
  let trueNorm = Math.sqrt(dot(r, r, n));
  if (trueNorm <= thresh) {
    return { x, iters: 0, relres: trueNorm / normb, converged: true, precondKind: M.kind };
  }

  let iters = 0;
  let restarts = 0;
  let converged = false;
  let lastTrue = trueNorm;
  outer: while (true) {
    // （重新）开始：p = z = M⁻¹r
    M.apply(r, z);
    let rz = dot(r, z, n);
    if (!(rz > 0)) break;
    p.set(z);
    while (iters < maxIter) {
      const pq = matvecDot(A, p, q);
      iters++;
      if (!(pq > 0)) break outer; // 非正定或已停滞
      const alpha = rz / pq;
      let rr = 0;
      for (let i = 0; i < n; i++) {
        x[i] += alpha * p[i];
        const ri = r[i] - alpha * q[i];
        r[i] = ri;
        rr += ri * ri;
      }
      const rn = Math.sqrt(rr);
      if (!(rn === rn)) break outer; // NaN
      if (rn <= thresh) {
        // 确认真残差
        matvec(A, x, q);
        for (let i = 0; i < n; i++) r[i] = bb[i] - q[i];
        trueNorm = Math.sqrt(dot(r, r, n));
        if (trueNorm <= thresh) { converged = true; break outer; }
        restarts++;
        if (restarts > maxRestarts || trueNorm > 0.5 * lastTrue) break outer;
        lastTrue = trueNorm;
        continue outer;
      }
      M.apply(r, z);
      const rzNew = dot(r, z, n);
      const beta = rzNew / rz;
      rz = rzNew;
      if (!(rz > 0)) break outer;
      for (let i = 0; i < n; i++) p[i] = z[i] + beta * p[i];
    }
    break;
  }
  if (!converged) {
    matvec(A, x, q);
    let s = 0;
    for (let i = 0; i < n; i++) { const d = bb[i] - q[i]; s += d * d; }
    trueNorm = Math.sqrt(s);
    converged = trueNorm <= thresh;
  }
  return { x, iters, relres: trueNorm / normb, converged, precondKind: M.kind };
}

export interface SolveSPDOptions extends PcgOptions {
  x0?: ArrayLike<number> | null;
}

/**
 * 便捷函数：默认 tol = 1e−12、预条件 DEFAULT_PRECOND（ic0）；IC(0) 出现非正主元时退回 Jacobi（再失败则无预条件）。
 * 结果的 precondKind 为实际使用的种类。
 * 同一矩阵反复求解时用 SPDSolver（预条件器只构建一次）。
 */
export function solveSPD(A: CSR, b: ArrayLike<number>, opts: SolveSPDOptions = {}): PcgResult {
  return pcg(A, b, opts.x0 ?? null, { ...opts, tol: opts.tol ?? 1e-12, precond: opts.precond ?? DEFAULT_PRECOND });
}

/** 冻结矩阵的反复求解器：预条件器与工作区只建一次。 */
export class SPDSolver {
  readonly precond: Preconditioner;
  private readonly ws: PcgWorkspace;
  constructor(readonly A: CSR, private readonly opts: PcgOptions = {}) {
    this.precond = typeof opts.precond === 'object' && opts.precond !== null
      ? opts.precond
      : makePreconditioner(A, (opts.precond as PrecondKind | undefined) ?? DEFAULT_PRECOND);
    this.ws = new PcgWorkspace(A.nRows);
  }

  solve(b: ArrayLike<number>, x0?: ArrayLike<number> | null, override: PcgOptions = {}): PcgResult {
    return pcg(this.A, b, x0 ?? null, {
      tol: override.tol ?? this.opts.tol ?? 1e-12,
      maxIter: override.maxIter ?? this.opts.maxIter,
      maxRestarts: override.maxRestarts ?? this.opts.maxRestarts,
      precond: this.precond,
    }, this.ws);
  }
}
