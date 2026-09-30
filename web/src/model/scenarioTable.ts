// 方案对比表（移植自 scenario_table.m）：行名与各方案的显示文字。
import { FAN_PRESETS } from './fans';
import { layoutGpuSlots } from './gpuSlots';
import type { Layout } from './types';

export interface ScenarioSummaryLike {
  cpu: number;
  gpu: number;
  psu: number;
  interior: number;
  cfm: number;
  intakeCfm: number;
  exhaustCfm: number;
  pressure: string;
  noiseDb: number;
  score: number;
  deadZonePct: number;
  nCaseFans: number;
  steps: number;
}

export interface ScenarioSnap {
  summary: ScenarioSummaryLike;
  label: string; // 布局名（预设 label、'自定义' 或 '配置 文件名'）
  layout: Layout;
  powers: [number, number, number];
  gridScale: number;
  steady: boolean;
}

const num1 = (x: number) => (Number.isNaN(x) ? '—' : x.toFixed(1));
const yesNo = (b: boolean) => (b ? '是' : '否');
/** MATLAB %g */
const g = (x: number) => String(Number(x.toPrecision(6)));

function shortLabel(label: string): string {
  const p = FAN_PRESETS.find((q) => q.label === label);
  if (p) return p.short;
  if (label.startsWith('配置 ')) {
    const f = label.slice(3);
    const base = f.replace(/^.*[\\/]/, '').replace(/\.[^.]*$/, '');
    return [...base].slice(0, 8).join('');
  }
  return label;
}

function slotsText(L: Layout): string {
  const sl = layoutGpuSlots(L);
  return Number.isNaN(sl) ? '—' : `${g(sl)} 槽`;
}

const hasGap = (L: Layout) => !!L.shroud && Array.isArray(L.shroud.gaps) && L.shroud.gaps.length > 0;

const ROWS: [string, (s: ScenarioSnap) => string][] = [
  ['CPU 结温 °C', (s) => num1(s.summary.cpu)],
  ['GPU 结温 °C', (s) => num1(s.summary.gpu)],
  ['电源 °C', (s) => num1(s.summary.psu)],
  ['箱内均温 °C', (s) => s.summary.interior.toFixed(1)],
  ['机箱风量 CFM', (s) => s.summary.cfm.toFixed(1)],
  ['标称进/排 CFM', (s) => `${s.summary.intakeCfm.toFixed(0)} / ${s.summary.exhaustCfm.toFixed(0)}`],
  ['压力', (s) => s.summary.pressure],
  ['噪音 dB(A)', (s) => s.summary.noiseDb.toFixed(1)],
  ['总分', (s) => String(s.summary.score)],
  ['死区 %', (s) => s.summary.deadZonePct.toFixed(1)],
  ['机箱风扇数', (s) => String(s.summary.nCaseFans)],
  ['布局', (s) => shortLabel(s.label)],
  ['挡板前部开孔', (s) => yesNo(hasGap(s.layout))],
  ['显卡厚度', (s) => slotsText(s.layout)],
  ['功率 C/G/P W', (s) => `${g(s.powers[0])}/${g(s.powers[1])}/${g(s.powers[2])}`],
  ['网格 · 步数', (s) => `${s.gridScale >= 1 ? '精确' : '预览'} · ${s.summary.steps}`],
  ['稳态', (s) => yesNo(s.steady)],
];

/** 行名与数据（行 × 方案，空位显示 "—"） */
export function scenarioTable(snaps: (ScenarioSnap | null)[]): { rowNames: string[]; data: string[][] } {
  return {
    rowNames: ROWS.map((r) => r[0]),
    data: ROWS.map(([, fmt]) => snaps.map((s) => (s ? fmt(s) : '—'))),
  };
}
