// 元件轮廓与风扇（主视图与对比展示页的缩略图共用）：只含画图所需的矩形与风扇盘，格坐标 1 基。
import { layoutGpuSlots } from '../model/gpuSlots';
import type { Rect } from '../model/types';
import type { Solver } from './solver';

export interface GeoOverlay {
  W: number; // 网格行数（y）
  H: number; // 网格列数（x）
  cellMm: number;
  caseOuter: Rect;
  motherboardTray?: Rect;
  /** finArea 为鳍片外廓；stacks 为各组鳍片（双塔 2 组，中间间隙放塔扇） */
  cpu?: { base: Rect; finArea: Rect; stacks: Rect[] };
  gpu?: { pcb: Rect; heatsink: Rect; slots: number; fanBottom: number };
  psu?: { body: Rect };
  ram: Rect[];
  vrm?: Rect;
  chipset?: Rect;
  fans: { role: string; type: string; mount: string; model: string; rows: [number, number]; cols: [number, number]; normal: [number, number] }[];
}

export function geoOverlay(s: Solver): GeoOverlay {
  const g = s.geo;
  let gpu: GeoOverlay['gpu'];
  if (g.gpu) {
    let fanBottom = g.gpu.heatsink.y + g.gpu.heatsink.h - 1;
    for (const f of g.fans) if (f.role === 'gpu') fanBottom = Math.max(fanBottom, f.rows[1]);
    gpu = { pcb: { ...g.gpu.pcb }, heatsink: { ...g.gpu.heatsink }, slots: layoutGpuSlots(s.layout), fanBottom };
  }
  return {
    W: s.W,
    H: s.H,
    cellMm: g.cellMm,
    caseOuter: { ...g.CASE2D.outer },
    motherboardTray: g.CASE2D.motherboardTray ? { ...g.CASE2D.motherboardTray } : undefined,
    cpu: g.cpu ? { base: { ...g.cpu.base }, finArea: { ...g.cpu.finArea }, stacks: g.cpu.stacks.map((r) => ({ ...r })) } : undefined,
    gpu,
    psu: g.psu ? { body: { ...g.psu.body } } : undefined,
    ram: g.ram.map((r) => ({ ...r })),
    vrm: g.vrm ? { ...g.vrm } : undefined,
    chipset: g.chipset ? { ...g.chipset } : undefined,
    fans: g.fans.map((f) => ({
      role: f.role,
      type: f.type,
      mount: f.mount,
      model: f.model,
      rows: [f.rows[0], f.rows[1]] as [number, number],
      cols: [f.cols[0], f.cols[1]] as [number, number],
      normal: [f.normal[0], f.normal[1]] as [number, number],
    })),
  };
}
