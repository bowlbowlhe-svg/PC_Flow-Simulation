// CPU 塔式散热器的结构：移植自 layout_cpu_tower.m、layout_set_cpu_fans.m。
import { LayoutError } from './gpuSlots';
import type { Layout } from './types';

export type CpuFanPos = 'front' | 'mid' | 'rear';

export interface CpuTower {
  /** 鳍片组数：1 单塔 / 2 双塔 */
  stacks: number;
  /** 双塔两组鳍片之间放风扇的间隙 [mm]（单塔为 0） */
  gapMm: number;
  /** 塔扇数量（无 cpu.fan 时为 0） */
  fans: number;
  /** 各塔扇位置，自前向后 */
  pos: CpuFanPos[];
}

const isNum = (v: unknown): v is number => typeof v === 'number' && Number.isFinite(v);
/** MATLAB %g */
const g6 = (x: number) => String(Number(x.toPrecision(6)));

/**
 * 塔数、间隙、塔扇数量与位置。cpu.fins 是全部鳍片的外廓（双塔含中间间隙）。
 * 塔扇位置：双塔 1 扇 → 中间；双塔 2 扇 → 前 + 中间；单塔 1 扇 → 前；单塔 2 扇 → 前 + 后（推拉）。
 * 没有 cpu.tower、cpu.fan.count 的旧布局按单塔、1 个前置塔扇解释（v4.4.0 及以前的模型）。取值不合法时抛错。
 */
export function layoutCpuTower(L: Layout): CpuTower {
  const c = L.cpu;
  if (!c) throw new LayoutError('layout_cpu_tower:noCpu', '布局中没有 CPU');
  let stacks: unknown = 1;
  let gapMm: unknown = 0;
  if (c.tower) {
    if (c.tower.stacks !== undefined && c.tower.stacks !== null) stacks = c.tower.stacks;
    if (c.tower.gapMm !== undefined && c.tower.gapMm !== null) gapMm = c.tower.gapMm;
  }
  if (!isNum(stacks) || (stacks !== 1 && stacks !== 2)) {
    throw new LayoutError('layout_cpu_tower:stacks', 'cpu.tower.stacks 应为 1（单塔）或 2（双塔）');
  }
  if (stacks === 1) gapMm = 0;
  else if (!isNum(gapMm) || !(gapMm > 0) || gapMm >= c.fins.w) {
    throw new LayoutError('layout_cpu_tower:gap', `cpu.tower.gapMm 应为大于 0、小于鳍片总宽 ${g6(c.fins.w)} mm 的数`);
  }
  if (stacks === 2 && c.porous && c.porous.thru !== 'x') {
    throw new LayoutError('layout_cpu_tower:thru', "双塔散热器的鳍片穿流方向应为 x（cpu.porous.thru = 'x'）");
  }
  let fans: unknown = 0;
  let pos: CpuFanPos[] = [];
  if (c.fan) {
    fans = c.fan.count === undefined || c.fan.count === null ? 1 : c.fan.count;
    if (!isNum(fans) || (fans !== 1 && fans !== 2)) {
      throw new LayoutError('layout_cpu_tower:fans', 'cpu.fan.count 应为 1 或 2');
    }
    const P: CpuFanPos[][] = stacks === 2 ? [['mid'], ['front', 'mid']] : [['front'], ['front', 'rear']];
    pos = P[fans - 1];
  }
  return { stacks, gapMm: gapMm as number, fans: fans as number, pos };
}

/** 设置 CPU 塔扇数量（1 或 2）；原来没有塔扇时按 Tower120 添加。返回新布局 */
export function layoutSetCpuFans(L: Layout, n: number): Layout {
  if (!L.cpu) throw new LayoutError('layout_set_cpu_fans:noCpu', '布局中没有 CPU');
  if (n !== 1 && n !== 2) throw new LayoutError('layout_set_cpu_fans:range', 'CPU 塔扇数量应为 1 或 2');
  const cpu = structuredClone(L.cpu);
  cpu.fan = cpu.fan ? { ...cpu.fan, count: n } : { model: 'Tower120', count: n };
  return { ...L, cpu };
}
