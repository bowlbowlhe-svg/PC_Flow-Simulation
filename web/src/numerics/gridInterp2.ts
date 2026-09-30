/**
 * 均匀单位格距网格上的二维插值 —— 逐元素复刻 matlab_app/src/grid_interp2.m（ALGORITHM.md §3.11）。
 *
 * 目标：与 Octave/MATLAB 结果逐位相同。所有算式按 .m 文件的运算次序书写（左结合的加减、同样的乘法次序），
 * 不重排、不用 FMA；MATLAB 的逐元素向量运算对每个元素的舍入与这里的标量运算完全一致。
 *
 * 布局约定（与 MATLAB 一致，列优先）：
 *   V 为 n1×n2，元素 (r, c)（0 基）位于 V[r + c·n1]；第 1 维（行，n1 个）节点坐标 o1 + (0 … n1−1)，
 *   第 2 维（列，n2 个）节点坐标 o2 + (0 … n2−1)。q1、q2 为同长度的查询坐标（第 1 维、第 2 维），
 *   输出与查询一一对应（长度 = q1.length）。
 *   求解器里 u 面阵是 W×(H+1)：第 1 维 = y（行），第 2 维 = x（列），与 MATLAB 调用
 *   grid_interp2(uM, Yq, Xq, 'cubic', 1, 0.5) 同序传参即可。
 */

export type InterpMethod = 'linear' | 'cubic' | 'makima';

/** makima 节点斜率（与 .m 中 makimaSlope 同式；分母为 0 时取 0）。 */
function makimaSlope(dm2: number, dm1: number, d0: number, dp1: number): number {
  const wLo = Math.abs(dm1 - dm2) + Math.abs(dm1 + dm2) / 2;
  const wHi = Math.abs(dp1 - d0) + Math.abs(dp1 + d0) / 2;
  const wSum = wLo + wHi;
  if (wSum === 0) return 0;
  return (wHi * dm1 + wLo * d0) / wSum;
}

/** 三次 Hermite（单位区间）：与 .m 中 hermite 同式同序。 */
function hermite(a: number, b: number, da: number, db: number, t: number): number {
  const t2 = t * t;
  const t3 = t2 * t;
  return (2 * t3 - 3 * t2 + 1) * a + (t3 - 2 * t2 + t) * da +
    (-2 * t3 + 3 * t2) * b + (t3 - t2) * db;
}

/** MATLAB 的 min(max(u, 1), n)：max(NaN, 1) = 1。 */
function clampU(u: number, n: number): number {
  let v = u;
  if (!(v >= 1)) v = 1; // 含 NaN
  if (v > n) v = n;
  return v;
}

/**
 * 沿第 2 维的节点斜率（单位格距），对 A（m×n，列优先）的每一行：两端各二次外插 2 列后求斜率。
 * 与 .m 的 slopesDim2 同式；结果与 A 同尺寸（列优先）。
 */
function slopesDim2(A: Float64Array, m: number, n: number, isMakima: boolean): Float64Array {
  const S = new Float64Array(m * n);
  const ap = new Float64Array(n + 4);
  const dl = new Float64Array(n + 3);
  for (let r = 0; r < m; r++) {
    const a1 = A[r];
    const a2 = A[r + m];
    const a3 = A[r + 2 * m];
    const e1 = A[r + (n - 1) * m];
    const e2 = A[r + (n - 2) * m];
    const e3 = A[r + (n - 3) * m];
    const f0 = 3 * a1 - 3 * a2 + a3;
    const fm = 3 * f0 - 3 * a1 + a2;
    const g0 = 3 * e1 - 3 * e2 + e3;
    const gm = 3 * g0 - 3 * e1 + e2;
    ap[0] = fm;
    ap[1] = f0;
    for (let c = 0; c < n; c++) ap[c + 2] = A[r + c * m];
    ap[n + 2] = g0;
    ap[n + 3] = gm;
    if (isMakima) {
      for (let c = 0; c < n + 3; c++) dl[c] = ap[c + 1] - ap[c];
      for (let j = 0; j < n; j++) {
        S[r + j * m] = makimaSlope(dl[j], dl[j + 1], dl[j + 2], dl[j + 3]);
      }
    } else {
      for (let j = 0; j < n; j++) {
        S[r + j * m] = 0.5 * (ap[j + 3] - ap[j + 1]);
      }
    }
  }
  return S;
}

/**
 * out = grid_interp2(V, q1, q2, method, o1, o2)。
 * @param V   n1×n2 节点值（列优先）。cubic/makima 要求 n1、n2 ≥ 3；linear 要求 ≥ 2。
 * @param q1  第 1 维查询坐标。
 * @param q2  第 2 维查询坐标（与 q1 同长度）。
 * @param out 可选输出缓冲（长度 ≥ q1.length）。
 */
export function gridInterp2(
  V: ArrayLike<number>,
  n1: number,
  n2: number,
  q1: ArrayLike<number>,
  q2: ArrayLike<number>,
  method: InterpMethod,
  o1: number,
  o2: number,
  out?: Float64Array,
): Float64Array {
  const nq = q1.length;
  if (q2.length !== nq) throw new Error('gridInterp2: q1 与 q2 长度不同');
  if (V.length !== n1 * n2) throw new Error('gridInterp2: V 尺寸与 n1×n2 不符');
  const res = out ?? new Float64Array(nq);

  if (method === 'linear') {
    if (n1 < 2 || n2 < 2) throw new Error('gridInterp2: linear 需要 n1、n2 ≥ 2');
    for (let k = 0; k < nq; k++) {
      const u1 = clampU(q1[k] - o1 + 1, n1);
      const u2 = clampU(q2[k] - o2 + 1, n2);
      const i1 = Math.min(Math.floor(u1), n1 - 1);
      const i2 = Math.min(Math.floor(u2), n2 - 1);
      const t1 = u1 - i1;
      const t2 = u2 - i2;
      // 1 基 V(i1 + (i2−1)·n1) → 0 基 (i1−1) + (i2−1)·n1
      const base = i1 - 1 + (i2 - 1) * n1;
      const a = V[base];
      const b = V[base + n1];
      const c = V[base + 1];
      const d = V[base + 1 + n1];
      res[k] = (a * (1 - t2) + b * t2) * (1 - t1) + (c * (1 - t2) + d * t2) * t1;
    }
    return res;
  }

  if (method !== 'cubic' && method !== 'makima') {
    throw new Error(`gridInterp2: 未知方法 ${String(method)}`);
  }
  if (n1 < 3 || n2 < 3) throw new Error('gridInterp2: cubic/makima 需要 n1、n2 ≥ 3');
  const isMakima = method === 'makima';

  // 第 1 维两端各延拓 2 行：Vp 为 (n1+4)×n2，行 0 = f_{−1}，行 1 = f_0，行 2..n1+1 = V，
  // 行 n1+2 = f_{n+1}，行 n1+3 = f_{n+2}（.m 中 [pad2(top); V; flipud(pad2(bottom))]）。
  const m = n1 + 4;
  const Vp = new Float64Array(m * n2);
  for (let c = 0; c < n2; c++) {
    const col = c * n1;
    const pc = c * m;
    {
      const a1 = V[col];
      const a2 = V[col + 1];
      const a3 = V[col + 2];
      const f0 = 3 * a1 - 3 * a2 + a3;
      const fm = 3 * f0 - 3 * a1 + a2;
      Vp[pc] = fm;
      Vp[pc + 1] = f0;
    }
    for (let r = 0; r < n1; r++) Vp[pc + r + 2] = V[col + r];
    {
      const a1 = V[col + n1 - 1];
      const a2 = V[col + n1 - 2];
      const a3 = V[col + n1 - 3];
      const f0 = 3 * a1 - 3 * a2 + a3;
      const fm = 3 * f0 - 3 * a1 + a2;
      Vp[pc + n1 + 2] = f0;
      Vp[pc + n1 + 3] = fm;
    }
  }
  const S2 = slopesDim2(Vp, m, n2, isMakima);

  for (let k = 0; k < nq; k++) {
    const u1 = clampU(q1[k] - o1 + 1, n1);
    const u2 = clampU(q2[k] - o2 + 1, n2);
    const i1 = Math.min(Math.floor(u1), n1 - 1);
    const i2 = Math.min(Math.floor(u2), n2 - 1);
    const t1 = u1 - i1;
    const t2 = u2 - i2;
    // 延拓后的 1 基行号 r = i1 + kk + 2（kk = −2..3）→ 0 基 i1 + kk + 1；
    // 1 基 la = r + (i2−1)·m → 0 基 (r−1) + (i2−1)·m，lb = la + m。
    const colA = (i2 - 1) * m;
    const colB = i2 * m;
    const r0 = i1 - 1; // kk = −2
    const la = r0 + colA;
    const lb = r0 + colB;
    // 6 个第 1 维节点行（i1−2 … i1+3）上的第 2 维 Hermite；cubic 只用到中间 4 个
    const f2 = hermite(Vp[la + 1], Vp[lb + 1], S2[la + 1], S2[lb + 1], t2);
    const f3 = hermite(Vp[la + 2], Vp[lb + 2], S2[la + 2], S2[lb + 2], t2);
    const f4 = hermite(Vp[la + 3], Vp[lb + 3], S2[la + 3], S2[lb + 3], t2);
    const f5 = hermite(Vp[la + 4], Vp[lb + 4], S2[la + 4], S2[lb + 4], t2);
    let d3: number;
    let d4: number;
    if (isMakima) {
      const f1 = hermite(Vp[la], Vp[lb], S2[la], S2[lb], t2);
      const f6 = hermite(Vp[la + 5], Vp[lb + 5], S2[la + 5], S2[lb + 5], t2);
      const dl1 = f2 - f1;
      const dl2 = f3 - f2;
      const dl3 = f4 - f3;
      const dl4 = f5 - f4;
      const dl5 = f6 - f5;
      d3 = makimaSlope(dl1, dl2, dl3, dl4);
      d4 = makimaSlope(dl2, dl3, dl4, dl5);
    } else {
      d3 = 0.5 * (f4 - f2);
      d4 = 0.5 * (f5 - f3);
    }
    res[k] = hermite(f3, f4, d3, d4, t1);
  }
  return res;
}
