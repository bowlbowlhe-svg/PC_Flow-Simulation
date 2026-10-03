// 方案对比展示页：多个风扇方案 × 办公/游戏/满载，一眼看清温度、性能、噪音与评分的差别；
// 预计算数据打开即显示，可把仿真页的当前布局加入对比（后台计算），点方案可回到仿真页细调。
import { useMemo, useState } from 'preact/hooks';
import { COMPARE_SCENARIOS, type ScenarioKey } from '../../compare/scenarios';
import type { CompareData } from '../../compare/data';
import { colormapGradient } from '../colormap';
import { BarChart, TradeoffChart } from './charts';
import {
  buildSchemes,
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
import { ThumbCanvas, type ThumbMode } from './ThumbCanvas';

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

/** 缩略图温度色标上限（空气温度为主，元件超出时取最亮色） */
const THUMB_TMAX: Record<ScenarioKey, number> = { office: 45, gaming: 60, heavy: 70 };
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
  const [thumbMode, setThumbMode] = useState<ThumbMode>('temperature');
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

  // 当前场景各指标的最佳方案（徽标）：按显示精度并列的都给；超过一半方案并列时不给（区分不出）
  const badges = new Map<string, string[]>();
  const withCase = schemes.filter((s) => s.cases[scenario]);
  for (const [k, label] of [
    ['score', '最高分'],
    ['tmax', '最凉'],
    ['noiseDb', '最安静'],
  ] as const) {
    const m = metricByKey(k);
    const shown = (s: SchemeView) => Number(m.get(s.cases[scenario]!.auto).toFixed(m.digits));
    const vals = withCase.map(shown).filter(Number.isFinite);
    if (!vals.length) continue;
    const bestV = m.better === 'low' ? Math.min(...vals) : Math.max(...vals);
    const top = withCase.filter((s) => shown(s) === bestV);
    if (top.length > withCase.length / 2) continue;
    for (const s of top) badges.set(s.id, [...(badges.get(s.id) ?? []), label]);
  }

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
            <button class={thumbMode === 'temperature' ? 'active' : ''} onClick={() => setThumbMode('temperature')}>
              温度
            </button>
            <button class={thumbMode === 'speed' ? 'active' : ''} onClick={() => setThumbMode('speed')}>
              风速
            </button>
          </div>
          <span class="cmp-legend">
            <span class="muted small">{thumbMode === 'temperature' ? '25' : '0'}</span>
            <span class="cmp-legend-bar" style={{ background: colormapGradient(thumbMode === 'temperature' ? 'heat' : 'speed', 'to right') }} />
            <span class="muted small">{thumbMode === 'temperature' ? `${THUMB_TMAX[scenario]} °C` : '2 m/s'}</span>
          </span>
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
          格子里：评分 CPU/GPU 结温 · 噪音（· 有降频时的频率保持率）。评分按功率分档，三列的分数不宜横向比较；同一列里比较各方案。
        </p>
      </section>

      <section class="section">
        <h3>{SCENARIO_LABEL[scenario]}场景：各方案（按{metric.label}排序）</h3>
        <p class="muted small">
          缩略图为自动温控末态的侧视{thumbMode === 'temperature' ? '温度' : '风速'}（左 = 后部 I/O，右 = 前面板）。"在仿真页打开"按仿真页当前的网格档跑到稳态，
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
                <ThumbCanvas src={c.thumb} mode={thumbMode} tMax={THUMB_TMAX[scenario]} title={`${s.label}（${SCENARIO_LABEL[scenario]}，自动温控末态）`} />
                <div class="cmp-badges">
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
                  <span>噪音 {f1(n(a.noiseDb))} dB</span>
                  <span>性能 {f1(n(a.perfPct))}%</span>
                  <span>内温 {f1(n(a.interior))}°C</span>
                  <span>风量 {f1(n(a.cfm))}</span>
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
                </tr>
              ))}
            </tbody>
          </table>
        </div>
        <p class="muted small">
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
    </div>
  );
}
