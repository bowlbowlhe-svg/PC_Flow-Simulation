// 对比展示页的场景与计算口径（不依赖求解器，界面主包可直接引用；推进见 protocol.ts）。
export type ScenarioKey = 'office' | 'gaming' | 'heavy';

/** 三个场景（同界面"办公 / 游戏 / 满载"按钮）：CPU、GPU、电源负载 [W] */
export const COMPARE_SCENARIOS: readonly { key: ScenarioKey; label: string; powers: [number, number, number] }[] = Object.freeze([
  { key: 'office', label: '办公', powers: [40, 35, 200] },
  { key: 'gaming', label: '游戏', powers: [100, 200, 500] },
  { key: 'heavy', label: '满载', powers: [180, 320, 850] },
]);

export interface CompareProtocol {
  gridScale: number; // 1 = 精确 280²
  turbUpdateEvery: number;
  autoSteps: number; // 自动温控阶段：从静止推进的步数
  autoAvgFrom: number; // 统计取本阶段第 autoAvgFrom 步之后的每一步
  sweepPct: number[]; // 全局手动转速扫描 [%]，依次接续推进
  sweepSteps: number;
  sweepAvgFrom: number;
}

/** 预计算数据的口径：280²，自动 1600 步（后 800 步均值），再依次 40/70/100% 各 800 步（后 400 步均值） */
export const DEFAULT_PROTOCOL: CompareProtocol = Object.freeze({
  gridScale: 1,
  turbUpdateEvery: 1,
  autoSteps: 1600,
  autoAvgFrom: 800,
  sweepPct: [40, 70, 100],
  sweepSteps: 800,
  sweepAvgFrom: 400,
}) as CompareProtocol;

/**
 * 公平比较：沿方案的转速扫描曲线（噪音单调增、温度单调减）在给定噪音处插值温度，或在给定温度处插值噪音。
 * xs/ys 为扫描点（按转速升序）；超出范围时返回 NaN（该方案达不到）。
 */
export function interpAt(xs: number[], ys: number[], x: number): number {
  const pts = xs.map((v, i) => [v, ys[i]] as [number, number]).filter(([a, b]) => Number.isFinite(a) && Number.isFinite(b));
  pts.sort((a, b) => a[0] - b[0]);
  if (pts.length < 2 || x < pts[0][0] || x > pts[pts.length - 1][0]) return NaN;
  for (let i = 0; i < pts.length - 1; i++) {
    const [x0, y0] = pts[i];
    const [x1, y1] = pts[i + 1];
    if (x >= x0 && x <= x1) return x1 === x0 ? y0 : y0 + ((x - x0) / (x1 - x0)) * (y1 - y0);
  }
  return NaN;
}
