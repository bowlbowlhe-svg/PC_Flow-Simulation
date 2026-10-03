// 自动温控风扇曲线与芯片频率/功率参数：移植自 fan_curve_profiles.m、layout_fan_curves.m、layout_dvfs.m。
import { LayoutError } from './gpuSlots';
import type { Dvfs, FanCurve, FanCurves, Layout } from './types';

export type FanProfile = 'quiet' | 'standard' | 'performance';
export const FAN_PROFILES: FanProfile[] = ['quiet', 'standard', 'performance'];
export const FAN_PROFILE_LABELS: Record<string, string> = { quiet: '静音', standard: '标准', performance: '性能' };

const crv = (T: number[], duty: number[]): FanCurve => ({ T, duty });

/**
 * 温控曲线档位（同 fan_curve_profiles.m）。机箱风扇跟 CPU/GPU 较高者，塔扇跟 CPU，显卡风扇跟 GPU（低温停转，回差），
 * 电源风扇跟电源温度（低负载半被动，回差）。转速 = max(rpm_min, duty·rpm_max)。
 */
export function fanCurveProfiles(name: string = 'standard'): FanCurves {
  let cs: FanCurve;
  let g: FanCurve;
  let p: FanCurve;
  switch (name) {
    case 'quiet':
      cs = crv([25, 60, 75, 85, 90], [0.2, 0.2, 0.45, 0.75, 1.0]);
      g = { ...crv([60, 75, 83, 90], [0.3, 0.45, 0.7, 1.0]), stopBelowC: 55, startAboveC: 60 };
      p = crv([25, 60, 75, 85, 90], [0.2, 0.2, 0.45, 0.75, 1.0]);
      break;
    case 'standard':
      cs = crv([25, 55, 70, 80, 85], [0.2, 0.2, 0.5, 0.8, 1.0]);
      g = { ...crv([55, 70, 80, 87], [0.3, 0.5, 0.75, 1.0]), stopBelowC: 50, startAboveC: 55 };
      p = crv([25, 55, 70, 80, 85], [0.2, 0.2, 0.5, 0.8, 1.0]);
      break;
    case 'performance':
      cs = crv([25, 45, 60, 70, 80], [0.3, 0.35, 0.6, 0.85, 1.0]);
      g = { ...crv([50, 65, 75, 85], [0.35, 0.6, 0.85, 1.0]), stopBelowC: 45, startAboveC: 50 };
      p = crv([25, 45, 60, 70, 80], [0.3, 0.35, 0.6, 0.85, 1.0]);
      break;
    default:
      throw new LayoutError('fan_curve_profiles:unknown', `未知风扇曲线档位：${name}（应为 quiet/standard/performance）`);
  }
  p = { ...p, passiveLoad: 0.4, passiveMaxC: 60, passiveRestartC: 65 };
  return { profile: name, caseFan: cs, cpu: structuredClone(cs), gpu: g, psu: p };
}

const isNum = (v: unknown): v is number => typeof v === 'number' && Number.isFinite(v);
/** 非空（同 MATLAB ~isempty：null、[]、'' 都算空） */
const has = (v: unknown) => v !== undefined && v !== null && v !== '' && !(Array.isArray(v) && v.length === 0);

const OPT_KEYS = ['stopBelowC', 'startAboveC', 'passiveLoad', 'passiveMaxC', 'passiveRestartC'] as const;
const isObj = (v: unknown): v is Record<string, unknown> => typeof v === 'object' && v !== null && !Array.isArray(v);

/**
 * 布局的温控曲线（缺省为标准档），并检查取值（同 layout_fan_curves.m）。
 * 档位名 profile 只在曲线与该档（quiet/standard/performance）完全相同时保留，否则记为 'custom'。
 */
export function layoutFanCurves(L: Layout): FanCurves {
  if (!has(L.fanCurves)) return fanCurveProfiles('standard');
  if (!isObj(L.fanCurves)) throw new LayoutError('layout_fan_curves:field', 'fanCurves 应为包含 caseFan/cpu/gpu/psu 曲线的结构体');
  const C = structuredClone(L.fanCurves) as FanCurves & Record<string, unknown>;
  for (const k of ['caseFan', 'cpu', 'gpu', 'psu'] as const) {
    const c = C[k] as unknown;
    if (!isObj(c) || !('T' in c) || !('duty' in c)) throw new LayoutError('layout_fan_curves:field', `fanCurves 缺少 ${k} 曲线（需要 T 与 duty）`);
    // 单个数读回时不是数组（同 MATLAB 标量）
    const T = (Array.isArray(c.T) ? c.T : [c.T]) as unknown[];
    const d = (Array.isArray(c.duty) ? c.duty : [c.duty]) as unknown[];
    const bad =
      T.length < 2 || T.length !== d.length ||
      T.some((x, i) => !isNum(x) || (i > 0 && !(x - (T[i - 1] as number) > 0))) || d.some((x) => !isNum(x) || x < 0 || x > 1);
    if (bad) throw new LayoutError('layout_fan_curves:value', `fanCurves.${k}：T 应严格递增，duty 应在 0–1，两者等长且至少 2 点`);
    c.T = T;
    c.duty = d;
  }
  const g = C.gpu;
  if (has(g.stopBelowC) && (!isNum(g.stopBelowC) || !isNum(g.startAboveC) || g.startAboveC < g.stopBelowC)) {
    throw new LayoutError('layout_fan_curves:value', 'fanCurves.gpu：低温停转需要 startAboveC ≥ stopBelowC（有限的数）');
  }
  const p = C.psu;
  if (
    has(p.passiveLoad) &&
    (!isNum(p.passiveLoad) || p.passiveLoad < 0 || p.passiveLoad > 1 || !isNum(p.passiveMaxC) || !isNum(p.passiveRestartC) || p.passiveRestartC < p.passiveMaxC)
  ) {
    throw new LayoutError('layout_fan_curves:value', 'fanCurves.psu：半被动需要 0 ≤ passiveLoad ≤ 1、passiveRestartC ≥ passiveMaxC（有限的数）');
  }
  // 档位名：与该档曲线逐项相同才保留（避免"标着性能、按静音运行"）
  const prof = C.profile as unknown;
  C.profile = typeof prof === 'string' && (FAN_PROFILES as string[]).includes(prof) && sameCurves(C, fanCurveProfiles(prof)) ? prof : 'custom';
  return C;
}

function sameCurves(A: FanCurves, B: FanCurves): boolean {
  for (const k of ['caseFan', 'cpu', 'gpu', 'psu'] as const) {
    const a = A[k];
    const b = B[k];
    if (a.T.length !== b.T.length || a.T.some((x, i) => x !== b.T[i])) return false;
    if (a.duty.length !== b.duty.length || a.duty.some((x, i) => x !== b.duty[i])) return false;
    for (const o of OPT_KEYS) {
      const ha = has(a[o]);
      if (ha !== has(b[o]) || (ha && a[o] !== b[o])) return false;
    }
  }
  return true;
}

/** 温控曲线 T → duty：点间线性插值，两端取端点值；T 为 NaN 时取最低占空比（同 Fan.curveDuty） */
export function curveDuty(c: FanCurve, T: number): number {
  const x = c.T;
  const v = c.duty;
  const n = x.length;
  if (!(T > x[0])) return v[0];
  if (T >= x[n - 1]) return v[n - 1];
  let i = 0;
  while (!(T <= x[i + 1])) i++;
  const t = (T - x[i]) / (x[i + 1] - x[i]);
  return v[i] + t * (v[i + 1] - v[i]);
}

/** CPU/GPU 频率与功率参数（布局 dvfs 与默认值合并，同 layout_dvfs.m） */
export function layoutDvfs(L: Layout, name: 'cpu' | 'gpu'): Dvfs {
  const def: Dvfs = { softStartC: 60, softSlope: 0.001, minFreq: 0.5, powerExp: 3, leakShare: 0.15, leakRefC: 70, leakDoubleC: 25 };
  if (name === 'gpu') {
    def.softStartC = 50;
    def.leakShare = 0.1;
  }
  let d: Dvfs = def;
  const user = L[name]?.dvfs as unknown;
  if (has(user)) {
    if (!isObj(user)) throw new LayoutError('layout_dvfs:field', `${name}.dvfs 应为结构体（字段见 layout_dvfs）`);
    const extra = Object.keys(user).filter((k) => !(k in def)).sort();
    if (extra.length) throw new LayoutError('layout_dvfs:field', `${name}.dvfs 中有未知字段：${extra.join(', ')}`);
    d = { ...def, ...(user as Partial<Dvfs>) };
  }
  const ok =
    isNum(d.softStartC) && isNum(d.softSlope) && d.softSlope >= 0 && isNum(d.minFreq) && d.minFreq > 0 && d.minFreq <= 1 &&
    isNum(d.powerExp) && d.powerExp >= 1 && isNum(d.leakShare) && d.leakShare >= 0 && d.leakShare < 1 && isNum(d.leakRefC) &&
    isNum(d.leakDoubleC) && d.leakDoubleC > 0;
  if (!ok) {
    throw new LayoutError(
      'layout_dvfs:value',
      `${name}.dvfs 取值不合法（softSlope ≥ 0，0 < minFreq ≤ 1，powerExp ≥ 1，0 ≤ leakShare < 1，leakDoubleC > 0，均为有限的数）`,
    );
  }
  return d;
}
