// 界面布局编辑逻辑（W2–W4 审计：自定义挡板缺口不能被默认值覆盖）。
import { describe, expect, it } from 'vitest';
import { buildPending, pendingFromLayout } from '../src/ui/layoutEdit';
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
