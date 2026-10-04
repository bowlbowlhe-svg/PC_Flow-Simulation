// 界面 ↔ 对比计算 Worker 的消息格式。
import type { CompareProtocol, PointMetrics, ScenarioKey, SweepPoint } from '../compare/protocol';
import type { FieldThumb } from '../compare/thumb';
import type { Layout } from '../model/types';

export type CompareCommand =
  | { type: 'start'; id: number; layout: Layout; scenarios: ScenarioKey[]; protocol: CompareProtocol }
  | { type: 'cancel'; id: number };

export type CompareMessage =
  | { type: 'progress'; id: number; scenario: ScenarioKey; index: number; count: number; done: number; total: number }
  | { type: 'case'; id: number; scenario: ScenarioKey; auto: PointMetrics; sweep: SweepPoint[]; thumb: FieldThumb }
  | { type: 'done'; id: number }
  | { type: 'cancelled'; id: number }
  | { type: 'error'; id: number; message: string };
