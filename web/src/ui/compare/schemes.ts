// 对比展示页的数据整理：方案（预设 + 自定义）× 场景的算例、指标定义、排名与配色。
import { COMPARE_SCENARIOS, interpAt, type ScenarioKey } from '../../compare/scenarios';
import type { PointMetrics, SweepPoint } from '../../compare/protocol';
import type { CompareData } from '../../compare/data';
import type { Thumb } from '../../compare/thumb';
import { FAN_PRESETS } from '../../model/fans';
import type { Layout } from '../../model/types';

/** 缩略图：预计算数据里是 PNG（异步解码），自定义方案直接是像素 */
export type ThumbSrc = Thumb | { w: number; h: number; png: string };

export interface CaseView {
  auto: PointMetrics;
  sweep: SweepPoint[];
  thumb: ThumbSrc;
}

export interface SchemeView {
  id: string; // 预设名或 custom-n
  label: string;
  short: string;
  kind: 'preset' | 'custom';
  fans: string; // 风扇配置说明
  gridScale: number;
  layout?: Layout; // 自定义方案的布局（"在仿真页打开"用）
  cases: Partial<Record<ScenarioKey, CaseView>>;
}

export interface CustomScheme {
  id: string;
  label: string;
  layout: Layout;
  gridScale: number;
  cases: Partial<Record<ScenarioKey, CaseView>>;
}

const SLOT_CN: Record<string, string> = { intake: '进', exhaust: '出' };

/** 预设的风扇说明，如"F2 F3 进 · R1 T1 出" */
function presetFans(name: string): string {
  const p = FAN_PRESETS.find((q) => q.name === name);
  if (!p) return '';
  const by = (t: string) => p.fans.filter((f) => f[1] === t).map((f) => f[0]);
  return (['intake', 'exhaust'] as const)
    .map((t) => (by(t).length ? `${by(t).join(' ')} ${SLOT_CN[t]}` : ''))
    .filter(Boolean)
    .join(' · ');
}

/** 自定义方案的风扇说明（按机箱风扇的安装壁与进/排气计数） */
export function layoutFans(L: Layout): string {
  const F = L.caseFans ?? [];
  const nIn = F.filter((f) => f.type === 'intake').length;
  const nOut = F.length - nIn;
  return `${nIn} 进 · ${nOut} 出`;
}

export function buildSchemes(data: CompareData, customs: CustomScheme[]): SchemeView[] {
  const out: SchemeView[] = FAN_PRESETS.map((p): SchemeView => {
    const cases: SchemeView['cases'] = {};
    for (const c of data.cases) if (c.preset === p.name) cases[c.scenario] = { auto: c.auto, sweep: c.sweep, thumb: c.thumb };
    return { id: p.name, label: p.label, short: p.short, kind: 'preset', fans: presetFans(p.name), gridScale: data.protocol.gridScale, cases };
  }).filter((s) => Object.keys(s.cases).length > 0);
  for (const c of customs)
    out.push({ id: c.id, label: c.label, short: c.label.replace(/（.*$/, ''), kind: 'custom', fans: layoutFans(c.layout), gridScale: c.gridScale, layout: c.layout, cases: c.cases });
  return out;
}

/** JSON 里的 null 读成 NaN */
export const n = (v: number | null | undefined) => (typeof v === 'number' ? v : NaN);

/** 有限值中的最大（都不是有限值时为 NaN） */
export const fmax = (...v: number[]) => {
  const f = v.filter(Number.isFinite);
  return f.length ? Math.max(...f) : NaN;
};

export interface MetricDef {
  key: string;
  label: string;
  unit: string;
  better: 'low' | 'high';
  digits: number;
  base?: number; // 条形图的起点（温度从环境温度起）
  get: (m: PointMetrics) => number;
}

export const METRICS: MetricDef[] = [
  { key: 'score', label: '评分', unit: '', better: 'high', digits: 0, base: 0, get: (m) => n(m.score) },
  { key: 'tmax', label: '最高结温', unit: '°C', better: 'low', digits: 1, base: 25, get: (m) => fmax(n(m.cpu), n(m.gpu)) },
  { key: 'cpu', label: 'CPU 结温', unit: '°C', better: 'low', digits: 1, base: 25, get: (m) => n(m.cpu) },
  { key: 'gpu', label: 'GPU 结温', unit: '°C', better: 'low', digits: 1, base: 25, get: (m) => n(m.gpu) },
  { key: 'noiseDb', label: '噪音', unit: 'dB(A)', better: 'low', digits: 1, base: 0, get: (m) => n(m.noiseDb) },
  { key: 'perfPct', label: '性能', unit: '%', better: 'high', digits: 1, base: 90, get: (m) => n(m.perfPct) },
  { key: 'interior', label: '机箱内温', unit: '°C', better: 'low', digits: 1, base: 25, get: (m) => n(m.interior) },
  { key: 'cfm', label: '机箱风量', unit: 'CFM', better: 'high', digits: 1, base: 0, get: (m) => n(m.cfm) },
  { key: 'airK', label: '机箱热阻', unit: '°C/100W', better: 'low', digits: 2, base: 0, get: (m) => n(m.airK) },
];

export const metricByKey = (k: string) => METRICS.find((m) => m.key === k) ?? METRICS[0];

/** 按指标排序（好的在前；缺数据的在最后） */
export function rankBy(schemes: SchemeView[], sc: ScenarioKey, m: MetricDef): SchemeView[] {
  const v = (s: SchemeView) => {
    const c = s.cases[sc];
    return c ? m.get(c.auto) : NaN;
  };
  return [...schemes].sort((a, b) => {
    const va = v(a);
    const vb = v(b);
    if (!Number.isFinite(va)) return 1;
    if (!Number.isFinite(vb)) return -1;
    return m.better === 'low' ? va - vb : vb - va;
  });
}

/** 方案配色（预设固定顺序，自定义接着排） */
const PAL = ['#59ccff', '#ff9940', '#80ff80', '#ff73bf', '#f2e64d', '#bfa6ff', '#4dffd9', '#ff8066', '#c0c0c0', '#a0d0ff', '#ffd0a0', '#d0ffa0'];
export const schemeColor = (k: number) => PAL[k % PAL.length];

/** 评分配色：0 红 → 50 黄 → 100 绿 */
export function scoreColor(v: number): string {
  if (!Number.isFinite(v)) return '#333';
  const t = Math.max(0, Math.min(1, v / 100));
  const h = 120 * t; // 0 红、60 黄、120 绿
  return `hsl(${h.toFixed(0)}, 55%, 32%)`;
}

export type FairMode = 'noise' | 'temp';

export interface FairRow {
  scheme: SchemeView;
  /** 同噪音：该噪音下的最高结温与性能；同温度：达到该温度所需的噪音 */
  value: number;
  perf: number;
  pct: number; // 对应的全局转速 [%]
  /** 同温度：最低一档转速已满足（value 为上界） */
  atMin: boolean;
  /** 所用扫描点有未完全稳态的（窗口内最高结温漂移 > 0.3°C） */
  unsettled: boolean;
}

/**
 * 公平比较：沿各方案的转速扫描（全局手动 40/70/100%）插值。同噪音 → 最高结温与性能；同温度（最高结温）→ 所需噪音。
 * 超出扫描范围（达不到）为 NaN。
 */
export function fairCompare(schemes: SchemeView[], sc: ScenarioKey, mode: FairMode, target: number): FairRow[] {
  const rows: FairRow[] = [];
  for (const s of schemes) {
    const c = s.cases[sc];
    if (!c || c.sweep.length < 2) continue;
    const sw = [...c.sweep].sort((a, b) => a.pct - b.pct);
    const noise = sw.map((p) => n(p.noiseDb));
    const tmax = sw.map((p) => fmax(n(p.cpu), n(p.gpu)));
    const perf = sw.map((p) => n(p.perfPct));
    const pct = sw.map((p) => p.pct);
    const unsettled = sw.some((p) => Math.abs(n(p.drift)) > 0.3);
    if (mode === 'noise') {
      const r = { scheme: s, value: interpAt(noise, tmax, target), perf: interpAt(noise, perf, target), pct: interpAt(noise, pct, target), atMin: false, unsettled };
      rows.push(r);
    } else {
      // 转速从低到高找第一个"最高结温 ≤ 目标"的位置（温度墙降频时低转速段结温持平，不能直接按温度插值）
      let r: FairRow = { scheme: s, value: NaN, perf: NaN, pct: NaN, atMin: false, unsettled };
      for (let i = 0; i < sw.length; i++) {
        if (!(tmax[i] <= target)) continue;
        if (i === 0) r = { scheme: s, value: noise[0], perf: perf[0], pct: pct[0], atMin: true, unsettled };
        else {
          const t = (tmax[i - 1] - target) / (tmax[i - 1] - tmax[i]);
          const lerp = (a: number[]) => a[i - 1] + t * (a[i] - a[i - 1]);
          r = { scheme: s, value: lerp(noise), perf: lerp(perf), pct: lerp(pct), atMin: false, unsettled };
        }
        break;
      }
      rows.push(r);
    }
  }
  // 小的在前；按显示精度（0.1）并列时性能高的在前（温度墙处结温都停在降频阈）
  const r1 = (v: number) => Math.round(v * 10);
  return rows.sort((a, b) => {
    if (!Number.isFinite(a.value)) return 1;
    if (!Number.isFinite(b.value)) return -1;
    if (r1(a.value) !== r1(b.value)) return a.value - b.value;
    return (Number.isFinite(b.perf) ? b.perf : -1) - (Number.isFinite(a.perf) ? a.perf : -1);
  });
}

export const SCENARIO_LABEL: Record<ScenarioKey, string> = Object.fromEntries(COMPARE_SCENARIOS.map((s) => [s.key, s.label])) as Record<ScenarioKey, string>;
