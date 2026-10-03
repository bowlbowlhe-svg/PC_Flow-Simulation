// 界面布局编辑逻辑（W2–W4 审计：自定义挡板缺口不能被默认值覆盖）。
import { describe, expect, it } from 'vitest';
import { buildPending, cpuFanItems, layoutCpuFans, layoutNotes, pendingFromLayout } from '../src/ui/layoutEdit';
import { layoutDefault } from '../src/model/layoutDefault';
import { layoutFromJson, layoutToJson } from '../src/model/layoutJson';
import { layoutSetGpuSlots } from '../src/model/gpuSlots';

const P = { cpu: 125, gpu: 250, psu: 450 };

describe('待应用布局', () => {
  it('载入带自定义挡板缺口的布局：缺口保留（保存、再应用都不被换成默认值）', () => {
    const def = layoutDefault();
    const L = layoutDefault();
    L.shroud!.gaps = [{ x0Mm: 300, x1Mm: 340 }];
    const loaded = layoutFromJson(layoutToJson(L));
    const st = pendingFromLayout(loaded, def.shroud!.gaps);
    expect(st.defaultGaps).toEqual([{ x0Mm: 300, x1Mm: 340 }]);
    expect(st.shroudGap).toBe(true);
    const slots = st.slots.map((s, k) => (k === 6 ? { ...s, type: 'intake' as const } : s)); // 改一个安装位
    const out = buildPending(loaded, slots, st.shroudGap!, st.gpuSlots, st.defaultGaps, P);
    expect(out.shroud!.gaps).toEqual([{ x0Mm: 300, x1Mm: 340 }]);
    // 取消勾选再勾选：仍是载入的缺口
    expect(buildPending(loaded, slots, false, st.gpuSlots, st.defaultGaps, P).shroud!.gaps).toEqual([]);
    expect(buildPending(loaded, slots, true, st.gpuSlots, st.defaultGaps, P).shroud!.gaps).toEqual([{ x0Mm: 300, x1Mm: 340 }]);
  });
  it('载入无缺口的布局：保留先前的缺口作为勾选时的默认值', () => {
    const L = layoutDefault();
    L.shroud!.gaps = [];
    const st = pendingFromLayout(L, [{ x0Mm: 300, x1Mm: 340 }]);
    expect(st.shroudGap).toBe(false);
    expect(st.defaultGaps).toEqual([{ x0Mm: 300, x1Mm: 340 }]);
  });
  it('显卡槽数不在下拉列表中（2 槽）时照原值应用，不改成最近档', () => {
    const L = layoutSetGpuSlots(layoutDefault(), 2);
    const st = pendingFromLayout(L, L.shroud!.gaps);
    expect(st.gpuSlots).toBe(2);
    const out = buildPending(L, st.slots, true, st.gpuSlots, st.defaultGaps, P);
    expect(out.gpu!.heatsink).toEqual(L.gpu!.heatsink);
  });
  it('显卡放不下时抛错（界面禁用应用与保存），功率写入布局', () => {
    const L = layoutSetGpuSlots(layoutDefault(), 3); // 3 槽放得下；挡板上移后改 4 槽放不下
    L.shroud!.yMm -= 30;
    const st = pendingFromLayout(L, L.shroud!.gaps);
    expect(() => buildPending(L, st.slots, true, 4, st.defaultGaps, P)).toThrow(/放不下/);
    expect(buildPending(layoutDefault(), st.slots, true, null, st.defaultGaps, { cpu: 1, gpu: 2, psu: 3 }).power).toEqual({ cpu: 1, gpu: 2, psu: 3 });
  });
});

describe('CPU 塔扇数量', () => {
  it('默认双塔 2 扇；改 1 扇只改 cpu.fan.count；null 不改；无塔扇时下拉框禁用', () => {
    const L = layoutDefault();
    const st = pendingFromLayout(L, L.shroud!.gaps);
    expect(st.cpuFans).toBe(2);
    const one = buildPending(L, st.slots, true, st.gpuSlots, st.defaultGaps, P, 1);
    expect(one.cpu!.fan).toEqual({ model: 'Tower120', count: 1 });
    expect({ ...one.cpu, fan: L.cpu!.fan }).toEqual(L.cpu);
    expect(buildPending(L, st.slots, true, st.gpuSlots, st.defaultGaps, P, null).cpu).toEqual(L.cpu);
    const N = layoutDefault();
    delete N.cpu!.fan;
    expect(layoutCpuFans(N)).toBeNull();
    expect(buildPending(N, st.slots, true, st.gpuSlots, st.defaultGaps, P, 2).cpu!.fan).toBeUndefined();
  });
  it('下拉项文字：双塔"中间 / 前 + 中间"，单塔"前侧 / 前 + 后"', () => {
    expect(cpuFanItems(2)).toEqual(['1 个（中间）', '2 个（前 + 中间）']);
    expect(cpuFanItems(1)).toEqual(['1 个（前侧）', '2 个（前 + 后）']);
  });
});

describe('布局页提示（旧配置兼容）', () => {
  it('默认布局无提示；v4.3 之前的 400 mm 见方配置提示机箱尺寸与不在安装位上的风扇', () => {
    expect(layoutNotes(layoutDefault())).toEqual([]);
    const old = layoutDefault();
    old.chassis.sizeMm = 400;
    old.chassis.originMm = 80;
    old.caseFans = old.caseFans!.map((f) => (f.mount === 'top' ? { ...f, alongMm: 140 } : f));
    const notes = layoutNotes(old);
    expect(notes).toHaveLength(2);
    expect(notes[0]).toContain('1 台机箱风扇不在安装位上');
    expect(notes[1]).toContain('400 × 400 mm');
    // 风扇都在安装位上、只是机箱尺寸不同：只提示尺寸
    const sq = layoutDefault();
    sq.chassis.sizeMm = [400, 400];
    expect(layoutNotes(sq)).toEqual([expect.stringContaining('400 × 400 mm')]);
  });
});
