// 界面配色表（移植自 pcflow_colormap.m）：锚点线性插值为 256 级 RGB 查找表。
export type ColormapName = 'speed' | 'heat' | 'diverging';

const ANCHORS: Record<ColormapName, number[][]> = {
  // 速度：深紫—蓝—青绿—黄（近似 viridis）
  speed: [
    [0.267, 0.005, 0.329],
    [0.283, 0.141, 0.458],
    [0.254, 0.265, 0.53],
    [0.207, 0.372, 0.553],
    [0.164, 0.471, 0.558],
    [0.128, 0.567, 0.551],
    [0.135, 0.659, 0.518],
    [0.267, 0.749, 0.441],
    [0.478, 0.821, 0.318],
    [0.741, 0.873, 0.15],
    [0.993, 0.906, 0.144],
  ],
  // 温度：黑—紫—红—橙—浅黄（近似 inferno）
  heat: [
    [0.001, 0.0, 0.014],
    [0.087, 0.045, 0.224],
    [0.258, 0.039, 0.406],
    [0.416, 0.09, 0.433],
    [0.578, 0.148, 0.404],
    [0.735, 0.216, 0.33],
    [0.866, 0.317, 0.226],
    [0.955, 0.463, 0.106],
    [0.988, 0.645, 0.04],
    [0.964, 0.845, 0.261],
    [0.988, 0.998, 0.645],
  ],
  // 发散：蓝—浅灰—红（温差、涡量、压力，0 为中点）
  diverging: [
    [0.23, 0.3, 0.75],
    [0.55, 0.69, 0.99],
    [0.87, 0.87, 0.87],
    [0.96, 0.6, 0.48],
    [0.71, 0.02, 0.15],
  ],
};

const cache = new Map<ColormapName, Uint8ClampedArray>();

/** 256 级 RGB 查找表（每级 3 字节） */
export function colormapLUT(name: ColormapName): Uint8ClampedArray {
  let lut = cache.get(name);
  if (lut) return lut;
  const k = ANCHORS[name];
  const n = 256;
  lut = new Uint8ClampedArray(n * 3);
  for (let i = 0; i < n; i++) {
    const t = (i / (n - 1)) * (k.length - 1);
    const j = Math.min(k.length - 2, Math.floor(t));
    const f = t - j;
    for (let c = 0; c < 3; c++) lut[i * 3 + c] = Math.round(255 * (k[j][c] + f * (k[j + 1][c] - k[j][c])));
  }
  cache.set(name, lut);
  return lut;
}

/** CSS 渐变（色标用）；t0–t1 为取用的配色表区段（0–1） */
export function colormapGradient(name: ColormapName, dir = 'to top', t0 = 0, t1 = 1): string {
  const lut = colormapLUT(name);
  const stops: string[] = [];
  for (let s = 0; s <= 10; s++) {
    const i = Math.round((t0 + (s / 10) * (t1 - t0)) * 255);
    stops.push(`rgb(${lut[i * 3]},${lut[i * 3 + 1]},${lut[i * 3 + 2]}) ${s * 10}%`);
  }
  return `linear-gradient(${dir}, ${stops.join(', ')})`;
}
