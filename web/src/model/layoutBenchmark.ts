// 验证用的简化布局（移植自 layout_benchmark.m）。
import type { Layout } from './types';

export function layoutBenchmark(kind: 'empty'): Layout;
export function layoutBenchmark(kind: 'cavity', Ra?: number): Layout;
export function layoutBenchmark(kind: 'duct', zetaPlug?: number): Layout;
export function layoutBenchmark(kind: 'empty' | 'cavity' | 'duct', arg?: number): Layout {
  const base = {
    name: 'bench_' + kind,
    ambientC: 25,
    turbulenceModel: 'laminar' as Layout['turbulenceModel'],
    fanDiskMm: 12,
    grille: { intakeZeta: 2.0, exhaustZeta: 0.8 },
    power: { cpu: 0, gpu: 0, psu: 0 },
  };
  switch (kind) {
    case 'empty':
      return {
        ...base,
        domain: { sizeMm: 200, baseCellMm: 2 },
        chassis: {
          enabled: false,
          originMm: 40,
          sizeMm: 120,
          depthM: 0.15,
          wallTempC: { rear: NaN, front: NaN, top: NaN, bottom: NaN },
        },
      };
    case 'cavity': {
      const Ra = arg ?? 1e5;
      // 冷热壁定温点在壁格中心，间距 = (边长格数 − 1)·格距
      const Lc = (120 / 2 - 1) * 0.002;
      const dT = 20;
      const g = 9.81;
      const beta = 3.4e-3;
      const Pr = 0.71;
      const nu = Math.sqrt((Pr * g * beta * dT * Lc ** 3) / Ra);
      return {
        ...base,
        domain: { sizeMm: 160, baseCellMm: 2 },
        chassis: {
          enabled: true,
          originMm: 20,
          sizeMm: 120,
          depthM: 0.15,
          wallTempC: { rear: 45, front: 25, top: NaN, bottom: NaN },
        },
        air: { nu, Pr },
        benchmark: { Ra, Lc, dT },
      };
    }
    case 'duct': {
      const zetaPlug = arg ?? 20;
      return {
        ...base,
        turbulenceModel: 'komega',
        domain: { sizeMm: 560, baseCellMm: 2 },
        chassis: {
          enabled: true,
          originMm: 80,
          sizeMm: 400,
          depthM: 0.15,
          wallTempC: { rear: 25, front: 25, top: 25, bottom: 25 },
        },
        // 上下实心块围出 120 mm 高、贯通前后的风道
        solidBlocks: [
          { x: 2, y: 2, w: 396, h: 138 },
          { x: 2, y: 260, w: 396, h: 138 },
        ],
        porousBlocks: [{ rect: { x: 180, y: 140, w: 20, h: 120 }, zetaThru: zetaPlug, zetaCross: zetaPlug, thru: 'x' }],
        caseFans: [{ mount: 'front', alongMm: 200, type: 'intake', model: 'P12', speedMode: 'manual', manualPct: 100 }],
        vents: [{ mount: 'rear', alongMm: 200, lengthMm: 120, zeta: 1.0 }],
        benchmark: { zetaPlug, zetaIn: 2.0, zetaOut: 1.0, areaM2: 0.12 * 0.15 },
      };
    }
  }
}
