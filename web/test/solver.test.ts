// 求解器与标准答案（matlab_app/tests/reference/fixed_*.json）逐步对照：README 第 2 级判据
// （温度 ≤ 1e−3°C，其余场 ≤ 1e−5 × 场最大绝对值；装配步逐一相同）。
import { describe, expect, it } from 'vitest';
import { loadRef } from './refdata';
import { compareScalars, compareSnapshot, fmt, makeSolver } from './solverCompare';

function runCase(name: string, pressureSolver: 'direct' | 'pcg', maxStep = Infinity) {
  const ref = loadRef(name);
  const s = makeSolver(ref, pressureSolver);
  for (const snap of ref.snapshots) {
    if (snap.step > maxStep) break;
    s.stepMultiple(snap.step - s.iteration);
    const bad = [...compareSnapshot(s, snap), ...compareScalars(s, snap)].filter((d) => !d.ok);
    expect(bad.map((d) => `step ${snap.step}: ${fmt(d)}`)).toEqual([]);
  }
}

describe('求解器快照对照（第 1/10/13/200 步）', () => {
  it('fixed_default（默认布局与功率，140²）', () => runCase('fixed_default', 'direct'));
  it('fixed_duct（直风道 ζ = 20，140²）', () => runCase('fixed_duct', 'direct'));
  it('压力用 PCG 时前 13 步同样一致', () => runCase('fixed_default', 'pcg', 13));
});
