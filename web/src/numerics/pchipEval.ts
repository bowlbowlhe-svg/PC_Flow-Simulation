/**
 * 分段三次保形插值 —— 复刻 matlab_app/src/pchip_eval.m（ALGORITHM.md §3.11；Fritsch–Carlson/Brodlie，
 * 与 MATLAB pchip 同式）。算式与运算次序同 .m，结果与 MATLAB/Octave 逐位相同。
 *
 * x 严格递增、≥ 3 个节点；q 钳入 [x_1, x_n]（MATLAB 的 min(max(q, x1), xn)：NaN 钳为 x_1）。
 */

/** MATLAB sign：sign(0) = 0，sign(NaN) = NaN。 */
function sign(v: number): number {
  return v > 0 ? 1 : v < 0 ? -1 : v === 0 ? 0 : NaN;
}

function endSlope(h1: number, h2: number, del1: number, del2: number): number {
  let d = ((2 * h1 + h2) * del1 - h1 * del2) / (h1 + h2);
  // MATLAB 的 ~= 对 NaN 为 true；JS 的 !== 同样
  if (sign(d) !== sign(del1)) {
    d = 0;
  } else if (sign(del1) !== sign(del2) && Math.abs(d) > Math.abs(3 * del1)) {
    d = 3 * del1;
  }
  return d;
}

/** 节点斜率 d（长度 n）、区间宽 h（n−1）。 */
export function pchipSlopes(x: ArrayLike<number>, y: ArrayLike<number>): { h: Float64Array; d: Float64Array } {
  const n = x.length;
  if (y.length !== n) throw new Error('pchipSlopes: x 与 y 长度不同');
  if (n < 3) throw new Error('pchipSlopes: 至少需要 3 个节点');
  const h = new Float64Array(n - 1);
  const del = new Float64Array(n - 1);
  for (let k = 0; k < n - 1; k++) {
    h[k] = x[k + 1] - x[k];
    del[k] = (y[k + 1] - y[k]) / h[k];
  }
  const d = new Float64Array(n);
  // 1 基 k = 2..n−1 → 0 基 k = 1..n−2；h(k) → h[k]，h(k−1) → h[k−1]
  for (let k = 1; k < n - 1; k++) {
    if (del[k - 1] * del[k] > 0) {
      const w1 = 2 * h[k] + h[k - 1];
      const w2 = h[k] + 2 * h[k - 1];
      d[k] = (w1 + w2) / (w1 / del[k - 1] + w2 / del[k]);
    }
  }
  d[0] = endSlope(h[0], h[1], del[0], del[1]);
  d[n - 1] = endSlope(h[n - 2], h[n - 3], del[n - 2], del[n - 3]);
  return { h, d };
}

/** 已求好斜率时的单点求值。 */
function evalOne(x: ArrayLike<number>, y: ArrayLike<number>, h: Float64Array, d: Float64Array, q: number): number {
  const n = x.length;
  let qc = q;
  if (!(qc >= x[0])) qc = x[0]; // max(q, x1)（含 NaN → x1）
  if (qc > x[n - 1]) qc = x[n - 1];
  // i = find(x(1:n−1) <= qc, 1, 'last')
  let i = n - 2;
  while (i > 0 && !(x[i] <= qc)) i--;
  const t = (qc - x[i]) / h[i];
  const t2 = t * t;
  const t3 = t2 * t;
  return (2 * t3 - 3 * t2 + 1) * y[i] + (t3 - 2 * t2 + t) * h[i] * d[i] +
    (-2 * t3 + 3 * t2) * y[i + 1] + (t3 - t2) * h[i] * d[i + 1];
}

/** v = pchip_eval(x, y, q)，q 为数组（返回同长度 Float64Array）。 */
export function pchipEval(x: ArrayLike<number>, y: ArrayLike<number>, q: ArrayLike<number>): Float64Array {
  const { h, d } = pchipSlopes(x, y);
  const v = new Float64Array(q.length);
  for (let m = 0; m < q.length; m++) v[m] = evalOne(x, y, h, d, q[m]);
  return v;
}

/** 标量版：v = pchip_eval(x, y, q)。 */
export function pchipEval1(x: ArrayLike<number>, y: ArrayLike<number>, q: number): number {
  const { h, d } = pchipSlopes(x, y);
  return evalOne(x, y, h, d, q);
}

/** 预先求好斜率的插值器（节点不变、反复求值时用；结果与 pchipEval 逐位相同）。 */
export function makePchip(x: ArrayLike<number>, y: ArrayLike<number>): (q: number) => number {
  const xs = Float64Array.from(x);
  const ys = Float64Array.from(y);
  const { h, d } = pchipSlopes(xs, ys);
  return (q: number) => evalOne(xs, ys, h, d, q);
}
