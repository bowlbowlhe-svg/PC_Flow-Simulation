// 布局工具函数与 Octave 对照（fixtures/layout.json，由 test/gen/gen_layout_fixtures.m 生成）：
// 风扇布局静态检查与标称风量、安装位状态、显卡槽数设置、CPU 塔式散热器结构与塔扇数量。
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { describe, expect, it } from 'vitest';
import { layoutFanReport } from '../src/model/fanReport';
import { getSlotStates } from '../src/model/fans';
import { layoutGpuSlots, layoutSetGpuSlots, LayoutError } from '../src/model/gpuSlots';
import { layoutDefault } from '../src/model/layoutDefault';
import { normalizeLayout } from '../src/model/layoutJson';
import { layoutCpuTower, layoutSetCpuFans } from '../src/model/cpuTower';
import { buildGeometry, GeometryError } from '../src/solver/geometry';
import type { Ref } from './refdata';

const here = dirname(fileURLToPath(import.meta.url));
const FX: Ref = JSON.parse(readFileSync(join(here, 'fixtures', 'layout.json'), 'utf8'));
const list = <T,>(v: T | T[]): T[] => (Array.isArray(v) ? v : v === undefined || v === null ? [] : [v]);

describe('layoutFanReport 与 Octave 一致', () => {
  for (const c of FX.reports as Ref[]) {
    it(c.name, () => {
      const L = normalizeLayout(c.layout);
      const R = layoutFanReport(L);
      expect(R.warnings).toEqual(list(c.report.warnings));
      for (const k of ['intakeCfm', 'exhaustCfm', 'intakeCfmIdle', 'exhaustCfmIdle', 'totalPrice'] as const) expect(R[k]).toBeCloseTo(c.report[k], 10);
      expect(R.pressure).toBe(c.report.pressure);
      expect(R.pressureIdle).toBe(c.report.pressureIdle);
      expect(R.nIntake).toBe(c.report.nIntake);
      expect(R.nExhaust).toBe(c.report.nExhaust);
      expect(getSlotStates(L)).toEqual(list(c.slots));
    });
  }
  it('自造布局覆盖了全部 4 类警告', () => {
    const w = list<string>(FX.reports.find((c: Ref) => c.name === 'custom_warnings').report.warnings).join('\n');
    for (const s of ['超出壁面', '重叠', '角部相碰', '与电源重叠']) expect(w).toContain(s);
  });
});

describe('显卡槽数', () => {
  for (const g of FX.gpuSlots as Ref[]) {
    it(`${g.slots} 槽`, () => {
      const L = layoutSetGpuSlots(layoutDefault(), g.slots);
      expect(g.ok).toBe(true);
      expect(L.gpu!.heatsink).toEqual(g.gpu.heatsink);
      expect(L.gpu!.pcb).toEqual(g.gpu.pcb);
      expect(L.gpu!.thermal.A_fin_total_m2).toBeCloseTo(g.gpu.thermal.A_fin_total_m2, 14);
      expect(layoutGpuSlots(L)).toBe(g.read);
    });
  }
  it('挡板上移后放不下：报错 id 与信息同 MATLAB', () => {
    const L = layoutDefault();
    L.shroud!.yMm = FX.shroudYMm;
    let err: unknown;
    try {
      layoutSetGpuSlots(L, 4);
    } catch (e) {
      err = e;
    }
    expect(err).toBeInstanceOf(LayoutError);
    expect((err as LayoutError).id).toBe(FX.shroudTooHigh.id);
    expect((err as LayoutError).message).toBe(FX.shroudTooHigh.message);
  });
});

describe('CPU 塔式散热器（layout_cpu_tower / layout_set_cpu_fans）', () => {
  for (const c of FX.cpuTower as Ref[]) {
    it(c.name, () => {
      const L = layoutDefault();
      L.cpu = structuredClone(c.cpu);
      if (c.ok) {
        expect(layoutCpuTower(L)).toEqual({ stacks: c.stacks, gapMm: c.gapMm, fans: c.fans, pos: list(c.pos) });
      } else {
        let err: unknown;
        try {
          layoutCpuTower(L);
        } catch (e) {
          err = e;
        }
        expect(err).toBeInstanceOf(LayoutError);
        expect((err as LayoutError).id).toBe(c.id);
        expect((err as LayoutError).message).toBe(c.message);
      }
    });
  }
  it('layoutSetCpuFans：改数量；原来没有塔扇时按 Tower120 添加；不改输入', () => {
    const L = layoutDefault();
    expect(layoutSetCpuFans(L, 1).cpu).toEqual(FX.setCpuFans.one);
    const N = layoutDefault();
    delete N.cpu!.fan;
    expect(layoutSetCpuFans(N, 2).cpu).toEqual(FX.setCpuFans.addFan);
    expect(L.cpu!.fan!.count).toBe(2);
    expect(() => layoutSetCpuFans(L, 3)).toThrow(LayoutError);
  });
  it('JSON 里写成 [] 或 null 的塔扇/塔字段按没写处理（同 MATLAB isempty）', () => {
    const base = layoutDefault() as unknown as Ref;
    const noFan = structuredClone(base);
    noFan.cpu.fan = [];
    const L1 = normalizeLayout(noFan);
    expect(L1.cpu!.fan).toBeUndefined();
    expect(buildGeometry(L1, 0.5).fans.filter((f) => f.role === 'cpu')).toHaveLength(0);
    const noCount = structuredClone(base);
    noCount.cpu.fan.count = [];
    noCount.cpu.tower.stacks = null;
    expect(layoutCpuTower(normalizeLayout(noCount))).toEqual({ stacks: 1, gapMm: 0, fans: 1, pos: ['front'] });
  });
  it('塔扇压到机箱壁、双塔放不下：报错同 MATLAB', () => {
    const rear = layoutDefault();
    delete rear.cpu!.tower;
    rear.cpu!.fins.x = 6; // 单塔推拉：鳍片离后壁太近
    const front = layoutDefault();
    front.cpu!.fins.x = 204; // 鳍片贴前壁
    const wide = layoutDefault();
    wide.cpu!.tower!.gapMm = 110; // 间隙太宽
    for (const [L, msg] of [
      [rear, 'CPU 塔扇（后）放不下：执行盘第 29–31 列压到机箱壁（壁内为第 32–109 列）'],
      [front, 'CPU 塔扇（前）放不下：执行盘第 109–111 列压到机箱壁（壁内为第 32–109 列）'],
      [wide, '双塔散热器在当前网格上放不下（鳍片外廓宽 28 格、间隙 28 格）'],
    ] as const) {
      expect(() => buildGeometry(L, 0.5)).toThrow(GeometryError);
      expect(() => buildGeometry(L, 0.5)).toThrow(msg);
    }
  });
  it('间隙比执行盘窄（预览 2 格 < 3 格）：中扇占满间隙、盘厚 = 间隙宽（同 MATLAB）', () => {
    const L = layoutDefault();
    L.cpu!.tower!.gapMm = 8;
    const g = buildGeometry(L, 0.5);
    const mid = g.fans.find((f) => f.pos === 'mid')!;
    expect(g.cpu!.gap).toEqual({ x: 52, y: 39, w: 2, h: 30 });
    expect(mid.cols).toEqual([52, 53]);
    expect(mid.thickM).toBe(0.008);
  });
  it('载入取值不合法的 cpu 字段：layout_json:invalid', () => {
    const L = layoutDefault() as unknown as Ref;
    L.cpu.fan.count = 3;
    expect(() => normalizeLayout(L)).toThrow(/CPU 散热器：cpu.fan.count 应为 1 或 2/);
  });
});

describe('布局规整与值语义（W0/W1 审计）', () => {
  it('applyPreset / setSlotStates / layoutSetGpuSlots 返回的布局不与输入共享嵌套对象', async () => {
    const { applyPreset, setSlotStates } = await import('../src/model/fans');
    const L = layoutDefault();
    const A = applyPreset(L, 'positive');
    A.chassis.wallTempC.rear = 99;
    A.gpu!.pcb.x = 1;
    expect(L.chassis.wallTempC.rear).not.toBe(99);
    expect(L.gpu!.pcb.x).not.toBe(1);
    const B = setSlotStates(L, getSlotStates(L));
    B.power.cpu = 1;
    expect(L.power.cpu).not.toBe(1);
    const G = layoutSetGpuSlots(L, 3);
    G.chassis.sizeMm = 1;
    expect(L.chassis.sizeMm).not.toBe(1);
  });
  it('机箱风扇显式的 null 转速字段报错（同 layout_json），缺字段补默认', () => {
    const raw = JSON.parse(JSON.stringify(layoutDefault()));
    raw.caseFans[0].manualPct = null;
    expect(() => normalizeLayout(raw)).toThrow(LayoutError);
    raw.caseFans[0].manualPct = 60;
    raw.caseFans[1].speedMode = null;
    expect(() => normalizeLayout(raw)).toThrow(LayoutError);
    delete raw.caseFans[1].speedMode;
    delete raw.caseFans[1].manualPct;
    const L = normalizeLayout(raw);
    expect(L.caseFans![1].speedMode).toBe('auto');
    expect(L.caseFans![1].manualPct).toBe(60);
  });
  it('节流温度为 null 或 [] 时按 tjmax − 15（MATLAB isempty）', async () => {
    const { Solver } = await import('../src/solver/solver');
    for (const v of [null, []]) {
      const raw = JSON.parse(JSON.stringify(layoutDefault()));
      raw.cpu.throttleTemp = v;
      const L = normalizeLayout(raw);
      expect(L.cpu!.throttleTemp).toBeUndefined();
      const s = new Solver(L, { gridScale: 0.5 });
      expect(s.thermalNetworks.cpu!.throttlingTemp).toBe(L.cpu!.tjmax - 15);
    }
  });
  it('通风口安装位未知时报错（MATLAB 同样报错）', async () => {
    const { buildGeometry, GeometryError } = await import('../src/solver/geometry');
    const L = layoutDefault();
    L.vents = [{ mount: 'side' as never, alongMm: 100, lengthMm: 40, zeta: 3 }];
    expect(() => buildGeometry(L, 0.5)).toThrow(GeometryError);
  });
  it('基准布局与 bench.json 嵌入的布局逐项相同（方腔的 ν 用正确舍入的 Lc³）', async () => {
    const { layoutBenchmark } = await import('../src/model/layoutBenchmark');
    const { loadRef } = await import('./refdata');
    const B = loadRef('bench');
    for (const c of B.cavity) expect(layoutBenchmark('cavity', c.Ra)).toEqual(normalizeLayout(c.layout));
    for (const d of B.duct) expect(layoutBenchmark('duct', d.zeta)).toEqual(normalizeLayout(d.layout));
  });
});

describe('计算域尺寸校验（最终审计）', () => {
  it('域过大、为 0 或负、机箱越出域时报错；现有各种布局都通过', async () => {
    const { layoutBenchmark } = await import('../src/model/layoutBenchmark');
    for (const L of [layoutDefault(), layoutBenchmark('duct', 20), layoutBenchmark('cavity', 1e5), layoutBenchmark('empty')])
      expect(() => normalizeLayout(JSON.parse(JSON.stringify(L)))).not.toThrow();
    const bad = (f: (L: ReturnType<typeof layoutDefault>) => void) => {
      const L = layoutDefault();
      f(L);
      return () => normalizeLayout(JSON.parse(JSON.stringify(L)));
    };
    expect(bad((L) => (L.domain.sizeMm = 8000))).toThrow(/20–400 格/);
    expect(bad((L) => (L.domain.sizeMm = 0))).toThrow(LayoutError);
    expect(bad((L) => ((L.domain as { sizeMm: unknown }).sizeMm = null))).toThrow(LayoutError);
    expect(bad((L) => (L.domain.baseCellMm = -2))).toThrow(LayoutError);
    expect(bad((L) => (L.chassis.originMm = 300))).toThrow(/机箱/);
  });

  it('矩形机箱：sizeMm/originMm 可为数或 [x y]，按 MATLAB 的 v(1)、v(end) 解释；两个方向分别检查是否越出域', async () => {
    const { pairMm, chassisSizeMm, chassisOriginMm } = await import('../src/model/chassis');
    expect(pairMm(400)).toEqual([400, 400]);
    expect(pairMm([400])).toEqual([400, 400]);
    expect(pairMm([320, 400])).toEqual([320, 400]);
    const L0 = layoutDefault();
    expect(chassisSizeMm(L0)).toEqual([320, 400]);
    expect(chassisOriginMm(L0)).toEqual([120, 80]);
    const bad = (f: (L: ReturnType<typeof layoutDefault>) => void) => {
      const L = layoutDefault();
      f(L);
      return () => normalizeLayout(JSON.parse(JSON.stringify(L)));
    };
    // 单元素数组（MATLAB 读回的 1×1）与标量等价
    expect(bad((L) => ((L.chassis.sizeMm = [400]), (L.chassis.originMm = [80])))).not.toThrow();
    expect(normalizeLayout(JSON.parse(JSON.stringify(L0))).chassis.sizeMm).toEqual([320, 400]);
    expect(bad((L) => (L.chassis.originMm = [120, 200]))).toThrow(/机箱/); // y 越出（200 + 400 > 560），x 不越出
    expect(bad((L) => (L.chassis.originMm = [300, 80]))).toThrow(/机箱/); // x 越出（300 + 320 > 560）
    expect(bad((L) => (L.chassis.sizeMm = [320, 0]))).toThrow(/机箱/);
    expect(bad((L) => (L.chassis.sizeMm = [320, 400, 500]))).toThrow(/机箱/);
    expect(bad((L) => ((L.chassis as { sizeMm: unknown }).sizeMm = [320, '400']))).toThrow(/机箱/);
    expect(bad((L) => ((L.chassis as { sizeMm: unknown }).sizeMm = []))).toThrow(/机箱/);
  });
});
