// 主界面：左侧主视图 + 工具栏 + 温度曲线/风扇工作点，右侧视图与操作 + 标签页（状态、功率与风扇、风扇布局、方案对比）。
import { useEffect, useMemo, useRef, useState } from 'preact/hooks';
import { FAN_PRESETS, applyPreset, getSlotStates, type SlotState } from '../model/fans';
import { buildPending, layoutCpuFans, layoutNotes, pendingFromLayout, type Gaps } from './layoutEdit';
import { layoutCpuTower } from '../model/cpuTower';
import { layoutFanReport, type FanReport } from '../model/fanReport';
import { layoutGpuSlots } from '../model/gpuSlots';
import { layoutDefault } from '../model/layoutDefault';
import { layoutFromJson, layoutToJson, migrationNote, type LayoutMigration } from '../model/layoutJson';
import type { ScenarioSnap } from '../model/scenarioTable';
import { fanCurveProfiles, layoutFanCurves, type FanProfile } from '../model/fanCurves';
import type { FanCurves, Layout } from '../model/types';
import type { ComponentName } from '../worker/protocol';
import { colormapGradient, type ColormapName } from './colormap';
import { compositeImage, downloadBlob, GifRecorder, timestamp } from './exporters';
import { FieldView, type ViewMode } from './FieldView';
import { HistoryChart, type HistoryPoint } from './HistoryChart';
import { LayoutTab, SCENARIO_NAMES, ScenarioTab } from './layoutTabs';
import { FansTab, POWER_LIMITS, StatusTab } from './panels';
import { PQChart } from './PQChart';
import { SimClient, type SimState } from './simClient';
import type { CompareClient } from './compareClient';
import type { AddOptions, CompareJob } from './compare/ComparePage';
import type { CustomScheme, SchemeView } from './compare/schemes';
import { COMPARE_SCENARIOS, type ScenarioKey } from '../compare/scenarios';

/** 对比展示页（含预计算数据与对比 Worker）按需加载 */
type CompareMod = typeof import('./compare/lazy');

export const APP_VERSION = '1.7.0';

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
type Page = 'sim' | 'compare';

interface Scenario extends ScenarioSnap {
  autoFan: boolean;
  fanPct: number;
  T: Float32Array;
  W: number;
  version: number; // 每次保存递增（温差视图据此重画）
}

/** 待应用布局：基底 + 安装位状态 + 挡板开孔 + 显卡厚度 + 当前功率（同 MATLAB pendingLayout） */
export function App() {
  const client = useMemo(() => new SimClient(), []);
  const [sim, setSim] = useState<SimState>(client.state);
  const [mode, setMode] = useState<ViewMode>('velocity');
  const [particles, setParticles] = useState(true);
  const [labels, setLabels] = useState(true);
  const [side, setSide] = useState<'temp' | 'pq'>('temp');
  const [tab, setTab] = useState<Tab>('status');
  const [page, setPage] = useState<Page>('sim');
  // ---- 对比展示页：自定义方案（后台计算，只保存在当前页面）----
  const [cmp, setCmp] = useState<CompareMod | null>(null);
  const compareClientRef = useRef<CompareClient | null>(null);
  const [customs, setCustoms] = useState<CustomScheme[]>([]);
  const [job, setJob] = useState<CompareJob | null>(null);
  const jobRef = useRef<{ id: number; scheme: string } | null>(null);
  const customSeq = useRef(0);
  const [gridScale, setGridScale] = useState(0.5);
  const initial = useMemo(() => layoutDefault(), []);
  // 挡板"前部开孔"勾选时使用的缺口：载入的布局带非空缺口时随之更新（同 MATLAB setPendingFromLayout）
  const [defaultGaps, setDefaultGaps] = useState<Gaps>(() => structuredClone(initial.shroud!.gaps));
  const [building, setBuilding] = useState(false);
  const scenarioSeq = useRef(0);
  const [powers, setPowers] = useState<Record<ComponentName, number>>(() => ({ ...initial.power }));
  const [autoFan, setAutoFan] = useState(true);
  const [fanPct, setFanPct] = useState(40);
  // 当前求解器的温控曲线（档位下拉框；应用布局、保存配置、方案快照沿用，同 MATLAB Solver.fanCurves）
  const [fanCurves, setFanCurves] = useState<FanCurves>(() => layoutFanCurves(initial));
  const [precise, setPrecise] = useState(false);
  const [hover, setHover] = useState('');
  const [spec, setSpec] = useState<{ title: string; unit: string; cmap: ColormapName; clim: [number, number] }>({ title: '', unit: '', cmap: 'speed', clim: [0, 2] });
  // ---- 布局编辑 ----
  const [applied, setApplied] = useState<Layout>(initial);
  const [pendingBase, setPendingBase] = useState<Layout>(initial);
  const [slots, setSlots] = useState<SlotState[]>(() => getSlotStates(initial));
  const [shroudGap, setShroudGap] = useState(true);
  const [gpuSlots, setGpuSlots] = useState<number | null>(() => layoutGpuSlots(initial));
  const [cpuFans, setCpuFans] = useState<number | null>(() => layoutCpuFans(initial));
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
      compareClientRef.current?.dispose();
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
  const busy = steadyActive || !sim.info || building;

  // 待应用布局与安装检查
  let pending: Layout | null = null;
  let pendingError: string | null = null;
  try {
    pending = buildPending(pendingBase, slots, shroudGap, gpuSlots, defaultGaps, powers, cpuFans, fanCurves);
  } catch (e) {
    pendingError = e instanceof Error ? e.message : String(e);
  }
  const report: FanReport = layoutFanReport(pending ?? pendingBase);

  /**
   * 暂停时改了功率或全局风扇：自动继续仿真（同 MATLAB resumeAfterChange）。新设置立即作用于求解器，
   * 但温度、噪音、评分要推进后才会变；暂停着不动，看起来就像没生效。跑到稳态中不打断（新设置照常生效）。
   */
  const resumeIfPaused = () => {
    if (!running && !steadyActive && sim.info && !building) client.send({ type: 'run' });
  };
  // 滑块拖动中只更新显示，松手（或按钮）才发给求解器（同 MATLAB 滑块的 ValueChanged）
  const onPower = (name: ComponentName, w: number, send = true, resume = true) => {
    const [lo, hi] = POWER_LIMITS[name];
    const v = Math.min(hi, Math.max(lo, w));
    setPowers((p) => ({ ...p, [name]: v }));
    if (send) {
      client.send({ type: 'setPower', name, watts: v });
      if (resume) resumeIfPaused();
    }
  };
  const onFan = (auto: boolean, pct: number, send = true) => {
    setAutoFan(auto);
    setFanPct(pct);
    if (send) {
      client.send({ type: 'setFan', auto, pct });
      resumeIfPaused();
    }
  };
  const onFanProfile = (key: FanProfile) => {
    const C = fanCurveProfiles(key);
    setFanCurves(C);
    client.send({ type: 'setFanCurves', curves: C });
    resumeIfPaused();
  };
  const preciseRef = useRef(precise);
  preciseRef.current = precise;
  /**
   * 重建求解器，成功后才返回 true（同 MATLAB rebuildSolver：失败时原求解器保留、界面状态不变，Worker 报"重建失败"）。
   * 调用方只在成功后提交界面状态（已应用布局、标签、网格、功率），也只在成功后才发"跑到稳态"。
   */
  const rebuild = async (L: Layout, gs: number, p = powers, auto = autoFan, pct = fanPct): Promise<boolean> => {
    setBuilding(true);
    const r = await client.init({ layout: L, gridScale: gs, powers: p, autoFan: auto, fanPct: pct });
    setBuilding(false);
    // 精确模式按当前勾选状态（重建期间勾选框禁用；这里取最新值而不是调用时的旧值）
    if (r.ok && preciseRef.current) client.send({ type: 'setForceReassemble', on: true });
    return r.ok;
  };
  const setPendingFromLayout = (L: Layout) => {
    const st = pendingFromLayout(L, defaultGaps);
    setPendingBase(L);
    setSlots(st.slots);
    setGpuSlots(st.gpuSlots);
    setCpuFans(st.cpuFans);
    setDefaultGaps(st.defaultGaps);
    if (st.shroudGap !== null) setShroudGap(st.shroudGap);
  };
  const edited = (fansChanged = true) => {
    setDirty(true);
    if (fansChanged) setLayoutLabel('自定义');
  };
  const applyLayout = async (runSteady: boolean, L = pending, label = layoutLabel, p = powers, auto = autoFan, pct = fanPct, force = false): Promise<boolean> => {
    // force：跑稳态中也重建（对比展示页"在仿真页打开"；重建会先停止稳态推进）
    if (!L || building || !sim.info || (steadyActive && !force)) return false;
    if (!(await rebuild(L, gridScale, p, auto, pct))) return false;
    setApplied(L);
    setPendingBase(L);
    setDirty(false);
    setAppliedLabel(label);
    setLayoutLabel(label);
    setPowers(p);
    setAutoFan(auto);
    setFanPct(pct);
    setFanCurves(layoutFanCurves(L));
    if (runSteady) client.send({ type: 'steady', opts: gridScale >= 1 ? { chunk: 25 } : {} });
    return true;
  };
  const onSlotClick = (k: number) => {
    const order: SlotState['type'][] = ['none', 'intake', 'exhaust'];
    setSlots((ss) => ss.map((s, i) => (i === k ? { ...s, type: order[(order.indexOf(s.type) + 1) % 3] } : s)));
    edited();
  };
  const onLoadFile = async (f: File) => {
    let L: Layout;
    const info: { migration?: LayoutMigration } = {};
    try {
      L = layoutFromJson(await f.text(), info);
    } catch (e) {
      client.state.error = `读取配置失败：${e instanceof Error ? e.message : String(e)}`;
      setSim({ ...client.state });
      return;
    }
    // 功率：配置里没有 power 时沿用当前功率（同 MATLAB isfield）；有则每项须为有限数，夹在滑块范围内并取整
    const p = { ...powers };
    const raw = (L as { power?: Record<string, unknown> }).power;
    if (raw !== undefined && raw !== null) {
      for (const n of ['cpu', 'gpu', 'psu'] as const) {
        const v = raw[n];
        if (typeof v !== 'number' || !Number.isFinite(v)) {
          client.state.error = `配置无效：power.${n} 应为有限的数（${f.name}）`;
          setSim({ ...client.state });
          return;
        }
        p[n] = Math.round(Math.min(POWER_LIMITS[n][1], Math.max(POWER_LIMITS[n][0], v)));
      }
    }
    const L2 = { ...L, power: p };
    if (await applyLayout(false, L2, `配置 ${f.name}${migrationNote(info.migration ?? 'none')}`, p)) setPendingFromLayout(L2);
  };
  const currentSnap = (): Scenario | null => {
    if (!st || !sim.info || !sim.fields) return null;
    return {
      summary: st.summary,
      label: appliedLabel,
      layout: { ...sim.info.layout, fanCurves: structuredClone(fanCurves) },
      powers: [powers.cpu, powers.gpu, powers.psu],
      gridScale: sim.info.gridScale,
      steady: st.atSteady,
      autoFan,
      fanPct,
      T: sim.fields.T.slice(),
      W: sim.info.W,
      version: ++scenarioSeq.current,
    };
  };
  const loadScenario = async () => {
    const s = scenarios[selScenario];
    if (!s || busy) return;
    const p = { cpu: s.powers[0], gpu: s.powers[1], psu: s.powers[2] };
    const L = { ...s.layout, power: p };
    if (await applyLayout(false, L, s.label, p, s.autoFan, s.fanPct)) setPendingFromLayout(L);
  };
  /** 对比展示页：把仿真页当前已应用的布局（含温控曲线）加入对比，后台按同样口径计算 */
  const addCurrentToCompare = (o: AddOptions) => {
    if (!sim.info || !cmp) return;
    if (jobRef.current) cancelCompareJob(); // 同一时刻只算一个
    const compareClient = (compareClientRef.current ??= new cmp.CompareClient());
    const COMPARE_DATA = cmp.COMPARE_DATA;
    const k = ++customSeq.current;
    const id = `custom-${k}`;
    const label = `自定义 ${k}（${appliedLabel}）`;
    const layout: Layout = { ...structuredClone(sim.info.layout), fanCurves: structuredClone(fanCurves) };
    const proto = { ...COMPARE_DATA.protocol, gridScale: o.gridScale, turbUpdateEvery: o.gridScale >= 1 ? 1 : 2, sweepPct: o.sweep ? COMPARE_DATA.protocol.sweepPct : [] };
    setCustoms((cs) => [...cs, { id, label, layout, gridScale: o.gridScale, cases: {} }]);
    // 立即进入"计算中"（Worker 构建求解器要几秒才回第一条进度），避免重复点击
    setJob({ label, scenario: o.scenarios[0], index: 0, count: o.scenarios.length, done: 0, total: 0 });
    const dropIfEmpty = () => setCustoms((cs) => cs.filter((c) => c.id !== id || Object.keys(c.cases).length > 0));
    const jid = compareClient.start({ layout, scenarios: o.scenarios, protocol: proto }, (m) => {
      switch (m.type) {
        case 'progress':
          setJob({ label, scenario: m.scenario, index: m.index, count: m.count, done: m.done, total: m.total });
          break;
        case 'case':
          setCustoms((cs) => cs.map((c) => (c.id === id ? { ...c, cases: { ...c.cases, [m.scenario]: { auto: m.auto, sweep: m.sweep, thumb: m.thumb } } } : c)));
          break;
        case 'done':
        case 'cancelled':
          jobRef.current = null;
          setJob(null);
          break;
        case 'error':
          jobRef.current = null;
          dropIfEmpty();
          setJob((j) => ({ ...(j ?? { label, scenario: o.scenarios[0], index: 0, count: o.scenarios.length, done: 0, total: 0 }), error: m.message }));
          break;
      }
    });
    jobRef.current = { id: jid, scheme: id };
  };
  const cancelCompareJob = () => {
    const j = jobRef.current;
    if (j) {
      compareClientRef.current?.cancel(j.id);
      // 没算完任何场景的自定义方案一并移除
      setCustoms((cs) => cs.filter((c) => c.id !== j.scheme || Object.keys(c.cases).length > 0));
    }
    jobRef.current = null;
    setJob(null);
  };
  /** 对比展示页 → 仿真页：载入方案与场景功率，应用并跑到稳态 */
  const openInSim = async (s: SchemeView, sc: ScenarioKey) => {
    const scen = COMPARE_SCENARIOS.find((x) => x.key === sc)!;
    const p = { cpu: scen.powers[0], gpu: scen.powers[1], psu: scen.powers[2] };
    const base = s.kind === 'preset' ? applyPreset(layoutDefault(), s.id) : structuredClone(s.layout!);
    const L = { ...base, power: p };
    if (building || !sim.info) return; // 按钮此时禁用
    setPage('sim');
    // 仿真页正在跑稳态也照常载入：重建求解器会先停止原来的稳态推进
    if (await applyLayout(true, L, s.label, p, true, fanPct, true)) setPendingFromLayout(L);
  };
  const goCompare = () => {
    stopGifRef.current(); // 主视图卸载前停止 GIF 录制（已录的帧照常保存）
    setPage('compare');
    if (!cmp) import('./compare/lazy').then(setCmp, (e) => {
      client.state.error = `对比展示页载入失败：${e instanceof Error ? e.message : String(e)}`;
      setSim({ ...client.state });
    });
  };
  const exportPng = () => {
    const c = fieldCanvas.current;
    if (!c) return;
    compositeImage(c, spec).toBlob((b) => b && downloadBlob(b, `pcflow_${timestamp()}.png`));
  };
  // GIF 录制：每 150 ms 取一帧（宽约 480 px），最多 300 帧，延时按实际取帧间隔写。定时器只随录制开始/结束重建
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
      const more = gif.addFrame(compositeImage(c, specRef.current, 480 / c.width));
      setGifFrames(gif.frames);
      if (!more) stopGifRef.current();
    }, 150);
    return () => clearInterval(id);
  }, [gif]);

  let note = '';
  if (steady) note = steady.active ? `跑到稳态中：${steady.steps} 步` : steady.message;
  const diffScenario = scenarios[diffRef];

  const nav = (
    <nav class="topnav">
      <span class="topnav-title">
        PC 风道仿真器 <span class="ver">网页版 {APP_VERSION}</span>
      </span>
      <button class={page === 'sim' ? 'active' : ''} onClick={() => setPage('sim')}>
        仿真
      </button>
      <button class={page === 'compare' ? 'active' : ''} onClick={goCompare}>
        方案对比展示{job && !job.error ? ' ⏳' : ''}
      </button>
    </nav>
  );
  if (page === 'compare')
    return (
      <>
        {nav}
        {cmp ? (
        <cmp.ComparePage
          data={cmp.COMPARE_DATA}
          customs={customs}
          job={job}
          currentLabel={appliedLabel}
          canAddCurrent={!!sim.info && !building}
          canOpen={!!sim.info && !building}
          onAddCurrent={addCurrentToCompare}
          onCancelJob={cancelCompareJob}
          onRemoveCustom={(id) => setCustoms((cs) => cs.filter((c) => c.id !== id))}
          onOpenInSim={openInSim}
        />
        ) : (
          <div class="compare-page muted">正在载入对比数据…</div>
        )}
      </>
    );

  return (
    <>
    {nav}
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
              diff={{ name: SCENARIO_NAMES[diffRef], T: diffScenario?.T ?? null, W: diffScenario?.W ?? 0, version: diffScenario?.version ?? 0 }}
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
          {dirty && <span class="pending-note">⚠ 布局有未应用的修改：流场仍按已应用的布局计算，点"应用布局"后生效</span>}
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
                onChange={async (e) => {
                  const sel = e.target as HTMLSelectElement;
                  const gs = Number(sel.value);
                  if (await rebuild({ ...applied, fanCurves }, gs)) setGridScale(gs); // 沿用当前温控曲线（同 MATLAB Solver.layout）
                  else sel.value = String(gridScale); // 失败：下拉框回到原网格档
                }}
              >
                <option value="0.5">预览 140²</option>
                <option value="1">精确 280²</option>
              </select>
            </label>
            <label title="每步按当前系数重装全部冻结算子（ALGORITHM §3.10），结果更精确，约慢 2 倍（与网格的“精确 280²”无关）">
              <input
                type="checkbox"
                checked={precise}
                disabled={building}
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
              每步 {st.msPerStep.toFixed(0)} ms · {building ? '正在重建流场…' : running ? '运行中' : steady ? steady.message : '已暂停'}
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
            fanProfile={fanCurves.profile}
            onFanProfile={onFanProfile}
            onPower={onPower}
            disabled={building}
            onScenario={(p) => {
              (['cpu', 'gpu', 'psu'] as const).forEach((n, k) => onPower(n, p[k], true, false));
              resumeIfPaused(); // 三项都设完后再继续（同 MATLAB setScenario）
            }}
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
            cpuFans={cpuFans}
            cpuStacks={pendingBase.cpu ? layoutCpuTower(pendingBase).stacks : 2}
            notes={layoutNotes(pendingBase)}
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
            onCpuFans={(v) => {
              setCpuFans(v);
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
    </>
  );
}

function fmtLim(v: number): string {
  return Math.abs(v) >= 10 || Number.isInteger(v) ? v.toFixed(0) : v.toFixed(1);
}
