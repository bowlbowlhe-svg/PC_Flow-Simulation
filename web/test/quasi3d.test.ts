// v4.8.0 / web-1.6.0：准三维修正（零件只占部分深度 → 多孔区）、机箱壁散热、鳍片换热（h 参数、穿流方向风速）、
// 取值检查与旧配置迁移。同 MATLAB test_quasi3d.m。
import { describe, expect, it } from 'vitest';
import { layoutDefault } from '../src/model/layoutDefault';
import { layoutBenchmark } from '../src/model/layoutBenchmark';
import { layoutToJson, normalizeLayout, type LayoutMigration } from '../src/model/layoutJson';
import { layoutHeatCoef, partialZeta } from '../src/model/quasi3d';
import { gpuFinArea, layoutSetGpuSlots } from '../src/model/gpuSlots';
import { layoutDvfs } from '../src/model/fanCurves';
import type { Layout } from '../src/model/types';
import { buildGeometry, OBSTACLE } from '../src/solver/geometry';
import { AIR_CP, AIR_DENSITY } from '../src/solver/constants';
import { Solver } from '../src/solver/solver';
import { ThermalNetwork } from '../src/solver/thermal';

const L0 = layoutDefault();
const cells = (g: ReturnType<typeof buildGeometry>, r: { x: number; y: number; w: number; h: number }) => {
  const out: number[] = [];
  for (let x = r.x; x <= r.x + r.w - 1; x++) for (let y = r.y; y <= r.y + r.h - 1; y++) out.push((x - 1) * g.W + (y - 1));
  return out;
};

describe('部分遮挡（Z 向占比）', () => {
  it('ζ = (0.5z + z²)/(1 − z)²', () => {
    expect(partialZeta(0.8)).toBeCloseTo(26, 12);
    expect(partialZeta(0.2)).toBeCloseTo(0.21875, 14);
  });

  it('默认布局的显卡 PCB、内存、VRM 为多孔区；z = 1 时为障碍（旧模型）', () => {
    const g = buildGeometry(L0, 0.5);
    const pcb = cells(g, g.gpu!.pcb);
    const ram = cells(g, g.ram[0]);
    const vrm = cells(g, g.vrm!);
    for (const i of [...pcb, ...ram, ...vrm]) expect(g.obstacle[i]).toBe(0);
    const zt = g.porousZones.map((z) => z.zetaThru);
    expect(zt.filter((v) => Math.abs(v - partialZeta(0.8)) < 1e-12).length).toBe(1);
    expect(zt.filter((v) => Math.abs(v - partialZeta(0.2)) < 1e-12).length).toBe(5);
    for (const i of g.heatObsIdx) expect(g.obstacle[i]).toBe(OBSTACLE.PSU_CASE);
    const L1: Layout = { ...structuredClone(L0), zShare: { gpu: 1, ram: 1, vrm: 1 } };
    const g1 = buildGeometry(L1, 0.5);
    for (const i of pcb) expect(g1.obstacle[i]).toBe(OBSTACLE.GPU_PCB);
    for (const i of ram) expect(g1.obstacle[i]).toBe(OBSTACLE.RAM_SLOT);
    for (const i of vrm) expect(g1.obstacle[i]).toBe(OBSTACLE.VRM);
    expect(g1.porousZones.length).toBe(g.porousZones.length - 6);
  });
});

describe('机箱壁散热', () => {
  const g = buildGeometry(L0, 0.5);
  const co = g.CASE2D.outer;
  const rc = AIR_DENSITY * AIR_CP;
  const kSide = (2 * L0.chassis.panelU!.side) / (rc * L0.chassis.depthM);
  const kEdge = L0.chassis.panelU!.edge / (rc * (g.cellMm / 1000));
  const decayOf = (gg: typeof g, i: number) => {
    const k = Array.from(gg.wallLossIdx).indexOf(i);
    return k >= 0 ? gg.wallLossDecay[k] : NaN;
  };
  const iMid = (co.x + 40 - 1) * g.W + (co.y + 20 - 1);
  const iTop = (co.x + 40 - 1) * g.W + (co.y + 1 - 1);

  it('侧板 + 贴壁边的衰减因子；电源外壳内不散热；都在机箱内', () => {
    expect(g.wallLossIdx.length).toBe(6749);
    expect(Math.abs(decayOf(g, iMid) - Math.exp(-kSide * g.DT))).toBeLessThan(1e-15);
    expect(Math.abs(decayOf(g, iTop) - Math.exp(-(kEdge + kSide) * g.DT))).toBeLessThan(1e-15);
    const psu = new Set(g.psuInteriorIdx);
    const inside = new Set(g.insideMask);
    for (const i of g.wallLossIdx) {
      expect(psu.has(i)).toBe(false);
      expect(inside.has(i)).toBe(true);
    }
  });

  it('缺 chassis.panelU 时没有；定温壁旁只有侧板散热', () => {
    expect(buildGeometry(layoutBenchmark('cavity', 1e4), 0.5).wallLossIdx.length).toBe(0);
    const Ld = structuredClone(L0);
    Ld.chassis.wallTempC.top = 25;
    expect(Math.abs(decayOf(buildGeometry(Ld, 0.5), iTop) - Math.exp(-kSide * g.DT))).toBeLessThan(1e-15);
  });
});

describe('鳍片换热', () => {
  const th = L0.gpu!.thermal;
  it('h = h_free + h_forced·V^h_exp；缺字段为旧式 30 + 130·V', () => {
    const n = new ThermalNetwork('gpu', 100, 95, 87, th, layoutDvfs(L0, 'gpu'));
    n.solve(1, 30, 0.005);
    expect(Math.abs(n.h_conv - (th.h_free! + th.h_forced!))).toBeLessThan(1e-12);
    const { h_free, h_forced, h_exp, ...old } = th;
    void h_free;
    void h_forced;
    void h_exp;
    const n0 = new ThermalNetwork('gpu', 100, 95, 87, old, layoutDvfs(L0, 'gpu'));
    n0.solve(0.5, 30, 0.005);
    expect(Math.abs(n0.h_conv - (30 + 130 * 0.5))).toBeLessThan(1e-12);
    expect(n0.heat!.legacy).toBe(true);
    expect(() => layoutHeatCoef({ ...th, h_exp: undefined }, 'gpu')).toThrow();
  });

  it('停转时的换热风速比例：停转乘 passiveFlowShare，转动或没有风扇为 1', () => {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const ps = (s: Solver, role: 'cpu' | 'gpu') => (s as any).passiveScale(s.thermalNetworks[role], role);
    const s = new Solver(L0, { gridScale: 0.5 }); // 构建时显卡风扇停转（结温 = 环境温度）
    expect(ps(s, 'gpu')).toBe(th.passiveFlowShare);
    expect(ps(s, 'cpu')).toBe(1);
    s.autoFanEnabled = false;
    expect(ps(s, 'gpu')).toBe(1);
    const Ln = structuredClone(L0);
    delete (Ln.gpu as unknown as Record<string, unknown>).fans;
    expect(ps(new Solver(Ln, { gridScale: 0.5 }), 'gpu')).toBe(1);
  });

  it('换热风速取穿流分量：横向流不计入 GPU 鳍片（穿流 y），CPU 鳍片（穿流 x）照计', () => {
    const s = new Solver(L0, { gridScale: 0.5 });
    s.uF.fill(0.5 / s.VEL_SCALE);
    for (let k = 0; k < s.uF.length; k++) if (!s.geo.uFaceActive[k]) s.uF[k] = 0;
    s.vF.fill(0);
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    (s as any).solveConjugateHeatTransfer(s.getCellVelocity());
    expect(Math.abs(s.thermalNetworks.gpu!.h_conv - th.h_free!)).toBeLessThan(1e-12);
    expect(s.thermalNetworks.cpu!.h_conv).toBeGreaterThan(L0.cpu!.thermal.h_free! + 1);
    // 旧模型（三个 h 参数都不给）：换热风速取风速模
    const Lg = structuredClone(L0);
    const { h_free, h_forced, h_exp, passiveFlowShare, ...oldTh } = Lg.gpu!.thermal;
    void [h_free, h_forced, h_exp, passiveFlowShare];
    Lg.gpu!.thermal = oldTh;
    Lg.gpu!.ioBlock = false; // 挡板端实心块旁的鳍片格有一面封闭，格心风速不是 0.5；这里只看换热式
    const sg = new Solver(Lg, { gridScale: 0.5 });
    sg.uF.fill(0.5 / sg.VEL_SCALE);
    for (let k = 0; k < sg.uF.length; k++) if (!sg.geo.uFaceActive[k]) sg.uF[k] = 0;
    sg.vF.fill(0);
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    (sg as any).solveConjugateHeatTransfer(sg.getCellVelocity());
    expect(Math.abs(sg.thermalNetworks.gpu!.h_conv - (30 + 130 * 0.5))).toBeLessThan(1e-9);
  });
});

describe('取值检查与旧配置迁移', () => {
  it('v4.9.0 的新字段：gpu.ioBlock、shroud.lengthMm、acoustics 的底噪与时转时停参数（同 MATLAB test_layout 5c）', () => {
    const raw = (f: (L: Record<string, any>) => void) => {
      const L = JSON.parse(layoutToJson(L0));
      f(L);
      return normalizeLayout(L);
    };
    // MATLAB 可写成 0/1、单元素数组（jsondecode 读成标量）；[] / null 为缺省
    expect(raw((L) => (L.gpu.ioBlock = 0)).gpu!.ioBlock).toBe(false);
    expect(raw((L) => (L.gpu.ioBlock = [true])).gpu!.ioBlock).toBe(true);
    expect('ioBlock' in raw((L) => (L.gpu.ioBlock = [])).gpu!).toBe(false);
    expect(raw((L) => (L.shroud.lengthMm = [200])).shroud!.lengthMm).toBe(200);
    expect('lengthMm' in raw((L) => (L.shroud.lengthMm = null)).shroud!).toBe(false);
    const bad: ((L: Record<string, any>) => void)[] = [
      (L) => (L.gpu.ioBlock = 2),
      (L) => (L.gpu.ioBlock = 'yes'),
      (L) => (L.shroud.lengthMm = 0),
      (L) => (L.shroud.lengthMm = -5),
      (L) => (L.shroud.lengthMm = 'x'),
    ];
    for (const f of bad) expect(() => raw(f)).toThrow();
    // 噪音参数同其它 acoustics 字段，在构建求解器时检查（mergeAcoustics；界面上报"重建失败"）
    const badAc: ((L: Record<string, any>) => void)[] = [
      (L) => (L.acoustics.floorDb = 'x'),
      (L) => (L.acoustics.intermittentDb = -1),
      (L) => (L.acoustics.cycleWindowS = 0),
    ];
    for (const f of badAc) expect(() => new Solver(raw(f), { gridScale: 0.5 })).toThrow();
    // 缺新字段的旧配置：acoustics 补默认值，ioBlock、lengthMm 保持缺省（旧几何）
    const old = raw((L) => {
      delete L.acoustics.floorDb;
      delete L.acoustics.intermittentDb;
      delete L.acoustics.cycleWindowS;
      delete L.gpu.ioBlock;
      delete L.shroud.lengthMm;
    });
    expect(new Solver(old, { gridScale: 0.5 }).geo.acoustics).toEqual(L0.acoustics);
    expect(old.gpu!.ioBlock).toBeUndefined();
    expect(old.shroud!.lengthMm).toBeUndefined();
  });
  it('不合法的 zShare、panelU、h_exp 报错', () => {
    const bad: ((L: Layout) => void)[] = [
      (L) => (L.zShare = { gpu: 0 }),
      (L) => (L.zShare = { gpu: 0.5, cpu: 0.5 } as never),
      (L) => (L.zShare = { gpu: 0.97 }),
      (L) => (L.zShare = 0.8 as never),
      (L) => (L.chassis.panelU!.side = -1),
      (L) => (L.gpu!.thermal.h_exp = 3),
    ];
    for (const f of bad) {
      const L = structuredClone(L0);
      f(L);
      expect(() => new Solver(L, { gridScale: 0.5 })).toThrow();
      expect(() => normalizeLayout(JSON.parse(layoutToJson(L)))).toThrow();
    }
  });

  it('热参数都是 v4.7 默认值时整体升级；改过的整个文件保持 v4.7 模型；基准布局不迁移', () => {
    const Lo = structuredClone(L0) as Layout & Record<string, unknown>;
    delete Lo.chassis.panelU;
    Lo.chassis.wallTempC = { rear: 25, front: 25, top: 25, bottom: 25 };
    delete Lo.zShare;
    Lo.cpu!.thermal = { R_junction_to_case: 0.15, R_tim: 0.04, R_base: 0.05, fin_thickness_mm: 0.4, A_fin_total_m2: 0.15 };
    Lo.gpu!.thermal = { R_junction_to_case: 0.08, R_tim: 0.02, R_base: 0.02, fin_thickness_mm: 0.35, A_fin_total_m2: (0.5 * L0.gpu!.heatsink.h) / 47 };
    Lo.gpu!.porous = { zetaThru: 4, zetaCross: 10, thru: 'x' };
    const load = (L: Layout) => {
      const info: { migration?: LayoutMigration } = {};
      return { L: normalizeLayout(JSON.parse(layoutToJson(L)), info), m: info.migration };
    };
    const a = load(Lo);
    expect(a.m).toBe('v48');
    expect(Number.isNaN(a.L.chassis.wallTempC.top)).toBe(true);
    expect(a.L.chassis.panelU).toEqual(L0.chassis.panelU);
    expect(a.L.zShare).toEqual(L0.zShare);
    expect(a.L.cpu!.thermal).toEqual(L0.cpu!.thermal);
    expect(a.L.gpu!.thermal).toEqual(L0.gpu!.thermal);
    expect(a.L.gpu!.porous).toEqual(L0.gpu!.porous);
    const L35 = layoutSetGpuSlots(Lo, 3.5); // 旧模型布局改槽数：仍按旧标定 0.5·h/47
    expect(Math.abs(L35.gpu!.thermal.A_fin_total_m2 - (0.5 * 47) / 47)).toBeLessThan(1e-15);
    expect(Math.abs(layoutSetGpuSlots(L0, 3.5).gpu!.thermal.A_fin_total_m2 - gpuFinArea(47))).toBeLessThan(1e-15);
    const b = load(L35);
    expect(b.m).toBe('v48');
    expect(Math.abs(b.L.gpu!.thermal.A_fin_total_m2 - gpuFinArea(47))).toBeLessThan(1e-15);
    const variants: ((L: Layout) => void)[] = [(L) => (L.cpu!.thermal.R_tim = 0.05), (L) => (L.gpu!.porous.zetaCross = 12)];
    for (const v of variants) {
      const Lk = structuredClone(Lo);
      v(Lk);
      Lk.chassis.wallTempC.rear = 30;
      const c = load(Lk);
      expect(c.m).toBe('legacy');
      expect(c.L.chassis.panelU).toBeUndefined();
      expect(c.L.zShare).toBeUndefined();
      expect(c.L.chassis.wallTempC.top).toBe(25);
      expect(c.L.chassis.wallTempC.rear).toBe(30);
      expect(c.L.cpu!.thermal).toEqual(Lk.cpu!.thermal);
      expect(c.L.gpu!.porous).toEqual(Lk.gpu!.porous);
    }
    expect(load(layoutBenchmark('cavity', 1e4)).m).toBe('none');
    // 新版配置往返不变
    expect(normalizeLayout(JSON.parse(layoutToJson(L0)))).toEqual(L0);
  });
});
