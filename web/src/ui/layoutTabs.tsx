// 风扇布局页（安装位表、预设、挡板开孔、显卡厚度、标称风量与冲突检查、应用/撤销/存取 JSON）
// 与方案对比页（A/B/C 保存、载入、清除、对比表、温差视图参考）。移植自 MATLAB 界面的 createLayoutTab / createScenarioTab。
import { useRef } from 'preact/hooks';
import { FAN_PRESETS, FAN_SLOTS, type SlotState } from '../model/fans';
import type { FanReport } from '../model/fanReport';
import { scenarioTable, type ScenarioSnap } from '../model/scenarioTable';

export const STATE_ITEMS: { key: SlotState['type']; label: string }[] = [
  { key: 'none', label: '空' },
  { key: 'intake', label: '进气' },
  { key: 'exhaust', label: '排气' },
];
export const MODEL_ITEMS = ['P12', 'P14', 'NF_A12', 'NF_A14', 'RX120', 'RX140', 'Stock120'];
export const SPEED_ITEMS = ['自动', '30%', '40%', '50%', '60%', '70%', '80%', '90%', '100%'];
export const GPU_SLOT_VALUES = [2.5, 3, 3.5, 4];
export const GPU_SLOT_ITEMS = ['2.5 槽（51 mm）', '3 槽（61 mm）', '3.5 槽（71 mm）', '4 槽（81 mm）'];
export const SCENARIO_NAMES = ['A', 'B', 'C'];

interface LayoutTabProps {
  slots: SlotState[];
  report: FanReport;
  reportError: string | null;
  dirty: boolean;
  layoutLabel: string;
  appliedLabel: string;
  shroudGap: boolean;
  hasShroud: boolean;
  gpuSlots: number | null; // null = 布局中无显卡
  busy: boolean;
  onSlot: (k: number, st: SlotState) => void;
  onPreset: (name: string) => void;
  onShroudGap: (v: boolean) => void;
  onGpuSlots: (v: number) => void;
  onApply: (steady: boolean) => void;
  onRevert: () => void;
  onSave: () => void;
  onLoad: (file: File) => void;
}

export function LayoutTab(p: LayoutTabProps) {
  const presetRef = useRef<HTMLSelectElement>(null);
  const fileRef = useRef<HTMLInputElement>(null);
  const R = p.report;
  const warnings = [...(p.reportError ? [`布局无效：${p.reportError}`] : []), ...R.warnings];
  return (
    <div class="tab-body">
      <p class="muted small">编辑表格，或点击主视图中的风扇位（空 → 进气 → 排气）</p>
      <div class="table-wrap">
        <table class="slot-table">
          <thead>
            <tr>
              <th>位</th>
              <th>位置</th>
              <th>状态</th>
              <th>型号</th>
              <th>转速</th>
            </tr>
          </thead>
          <tbody>
            {FAN_SLOTS.map((sl, k) => {
              const st = p.slots[k];
              const speed = st.speedMode === 'manual' ? `${Math.round(st.manualPct)}%` : '自动';
              return (
                <tr key={sl.id} class={`slot-${st.type}`}>
                  <td>{sl.id}</td>
                  <td>{sl.label}</td>
                  <td>
                    <select value={st.type} onChange={(e) => p.onSlot(k, { ...st, type: (e.target as HTMLSelectElement).value as SlotState['type'] })}>
                      {STATE_ITEMS.map((s) => (
                        <option key={s.key} value={s.key}>
                          {s.label}
                        </option>
                      ))}
                    </select>
                  </td>
                  <td>
                    <select value={st.model} onChange={(e) => p.onSlot(k, { ...st, model: (e.target as HTMLSelectElement).value })}>
                      {(MODEL_ITEMS.includes(st.model) ? MODEL_ITEMS : [st.model, ...MODEL_ITEMS]).map((m) => (
                        <option key={m} value={m}>
                          {m}
                        </option>
                      ))}
                    </select>
                  </td>
                  <td>
                    <select
                      value={SPEED_ITEMS.includes(speed) ? speed : '自动'}
                      onChange={(e) => {
                        const v = (e.target as HTMLSelectElement).value;
                        p.onSlot(k, v === '自动' ? { ...st, speedMode: 'auto' } : { ...st, speedMode: 'manual', manualPct: Math.min(100, Math.max(0, parseFloat(v))) });
                      }}
                    >
                      {(SPEED_ITEMS.includes(speed) ? SPEED_ITEMS : [speed, ...SPEED_ITEMS]).map((m) => (
                        <option key={m} value={m}>
                          {m}
                        </option>
                      ))}
                    </select>
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>
      <div class="row">
        <span>预设</span>
        <select ref={presetRef} class="grow">
          {FAN_PRESETS.map((q) => (
            <option key={q.name} value={q.name}>
              {q.label}
            </option>
          ))}
        </select>
        <button onClick={() => p.onPreset(presetRef.current!.value)}>载入预设</button>
      </div>
      <div class="row">
        <label title="电源仓挡板前部的缺口，让前下风扇的气流进入电源仓上方">
          <input type="checkbox" checked={p.shroudGap} disabled={!p.hasShroud} onChange={(e) => p.onShroudGap((e.target as HTMLInputElement).checked)} /> 电源仓挡板前部开孔
        </label>
        <span class="grow" />
        <span>显卡厚度</span>
        <select
          value={p.gpuSlots === null ? '' : String(p.gpuSlots)}
          disabled={p.gpuSlots === null}
          onChange={(e) => p.onGpuSlots(Number((e.target as HTMLSelectElement).value))}
        >
          {/* 载入的布局槽数不在列表中（如 2 或 4.5 槽）时照实显示为额外一项，不悄悄改成最近的档 */}
          {p.gpuSlots !== null && !GPU_SLOT_VALUES.includes(p.gpuSlots) && <option value={String(p.gpuSlots)}>{`${p.gpuSlots} 槽（载入值）`}</option>}
          {GPU_SLOT_VALUES.map((v, k) => (
            <option key={v} value={String(v)}>
              {GPU_SLOT_ITEMS[k]}
            </option>
          ))}
        </select>
      </div>
      <div class="layout-info">
        <div>{p.dirty ? `待应用：${p.layoutLabel}` : `当前：${p.appliedLabel}`}</div>
        <div>
          标称进/排 满速 {R.intakeCfm.toFixed(0)} / {R.exhaustCfm.toFixed(0)} CFM（{R.pressure}）
        </div>
        <div>
          低速 {R.intakeCfmIdle.toFixed(0)} / {R.exhaustCfmIdle.toFixed(0)} CFM（{R.pressureIdle}）
        </div>
      </div>
      <ul class="warnings">{warnings.length ? warnings.map((w, k) => <li key={k}>{w}</li>) : <li class="ok">安装检查：无冲突</li>}</ul>
      <div class="btn-grid">
        <button class={p.dirty ? 'pending' : 'primary'} disabled={p.busy || !!p.reportError} onClick={() => p.onApply(false)}>
          应用布局
        </button>
        <button class="primary" disabled={p.busy || !!p.reportError} onClick={() => p.onApply(true)}>
          应用并跑到稳态
        </button>
        <button disabled={!p.dirty} onClick={p.onRevert}>
          撤销未应用的修改
        </button>
        <span />
        <button disabled={!!p.reportError} onClick={p.onSave}>
          保存配置（JSON）
        </button>
        <button disabled={p.busy} onClick={() => fileRef.current!.click()}>
          载入配置（JSON）
        </button>
      </div>
      <input
        ref={fileRef}
        type="file"
        accept=".json,application/json"
        style={{ display: 'none' }}
        onChange={(e) => {
          const f = (e.target as HTMLInputElement).files?.[0];
          if (f) p.onLoad(f);
          (e.target as HTMLInputElement).value = '';
        }}
      />
      <p class="muted small">应用布局会按当前功率重建流场（从静止开始）。配置文件包含整个布局、功率与各风扇转速设置。</p>
    </div>
  );
}


interface ScenarioTabProps {
  current: ScenarioSnap | null;
  scenarios: (ScenarioSnap | null)[];
  selected: number;
  diffRef: number;
  busy: boolean;
  onSelect: (k: number) => void;
  onSave: () => void;
  onLoad: () => void;
  onClear: () => void;
  onDiffRef: (k: number) => void;
  onShowDiff: () => void;
}

export function ScenarioTab(p: ScenarioTabProps) {
  const { rowNames, data } = scenarioTable([p.current, ...p.scenarios]);
  return (
    <div class="tab-body">
      <div class="row">
        <span>方案</span>
        <select value={String(p.selected)} onChange={(e) => p.onSelect(Number((e.target as HTMLSelectElement).value))}>
          {SCENARIO_NAMES.map((n, k) => (
            <option key={n} value={String(k)}>
              {n}
            </option>
          ))}
        </select>
        <button onClick={p.onSave} disabled={!p.current}>
          保存当前
        </button>
        <button onClick={p.onLoad} disabled={p.busy || !p.scenarios[p.selected]}>
          载入布局
        </button>
        <button onClick={p.onClear} disabled={!p.scenarios[p.selected]}>
          清除
        </button>
      </div>
      <div class="table-wrap">
        <table class="scenario-table">
          <thead>
            <tr>
              <th />
              <th>当前</th>
              {SCENARIO_NAMES.map((n) => (
                <th key={n}>{n}</th>
              ))}
            </tr>
          </thead>
          <tbody>
            {rowNames.map((r, i) => (
              <tr key={r}>
                <th>{r}</th>
                {data[i].map((v, j) => (
                  <td key={j}>{v}</td>
                ))}
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <div class="row">
        <span>温差视图：当前 −</span>
        <select value={String(p.diffRef)} onChange={(e) => p.onDiffRef(Number((e.target as HTMLSelectElement).value))}>
          {SCENARIO_NAMES.map((n, k) => (
            <option key={n} value={String(k)}>
              {n}
            </option>
          ))}
        </select>
        <button onClick={p.onShowDiff}>显示温差</button>
      </div>
      <p class="muted small">
        用法：先“跑到稳态”，把结果保存为方案 A；改布局、风扇或功率后再跑到稳态，保存为方案 B，表中逐项对比。“载入布局”可回到某个方案继续调整。
        温差视图 = 当前温度场 − 参考方案（需同一网格精度），红色表示当前更热。未到稳态的方案“稳态”一栏显示“否”。方案只保存在本页面，刷新即清空。
      </p>
    </div>
  );
}
