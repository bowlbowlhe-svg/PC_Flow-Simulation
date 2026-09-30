// MATLAB 语义的二元 max/min：一侧为 NaN 时返回另一侧（两侧都是 NaN 才返回 NaN）。
// JavaScript 的 Math.max/min 会传播 NaN；移植 MATLAB 的钳位与下限时必须用这两个函数，
// 否则一个 NaN（例如空区域的均值）会扩散到整个状态（W0/W1 审计：散热体被固体覆盖的布局）。

export function mmax(a: number, b: number): number {
  if (a !== a) return b;
  if (b !== b) return a;
  return a > b ? a : b;
}

export function mmin(a: number, b: number): number {
  if (a !== a) return b;
  if (b !== b) return a;
  return a < b ? a : b;
}
