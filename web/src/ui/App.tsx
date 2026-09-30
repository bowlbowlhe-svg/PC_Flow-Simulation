// 主界面：左侧主视图 + 工具栏 + 温度曲线/风扇工作点，右侧视图与操作 + 标签页（状态、功率与风扇、风扇布局、方案对比）。
import { useEffect, useMemo, useRef, useState } from 'preact/hooks';
import { FAN_PRESETS, applyPreset, getSlotStates, setSlotStates, type SlotState } from '../model/fans';
import { layoutFanReport, type FanReport } from '../model/fanReport';
import { layoutGpuSlots, layoutSetGpuSlots } from '../model/gpuSlots';
import { layoutDefault } from '../model/layoutDefault';
import { layoutFromJson, layoutToJson } from '../model/layoutJson';
import type { ScenarioSnap } from '../model/scenarioTable';
import type { Layout } from '../model/types';
import type { ComponentName } from '../worker/protocol';
import { colormapGradient, type ColormapName } from './colormap';
import { compositeImage, downloadBlob, GifRecorder, timestamp } from './exporters';
import { FieldView, type ViewMode } from './FieldView';
import { HistoryChart, type HistoryPoint } from './HistoryChart';
import { LayoutTab, SCENARIO_NAMES, ScenarioTab } from './layoutTabs';
import { FansTab, POWER_LIMITS, StatusTab } from './panels';
import { PQChart } from './PQChart';
import { SimClient, type SimState } from './simClient';

export const APP_VERSION = '0.5.0';

const MODES: { key: ViewMode; label: string }[] = [
  { key: 'velocity', label: '速度' },
  { key: 'temperature', label: '温度' },
  { key: 'pressure', label: '压力' },
  { key: 'vorticity', label: '涡量' },
  { key: 'solid', label: '固体温度' },
  { key: 'diff', label: '温差' },
];

const MAX_HISTORY = 600;
type Tab = 'status' | 'fans' | 'layout' | 'scenario';

interface Scenario extends ScenarioSnap {
  autoFan: boolean;
  fanPct: number;
  T: Float32Array;
  W: number;
}

/** 待应用布局：基底 + 安装位状态 + 挡板开孔 + 显卡厚度 + 当前功率（同 MATLAB pendingLayout） */
type Gaps = { x0Mm: number; x1Mm: number }[];

function buildPending(base: Layout, slots: SlotState[], gap: boolean, gpuSlots: number | null, defaultGaps: Gaps, powers: Record<ComponentName, number>): Layout {
  let L = setSlotStates(base, slots);
  if (L.shroud) L = { ...L, shroud: { ...L.shroud, gaps: gap ? structuredClone(defaultGaps) : [] } };
  if (L.gpu && gpuSlots !== null && gpuSlots !== layoutGpuSlots(L)) L = layoutSetGpuSlots(L, gpuSlots);
  return { ...L, power: { cpu: powers.cpu, gpu: powers.gpu, psu: powers.psu } };
}

export function App() {
  const client = useMemo(() => new SimClient(), []);
  const [sim, setSim] = useState<SimState>(client.state);
  const [mode, setMode] = useState<ViewMode>('velocity');
  const [particles, setParticles] = useState(true);
  const [labels, setLabels] = useState(true);
  const [side, setSide] = useState<'temp' | 'pq'>('temp');
  const [tab, setTab] = useState<Tab>('status');
  const [gridScale, setGridScale] = useState(0.5);
  const initial = useMemo(() => layoutDefault(), []);
  const defaultGaps = useMemo(() => structuredClone(initial.shroud!.gaps), [initial]);
  const [powers, setPowers] = useState<Record<ComponentName, number>>(() => ({ ...initial.power }));
  const [autoFan, setAutoFan] = useState(true);
  const [fanPct, setFanPct] = useState(40);
  const [precise, setPrecise] = useState(false);
  const [hover, setHover] = useState('');
  const [spec, setSpec] = useState<{ title: string; unit: string; cmap: ColormapName; clim: [number, number] }>({ title: '', unit: '', cmap: 'speed', clim: [0, 2] });
  // ---- 布局编辑 ----
  const [applied, setApplied] = useState<Layout>(initial);
  const [pendingBase, setPendingBase] = useState<Layout>(initial);
  const [slots, setSlots] = useState<SlotState[]>(() => getSlotStates(initial));
  const [shroudGap, setShroudGap] = useState(true);
  const [gpuSlots, setGpuSlots] = useState<number | null>(() => layoutGpuSlots(initial));
  const [dirty, setDirty] = useState(false);
  const [layoutLabel, setLayoutLabel] = useState(FAN_PRESETS[0].label);
  const [appliedLabel, setAppliedLabel] = useState(FAN_PRESETS[0].label);
  // ---- 方案对比 ----
  const [scenarios, setScenarios] = useState<(Scenario | null)[]>([null, null, null]);
  const [selScenario, setSelScenario] = useState(0);
  const [diffRef, setDiffRef] = useState(0);
  // ---- 导出 ----
  const fieldCanvas = useRef<HTMLCanvasElement | null>(null);
  const [gif, setGif] = useState<GifRecorder | null>(null);
  const history = useRef<{ build: number; pts: HistoryPoint[] }>({ build: -1, pts: [] });

  useEffect(() => {
    const off = client.subscribe(setSim);
    client.send({ type: 'init', layout: initial, gridScale, powers, autoFan, fanPct });
    return () => {
      off();
      client.dispose();
    };
  }, []);

  const st = sim.status;
  // 温度曲线：每帧追加一点；重建或重置（步数回退）时清空
  if (st) {
    const h = history.current;
    const last = h.pts[h.pts.length - 1];
    if (h.build !== sim.buildNo || (last && st.time < last.t)) {
      h.build = sim.buildNo;
      h.pts = [];
    }
    const tail = h.pts[h.pts.length - 1];
    if (!tail || st.time > tail.t) {
      h.pts.push({ t: st.time, cpu: st.tj.cpu ?? NaN, gpu: st.tj.gpu ?? NaN, rear: st.temps.rearExhaust });
      if (h.pts.length > MAX_HISTORY) h.pts.splice(0, h.pts.length - MAX_HISTORY);
    }
  }

  const running = !!st?.running;
  const steady = st?.steady ?? null;
  const steadyActive = !!steady?.active;
  const busy = steadyActive || !sim.info;

  // 待应用布局与安装检查
  let pending: Layout | null = null;
  let pendingError: string | null = null;
  try {
    pending = buildPending(pendingBase, slots, shroudGap, gpuSlots, defaultGaps, powers);
  } catch (e) {
    pendingError = e instanceof Error ? e.message : String(e);
  }
  const report: FanReport = layoutFanReport(pending ?? pendingBase);

  const onPower = (name: ComponentName, w: number) => {
    const [lo, hi] = POWER_LIMITS[name];
    const v = Math.min(hi, Math.max(lo, w));
    setPowers((p) => ({ ...p, [name]: v }));
    client.send({ type: 'setPower', name, watts: v });
  };
  const onFan = (auto: boolean, pct: number) => {
    setAutoFan(auto);
    setFanPct(pct);
    client.send({ type: 'setFan', auto, pct });
  };
  const rebuild = (L: Layout, gs: number, p = powers, auto = autoFan, pct = fanPct) => {
    client.send({ type: 'init', layout: L, gridScale: gs, powers: p, autoFan: auto, fanPct: pct });
    if (precise) client.send({ type: 'setForceReassemble', on: true });
  };
  const setPendingFromLayout = (L: Layout) => {
    setPendingBase(L);
    setSlots(getSlotStates(L));
    setGpuSlots(L.gpu ? layoutGpuSlots(L) : null);
    if (L.shroud) setShroudGap(L.shroud.gaps.length > 0);
  };
  const edited = (fansChanged = true) => {
    setDirty(true);
    if (fansChanged) setLayoutLabel('自定义');
  };
  const applyLayout = (runSteady: boolean, L = pending, label = layoutLabel, p = powers, auto = autoFan, pct = fanPct) => {
    if (!L || busy) return;
    rebuild(L, gridScale, p, auto, pct);
    setApplied(L);
    setPendingBase(L);
    setDirty(false);
    setAppliedLabel(label);
    setLayoutLabel(label);
    if (runSteady) client.send({ type: 'steady', opts: gridScale >= 1 ? { chunk: 25 } : {} });
  };
  const onSlotClick = (k: number) => {
    const order: SlotState['type'][] = ['none', 'intake', 'exhaust'];
    setSlots((ss) => ss.map((s, i) => (i === k ? { ...s, type: order[(order.indexOf(s.type) + 1) % 3] } : s)));
    edited();
  };
  const onLoadFile = async (f: File) => {
    try {
      const L = layoutFromJson(await f.text());
      const p = { cpu: L.power.cpu, gpu: L.power.gpu, psu: L.power.psu };
      for (const n of ['cpu', 'gpu', 'psu'] as const) p[n] = Math.min(POWER_LIMITS[n][1], Math.max(POWER_LIMITS[n][0], p[n]));
      setPowers(p);
      setPendingFromLayout(L);
      applyLayout(false, { ...L, power: p }, `配置 ${f.name}`, p);
    } catch (e) {
      client.state.error = `读取配置失败：${e instanceof Error ? e.message : String(e)}`;
      setSim({ ...client.state });
    }
  };
  const currentSnap = (): Scenario | null => {
    if (!st || !sim.info || !sim.fields) return null;
    return {
      summary: st.summary,
      label: appliedLabel,
      layout: sim.info.layout,
      powers: [powers.cpu, powers.gpu, powers.psu],
      gridScale: sim.info.gridScale,
      steady: st.atSteady,
      autoFan,
      fanPct,
      T: sim.fields.T.slice(),
      W: sim.info.W,
    };
  };
  const loadScenario = () => {
    const s = scenarios[selScenario];
    if (!s || busy) return;
    const p = { cpu: s.powers[0], gpu: s.powers[1], psu: s.powers[2] };
    setPowers(p);
    setAutoFan(s.autoFan);
    setFanPct(s.fanPct);
    setPendingFromLayout(s.layout);
    applyLayout(false, { ...s.layout, power: p }, s.label, p, s.autoFan, s.fanPct);
  };
  const exportPng = () => {
    const c = fieldCanvas.current;
    if (!c) return;
    compositeImage(c, spec).toBlob((b) => b && downloadBlob(b, `pcflow_${timestamp()}.png`));
  };
  // GIF 录制：每 150 ms 取一帧（宽约 520 px），最多 300 帧。定时器只随录制开始/结束重建
  // （不能每次重绘都重建：帧间隔短于 150 ms 时定时器永远不会触发）；标题与色标取最新值
  const specRef = useRef(spec);
  specRef.current = spec;
  const [gifFrames, setGifFrames] = useState(0);
  const stopGif = () => {
    if (!gif) return;
    const g = gif;
    setGif(null);
    if (g.frames) downloadBlob(g.finish(), `pcflow_${timestamp()}.gif`);
  };
  const stopGifRef = useRef(stopGif);
  stopGifRef.current = stopGif;
  useEffect(() => {
    if (!gif) return;
    setGifFrames(0);
    const id = setInterval(() => {
      const c = fieldCanvas.current;
      if (!c) return;
      const more = gif.addFrame(compositeImage(c, specRef.current, 520 / c.width));
      setGifFrames(gif.frames);
      if (!more) stopGifRef.current();
    }, 150);
    return () => clearInterval(id);
  }, [gif]);

  let note = '';
  if (steady) note = steady.active ? `跑到稳态中：${steady.steps} 步` : steady.message;
  const diffScenario = scenarios[diffRef];

  return (
    <div class="app">
      <div class="left">
        <div class="view-title">
          {spec.title}
          {sim.info && <span class="muted"> · {sim.info.W}² 网格{precise ? ' · 精确模式' : ''}</span>}
        </div>
        <div class="view-row">
          {sim.info && sim.fields ? (
            <FieldView
              info={sim.info}
              fields={sim.fields}
              status={st}
              frameNo={sim.frameNo}
              buildNo={sim.buildNo}
              mode={mode}
              particles={particles}
              labels={labels}
              running={running}
              onHover={setHover}
              onSpec={setSpec}
              slotTypes={slots.map((s) => s.type)}
              onSlotClick={onSlotClick}
              diff={{ name: SCENARIO_NAMES[diffRef], T: diffScenario?.T ?? null, W: diffScenario?.W ?? 0 }}
              onCanvas={(c) => (fieldCanvas.current = c)}
            />
          ) : (
            <div class="field-wrap loading">正在构建流场…</div>
          )}
          <div class="colorbar">
            <span>{fmtLim(spec.clim[1])}</span>
            <div class="colorbar-bar" style={{ background: colormapGradient(spec.cmap) }} />
            <span>{fmtLim(spec.clim[0])}</span>
          </div>
        </div>
        <div class="toolbar">
          <span class="hover">{hover || '移动鼠标查看读数；点击安装位切换风扇'}</span>
          <select value={side} onChange={(e) => setSide((e.target as HTMLSelectElement).value as 'temp' | 'pq')}>
            <option value="temp">温度曲线</option>
            <option value="pq">风扇工作点</option>
          </select>
          <label>
            <input type="checkbox" checked={particles} onChange={(e) => setParticles((e.target as HTMLInputElement).checked)} /> 粒子
          </label>
          <label>
            <input type="checkbox" checked={labels} onChange={(e) => setLabels((e.target as HTMLInputElement).checked)} /> 风量标注
          </label>
          <button onClick={exportPng} disabled={!sim.fields}>
            导出 PNG
          </button>
          <button class={gif ? 'danger' : ''} onClick={() => (gif ? stopGif() : setGif(new GifRecorder()))} disabled={!sim.fields}>
            {gif ? `■ 停止录制（${gifFrames}）` : '● 录制 GIF'}
          </button>
        </div>
        {side === 'temp' ? <HistoryChart data={history.current.pts} note={note} /> : <PQChart pq={st?.pq ?? []} note={note} />}
      </div>
      <div class="right">
        <h1>
          PC 风道仿真器 <span class="ver">网页版 {APP_VERSION}</span>
        </h1>
        <section class="section">
          <h3>视图与操作</h3>
          <div class="mode-btns">
            {MODES.map((m) => (
              <button key={m.key} class={mode === m.key ? 'active' : ''} onClick={() => setMode(m.key)}>
                {m.label}
              </button>
            ))}
          </div>
          <div class="run-btns">
            <button class={running ? 'danger' : 'primary'} disabled={busy} onClick={() => client.send({ type: running ? 'pause' : 'run' })}>
              {running ? '⏸ 暂停仿真' : '▶ 开始仿真'}
            </button>
            <button
              class={steadyActive ? 'danger' : ''}
              disabled={!sim.info}
              onClick={() => client.send(steadyActive ? { type: 'stopSteady' } : { type: 'steady', opts: gridScale >= 1 ? { chunk: 25 } : {} })}
              title={steady?.message ?? '推进到结温、内温与风量都不再变化'}
            >
              {steadyActive ? `■ 停止（${steady!.steps} 步）` : '⏩ 跑到稳态'}
            </button>
            <button disabled={busy} onClick={() => client.send({ type: 'reset' })}>
              重置
            </button>
          </div>
          <div class="grid-row">
            <label>
              网格{' '}
              <select
                value={String(gridScale)}
                disabled={busy}
                onChange={(e) => {
                  const gs = Number((e.target as HTMLSelectElement).value);
                  setGridScale(gs);
                  rebuild(applied, gs);
                }}
              >
                <option value="0.5">预览 140²</option>
                <option value="1">精确 280²</option>
              </select>
            </label>
            <label title="每步按当前系数重装全部冻结算子（ALGORITHM §3.10），结果更精确，约慢 3 倍">
              <input
                type="checkbox"
                checked={precise}
                onChange={(e) => {
                  const on = (e.target as HTMLInputElement).checked;
                  setPrecise(on);
                  client.send({ type: 'setForceReassemble', on });
                }}
              />{' '}
              精确模式
            </label>
            <span class="warn small">⚠ 2D 定性模型，仅供理解风道趋势</span>
          </div>
          {st && (
            <div class="muted small">
              每步 {st.msPerStep.toFixed(0)} ms · {steady && !steady.active ? steady.message : running ? '运行中' : '已暂停'}
            </div>
          )}
        </section>
        {sim.error && (
          <div class="error" onClick={() => client.clearError()}>
            {sim.error}（点击关闭）
          </div>
        )}
        <div class="tabs">
          {(
            [
              ['status', '状态'],
              ['fans', '功率与风扇'],
              ['layout', '风扇布局'],
              ['scenario', '方案对比'],
            ] as [Tab, string][]
          ).map(([k, label]) => (
            <button key={k} class={tab === k ? 'active' : ''} onClick={() => setTab(k)}>
              {label}
              {k === 'layout' && dirty ? ' •' : ''}
            </button>
          ))}
        </div>
        {tab === 'status' && <StatusTab st={st} info={sim.info} />}
        {tab === 'fans' && (
          <FansTab
            st={st}
            powers={powers}
            autoFan={autoFan}
            fanPct={fanPct}
            onPower={onPower}
            onScenario={(p) => (['cpu', 'gpu', 'psu'] as const).forEach((n, k) => onPower(n, p[k]))}
            onFan={onFan}
          />
        )}
        {tab === 'layout' && (
          <LayoutTab
            slots={slots}
            report={report}
            reportError={pendingError}
            dirty={dirty}
            layoutLabel={layoutLabel}
            appliedLabel={appliedLabel}
            shroudGap={shroudGap}
            hasShroud={!!pendingBase.shroud}
            gpuSlots={gpuSlots}
            busy={busy}
            onSlot={(k, s) => {
              setSlots((ss) => ss.map((x, i) => (i === k ? s : x)));
              edited();
            }}
            onPreset={(name) => {
              const L = applyPreset(pendingBase, name);
              setPendingBase(L);
              setSlots(getSlotStates(L));
              setDirty(true);
              setLayoutLabel(FAN_PRESETS.find((q) => q.name === name)!.label);
            }}
            onShroudGap={(v) => {
              setShroudGap(v);
              edited(false);
            }}
            onGpuSlots={(v) => {
              setGpuSlots(v);
              edited(false);
            }}
            onApply={(s) => applyLayout(s)}
            onRevert={() => {
              setPendingFromLayout(applied);
              setDirty(false);
              setLayoutLabel(appliedLabel);
            }}
            onSave={() => pending && downloadBlob(new Blob([layoutToJson(pending)], { type: 'application/json' }), 'pcflow_layout.json')}
            onLoad={onLoadFile}
          />
        )}
        {tab === 'scenario' && (
          <ScenarioTab
            current={currentSnap()}
            scenarios={scenarios}
            selected={selScenario}
            diffRef={diffRef}
            busy={busy}
            onSelect={setSelScenario}
            onSave={() => {
              const s = currentSnap();
              if (s) setScenarios((ss) => ss.map((x, i) => (i === selScenario ? s : x)));
            }}
            onLoad={loadScenario}
            onClear={() => setScenarios((ss) => ss.map((x, i) => (i === selScenario ? null : x)))}
            onDiffRef={setDiffRef}
            onShowDiff={() => setMode('diff')}
          />
        )}
      </div>
    </div>
  );
}

function fmtLim(v: number): string {
  return Math.abs(v) >= 10 || Number.isInteger(v) ? v.toFixed(0) : v.toFixed(1);
}
