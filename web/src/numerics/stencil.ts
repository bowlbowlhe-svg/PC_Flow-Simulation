/**
 * 规则网格 5 点对称正定系统（扩散算子）的模板存储与 PCG 求解（修正 IC(0) 预条件）。
 *
 * 网格 nR 行 × nC 列、列优先（节点 i = c·nR + r），邻点 i−nR（左）、i−1（上）、i+1（下）、i+nR（右）。
 * 矩阵按行存对角 d 与两个下三角系数：west[i] = a(i, i−nR)、south[i] = a(i, i−1)（缺失或不耦合为 0）；
 * 对称性给出上三角：a(i, i+1) = south[i+1]、a(i, i+nR) = west[i+nR]。不参与求解的节点（非激活面）为单位行、右端 0。
 *
 * 与 CSR 版（pcg.ts 的 pcg + mic0）数学上相同、运算次序相同（行内按列号递增累加，零系数项加 0 不改变结果），
 * 因而迭代与结果逐位相同；只是去掉了列号间接寻址，约快一倍。
 */

export class StencilMatrix {
  readonly n: number;
  readonly diag: Float64Array;
  readonly west: Float64Array; // a(i, i − nR)
  readonly south: Float64Array; // a(i, i − 1)
  constructor(
    readonly nR: number,
    readonly nC: number,
  ) {
    this.n = nR * nC;
    this.diag = new Float64Array(this.n);
    this.west = new Float64Array(this.n);
    this.south = new Float64Array(this.n);
  }

  /** q = A·p，并返回 pᵀq（同 pcg.ts 的 matvecDot：行内按列号递增累加） */
  matvecDot(p: Float64Array, q: Float64Array): number {
    const { n, nR, diag, west, south } = this;
    let pq = 0;
    // 首尾各 nR 行有缺失邻点，逐项判断；中间段无分支（零系数项加 0 不改变结果）
    const i0 = Math.min(nR, n);
    const i1 = Math.max(i0, n - nR);
    for (let i = 0; i < i0; i++) pq += p[i] * (q[i] = this.rowEdge(p, i));
    for (let i = i0; i < i1; i++) {
      let s = west[i] * p[i - nR];
      s += south[i] * p[i - 1];
      s += diag[i] * p[i];
      s += south[i + 1] * p[i + 1];
      s += west[i + nR] * p[i + nR];
      q[i] = s;
      pq += p[i] * s;
    }
    for (let i = i1; i < n; i++) pq += p[i] * (q[i] = this.rowEdge(p, i));
    return pq;
  }

  private rowEdge(p: Float64Array, i: number): number {
    const { n, nR, diag, west, south } = this;
    let s = 0;
    if (i >= nR) s += west[i] * p[i - nR];
    if (i >= 1) s += south[i] * p[i - 1];
    s += diag[i] * p[i];
    if (i + 1 < n) s += south[i + 1] * p[i + 1];
    if (i + nR < n) s += west[i + nR] * p[i + nR];
    return s;
  }

  matvec(p: Float64Array, q: Float64Array): void {
    this.matvecDot(p, q);
  }
}

/**
 * 修正 IC(0) 预条件（同 pcg.ts 的 mic0，ω = 0.97、σ = 0.25）：
 *   d_i = a_ii − Σ_{j<i, a_ij≠0} (a_ij/d_j)·(a_ij + ω·(U_j − a_ij))，U_j = Σ_{k>j} a_jk；d_i < σ·a_ii 时取 a_ii。
 * M = L·Lᵀ，L = (D + L_A)·D^{−1/2}。
 */
export class StencilMIC {
  private readonly lw: Float64Array; // L(i, i − nR)
  private readonly ls: Float64Array; // L(i, i − 1)
  private readonly invD: Float64Array;
  constructor(private readonly A: StencilMatrix, omega = 0.97, sigma = 0.25) {
    const { n, nR, diag, west, south } = A;
    const upSum = new Float64Array(n);
    for (let i = 0; i < n; i++) {
      // CSR 行内上三角按列号递增：i+1 再 i+nR
      let s = 0;
      if (i + 1 < n && south[i + 1] !== 0) s += south[i + 1];
      if (i + nR < n && west[i + nR] !== 0) s += west[i + nR];
      upSum[i] = s;
    }
    const d = new Float64Array(n);
    const invD = new Float64Array(n);
    for (let i = 0; i < n; i++) {
      const aii = diag[i];
      if (!(aii > 0)) throw new Error('StencilMIC: 对角元非正');
      let s = aii;
      // 下三角按列号递增：i−nR 再 i−1
      if (i >= nR) {
        const aij = west[i];
        if (aij !== 0) s -= aij * invD[i - nR] * (aij + omega * (upSum[i - nR] - aij));
      }
      if (i >= 1) {
        const aij = south[i];
        if (aij !== 0) s -= aij * invD[i - 1] * (aij + omega * (upSum[i - 1] - aij));
      }
      if (!(s >= sigma * aii)) s = aii;
      d[i] = s;
      invD[i] = 1 / s;
    }
    const sq = new Float64Array(n);
    for (let i = 0; i < n; i++) sq[i] = Math.sqrt(d[i]);
    this.lw = new Float64Array(n);
    this.ls = new Float64Array(n);
    this.invD = new Float64Array(n);
    for (let i = 0; i < n; i++) {
      if (i >= nR && west[i] !== 0) this.lw[i] = west[i] / sq[i - nR];
      if (i >= 1 && south[i] !== 0) this.ls[i] = south[i] / sq[i - 1];
      this.invD[i] = 1 / sq[i];
    }
  }

  /** z = M⁻¹·r：前代 L·y = r，回代 Lᵀ·z = y（运算次序同 pcg.ts 的 CholFactorPrecond.apply） */
  apply(r: Float64Array, z: Float64Array): void {
    const { n, nR } = this.A;
    const { lw, ls, invD } = this;
    // 前代：首 nR 行逐项判断，其余无分支（零系数项减 0 不改变结果）
    const i0 = Math.min(nR, n);
    for (let i = 0; i < i0; i++) {
      let s = r[i];
      if (i >= 1) s -= ls[i] * z[i - 1];
      z[i] = s * invD[i];
    }
    for (let i = i0; i < n; i++) {
      let s = r[i];
      s -= lw[i] * z[i - nR];
      s -= ls[i] * z[i - 1];
      z[i] = s * invD[i];
    }
    // 回代：末 nR 行逐项判断
    const i1 = Math.max(0, n - nR);
    for (let i = n - 1; i >= i1; i--) {
      let s = z[i];
      if (i + 1 < n) s -= ls[i + 1] * z[i + 1];
      z[i] = s * invD[i];
    }
    for (let i = i1 - 1; i >= 0; i--) {
      let s = z[i];
      s -= ls[i + 1] * z[i + 1];
      s -= lw[i + nR] * z[i + nR];
      z[i] = s * invD[i];
    }
  }
}

function dot(a: Float64Array, b: Float64Array, n: number): number {
  let s = 0;
  for (let i = 0; i < n; i++) s += a[i] * b[i];
  return s;
}

/** 冻结的模板矩阵 + 预条件器 + 工作区；solve 与 pcg.ts 的 pcg 相同（真残差判据、重启规则） */
export class StencilSolver {
  private readonly M: StencilMIC;
  private readonly r: Float64Array;
  private readonly z: Float64Array;
  private readonly p: Float64Array;
  private readonly q: Float64Array;
  constructor(
    readonly A: StencilMatrix,
    private readonly tol = 1e-12,
    private readonly maxRestarts = 10,
  ) {
    this.M = new StencilMIC(A);
    const n = A.n;
    this.r = new Float64Array(n);
    this.z = new Float64Array(n);
    this.p = new Float64Array(n);
    this.q = new Float64Array(n);
  }

  solve(b: Float64Array, x0: Float64Array | null): { x: Float64Array; iters: number; relres: number; converged: boolean } {
    const A = this.A;
    const n = A.n;
    // maxIter 按全网格 n 计（CSR 版按激活面数）；只在不收敛时才有差别
    const maxIter = Math.max(200, Math.min(n, 10000));
    const { r, z, p, q, M } = this;
    const x = new Float64Array(n);
    const normb = Math.sqrt(dot(b, b, n));
    if (normb === 0) return { x, iters: 0, relres: 0, converged: true };
    const thresh = this.tol * normb;
    if (x0) {
      x.set(x0);
      A.matvec(x, q);
      for (let i = 0; i < n; i++) r[i] = b[i] - q[i];
    } else r.set(b);
    let trueNorm = Math.sqrt(dot(r, r, n));
    if (trueNorm <= thresh) return { x, iters: 0, relres: trueNorm / normb, converged: true };
    let iters = 0;
    let restarts = 0;
    let converged = false;
    let lastTrue = trueNorm;
    outer: while (true) {
      M.apply(r, z);
      let rz = dot(r, z, n);
      if (!(rz > 0)) break;
      p.set(z);
      while (iters < maxIter) {
        const pq = A.matvecDot(p, q);
        iters++;
        if (!(pq > 0)) break outer;
        const alpha = rz / pq;
        let rr = 0;
        for (let i = 0; i < n; i++) {
          x[i] += alpha * p[i];
          const ri = r[i] - alpha * q[i];
          r[i] = ri;
          rr += ri * ri;
        }
        const rn = Math.sqrt(rr);
        if (!(rn === rn)) break outer;
        if (rn <= thresh) {
          A.matvec(x, q);
          for (let i = 0; i < n; i++) r[i] = b[i] - q[i];
          trueNorm = Math.sqrt(dot(r, r, n));
          if (trueNorm <= thresh) {
            converged = true;
            break outer;
          }
          restarts++;
          if (restarts > this.maxRestarts || trueNorm > 0.5 * lastTrue) break outer;
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
      A.matvec(x, q);
      let s = 0;
      for (let i = 0; i < n; i++) {
        const d = b[i] - q[i];
        s += d * d;
      }
      trueNorm = Math.sqrt(s);
      converged = trueNorm <= thresh;
    }
    return { x, iters, relres: trueNorm / normb, converged };
  }
}
