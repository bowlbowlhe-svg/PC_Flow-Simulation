// 对比展示页的图（SVG，随容器宽度缩放）：指标条形图、噪音—温度权衡曲线。
import type { ScenarioKey } from '../../compare/scenarios';
import { fmax, n, type MetricDef, type SchemeView } from './schemes';

function niceStep(range: number, target: number): number {
  const raw = range / Math.max(1, target);
  const p = 10 ** Math.floor(Math.log10(raw));
  const m = raw / p;
  return (m <= 1 ? 1 : m <= 2 ? 2 : m <= 5 ? 5 : 10) * p;
}

const fmtV = (v: number, d: number) => (Number.isFinite(v) ? v.toFixed(d) : '—');

/** 横向条形图：按指标从好到差排列；selected 高亮 */
export function BarChart(p: {
  schemes: SchemeView[]; // 已排序
  scenario: ScenarioKey;
  metric: MetricDef;
  colors: Map<string, string>;
  selected: string | null;
  onSelect: (id: string) => void;
}) {
  const rowH = 26;
  const L = 112;
  const R = 64;
  const W = 640;
  const H = p.schemes.length * rowH + 24;
  const vals = p.schemes.map((s) => {
    const c = s.cases[p.scenario];
    return c ? p.metric.get(c.auto, s) : NaN;
  });
  const fin = vals.filter(Number.isFinite);
  const base = Math.min(p.metric.base ?? 0, ...(fin.length ? fin : [0]));
  let top = fin.length ? Math.max(...fin) : 1;
  if (top <= base) top = base + 1;
  const step = niceStep(top - base, 5);
  const hi = Math.ceil(top / step) * step;
  const x = (v: number) => L + ((v - base) / (hi - base)) * (W - L - R);
  const ticks: number[] = [];
  for (let v = Math.ceil(base / step) * step; v <= hi + 1e-9; v += step) ticks.push(v);
  return (
    <svg class="chart-svg" viewBox={`0 0 ${W} ${H}`} role="img" aria-label={`${p.metric.label}条形图`}>
      {ticks.map((v) => (
        <g key={v}>
          <line x1={x(v)} x2={x(v)} y1={4} y2={H - 18} class="grid" />
          <text x={x(v)} y={H - 4} class="tick" text-anchor="middle">
            {v.toFixed(step < 1 ? 1 : 0)}
          </text>
        </g>
      ))}
      {p.schemes.map((s, k) => {
        const v = vals[k];
        const y = 6 + k * rowH;
        const sel = p.selected === s.id;
        return (
          <g key={s.id} class={`bar-row${sel ? ' sel' : ''}`} onClick={() => p.onSelect(s.id)}>
            <text x={L - 8} y={y + 13} class="bar-label" text-anchor="end">
              {s.short}
            </text>
            {Number.isFinite(v) && (
              <rect x={L} y={y + 2} width={Math.max(1, x(v) - L)} height={rowH - 8} rx={3} fill={p.colors.get(s.id)} opacity={sel ? 1 : 0.75} />
            )}
            <text x={Number.isFinite(v) ? x(v) + 6 : L + 6} y={y + 13} class="bar-value">
              {fmtV(v, p.metric.digits)}
            </text>
          </g>
        );
      })}
    </svg>
  );
}

/**
 * 噪音—温度（或性能）权衡曲线：每个方案一条线（全局手动转速扫描），空心圆为自动温控的结果；
 * 竖线（同噪音）或横线（同温度）为当前比较位置。曲线越靠左下（性能为左上）越好。
 */
export function TradeoffChart(p: {
  schemes: SchemeView[];
  scenario: ScenarioKey;
  yKey: 'tmax' | 'perfPct';
  colors: Map<string, string>;
  selected: string | null;
  guide: { mode: 'noise' | 'temp'; value: number };
  onSelect: (id: string) => void;
}) {
  const W = 640;
  const H = 340;
  const L = 48;
  const R = 16;
  const T = 14;
  const B = 36;
  const yOf = (m: { cpu: number; gpu: number; perfPct: number }) => (p.yKey === 'tmax' ? fmax(n(m.cpu), n(m.gpu)) : n(m.perfPct));
  const pts: { x: number; y: number }[] = [];
  for (const s of p.schemes) {
    const c = s.cases[p.scenario];
    if (!c) continue;
    for (const q of [...c.sweep, c.auto]) pts.push({ x: n(q.noiseDb), y: yOf(q) });
  }
  const fx = pts.map((q) => q.x).filter(Number.isFinite);
  const fy = pts.map((q) => q.y).filter(Number.isFinite);
  if (!fx.length || !fy.length) return <div class="muted small">没有转速扫描数据</div>;
  const xs0 = niceStep(Math.max(...fx) - Math.min(...fx) || 1, 6);
  const x0 = Math.floor(Math.min(...fx) / xs0) * xs0;
  const x1 = Math.ceil(Math.max(...fx) / xs0) * xs0 || x0 + xs0;
  const ys0 = niceStep(Math.max(...fy) - Math.min(...fy) || 1, 5);
  const y0 = Math.floor(Math.min(...fy) / ys0) * ys0;
  const y1 = Math.ceil(Math.max(...fy) / ys0) * ys0 || y0 + ys0;
  const X = (v: number) => L + ((v - x0) / (x1 - x0 || 1)) * (W - L - R);
  const Y = (v: number) => T + (1 - (v - y0) / (y1 - y0 || 1)) * (H - T - B);
  const xt: number[] = [];
  for (let v = x0; v <= x1 + 1e-9; v += xs0) xt.push(v);
  const yt: number[] = [];
  for (let v = y0; v <= y1 + 1e-9; v += ys0) yt.push(v);
  const g = p.guide;
  return (
    <svg class="chart-svg" viewBox={`0 0 ${W} ${H}`} role="img" aria-label="噪音与温度权衡曲线">
      {xt.map((v) => (
        <g key={`x${v}`}>
          <line x1={X(v)} x2={X(v)} y1={T} y2={H - B} class="grid" />
          <text x={X(v)} y={H - B + 14} class="tick" text-anchor="middle">
            {v.toFixed(xs0 < 1 ? 1 : 0)}
          </text>
        </g>
      ))}
      {yt.map((v) => (
        <g key={`y${v}`}>
          <line x1={L} x2={W - R} y1={Y(v)} y2={Y(v)} class="grid" />
          <text x={L - 6} y={Y(v) + 4} class="tick" text-anchor="end">
            {v.toFixed(ys0 < 1 ? 1 : 0)}
          </text>
        </g>
      ))}
      <text x={(L + W - R) / 2} y={H - 4} class="axis-label" text-anchor="middle">
        噪音 dB(A)
      </text>
      <text x={12} y={(T + H - B) / 2} class="axis-label" text-anchor="middle" transform={`rotate(-90 12 ${(T + H - B) / 2})`}>
        {p.yKey === 'tmax' ? '最高结温 °C' : '性能 %'}
      </text>
      {g.mode === 'noise' && Number.isFinite(g.value) && g.value >= x0 && g.value <= x1 && (
        <line x1={X(g.value)} x2={X(g.value)} y1={T} y2={H - B} class="guide" />
      )}
      {g.mode === 'temp' && p.yKey === 'tmax' && Number.isFinite(g.value) && g.value >= y0 && g.value <= y1 && (
        <line x1={L} x2={W - R} y1={Y(g.value)} y2={Y(g.value)} class="guide" />
      )}
      {p.schemes.map((s) => {
        const c = s.cases[p.scenario];
        if (!c) return null;
        const col = p.colors.get(s.id)!;
        const sw = [...c.sweep].sort((a, b) => a.pct - b.pct).filter((q) => Number.isFinite(n(q.noiseDb)) && Number.isFinite(yOf(q)));
        const sel = p.selected === s.id;
        const a = c.auto;
        return (
          <g key={s.id} class="trade-line" onClick={() => p.onSelect(s.id)} opacity={p.selected && !sel ? 0.35 : 1}>
            <polyline points={sw.map((q) => `${X(n(q.noiseDb))},${Y(yOf(q))}`).join(' ')} fill="none" stroke={col} stroke-width={sel ? 3 : 1.8} />
            {sw.map((q) => (
              <circle key={q.pct} cx={X(n(q.noiseDb))} cy={Y(yOf(q))} r={3} fill={col}>
                <title>{`${s.short} 全局 ${q.pct}%：${n(q.noiseDb).toFixed(1)} dB，${yOf(q).toFixed(1)}${Math.abs(n(q.drift)) > 0.3 ? '（未完全稳态）' : ''}`}</title>
              </circle>
            ))}
            {Number.isFinite(n(a.noiseDb)) && Number.isFinite(yOf(a)) && (
              <circle cx={X(n(a.noiseDb))} cy={Y(yOf(a))} r={5} fill="none" stroke={col} stroke-width={2}>
                <title>{`${s.short} 自动温控：${n(a.noiseDb).toFixed(1)} dB，${yOf(a).toFixed(1)}`}</title>
              </circle>
            )}
          </g>
        );
      })}
    </svg>
  );
}
