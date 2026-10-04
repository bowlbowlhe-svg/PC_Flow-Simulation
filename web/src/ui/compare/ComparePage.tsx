// 方案对比展示页：多个风扇方案 × 办公/游戏/满载，一眼看清温度、性能、噪音与评分的差别；
// 预计算数据打开即显示，可把仿真页的当前布局加入对比（后台计算），点方案可回到仿真页细调。
import { useEffect, useMemo, useRef, useState } from 'preact/hooks';
import { COMPARE_SCENARIOS, type ScenarioKey } from '../../compare/scenarios';
import type { CompareData } from '../../compare/data';
import { fieldStats, inScaleRegion, percentile, type FieldThumb, type ThumbSrc } from '../../compare/thumb';
import { layoutDefault } from '../../model/layoutDefault';
import { colormapGradient } from '../colormap';
import { BarChart, TradeoffChart } from './charts';
import {
  buildSchemes,
  cheapestNearBest,
  cyclingNoise,
  fairCompare,
  fmax,
  METRICS,
  metricByKey,
  n,
  rankBy,
  SCENARIO_LABEL,
  schemeColor,
  scoreColor,
  type CustomScheme,
  type FairMode,
  type SchemeView,
} from './schemes';
import { decodeThumb, FieldThumbView, HEAT_FLOOR, useThumb } from './FieldThumbView';
import { sameGrid, type FieldMode, type FieldStyle } from './fieldMath';

export interface CompareJob {
  label: string;
  scenario: ScenarioKey;
  index: number;
  count: number;
  done: number;
  total: number;
  error?: string;
}

export interface AddOptions {
  gridScale: number;
  sweep: boolean;
  scenarios: ScenarioKey[];
}

interface Props {
  data: CompareData;
  customs: CustomScheme[];
  job: CompareJob | null;
  currentLabel: string;
  canAddCurrent: boolean;
  /** 仿真页能否接收"在仿真页打开"（重建流场期间不行） */
  canOpen: boolean;
  onAddCurrent: (o: AddOptions) => void;
  onCancelJob: () => void;
  onRemoveCustom: (id: string) => void;
  onOpenInSim: (s: SchemeView, sc: ScenarioKey) => void;
}

/** 预设方案的环境温度（流场图温度色标的下端；自定义方案按其布局） */
const T_AMB_DEFAULT = layoutDefault().ambientC;
/** 色标上限解码完成前的缺省值 */
const T_HI_DEFAULT: Record<ScenarioKey, number> = { office: 45, gaming: 60, heavy: 70 };
/** 温差参考方案的缺省（默认方案） */
const DEFAULT_REF = 'balanced';
const niceCeil = (v: number, step: number) => Math.ceil(v / step - 1e-9) * step;
const f1 = (v: number) => (Number.isFinite(v) ? v.toFixed(1) : '—');
/** 统计窗口内最高结温漂移超过它（°C）视为"未完全稳态" */
const DRIFT_WARN = 0.3;
const DT = 0.005; // 求解器时间步 [s]（预计算与后台计算都用默认值）
const f0 = (v: number) => (Number.isFinite(v) ? v.toFixed(0) : '—');

export function ComparePage(p: Props) {
  const schemes = useMemo(() => buildSchemes(p.data, p.customs), [p.data, p.customs]);
  const colors = useMemo(() => new Map(schemes.map((s, k) => [s.id, schemeColor(k)])), [schemes]);
  const [scenario, setScenario] = useState<ScenarioKey>('gaming');
  const [metricKey, setMetricKey] = useState('score');
  const [thumbMode, setThumbMode] = useState<FieldMode>('temperature');
  const [stream, setStream] = useState(true);
  const [labels, setLabels] = useState(true);
  const [refId, setRefId] = useState(DEFAULT_REF);
  const [zoom, setZoom] = useState<string | null>(null);
  const [selected, setSelected] = useState<string | null>(null);
  const [fairMode, setFairMode] = useState<FairMode>('noise');
  const [yKey, setYKey] = useState<'tmax' | 'perfPct'>('tmax');
  const [targets, setTargets] = useState<Record<string, number>>({});
  const metric = metricByKey(metricKey);
  const ranked = rankBy(schemes, scenario, metric);

  // 公平比较：目标的可调范围为全部方案扫描点的范围；默认取各方案都能达到的公共区间的中点
  const tKey = `${scenario}:${fairMode}`;
  const sweepOf = (s: SchemeView) =>
    (s.cases[scenario]?.sweep ?? []).map((q) => (fairMode === 'noise' ? n(q.noiseDb) : fmax(n(q.cpu), n(q.gpu)))).filter(Number.isFinite);
  const ranges = schemes.map(sweepOf).filter((v) => v.length >= 2);
  const all = ranges.flat();
  const tMin = all.length ? Math.floor(Math.min(...all)) : 0;
  const tMax = all.length ? Math.ceil(Math.max(...all)) : 100;
  const lo = ranges.length ? Math.max(...ranges.map((v) => Math.min(...v))) : tMin;
  const hi = ranges.length ? Math.min(...ranges.map((v) => Math.max(...v))) : tMax;
  const defTarget = Math.round(2 * (lo <= hi ? (lo + hi) / 2 : (tMin + tMax) / 2)) / 2;
  const target = targets[tKey] ?? defTarget;
  const fair = fairCompare(schemes, scenario, fairMode, target);
  const value = cheapestNearBest(fair);

  // 当前场景各指标的最佳方案（徽标）：按显示精度并列的都给；超过一半方案并列时不给（区分不出）
  const badges = new Map<string, string[]>();
  const withCase = schemes.filter((s) => s.cases[scenario]);
  for (const [k, label] of [
    ['score', '最高分'],
    ['tmax', '最凉'],
    ['noiseDb', '最安静'],
  ] as const) {
    const m = metricByKey(k);
    const shown = (s: SchemeView) => Number(m.get(s.cases[scenario]!.auto, s).toFixed(m.digits));
    const vals = withCase.map(shown).filter(Number.isFinite);
    if (!vals.length) continue;
    const bestV = m.better === 'low' ? Math.min(...vals) : Math.max(...vals);
    const top = withCase.filter((s) => shown(s) === bestV);
    if (top.length > withCase.length / 2) continue;
    for (const s of top) badges.set(s.id, [...(badges.get(s.id) ?? []), label]);
  }

  // 流场图的色标：同一场景各方案共用（温度上限 = 各方案机箱内空气温度 99 百分位的最大值，取整到 5°C）
  const refScheme = schemes.find((s) => s.id === refId && s.cases[scenario]) ?? schemes.find((s) => s.cases[scenario]);
  const { t: refThumb, loading: refLoading } = useThumb(refScheme?.cases[scenario]?.thumb);
  const thumbs = withCase.map((s) => s.cases[scenario]!.thumb);
  const stats = useScaleStats(thumbs);
  const tAmb = Math.min(...withCase.map((s) => s.layout?.ambientC ?? T_AMB_DEFAULT), T_AMB_DEFAULT);
  const tHi = stats ? Math.max(tAmb + 10, niceCeil(stats.t99, 5)) : T_HI_DEFAULT[scenario];
  const sHi = stats ? Math.max(1, niceCeil(stats.s99, 0.5)) : 2;
  const dHi = useDiffRange(thumbs, thumbMode === 'diff' ? refThumb : null);
  const range: [number, number] = thumbMode === 'temperature' ? [tAmb, tHi] : thumbMode === 'speed' ? [0, sHi] : [-dHi, dHi];
  const fieldStyle: FieldStyle = {
    mode: thumbMode,
    range,
    ref: thumbMode === 'diff' ? refThumb : null,
    refLoading: thumbMode === 'diff' && refLoading,
    stream,
    labels,
  };

  const [grid, setGrid] = useState(1);
  const [sweep, setSweep] = useState(true);
  const proto = p.data.protocol;
  const stepsPer = proto.autoSteps + (sweep ? proto.sweepPct.length * proto.sweepSteps : 0);
  const estMin = Math.round((3 * stepsPer * (grid >= 1 ? 0.5 : 0.1)) / 60);

  return (
    <div class="compare-page">
      <section class="section cmp-head">
        <div class="cmp-title">
          <h2>方案对比展示</h2>
          <span class="muted small">
            {schemes.length} 个风扇方案 × 办公 / 游戏 / 满载；预计算：{proto.gridScale >= 1 ? '精确 280²' : '预览 140²'}、自动温控（标准曲线）从静止推进{' '}
            {(proto.autoSteps * DT).toFixed(0)} s，取后 {((proto.autoSteps - proto.autoAvgFrom) * DT).toFixed(0)} s 均值（{p.data.generated} 生成）。
            2D 定性模型，看相对差别。
          </span>
        </div>
        <div class="cmp-controls">
          <div class="seg">
            {COMPARE_SCENARIOS.map((s) => (
              <button key={s.key} class={scenario === s.key ? 'active' : ''} onClick={() => setScenario(s.key)} title={`CPU/GPU/电源负载 ${s.powers.join('/')} W`}>
                {s.label}
              </button>
            ))}
          </div>
          <div class="seg">
            {(
              [
                ['temperature', '温度'],
                ['speed', '风速'],
                ['diff', '温差'],
              ] as const
            ).map(([k, label]) => (
              <button key={k} class={thumbMode === k ? 'active' : ''} onClick={() => setThumbMode(k)} title={k === 'diff' ? '与参考方案逐点相减：红 = 比参考方案热，蓝 = 更凉' : undefined}>
                {label}
              </button>
            ))}
          </div>
          {thumbMode === 'diff' && (
            <label class="small">
              参考{' '}
              <select class="cmp-ref" value={refScheme?.id ?? ''} onChange={(e) => setRefId((e.target as HTMLSelectElement).value)}>
                {withCase.map((s) => (
                  <option key={s.id} value={s.id}>
                    {s.short}
                  </option>
                ))}
              </select>
            </label>
          )}
          <label class="small">
            <input type="checkbox" checked={stream} onChange={(e) => setStream((e.target as HTMLInputElement).checked)} /> 流线
          </label>
          <label class="small">
            <input type="checkbox" checked={labels} onChange={(e) => setLabels((e.target as HTMLInputElement).checked)} /> 开口风量
          </label>
          <FieldLegend mode={thumbMode} range={range} />
        </div>
      </section>

      <section class="section">
        <h3>三个场景总览（评分，点格子切换场景）</h3>
        <div class="table-wrap">
          <table class="cmp-matrix">
            <thead>
              <tr>
                <th>方案</th>
                {COMPARE_SCENARIOS.map((s) => (
                  <th key={s.key}>{s.label}</th>
                ))}
              </tr>
            </thead>
            <tbody>
              {schemes.map((s) => (
                <tr key={s.id} class={selected === s.id ? 'sel' : ''}>
                  <th>
                    <span class="dot" style={{ background: colors.get(s.id) }} /> <span class="lbl-long">{s.label}</span>
                    <span class="lbl-short">{s.short}</span>
                    {s.kind === 'custom' && s.gridScale < 1 && <span class="tag">预览网格</span>}
                    {s.kind === 'custom' && (
                      <button class="link-btn" title="从对比中移除" onClick={() => p.onRemoveCustom(s.id)}>
                        ✕
                      </button>
                    )}
                  </th>
                  {COMPARE_SCENARIOS.map((sc) => {
                    const c = s.cases[sc.key];
                    return (
                      <td
                        key={sc.key}
                        class={scenario === sc.key ? 'cur' : ''}
                        style={{ background: c ? scoreColor(n(c.auto.score)) : undefined }}
                        onClick={() => {
                          setScenario(sc.key);
                          setSelected(s.id);
                        }}
                      >
                        {c ? (
                          <>
                            <b>{f0(n(c.auto.score))}</b>
                            <span class="small">
                              {' '}
                              {f0(n(c.auto.cpu))}/{f0(n(c.auto.gpu))}°C · {f1(n(c.auto.noiseDb))} dB
                              {Number.isFinite(cyclingNoise(c.auto)) ? ` ↻${f1(cyclingNoise(c.auto))}` : ''}
                              {n(c.auto.perfPct) < 99.95 ? ` · ${f1(n(c.auto.perfPct))}%` : ''}
                            </span>
                          </>
                        ) : (
                          <span class="muted">—</span>
                        )}
                      </td>
                    );
                  })}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
        <p class="muted small">
          格子里：评分 CPU/GPU 结温 · 噪音（· 有降频时的频率保持率）；↻ 后为显卡或电源风扇时转时停时评分用的感知噪音
          （转动时的声级 + 间歇性修正）。评分按功率分档，三列的分数不宜横向比较；同一列里比较各方案。
        </p>
      </section>

      <section class="section">
        <h3>{SCENARIO_LABEL[scenario]}场景：各方案（按{metric.label}排序）</h3>
        <p class="muted small">
          流场图为侧视（左 = 后部 I/O，右 = 前面板），{thumbMode === 'temperature' ? '温度' : thumbMode === 'speed' ? '风速' : `与"${refScheme?.short ?? ''}"的温差`}
          取自动温控阶段后 {((proto.autoSteps - proto.autoAvgFrom) * DT).toFixed(0)} s 的时间平均，各方案共用色标（温度色标的上限不计电源内部）。
          {stream ? `${thumbMode === 'diff' ? '深色线' : '白线'}为时均流线，箭头指流向；没有流线的地方时均风速低于 0.03 m/s（死区或回流中心）。` : ''}
          {labels ? '数字为各开口的时均净风量（CFM），橙色流出、青色流入。' : ''}点图放大，可看细节与读数。"在仿真页打开"按仿真页当前的网格档跑到稳态，
          预览 140² 与这里的精确 280² 相比 GPU 可能差几 °C。
        </p>
        <div class="cmp-cards">
          {ranked.map((s) => {
            const c = s.cases[scenario];
            if (!c) return null;
            const a = c.auto;
            return (
              <div key={s.id} class={`cmp-card${selected === s.id ? ' sel' : ''}`} onClick={() => setSelected(s.id)} style={{ borderColor: selected === s.id ? colors.get(s.id) : undefined }}>
                <div class="cmp-card-title">
                  <span class="dot" style={{ background: colors.get(s.id) }} />
                  <b>{s.label}</b>
                </div>
                <div class="muted small">{s.fans}</div>
                <FieldThumbView
                  src={c.thumb}
                  style={fieldStyle}
                  title={`${s.label}（${SCENARIO_LABEL[scenario]}）：点击放大`}
                  onClick={() => {
                    setSelected(s.id);
                    setZoom(s.id);
                  }}
                />
                <div class="cmp-badges">
                  {thumbMode === 'diff' && s.id === refScheme?.id && (
                    <span class="tag" title="温差图的参考方案（自身温差为 0）">
                      温差参考
                    </span>
                  )}
                  {(badges.get(s.id) ?? []).map((b) => (
                    <span key={b} class="badge">
                      {b}
                    </span>
                  ))}
                  {Math.abs(n(a.drift)) > DRIFT_WARN && (
                    <span class="tag" title="统计窗口内最高结温仍在变化（后 1/4 与前 1/4 均值之差），数值可能还差零点几 °C">
                      未完全稳态 {n(a.drift) > 0 ? '+' : ''}
                      {f1(n(a.drift))}°C
                    </span>
                  )}
                </div>
                <div class="cmp-metrics">
                  <span>CPU {f1(n(a.cpu))}°C</span>
                  <span>GPU {f1(n(a.gpu))}°C</span>
                  <span title={Number.isFinite(cyclingNoise(a)) ? '显卡或电源风扇时转时停：评分按感知噪音（转动时的声级 + 间歇性修正）' : undefined}>
                    噪音 {f1(n(a.noiseDb))} dB{Number.isFinite(cyclingNoise(a)) ? `（↻ 感知 ${f1(cyclingNoise(a))}）` : ''}
                  </span>
                  <span>性能 {f1(n(a.perfPct))}%</span>
                  <span>内温 {f1(n(a.interior))}°C</span>
                  <span>风量 {f1(n(a.cfm))}</span>
                  <span title={`机箱风扇：${s.price.detail}（型号库参考价，不含 CPU 塔扇、显卡与电源自带风扇）`}>风扇 ¥{f0(s.price.total)}</span>
                  <span class="cmp-score" style={{ background: scoreColor(n(a.score)) }}>
                    评分 {f0(n(a.score))}
                  </span>
                </div>
                <div class="row">
                  <button
                    class="cmp-open"
                    disabled={!p.canOpen}
                    onClick={(e) => {
                      e.stopPropagation();
                      p.onOpenInSim(s, scenario);
                    }}
                    title="载入这个方案与场景功率，回到仿真页并跑到稳态（之后可继续调整）"
                  >
                    在仿真页打开
                  </button>
                  {s.kind === 'custom' && (
                    <button
                      onClick={(e) => {
                        e.stopPropagation();
                        p.onRemoveCustom(s.id);
                      }}
                    >
                      移除
                    </button>
                  )}
                </div>
              </div>
            );
          })}
        </div>
      </section>

      <div class="cmp-two">
      <section class="section">
        <h3>
          指标对比
          <select class="cmp-metric" value={metricKey} onChange={(e) => setMetricKey((e.target as HTMLSelectElement).value)}>
            {METRICS.map((m) => (
              <option key={m.key} value={m.key}>
                {m.label}
                {m.unit ? `（${m.unit}）` : ''}
              </option>
            ))}
          </select>
          <span class="muted small">{metric.better === 'low' ? '越小越好' : '越大越好'}，点条可选中方案</span>
        </h3>
        <div class="chart-scroll">
          <BarChart schemes={ranked} scenario={scenario} metric={metric} colors={colors} selected={selected} onSelect={setSelected} />
        </div>
      </section>

      <section class="section">
        <h3>公平比较：同噪音 / 同温度</h3>
        <p class="muted small">
          自动温控下各方案的风扇转速不同，噪音也不同，直接比温度不公平。这里把风扇固定在全局 {proto.sweepPct.join(' / ')}% 转速各算一次
          （预设里是全部风扇；自定义布局里设为固定转速的风扇保持自己的转速），
          连成"噪音—温度"曲线（空心圆为自动温控的结果）：曲线越靠左下越好——同样的噪音更凉，或同样的温度更安静。
        </p>
        <div class="row cmp-fair-ctrl">
          <div class="seg">
            <button class={fairMode === 'noise' ? 'active' : ''} onClick={() => setFairMode('noise')}>
              同噪音
            </button>
            <button class={fairMode === 'temp' ? 'active' : ''} onClick={() => setFairMode('temp')}>
              同温度
            </button>
          </div>
          <label class="slider-row grow">
            <span class="slider-label">{fairMode === 'noise' ? '噪音' : '最高结温'}</span>
            <input
              type="range"
              min={tMin}
              max={tMax}
              step={0.5}
              value={Number.isFinite(target) ? target : tMin}
              onInput={(e) => setTargets({ ...targets, [tKey]: Number((e.target as HTMLInputElement).value) })}
            />
            <span class="slider-val">
              {f1(target)} {fairMode === 'noise' ? 'dB' : '°C'}
            </span>
          </label>
          <select value={yKey} onChange={(e) => setYKey((e.target as HTMLSelectElement).value as 'tmax' | 'perfPct')}>
            <option value="tmax">纵轴：最高结温</option>
            <option value="perfPct">纵轴：性能</option>
          </select>
        </div>
        <div class="chart-scroll">
          <TradeoffChart schemes={schemes} scenario={scenario} yKey={yKey} colors={colors} selected={selected} guide={{ mode: fairMode, value: target }} onSelect={setSelected} />
        </div>
        <div class="table-wrap">
          <table class="fan-table cmp-fair">
            <thead>
              <tr>
                <th>排名</th>
                <th>方案</th>
                <th>{fairMode === 'noise' ? `${f1(target)} dB 时最高结温` : `结温 ≤ ${f1(target)}°C 所需噪音`}</th>
                <th>性能 %</th>
                <th>全局转速 %</th>
                <th>风扇成本</th>
              </tr>
            </thead>
            <tbody>
              {fair.map((r, k) => (
                <tr key={r.scheme.id} class={selected === r.scheme.id ? 'sel' : ''} onClick={() => setSelected(r.scheme.id)}>
                  <td>{Number.isFinite(r.value) ? k + 1 : '—'}</td>
                  <td>
                    <span class="dot" style={{ background: colors.get(r.scheme.id) }} /> {r.scheme.short}
                  </td>
                  <td>
                    {Number.isFinite(r.value) ? `${r.atMin ? '≤ ' : ''}${f1(r.value)}${fairMode === 'noise' ? ' °C' : ' dB'}` : '达不到'}
                    {r.unsettled ? ' *' : ''}
                  </td>
                  <td>{f1(r.perf)}</td>
                  <td>{f0(r.pct)}</td>
                  <td title={r.scheme.price.detail}>¥{f0(r.scheme.price.total)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
        {value && (
          <p class="cmp-value small">
            {value.cheap.scheme.id === value.best.scheme.id ? (
              <>
                最好的方案 <b>{value.best.scheme.short}</b> 也是接近最好（{fairMode === 'noise' ? '结温差 ≤ 1°C' : '噪音差 ≤ 1 dB'}、性能相当）的方案里最便宜的（¥
                {f0(value.best.scheme.price.total)}）。
              </>
            ) : (
              <>
                性价比：<b>{value.cheap.scheme.short}</b>（¥{f0(value.cheap.scheme.price.total)}）与最好的 {value.best.scheme.short}（¥
                {f0(value.best.scheme.price.total)}）相差不到 {fairMode === 'noise' ? '1°C' : '1 dB'}、性能相当，便宜 ¥
                {f0(value.best.scheme.price.total - value.cheap.scheme.price.total)}。
              </>
            )}
          </p>
        )}
        <p class="muted small">
          风扇成本为机箱风扇的型号库参考价合计（原装风扇计 0 元，不含塔扇、显卡与电源自带风扇）。
          "达不到"：该方案在扫描的转速范围内到不了这个噪音或温度。"≤"：最低一档转速（{proto.sweepPct[0]}%）已经满足，实际所需噪音还可以更低，
          排名只作参考。满载时低转速可能触发温度墙降频，结温停在降频阈，此时看"性能"一栏（并列时按性能排序）。"*"：所用扫描点在统计窗口内
          仍有超过 {DRIFT_WARN}°C 的漂移，未完全稳态。
        </p>
      </section>
      </div>

      <section class="section">
        <h3>加入自定义方案</h3>
        <p class="muted small">
          把仿真页当前已应用的布局（{p.currentLabel}，含温控曲线）按同样的口径在后台计算三个场景，结果加入上面的对比（只保存在当前页面）。
        </p>
        <div class="row">
          <label>
            网格{' '}
            <select class="cmp-grid" value={String(grid)} onChange={(e) => setGrid(Number((e.target as HTMLSelectElement).value))}>
              <option value="1">精确 280²（与预计算一致）</option>
              <option value="0.5">预览 140²（快约 5 倍，GPU 可能差几 °C）</option>
            </select>
          </label>
          <label>
            <input type="checkbox" checked={sweep} onChange={(e) => setSweep((e.target as HTMLInputElement).checked)} /> 含转速扫描（公平比较用）
          </label>
          <span class="muted small">约 {estMin >= 60 ? `${Math.floor(estMin / 60)} 小时 ${estMin % 60} 分钟` : `${Math.max(1, estMin)} 分钟`}（仿真页同时运行会更慢）</span>
          <button
            class="primary cmp-add"
            disabled={!p.canAddCurrent || !!(p.job && !p.job.error)}
            onClick={() => p.onAddCurrent({ gridScale: grid, sweep, scenarios: COMPARE_SCENARIOS.map((s) => s.key) })}
          >
            加入当前布局
          </button>
        </div>
        {p.job && (
          <div class="cmp-job">
            {p.job.error ? (
              <span class="warn">计算失败：{p.job.error}</span>
            ) : (
              <>
                <span>
                  正在计算 {p.job.label}：{SCENARIO_LABEL[p.job.scenario]}（{p.job.index + 1}/{p.job.count}）{p.job.done}/{p.job.total} 步
                </span>
                <progress max={p.job.count * p.job.total} value={p.job.index * p.job.total + p.job.done} />
              </>
            )}
            <button class="cmp-cancel" onClick={p.onCancelJob}>
              {p.job.error ? '关闭' : '取消'}
            </button>
          </div>
        )}
      </section>
      {zoom && (
        <FieldModal
          schemes={ranked.filter((s) => s.cases[scenario])}
          id={zoom}
          scenario={scenario}
          style={fieldStyle}
          refLabel={refScheme?.short ?? ''}
          color={(id) => colors.get(id) ?? '#888'}
          onNav={setZoom}
          onClose={() => setZoom(null)}
        />
      )}
    </div>
  );
}

const statsCache = new WeakMap<FieldThumb, { t99: number; s99: number }>();
/** 每张流场图的色标统计只算一次（切回已看过的场景不再重算） */
function cachedStats(t: FieldThumb): { t99: number; s99: number } {
  let v = statsCache.get(t);
  if (!v) statsCache.set(t, (v = fieldStats(t)));
  return v;
}

/** 共用色标的上限：各方案色标统计（机箱内、不含电源内部，99 百分位）的最大值；解码完成前 null */
function useScaleStats(thumbs: ThumbSrc[]): { t99: number; s99: number } | null {
  const [st, setSt] = useState<{ key: string; v: { t99: number; s99: number } } | null>(null);
  const key = thumbs.map(objId).join('|');
  useEffect(() => {
    let live = true;
    Promise.all(thumbs.map(decodeThumb)).then(
      (ts) => {
        if (!live) return;
        const s = ts.map(cachedStats);
        const mx = (k: 't99' | 's99') => Math.max(...s.map((x) => x[k]).filter(Number.isFinite), -Infinity);
        setSt({ key, v: { t99: mx('t99'), s99: mx('s99') } });
      },
      () => {},
    );
    return () => {
      live = false;
    };
  }, [key]);
  return st && st.key === key && Number.isFinite(st.v.t99) ? st.v : null;
}

/** 对象的序号（依赖比较用：同一对象同一序号） */
const ids = new WeakMap<object, number>();
let nextId = 0;
function objId(o: object): number {
  let k = ids.get(o);
  if (k === undefined) ids.set(o, (k = ++nextId));
  return k;
}

/** 温差色标的范围：各方案与参考方案机箱内逐点温差绝对值 98 百分位的最大值（取整到 1°C，至少 2°C）；解码完成前用 5°C。
 *  ref = null（不在温差视图）时不计算 */
function useDiffRange(thumbs: ThumbSrc[], ref: FieldThumb | null): number {
  const [d, setD] = useState(5);
  const key = thumbs.map(objId).join('|');
  useEffect(() => {
    if (!ref) return;
    let live = true;
    Promise.all(thumbs.map(decodeThumb)).then(
      (ts) => {
        if (!live) return;
        let worst = 0;
        for (const t of ts) {
          if (t === ref || !sameGrid(t, ref)) continue;
          const diffs: number[] = [];
          for (let r = 0; r < t.crop.h; r++)
            for (let c = 0; c < t.crop.w; c++) {
              if (!inScaleRegion(ref, c, r)) continue;
              const k = r * t.crop.w + c;
              diffs.push(Math.abs(t.T[k] - ref.T[k]));
            }
          worst = Math.max(worst, n(percentile(diffs, 98)));
        }
        setD(Math.max(2, niceCeil(worst, 1)));
      },
      () => {},
    );
    return () => {
      live = false;
    };
  }, [key, ref]);
  return d;
}

/** 流场图色标（与卡片、大图共用） */
function FieldLegend({ mode, range }: { mode: FieldMode; range: [number, number] }) {
  const [lo, hi] = range;
  const grad =
    mode === 'temperature'
      ? colormapGradient('heat', 'to right', HEAT_FLOOR, 1)
      : mode === 'speed'
        ? colormapGradient('speed', 'to right')
        : colormapGradient('diverging', 'to right');
  const fmt = (v: number) => (mode === 'speed' ? v.toFixed(1) : `${v > 0 && mode === 'diff' ? '+' : ''}${v.toFixed(0)}`);
  const unit = mode === 'speed' ? 'm/s' : '°C';
  return (
    <span class="cmp-legend" title={mode === 'diff' ? '红 = 比参考方案热，蓝 = 更凉' : undefined}>
      <span class="muted small">
        {fmt(lo)}
        {mode === 'diff' ? ' 更凉' : ''}
      </span>
      <span class="cmp-legend-bar" style={{ background: grad }} />
      <span class="muted small">
        {fmt(hi)} {unit}
        {mode === 'diff' ? ' 更热' : ''}
      </span>
    </span>
  );
}

/** 放大的流场图：标注更全、流线更密、悬停读数；左右切换方案，Esc 关闭 */
function FieldModal(p: {
  schemes: SchemeView[];
  id: string;
  scenario: ScenarioKey;
  style: FieldStyle;
  refLabel: string;
  color: (id: string) => string;
  onNav: (id: string) => void;
  onClose: () => void;
}) {
  const k = Math.max(0, p.schemes.findIndex((s) => s.id === p.id));
  const s = p.schemes[k];
  const [hover, setHover] = useState('');
  const box = useRef<HTMLDivElement>(null);
  useEffect(() => setHover(''), [p.id, p.style.mode]); // 换方案后旧读数不再适用
  useEffect(() => box.current?.focus(), []);
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') p.onClose();
      else if (e.key === 'ArrowLeft' && k > 0) p.onNav(p.schemes[k - 1].id);
      else if (e.key === 'ArrowRight' && k < p.schemes.length - 1) p.onNav(p.schemes[k + 1].id);
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [k, p.schemes]);
  if (!s) return null;
  const c = s.cases[p.scenario]!;
  const a = c.auto;
  return (
    <div class="cmp-modal" onClick={p.onClose}>
      <div class="cmp-modal-box" ref={box} role="dialog" aria-modal="true" aria-label={`${s.label} 流场图`} tabIndex={-1} onClick={(e) => e.stopPropagation()}>
        <div class="cmp-modal-head">
          <span class="dot" style={{ background: p.color(s.id) }} />
          <b>{s.label}</b>
          <span class="muted small">
            {SCENARIO_LABEL[p.scenario]} · {s.fans}
            {p.style.mode === 'diff' ? ` · 减去"${p.refLabel}"` : ''}
          </span>
          <span class="grow" />
          <button disabled={k <= 0} onClick={() => p.onNav(p.schemes[k - 1].id)} title="上一个方案（←）">
            ‹
          </button>
          <span class="muted small">
            {k + 1}/{p.schemes.length}
          </span>
          <button disabled={k >= p.schemes.length - 1} onClick={() => p.onNav(p.schemes[k + 1].id)} title="下一个方案（→）">
            ›
          </button>
          <button class="cmp-modal-close" onClick={p.onClose} title="关闭（Esc）">
            ✕
          </button>
        </div>
        <FieldThumbView src={c.thumb} style={p.style} large onHover={setHover} />
        <div class="cmp-modal-foot">
          <FieldLegend mode={p.style.mode} range={p.style.range} />
          <span class="small">
            CPU {f1(n(a.cpu))}°C · GPU {f1(n(a.gpu))}°C · 噪音 {f1(n(a.noiseDb))} dB
            {Number.isFinite(cyclingNoise(a)) ? `（↻ 感知 ${f1(cyclingNoise(a))} dB）` : ''} · 风量 {f1(n(a.cfm))} CFM · 风扇 ¥{f0(s.price.total)}（{s.price.detail}）
          </span>
        </div>
        <div class="cmp-readout small muted">{hover || '把鼠标移到图上看读数'}</div>
      </div>
    </div>
  );
}
