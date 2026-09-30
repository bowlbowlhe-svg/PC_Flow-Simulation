/**
 * 精确欧氏距离变换 + 最近 true 格 —— 复刻 matlab_app/src/edt_nearest.m（ALGORITHM.md §3.11）。
 *
 * 布局约定：mask 为 W×H 列优先（W = 行数 = y 方向格数，H = 列数 = x 方向格数），
 * 0 基线性索引 x·W + y（对应 MATLAB 1 基 (x−1)·W + y）。非零即 true。
 *
 * 返回：
 *   D[k]   = 格 k 的格心到最近 true 格格心的欧氏距离（格）；true 格 D = 0。
 *   idx[k] = 该最近 true 格的 **0 基** 线性索引（MATLAB 返回 1 基，idx_matlab = idx + 1）。
 *   平局取线性索引最小（先 x 最小的列，再该列 y 最小的格）。
 *   mask 全 false 时 D = Infinity、idx = −1（MATLAB 为 idx = 0，即同样"无"）。
 *
 * 两遍可分离算法与 .m 相同；距离平方全为整数（双精度精确），D = sqrt(整数) 为正确舍入，
 * 因此与 MATLAB/Octave 逐位相同。第 2 遍用由近及远的剪枝搜索代替 .m 的全行扫描，结果相同
 * （(x − x')² > 当前最小值时不可能再出现更小或相等的值）。
 */
export function edtNearest(
  mask: Uint8Array | ArrayLike<number | boolean>,
  W: number,
  H: number,
): { D: Float64Array; idx: Int32Array } {
  const N = W * H;
  if (mask.length !== N) throw new Error('edtNearest: mask 长度与 W×H 不符');
  const D = new Float64Array(N);
  const idx = new Int32Array(N);
  let any = false;
  for (let k = 0; k < N; k++) {
    if (mask[k]) { any = true; break; }
  }
  if (!any) {
    D.fill(Infinity);
    idx.fill(-1);
    return { D, idx };
  }

  // 1) 列内最近：g = 到本列最近 true 格的行距（无则 ∞），r = 该格行号（0 基，无则 −1）；上下等距取上。
  const g2 = new Float64Array(N);
  const rowOf = new Int32Array(N);
  const up = new Int32Array(W);
  for (let x = 0; x < H; x++) {
    const col = x * W;
    let last = -1;
    for (let y = 0; y < W; y++) {
      if (mask[col + y]) last = y;
      up[y] = last;
    }
    let nxt = -1;
    for (let y = W - 1; y >= 0; y--) {
      if (mask[col + y]) nxt = y;
      const u = up[y];
      const dUp = u >= 0 ? y - u : Infinity;
      const dDn = nxt >= 0 ? nxt - y : Infinity;
      let g: number;
      let r: number;
      if (dUp <= dDn) { g = dUp; r = u; } else { g = dDn; r = nxt; }
      g2[col + y] = g * g;
      rowOf[col + y] = r;
    }
  }

  // 2) 行内：D²(y, x) = min_x' [(x − x')² + g(y, x')²]，等值取 x' 最小。
  for (let y = 0; y < W; y++) {
    for (let x = 0; x < H; x++) {
      let best = Infinity;
      let bestX = -1;
      for (let d = 0; d < H; d++) {
        const dd = d * d;
        if (dd > best) break;
        const xl = x - d;
        if (xl >= 0) {
          const v = dd + g2[y + xl * W];
          // xl 比此前所有候选都小：等值也更新
          if (v <= best && v !== Infinity) { best = v; bestX = xl; }
        }
        if (d > 0) {
          const xr = x + d;
          if (xr < H) {
            const v = dd + g2[y + xr * W];
            // xr 比此前所有候选都大：只在严格更小时更新
            if (v < best) { best = v; bestX = xr; }
          }
        }
        if (xl < 0 && x + d >= H) break;
      }
      const k = y + x * W;
      D[k] = Math.sqrt(best);
      idx[k] = bestX * W + rowOf[y + bestX * W];
    }
  }
  return { D, idx };
}
