// 求解器与标准答案（matlab_app/tests/reference/fixed_*.json）逐步对照：README 第 2 级判据
// （温度 ≤ 1e−3°C，其余场 ≤ 1e−5 × 场最大绝对值；装配步逐一相同）。
import { describe, expect, it } from 'vitest';
import { loadRef, stepYielding } from './refdata';
import { compareDiagnostics, compareDisplayFields, compareScalars, compareSnapshot, fmt, makeSolver } from './solverCompare';

async function runCase(name: string, pressureSolver: 'direct' | 'pcg', maxStep = Infinity) {
  const ref = loadRef(name);
  const s = makeSolver(ref, pressureSolver);
  for (const snap of ref.snapshots) {
    if (snap.step > maxStep) break;
    await stepYielding(s, snap.step - s.iteration);
    const all = [...compareSnapshot(s, snap), ...compareScalars(s, snap), ...compareDiagnostics(s, snap)];
    if (snap.step === ref.steps) all.push(...compareDisplayFields(s, ref.fields));
    const bad = all.filter((d) => !d.ok);
    expect(bad.map((d) => `step ${snap.step}: ${fmt(d)}`)).toEqual([]);
  }
  if (maxStep >= ref.steps) {
    // 数据集顶层 scalars 即第 steps 步的标量
    const bad = compareDiagnostics(s, { scalars: ref.scalars }).filter((d) => !d.ok);
    expect(bad.map(fmt)).toEqual([]);
  }
}

describe('求解器快照对照（第 1/10/13/200 步）', () => {
  it('fixed_default（默认布局与功率，140²）', () => runCase('fixed_default', 'direct'));
  it('fixed_duct（直风道 ζ = 20，140²）', () => runCase('fixed_duct', 'direct'));
  it('压力用 PCG 时前 13 步同样一致', () => runCase('fixed_default', 'pcg', 13));
});

describe('对照函数本身不漏检', () => {
  it('NaN、缺失场、缺元件、风扇数不符都判失败', async () => {
    const { diffField } = await import('./solverCompare');
    expect(diffField('x', [1, NaN, 3, 4], [1, 2, 3, 4], false).ok).toBe(false);
    expect(diffField('x', [NaN, NaN, NaN, 4], [1, 2, 3, 4], true).ok).toBe(false);
    expect(diffField('x', [1, Infinity, 3], [1, 2, 3], false).ok).toBe(false);
    expect(diffField('x', [1, NaN, 3], [1, null, 3], false).ok).toBe(true);
    expect(diffField('x', [1, 2, 3], [1, 2, 3, 4], false).ok).toBe(false);
    const ref = loadRef('fixed_duct');
    const s = makeSolver(ref);
    s.stepMultiple(1);
    const snap = ref.snapshots[0];
    expect(compareSnapshot(s, snap).every((d) => d.ok)).toBe(true);
    s.nuTAssembled = null;
    expect(compareSnapshot(s, snap).some((d) => !d.ok && d.name.includes('缺失'))).toBe(true);
    const sc = compareScalars(s, { ...snap, scalars: { ...snap.scalars, Tj_cpu: 30, fans: [...snap.scalars.fans, snap.scalars.fans[0]] } });
    expect(sc.some((d) => !d.ok && d.name === 'net cpu')).toBe(true);
    expect(sc.some((d) => !d.ok && d.name === 'fans.length')).toBe(true);
  });
});
