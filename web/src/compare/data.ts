// 对比展示页的数据：预计算结果（data.json，由 scripts/compareData.ts 生成）与界面后台计算的自定义方案同一格式。
import type { CompareProtocol, PointMetrics, ScenarioKey, SweepPoint } from './protocol';
import type { StoredThumb } from './thumb';

export interface CompareCase {
  /** 预设名（FAN_PRESETS 的 name）或自定义方案的 id */
  preset: string;
  scenario: ScenarioKey;
  auto: PointMetrics;
  sweep: SweepPoint[];
  /** 流场图：自动温控阶段统计窗口内的时均场（见 thumb.ts） */
  thumb: StoredThumb;
}

export interface CompareData {
  version: 2;
  generated: string; // 生成日期
  protocol: CompareProtocol;
  cases: CompareCase[];
}

/** 某方案某场景的算例 */
export function findCase(d: CompareData, preset: string, scenario: ScenarioKey): CompareCase | undefined {
  return d.cases.find((c) => c.preset === preset && c.scenario === scenario);
}

/** JSON 里的 null（NaN）读成 NaN */
export const num = (v: number | null | undefined) => (typeof v === 'number' ? v : NaN);
