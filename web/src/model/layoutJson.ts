// 布局 JSON 存取与规整（移植自 layout_json.m、acoustics_validate.m）。
// JSON 里 NaN 存为 null；读取时补齐缺省字段、把单个对象规整为数组、并做取值检查。
import type { Acoustics, CaseFan, Layout } from './types';
import { hasModel } from './fans';
import { acousticsDefault } from './layoutDefault';
import { LayoutError } from './gpuSlots';

/** 保存：JSON.stringify 会把 NaN 写成 null，与 MATLAB jsonencode 一致 */
export function layoutToJson(L: Layout): string {
  return JSON.stringify(L);
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
type Raw = any;

function asArray<T>(v: T | T[] | null | undefined): T[] {
  if (v === undefined || v === null) return [];
  return Array.isArray(v) ? v : [v];
}

function numOrNaN(v: unknown): number {
  return v === null || v === undefined ? NaN : Number(v);
}

/** 读取并规整（与 layout_json('load') 同口径） */
export function layoutFromJson(text: string): Layout {
  return normalizeLayout(JSON.parse(text));
}

export function normalizeLayout(raw: Raw): Layout {
  const L: Raw = structuredClone(raw);
  validateDomain(L);
  // 壁温：null → NaN（绝热）
  for (const side of ['rear', 'front', 'top', 'bottom']) {
    L.chassis.wallTempC[side] = numOrNaN(L.chassis.wallTempC[side]);
  }
  if (L.gpu && L.gpu.fans) L.gpu.fans.xs = asArray(L.gpu.fans.xs).map(Number);
  if (L.psu && L.psu.effCurve) {
    L.psu.effCurve.load = asArray(L.psu.effCurve.load).map(Number);
    L.psu.effCurve.eff = asArray(L.psu.effCurve.eff).map(Number);
  }
  if (L.ram !== undefined) L.ram = asArray(L.ram);
  // 节流温度为空（null 或 []，MATLAB isempty）时按 tjmax − 15
  for (const c of ['cpu', 'gpu']) {
    const t = L[c]?.throttleTemp;
    if (L[c] && (t === null || (Array.isArray(t) && t.length === 0))) delete L[c].throttleTemp;
  }
  // 机箱风扇：缺转速字段的补默认值
  if (L.caseFans !== undefined) {
    L.caseFans = asArray<Raw>(L.caseFans).map(
      (f: Raw): CaseFan => ({
        mount: f.mount,
        alongMm: f.alongMm,
        type: f.type,
        model: f.model,
        // 缺字段补默认值；显式的 null（MATLAB 读为 []）不补，由校验报错（同 layout_json）
        speedMode: f.speedMode === undefined ? 'auto' : f.speedMode,
        manualPct: f.manualPct === undefined ? 60 : f.manualPct,
      }),
    );
  }
  validateFans(L);
  for (const nm of ['vents', 'solidBlocks', 'porousBlocks']) {
    if (L[nm] === undefined) continue;
    const items = asArray<Raw>(L[nm]);
    if (items.length > 1) {
      const keys = Object.keys(items[0]).sort().join(',');
      for (const it of items) {
        if (Object.keys(it).sort().join(',') !== keys) {
          throw new LayoutError('layout_json:list', `${nm} 的各项字段不一致`);
        }
      }
    }
    L[nm] = items;
  }
  if (L.shroud) L.shroud.gaps = asArray(L.shroud.gaps);
  return L as Layout;
}

/**
 * 计算域与机箱尺寸的合理范围（网页版额外的检查，MATLAB 版不查）：域边长 / 基准格距为 20–400 格
 * （默认 560 / 2 = 280），机箱在域内。超大的域会让浏览器长时间卡在构建上，0 或负数会构建出空网格。
 */
function validateDomain(L: Raw): void {
  const num = (x: unknown) => typeof x === 'number' && Number.isFinite(x);
  const d = L?.domain;
  const c = L?.chassis;
  let bad = '';
  if (!d || !num(d.sizeMm) || !num(d.baseCellMm) || d.sizeMm <= 0 || d.baseCellMm <= 0) bad = 'domain.sizeMm、domain.baseCellMm 应为正数';
  else if (d.sizeMm / d.baseCellMm < 20 || d.sizeMm / d.baseCellMm > 400) bad = `计算域 ${d.sizeMm} mm / 格距 ${d.baseCellMm} mm 应为 20–400 格`;
  else if (!c || !num(c.sizeMm) || !num(c.originMm) || c.sizeMm <= 0 || c.originMm < 0 || c.originMm + c.sizeMm > d.sizeMm)
    bad = 'chassis.originMm、chassis.sizeMm 应使机箱位于计算域内';
  if (bad) throw new LayoutError('layout_json:domain', bad);
}

function validateFans(L: Raw): void {
  const fans: CaseFan[] = L.caseFans ?? [];
  fans.forEach((f, k) => {
    let bad = '';
    if (!['front', 'rear', 'top', 'bottom'].includes(f.mount)) bad = `mount = "${f.mount}"（应为 front/rear/top/bottom）`;
    else if (!['intake', 'exhaust'].includes(f.type)) bad = `type = "${f.type}"（应为 intake/exhaust）`;
    else if (!hasModel(f.model)) bad = `model = "${f.model}"（不在 fan_catalog 中）`;
    else if (!['auto', 'manual'].includes(f.speedMode)) bad = `speedMode = "${f.speedMode}"（应为 auto/manual）`;
    else if (typeof f.manualPct !== 'number' || !(f.manualPct >= 0 && f.manualPct <= 100)) bad = 'manualPct 应为 0–100 的数';
    else if (typeof f.alongMm !== 'number') bad = 'alongMm 应为数';
    if (bad) throw new LayoutError('layout_json:invalid', `第 ${k + 1} 台机箱风扇：${bad}`);
  });
}

/** 噪音参数：布局 acoustics 覆盖默认值（逐字段合并），并检查取值（与 acoustics_validate 同口径） */
export function mergeAcoustics(over: Partial<Acoustics> | undefined): Acoustics {
  const def = acousticsDefault();
  if (!over) return def;
  const ac: Raw = { ...def, ...over, positionDb: { ...def.positionDb, ...(over.positionDb ?? {}) } };
  const extra = Object.keys(ac).filter((k) => !(k in def));
  if (extra.length) throw new LayoutError('acoustics:field', `acoustics 中有未知字段：${extra.join(', ')}`);
  const extraPos = Object.keys(ac.positionDb).filter((k) => !(k in def.positionDb));
  if (extraPos.length) throw new LayoutError('acoustics:field', `acoustics.positionDb 中有未知字段：${extraPos.join(', ')}`);
  const num = (x: unknown) => typeof x === 'number' && Number.isFinite(x);
  if (!num(ac.stallQ) || ac.stallQ <= 0 || ac.stallQ > 1) throw new LayoutError('acoustics:value', 'acoustics.stallQ 应为 (0, 1] 的数');
  if (!num(ac.stallDb) || ac.stallDb < 0) throw new LayoutError('acoustics:value', 'acoustics.stallDb 应为 ≥ 0 的数');
  if (!num(ac.grilleRefZeta) || ac.grilleRefZeta <= 0) throw new LayoutError('acoustics:value', 'acoustics.grilleRefZeta 应为 > 0 的数');
  for (const k of Object.keys(ac.positionDb)) {
    if (!num(ac.positionDb[k])) throw new LayoutError('acoustics:value', `acoustics.positionDb.${k} 应为有限的数`);
  }
  return ac as Acoustics;
}
