// 等值线（marching squares）：在格心网格上求 level 等值线段，坐标为 1 基格坐标（x 列、y 行）。
// NaN 格（固体）所在的方格跳过。输出扁平数组 [x1, y1, x2, y2, ...]。

export function contourSegments(F: ArrayLike<number>, W: number, H: number, level: number): Float32Array {
  const out: number[] = [];
  const at = (x: number, y: number) => F[x * W + y]; // 0 基
  for (let x = 0; x < H - 1; x++) {
    for (let y = 0; y < W - 1; y++) {
      const a = at(x, y); // 左上
      const b = at(x + 1, y); // 右上
      const c = at(x + 1, y + 1); // 右下
      const d = at(x, y + 1); // 左下
      if (!(Number.isFinite(a) && Number.isFinite(b) && Number.isFinite(c) && Number.isFinite(d))) continue;
      let code = 0;
      if (a >= level) code |= 8;
      if (b >= level) code |= 4;
      if (c >= level) code |= 2;
      if (d >= level) code |= 1;
      if (code === 0 || code === 15) continue;
      const X = x + 1;
      const Y = y + 1;
      const t = (p: number, q: number) => (level - p) / (q - p);
      // 四条边上的交点
      const top = () => [X + t(a, b), Y];
      const right = () => [X + 1, Y + t(b, c)];
      const bottom = () => [X + t(d, c), Y + 1];
      const left = () => [X, Y + t(a, d)];
      const seg = (p: number[], q: number[]) => out.push(p[0], p[1], q[0], q[1]);
      switch (code) {
        case 1:
        case 14:
          seg(left(), bottom());
          break;
        case 2:
        case 13:
          seg(bottom(), right());
          break;
        case 3:
        case 12:
          seg(left(), right());
          break;
        case 4:
        case 11:
          seg(top(), right());
          break;
        case 5: {
          // 鞍点：按中心值区分
          const m = 0.25 * (a + b + c + d);
          if (m >= level) {
            seg(top(), left());
            seg(bottom(), right());
          } else {
            seg(top(), right());
            seg(left(), bottom());
          }
          break;
        }
        case 6:
        case 9:
          seg(top(), bottom());
          break;
        case 7:
        case 8:
          seg(top(), left());
          break;
        case 10: {
          const m = 0.25 * (a + b + c + d);
          if (m >= level) {
            seg(top(), right());
            seg(left(), bottom());
          } else {
            seg(top(), left());
            seg(bottom(), right());
          }
          break;
        }
      }
    }
  }
  return Float32Array.from(out);
}
