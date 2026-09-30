// 默认 ATX 中塔布局（移植自 matlab_app/src/layout_default.m，数值逐项一致）。
import type { Acoustics, CaseFan, FanType, Layout, Mount, Rect } from './types';
import { gpuFinArea } from './gpuSlots';

export function rect(x: number, y: number, w: number, h: number): Rect {
  return { x, y, w, h };
}

export function acousticsDefault(): Acoustics {
  // 听者位于机箱前侧约 1 m；见 matlab_app/src/acoustics_default.m
  return {
    stallQ: 0.4,
    stallDb: 6,
    grilleRefZeta: 2,
    positionDb: { front: 0, top: -1, bottom: -2, rear: -3, cpu: -3, gpu: -3, psu: -4 },
  };
}

function caseFan(mount: Mount, alongMm: number, type: FanType, model: string): CaseFan {
  return { mount, alongMm, type, model, speedMode: 'auto', manualPct: 60 };
}

export function layoutDefault(): Layout {
  return {
    name: 'atx_balanced',
    ambientC: 25,
    turbulenceModel: 'komega',
    // 计算域 560 mm 见方（基准网格 280×280、格距 2 mm），机箱 400 mm 见方，四周各留 80 mm 外部空气
    domain: { sizeMm: 560, baseCellMm: 2 },
    chassis: {
      enabled: true,
      originMm: 80,
      sizeMm: 400,
      depthM: 0.15,
      wallTempC: { rear: 25, front: 25, top: 25, bottom: 25 },
    },
    power: { cpu: 125, gpu: 250, psu: 450 },
    fanDiskMm: 12,
    grille: { intakeZeta: 2.0, exhaustZeta: 0.8 },
    acoustics: acousticsDefault(),
    cpu: {
      base: rect(194, 114, 48, 48),
      fins: rect(158, 86, 120, 104),
      porous: { zetaThru: 8, zetaCross: 60, thru: 'x' },
      thermal: { R_junction_to_case: 0.15, R_tim: 0.04, R_base: 0.05, fin_thickness_mm: 0.4, A_fin_total_m2: 0.15 },
      tjmax: 100,
      throttleTemp: 95,
      fan: { model: 'Tower120', side: 'front' },
    },
    gpu: {
      slots: 4,
      pcb: rect(160, 212, 216, 12),
      heatsink: rect(150, 224, 236, 57),
      porous: { zetaThru: 4, zetaCross: 10, thru: 'x' },
      thermal: {
        R_junction_to_case: 0.08,
        R_tim: 0.02,
        R_base: 0.02,
        fin_thickness_mm: 0.35,
        A_fin_total_m2: gpuFinArea(57),
      },
      tjmax: 95,
      throttleTemp: 87,
      fans: { model: 'GPU80', xs: [190, 268, 346] },
    },
    psu: {
      body: rect(4, 334, 164, 66),
      ratedW: 850,
      effCurve: { load: [0.1, 0.2, 0.5, 1.0], eff: [0.82, 0.87, 0.9, 0.87] },
      porous: { zetaThru: 6, zetaCross: 6, thru: 'x' },
      fan: { model: 'PSU120', xMm: 86 },
      intakeZeta: 2.0,
      exhaustZeta: 1.0,
      R_internal: 0.25,
      warnTemp: 85,
    },
    ram: [rect(314, 48, 4, 32), rect(320, 48, 4, 32), rect(326, 48, 4, 32), rect(332, 48, 4, 32)],
    vrm: rect(158, 44, 28, 20),
    chipset: rect(264, 306, 20, 8),
    motherboardTray: rect(150, 36, 248, 274),
    shroud: { yMm: 314, hMm: 16, gaps: [{ x0Mm: 360, x1Mm: 398 }] },
    caseFans: [
      caseFan('front', 220, 'intake', 'P12'),
      caseFan('front', 338, 'intake', 'P12'),
      caseFan('rear', 124, 'exhaust', 'P12'),
      caseFan('top', 140, 'exhaust', 'Stock120'),
    ],
  };
}
