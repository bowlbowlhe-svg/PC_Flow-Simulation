/**
 * MATLAB round：四舍五入，0.5 远离零（规格 §1）。JavaScript 的 Math.round 对负数的 .5 向 +∞ 取整，不能直接用。
 * 默认布局在 4 mm 网格上有很多 .5，取整规则不同会让元件错位一格。
 */
export function mround(x: number): number {
  return x < 0 ? -Math.round(-x) : Math.round(x);
}
