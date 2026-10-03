// 默认 ATX 机箱布局（移植自 matlab_app/src/layout_default.m，数值逐项一致）：紧凑机箱，只比主板略大，
// 主板贴后壁（I/O 与扩展槽在后面板），前部留出前进风风扇的空间，电源在底部电源仓。
import type { Acoustics, CaseFan, FanType, Layout, Mount, Rect } from './types';
import { gpuFinArea } from './gpuSlots';
import { fanCurveProfiles, layoutDvfs } from './fanCurves';

export function rect(x: number, y: number, w: number, h: number): Rect {
  return { x, y, w, h };
}

export function acousticsDefault(): Acoustics {
  // 听者位于机箱前侧约 1 m；见 matlab_app/src/acoustics_default.m
  return {
    stallQ: 0.4,
    stallDb: 6,
    grilleRefZeta: 2,
    finDb: 2, // 塔扇、显卡风扇贴着致密鳍片吹的附加噪音
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
    // 计算域 560 mm 见方（基准网格 280×280、格距 2 mm）。机箱深 320 mm（后 → 前）× 高 400 mm：ATX 主板 244 mm 深，
    // 前部 72 mm 放前进风风扇；机箱居中，前后各留 120 mm、上下各留 80 mm 外部空气
    domain: { sizeMm: 560, baseCellMm: 2 },
    chassis: {
      enabled: true,
      originMm: [120, 80],
      sizeMm: [320, 400],
      depthM: 0.15,
      wallTempC: { rear: 25, front: 25, top: 25, bottom: 25 },
    },
    power: { cpu: 125, gpu: 250, psu: 450 },
    // 自动温控风扇曲线（档位：quiet / standard / performance，见 fanCurves.ts）
    fanCurves: fanCurveProfiles('standard'),
    fanDiskMm: 12,
    grille: { intakeZeta: 2.0, exhaustZeta: 0.8 },
    acoustics: acousticsDefault(),
    cpu: {
      // 双塔风冷：前后两组鳍片（各 44 mm 厚、120 mm 高），中间 24 mm 间隙放塔扇；塔扇 1 个（中间）或 2 个（前 + 中间）。
      // 鳍片后端距后排风扇执行盘约 22 mm，下沿距显卡 PCB 16 mm；底座只显示、不挡风
      base: rect(68, 112, 48, 48),
      fins: rect(36, 76, 112, 120), // 鳍片外廓（两组鳍片 + 中间间隙）
      tower: { stacks: 2, gapMm: 24 },
      porous: { zetaThru: 8, zetaCross: 60, thru: 'x' },
      thermal: { R_junction_to_case: 0.15, R_tim: 0.04, R_base: 0.05, fin_thickness_mm: 0.4, A_fin_total_m2: 0.15 },
      tjmax: 100,
      throttleTemp: 95, // 温度墙：超过后降频把结温压在这里
      dvfs: layoutDvfs({} as Layout, 'cpu'),
      fan: { model: 'Tower120', count: 2 },
    },
    gpu: {
      slots: 4,
      pcb: rect(38, 212, 216, 12),
      heatsink: rect(28, 224, 236, 57), // 后端离后壁约 26 mm（挡板端接口区；热风可沿后壁上行），前端伸出主板前缘约 16 mm
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
      dvfs: layoutDvfs({} as Layout, 'gpu'),
      fans: { model: 'GPU80', xs: [68, 146, 224] },
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
    // 主板 ATX 244 × 305 mm，后缘贴后壁；下沿约 27 mm 在电源仓挡板后，主板区只画挡板以上部分
    ram: [rect(190, 48, 4, 32), rect(196, 48, 4, 32), rect(202, 48, 4, 32), rect(208, 48, 4, 32)],
    vrm: rect(34, 44, 28, 20),
    chipset: rect(174, 306, 20, 8),
    motherboardTray: rect(4, 36, 244, 278),
    shroud: { yMm: 314, hMm: 16, gaps: [{ x0Mm: 280, x1Mm: 318 }] },
    caseFans: [
      caseFan('front', 220, 'intake', 'P12'),
      caseFan('front', 338, 'intake', 'P12'),
      caseFan('rear', 124, 'exhaust', 'P12'),
      caseFan('top', 100, 'exhaust', 'Stock120'),
    ],
  };
}
