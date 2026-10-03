// v4.6.0 / web-1.4.0：芯片频率与功率（温度墙、加速频率、漏电）、风扇型号库与风扇定律噪音、温控曲线档位、
// 显卡低温停转与电源半被动、评分体系。同 MATLAB test_thermal.m、test_noise.m（1、2、8 节）、test_layout.m（4d 节）。
import { describe, expect, it } from 'vitest';
import { curveDuty, fanCurveProfiles, layoutDvfs, layoutFanCurves } from '../src/model/fanCurves';
import { FAN_CATALOG } from '../src/model/fans';
import { layoutDefault } from '../src/model/layoutDefault';
import { normalizeLayout } from '../src/model/layoutJson';
import { LayoutError } from '../src/model/gpuSlots';
import type { Layout } from '../src/model/types';
import { calculateScores, fanStatusList, getRecommendations, totalNoise } from '../src/solver/diagnostics';
import { fanNoiseTerms, type FanControl } from '../src/solver/fan';
import { Solver } from '../src/solver/solver';
import { ThermalNetwork } from '../src/solver/thermal';
import { stepYielding } from './refdata';

const settle = (n: ThermalNetwork, V: number, Tin: number) => {
  for (let k = 0; k < 4000; k++) n.solve(V, Tin, 0.005);
  return n;
};

describe('热网络：频率与功率控制（同 test_thermal）', () => {
  const L = layoutDefault();
  const d = layoutDvfs(L, 'cpu');
  const run = (P: number, V: number, Tin: number) => settle(new ThermalNetwork('cpu', P, L.cpu!.tjmax, L.cpu!.throttleTemp, L.cpu!.thermal, d), V, Tin);

  it('散热良好：只按加速频率降频，功率 = 动态 φ³ + 漏电，稳态自洽', () => {
    const n = run(125, 2.0, 30);
    const phiSoft = 1 - d.softSlope * Math.max(0, n.T_junction - d.softStartC);
    const Pexp = 125 * ((1 - d.leakShare) * n.freqRatio ** d.powerExp + d.leakShare * 2 ** ((n.T_junction - d.leakRefC) / d.leakDoubleC));
    expect(n.throttled).toBe(false);
    expect(Math.abs(n.freqRatio - phiSoft)).toBeLessThan(1e-6);
    expect(Math.abs(n.actualPower - Pexp)).toBeLessThan(1e-9);
    expect(Math.abs(n.T_junction - (30 + n.actualPower * n.R_total))).toBeLessThan(1e-4);
    expect(n.T_junction).toBeLessThan(L.cpu!.throttleTemp);
  });

  it('散热差：温度墙把结温压在降频阈；散热越好频率越高', () => {
    const n2 = run(250, 0.3, 45);
    const phiSoft2 = 1 - d.softSlope * Math.max(0, n2.T_junction - d.softStartC);
    expect(n2.throttled).toBe(true);
    expect(Math.abs(n2.T_junction - L.cpu!.throttleTemp)).toBeLessThan(0.05);
    expect(n2.freqRatio).toBeLessThan(phiSoft2 - 0.01);
    expect(run(250, 0.6, 45).freqRatio).toBeGreaterThan(n2.freqRatio);
  });

  it('漏电强、散热差（R·P ≈ 122 K）：温度墙仍把结温压在降频阈、不过热', () => {
    const n = run(250, 0, 40);
    expect(Math.abs(n.T_junction - L.cpu!.throttleTemp)).toBeLessThan(0.05);
    expect(n.overTemp).toBe(false);
    expect(n.freqRatio).toBeGreaterThan(d.minFreq + 0.02);
  });

  it('极差：降到最低频率仍压不住，置过热', () => {
    const n = run(300, 0, 85);
    expect(Math.abs(n.freqRatio - d.minFreq)).toBeLessThan(1e-6);
    expect(n.overTemp).toBe(true);
    expect(n.T_junction).toBeGreaterThan(L.cpu!.tjmax);
  });

  it('漏电：同频率下进风越热功率越大', () => {
    const d0 = { ...d, softSlope: 0 };
    const a = settle(new ThermalNetwork('cpu', 100, 200, 190, L.cpu!.thermal, d0), 2.0, 25);
    const b = settle(new ThermalNetwork('cpu', 100, 200, 190, L.cpu!.thermal, d0), 2.0, 45);
    expect(a.freqRatio).toBe(1);
    expect(b.freqRatio).toBe(1);
    expect(b.actualPower).toBeGreaterThan(a.actualPower + 1);
  });

  it('电源不降频', () => {
    const p = new ThermalNetwork('psu', 60, 100, 85, null);
    p.canThrottle = false;
    p.R_internal = 0.25;
    settle(p, 0.05, 40);
    expect(p.freqRatio).toBe(1);
    expect(p.actualPower).toBe(60);
    expect(p.overTemp).toBe(p.T_junction > 85);
  });

  it('求解器：300/500/1200 W 推进后显卡触发温度墙，满载档性能分下降并提示降频', async () => {
    const s = new Solver(layoutDefault(), { gridScale: 0.5, powers: { cpu: 300, gpu: 500, psu: 1200 } });
    s.turbUpdateEvery = 2;
    await stepYielding(s, 400); // 分段推进并让出事件循环（长时间同步运行会让 vitest 的进程通信超时）
    const g = s.thermalNetworks.gpu!;
    const sc = calculateScores(s);
    expect(g.throttled).toBe(true);
    expect(g.freqRatio).toBeLessThan(0.97);
    expect(Math.abs(g.T_junction - s.layout.gpu!.throttleTemp)).toBeLessThan(2);
    expect(sc.perf).toBeLessThan(100);
    expect(sc.cls).toBe('heavy');
    expect(getRecommendations(s).map((r) => r.title)).toContain('GPU触发温度墙降频');
  }, 60000);
});

describe('风扇噪音：分项、风扇定律（同 test_noise 1、2 节）', () => {
  const ac = layoutDefault().acoustics!;
  it('鳍片附加、可低于 0 dB、停转为 −Inf', () => {
    let p = fanNoiseTerms(20, 1, 0, ac.finDb, 0, ac);
    expect(p.total).toBeCloseTo(20 + ac.finDb, 12);
    expect(p.fin).toBe(ac.finDb);
    p = fanNoiseTerms(-8, 1, 0, 0, -3, ac);
    expect(p.total).toBe(-11); // 只对总噪音取 0 下限
    p = fanNoiseTerms(-Infinity, 0, 0, 2, 0, ac);
    expect(p.total).toBe(-Infinity);
  });

  it('风扇定律：满速 = noise_max，半速低 15.05 dB，转速不低于 rpm_min；NF-A12x25 1700 rpm ≈ 18.8 dB(A)', () => {
    const s = new Solver(layoutDefault(), { gridScale: 0.5 });
    const f = s.fans.find((x) => x.g.role === 'case' && x.spec === FAN_CATALOG.P12) ?? s.fans[0];
    const c: FanControl = { autoFanEnabled: false, fanSpeedRatio: 100, fanCurves: fanCurveProfiles('standard'), sensorTemp: () => 40, psuLoadRatio: () => 0.5 };
    f.speedMode = 'manual';
    f.manualPct = 100;
    const sp = f.spec;
    expect(Math.abs(f.baseNoise(c) - sp.noise_max)).toBeLessThan(1e-12);
    f.manualPct = 50;
    expect(f.getRPM(c)).toBe(0.5 * sp.rpm_max);
    expect(Math.abs(f.baseNoise(c) - (sp.noise_max - 50 * Math.log10(2)))).toBeLessThan(1e-12);
    f.manualPct = 1;
    expect(f.getRPM(c)).toBe(sp.rpm_min);
    const nf = FAN_CATALOG.NF_A12;
    expect(Math.abs(nf.noise_max + 50 * Math.log10(1700 / nf.rpm_max) - 18.8)).toBeLessThan(0.5);
  });
});

describe('显卡低温停转、电源半被动（同 test_noise 8 节）', () => {
  const s = new Solver(layoutDefault(), { gridScale: 0.5 });
  const C = fanCurveProfiles('standard');
  let T = 25;
  let load = 0.2;
  const c: FanControl = { autoFanEnabled: true, fanSpeedRatio: 40, fanCurves: C, sensorTemp: () => T, psuLoadRatio: () => load };

  it('显卡：45/52/56/52/49°C → 停/停/转/转/停；停转时转速、风量为 0，噪音 −Inf', () => {
    const g = s.fans.find((f) => f.g.role === 'gpu')!;
    g.stopped = false;
    const got = [45, 52, 56, 52, 49].map((t) => {
      T = t;
      g.updateControl(c);
      return g.isStopped(c);
    });
    expect(got).toEqual([true, true, false, false, true]);
    T = 45;
    expect(g.getRPM(c)).toBe(0);
    expect(g.getCFM(c)).toBe(0);
    expect(g.baseNoise(c)).toBe(-Infinity);
  });

  it('电源：负载 20% 时 50/62/66/58°C → 停/停/转/停；负载 ≥ 40% 一直转', () => {
    const p = s.fans.find((f) => f.g.role === 'psu')!;
    p.stopped = false;
    load = 0.2;
    const got = [50, 62, 66, 58].map((t) => {
      T = t;
      p.updateControl(c);
      return p.isStopped(c);
    });
    expect(got).toEqual([true, true, false, true]);
    load = 0.5;
    T = 40;
    p.updateControl(c);
    expect(p.isStopped(c)).toBe(false);
  });

  it('手动转速或关闭自动温控时不停转', () => {
    const g = s.fans.find((f) => f.g.role === 'gpu')!;
    T = 30;
    g.updateControl(c);
    expect(g.isStopped(c)).toBe(true);
    expect(g.isStopped({ ...c, autoFanEnabled: false })).toBe(false);
  });

  it('办公场景（40/35/200 W）：3 台显卡风扇与电源风扇停转、不计入噪音；办公档评分', async () => {
    const so = new Solver(layoutDefault(), { gridScale: 0.5, powers: { cpu: 40, gpu: 35, psu: 200 } });
    // 推进前即按初始温度判定（与第 1 步相同）
    expect(fanStatusList(so).filter((f) => f.stopped).map((f) => f.role)).toEqual(['gpu', 'gpu', 'gpu', 'psu']);
    so.turbUpdateEvery = 2;
    await stepYielding(so, 100);
    const fl = fanStatusList(so);
    const stopped = fl.filter((f) => f.stopped);
    expect(stopped.filter((f) => f.role === 'gpu').length).toBe(3);
    expect(stopped.some((f) => f.role === 'psu')).toBe(true);
    const { dbTotal, perFan } = totalNoise(so);
    fl.forEach((f, k) => f.stopped && expect(perFan[k]).toBe(-Infinity));
    expect(Number.isFinite(dbTotal)).toBe(true);
    const sc = calculateScores(so);
    expect(sc.cls).toBe('office');
    expect(sc.clsName).toBe('办公');
    // 办公档风扇都在最低转速，机箱热阻 K 偏大（推进 3 s 后约 5–7）：对数计分仍有区分度（不截到 0），也不提示风道效率偏低
    await stepYielding(so, 500);
    const sc3 = calculateScores(so);
    expect(sc3.airK).toBeGreaterThan(3);
    expect(sc3.airflow).toBeGreaterThan(0);
    expect(sc3.airflow).toBeLessThan(100);
    expect(getRecommendations(so).map((r) => r.title)).not.toContain('机箱风道效率偏低');
  }, 90000);
});

describe('温控曲线档位与型号别名（同 test_layout 4d 节）', () => {
  it('三个档位：曲线分段线性、端点外取端点值；显卡停转 / 电源半被动参数', () => {
    for (const k of ['quiet', 'standard', 'performance']) {
      const C = fanCurveProfiles(k);
      expect(C.profile).toBe(k);
      expect(curveDuty(C.caseFan, 0)).toBe(C.caseFan.duty[0]);
      expect(curveDuty(C.caseFan, 200)).toBe(1);
      expect(C.gpu.startAboveC! - C.gpu.stopBelowC!).toBe(5);
      expect(C.psu.passiveLoad).toBe(0.4);
    }
    const C = fanCurveProfiles('standard');
    expect(curveDuty(C.caseFan, 62.5)).toBeCloseTo(0.35, 12);
    expect(() => fanCurveProfiles('turbo')).toThrow(LayoutError);
  });

  it('旧布局（无 fanCurves、无 dvfs）按标准档与默认参数；旧型号名 RX120/RX140 读为 T30/M25_140', () => {
    const raw = JSON.parse(JSON.stringify(layoutDefault())) as Layout & Record<string, unknown>;
    delete raw.fanCurves;
    delete raw.cpu!.dvfs;
    raw.caseFans![0].model = 'RX120';
    raw.caseFans![1].model = 'RX140';
    const L = normalizeLayout(raw);
    expect(layoutFanCurves(L).profile).toBe('standard');
    expect(layoutDvfs(L, 'cpu')).toEqual(layoutDvfs(layoutDefault(), 'cpu'));
    expect(L.caseFans![0].model).toBe('T30');
    expect(L.caseFans![1].model).toBe('M25_140');
  });

  it('取值不合法的曲线与 dvfs：layout_json:invalid', () => {
    const bad = (mut: (L: Record<string, any>) => void) => {
      const raw = JSON.parse(JSON.stringify(layoutDefault()));
      mut(raw);
      return () => normalizeLayout(raw);
    };
    expect(bad((L) => (L.fanCurves.caseFan.T = [25, 20, 70, 80, 85]))).toThrow(LayoutError);
    expect(bad((L) => (L.fanCurves.cpu.duty = [0.2, 0.2, 0.5, 0.8, 1.5]))).toThrow(LayoutError);
    expect(bad((L) => (L.fanCurves.gpu.startAboveC = 40))).toThrow(LayoutError);
    expect(bad((L) => (L.fanCurves.psu.passiveLoad = 2))).toThrow(LayoutError);
    expect(bad((L) => delete L.fanCurves.psu)).toThrow(LayoutError);
    expect(bad((L) => (L.cpu.dvfs = { minFreq: 0 }))).toThrow(LayoutError);
    expect(bad((L) => (L.gpu.dvfs = { foo: 1 }))).toThrow(LayoutError);
    expect(bad((L) => (L.cpu.dvfs = { powerExp: 0.5 }))).toThrow(LayoutError);
    expect(bad((L) => (L.fanCurves.caseFan = null))).toThrow(LayoutError);
    expect(bad((L) => (L.cpu.dvfs = 5))).toThrow(LayoutError);
    expect(bad((L) => (L.fanCurves.gpu.stopBelowC = 'x'))).toThrow(LayoutError);
    expect(bad((L) => (L.fanCurves.caseFan.T = [25, null, 70, 80, 85]))).toThrow(LayoutError);
    expect(bad((L) => (L.fanCurves.caseFan.T = ['25', 55, 70, 80, 85]))).toThrow(LayoutError);
  });

  it('档位名与曲线不符或为空时记为 custom', () => {
    const raw = JSON.parse(JSON.stringify(layoutDefault()));
    raw.fanCurves = fanCurveProfiles('quiet');
    raw.fanCurves.profile = 'performance';
    expect(normalizeLayout(raw).fanCurves!.profile).toBe('custom');
    const L = layoutDefault();
    L.fanCurves!.profile = '';
    expect(layoutFanCurves(L).profile).toBe('custom');
    expect(layoutFanCurves(layoutDefault()).profile).toBe('standard');
  });
});
