// 右侧面板：状态页（实时状态、综合评分、CFD 诊断、智能诊断）与功率/风扇页（功率、全局风扇、风扇工作状态表）。
import type { ComponentName, StaticInfo, Status } from '../worker/protocol';

const f1 = (v: number | undefined) => (v === undefined || !Number.isFinite(v) ? '--' : v.toFixed(1));
const f0 = (v: number | undefined) => (v === undefined || !Number.isFinite(v) ? '--' : v.toFixed(0));
const exp1 = (v: number) => {
  // MATLAB %.1e：1.2e+05
  const [m, e] = v.toExponential(1).split('e');
  const n = Number(e);
  return `${m}e${n < 0 ? '-' : '+'}${String(Math.abs(n)).padStart(2, '0')}`;
};

function Section({ title, children }: { title: string; children: preact.ComponentChildren }) {
  return (
    <section class="section">
      <h3>{title}</h3>
      {children}
    </section>
  );
}

export function StatusTab({ st, info }: { st: Status | null; info: StaticInfo | null }) {
  const sc = st?.scores;
  const t = st?.temps;
  const d = st?.diag;
  return (
    <div class="tab-body">
      <Section title="实时状态">
        <div class="grid4">
          <span class="c-intake">进气 {f1(t?.intake)}°C</span>
          <span class="c-exhaust">顶排 {f1(t?.topExhaust)}°C</span>
          <span class="c-exhaust">后排 {f1(t?.rearExhaust)}°C</span>
          <span class="c-inside">内部 {f1(t?.internalAmbient)}°C</span>
          <span class="c-noise">噪音 {sc ? sc.noiseDb : '--'} dB</span>
          <span class="c-perf">性能 {sc ? sc.performance : '--'}%</span>
          <span class={throttleClass(st, 'cpu')}>CPU {info?.cpu ? `${sc ? sc.cpuTemp : '--'}°C` : '—'}</span>
          <span class={throttleClass(st, 'gpu')}>GPU {info?.gpu ? `${sc ? sc.gpuTemp : '--'}°C` : '—'}</span>
        </div>
        <div class="muted small">
          风量 {f1(t?.totalCFM)} CFM · 电源 {st?.tj.psu !== undefined ? `${f1(st.tj.psu)}°C` : '—'} · 仿真 {st ? st.time.toFixed(2) : '--'} s（{st?.iteration ?? 0} 步）
        </div>
      </Section>
      <Section title="综合评分">
        <div class="score-row">
          <span class="score-total">总分 {sc ? sc.total : '--'}/100</span>
          <div class="grid3">
            <span>散热 {sc?.cooling ?? '--'}</span>
            <span>性能 {sc?.performance ?? '--'}</span>
            <span>均衡 {sc?.balance ?? '--'}</span>
            <span>余量 {sc?.margin ?? '--'}</span>
            <span>噪音 {sc?.noise ?? '--'}</span>
            <span>性价比 {sc?.value ?? '--'}</span>
          </div>
        </div>
      </Section>
      <Section title="CFD 诊断">
        <div class="grid3 c-cfd">
          <span>Re {d ? exp1(d.Re) : '--'}</span>
          <span>Gr {d ? exp1(d.Gr) : '--'}</span>
          <span>Nu {d ? d.Nu.toFixed(1) : '--'}</span>
          <span>Ra {d ? exp1(d.Ra) : '--'}</span>
          <span class="c-dead">死区 {st ? (st.deadZone * 100).toFixed(1) : '--'}%</span>
        </div>
        <div class="c-cfd small">流动状态：{d?.flowRegime ?? '--'}</div>
      </Section>
      <Section title="智能诊断">
        <ul class="recs">
          {(st?.recs ?? []).map((r, k) => (
            <li key={k} class={`rec-${r.level}`}>
              <b>{r.level === 'good' ? '✓' : r.level === 'warning' ? '!' : 'i'}</b> <span class="rec-title">{r.title}</span>：{r.desc}
            </li>
          ))}
        </ul>
      </Section>
    </div>
  );
}

function throttleClass(st: Status | null, n: ComponentName): string {
  return st && (st.throttle[n] ?? 0) > 0 ? 'c-hot' : 'c-plain';
}

export const POWER_LIMITS: Record<ComponentName, [number, number]> = { cpu: [20, 250], gpu: [20, 400], psu: [50, 1200] };
export const SCENARIOS: { key: string; label: string; p: [number, number, number] }[] = [
  { key: 'daily', label: '办公', p: [40, 35, 200] },
  { key: 'gaming', label: '游戏', p: [100, 200, 500] },
  { key: 'heavy', label: '满载', p: [180, 320, 850] },
];

interface FansTabProps {
  st: Status | null;
  powers: Record<ComponentName, number>;
  autoFan: boolean;
  fanPct: number;
  onPower: (name: ComponentName, w: number) => void;
  onScenario: (p: [number, number, number]) => void;
  onFan: (auto: boolean, pct: number) => void;
}

export function FansTab(p: FansTabProps) {
  const fans = p.st?.fans ?? [];
  let loud = -1;
  fans.forEach((f, k) => {
    if (loud < 0 || f.sharePct > fans[loud].sharePct) loud = k;
  });
  const sl = (name: ComponentName, label: string) => (
    <label class="slider-row">
      <span class="slider-label">{label}</span>
      <input
        type="range"
        min={POWER_LIMITS[name][0]}
        max={POWER_LIMITS[name][1]}
        step={1}
        value={p.powers[name]}
        onInput={(e) => p.onPower(name, Math.round(Number((e.target as HTMLInputElement).value)))}
      />
      <span class="slider-val">{p.powers[name]} W</span>
    </label>
  );
  return (
    <div class="tab-body">
      <Section title="功率调整">
        <div class="power-grid">
          <div>
            {sl('cpu', 'CPU')}
            {sl('gpu', 'GPU')}
            {sl('psu', '电源负载')}
          </div>
          <div class="scenario-btns">
            {SCENARIOS.map((s) => (
              <button key={s.key} onClick={() => p.onScenario(s.p)}>
                {s.label}
              </button>
            ))}
          </div>
        </div>
      </Section>
      <Section title="风扇转速（“自动”档风扇）">
        <div class="fan-ctrl">
          <button class={p.autoFan ? 'active' : ''} onClick={() => p.onFan(!p.autoFan, p.fanPct)} title="自动：按 CPU/GPU 温度调速；手动：固定转速">
            {p.autoFan ? '自动温控' : '手动'}
          </button>
          <label class="slider-row grow">
            <span class="slider-label">手动</span>
            <input
              type="range"
              min={0}
              max={100}
              step={1}
              value={p.fanPct}
              onInput={(e) => p.onFan(false, Math.round(Number((e.target as HTMLInputElement).value)))}
            />
            <span class="slider-val">{p.fanPct}%</span>
          </label>
        </div>
      </Section>
      <Section title="各风扇工作状态">
        <div class="table-wrap">
          <table class="fan-table">
            <thead>
              <tr>
                <th>风扇</th>
                <th>转速</th>
                <th>实测 CFM</th>
                <th>自由 CFM</th>
                <th>静压 Pa</th>
                <th>噪音 dB</th>
                <th>占比 %</th>
              </tr>
            </thead>
            <tbody>
              {fans.map((f, k) => (
                <tr key={k}>
                  <td>{f.name}</td>
                  <td>{f0(f.rpm)}</td>
                  <td>{f1(f.cfm)}</td>
                  <td>{f1(f.freeCfm)}</td>
                  <td>{f1(f.dp)}</td>
                  <td>{f1(f.noiseDb)}</td>
                  <td>{f0(f.sharePct)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
        {loud >= 0 && p.st && (
          <div class="c-noise small">
            总噪音 {p.st.noiseDb.toFixed(1)} dB(A)；最响：{fans[loud].name} {fans[loud].noise.total.toFixed(1)} dB（占 {fans[loud].sharePct.toFixed(0)}%）
            <br />= 转速 {fans[loud].noise.base.toFixed(1)} {sign1(fans[loud].noise.op)} 工作点 {sign1(fans[loud].noise.grille)} 格栅 {sign1(fans[loud].noise.pos)} 位置
          </div>
        )}
        <p class="muted small">
          实测 = 穿过风扇的流量；自由 = 当前转速下的自由风量（无阻力）；静压 = 工作点压升。噪音 = 听音位置（机箱前侧 1 m）单扇声压级 =
          转速 + 工作点（背压过高/近失速）+ 格栅/滤网 + 位置修正；占比 = 声能占总噪音的百分比。
        </p>
      </Section>
    </div>
  );
}

const sign1 = (v: number) => (v >= 0 ? '+' : '') + v.toFixed(1);
