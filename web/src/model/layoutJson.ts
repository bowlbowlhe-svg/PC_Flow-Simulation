// 布局 JSON 存取与规整（移植自 layout_json.m、acoustics_validate.m）。
// JSON 里 NaN 存为 null；读取时补齐缺省字段、把单个对象规整为数组、并做取值检查。
import type { Acoustics, CaseFan, Layout } from './types';
import { hasModel } from './fans';
import { acousticsDefault, layoutDefault } from './layoutDefault';
import { LayoutError } from './gpuSlots';
import { pairMm } from './chassis';
import { layoutCpuTower } from './cpuTower';
import { layoutDvfs, layoutFanCurves } from './fanCurves';
import { fanModelAlias } from './fans';
import { gpuFinArea } from './gpuSlots';
import { layoutHeatCoef, layoutPanelU, layoutZShare } from './quasi3d';

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
export function layoutFromJson(text: string, info?: { migration?: LayoutMigration }): Layout {
  return normalizeLayout(JSON.parse(text), info);
}

/** info.migration 返回版本迁移结果（见 migrateV48） */
export function normalizeLayout(raw: Raw, info?: { migration?: LayoutMigration }): Layout {
  const L: Raw = structuredClone(raw);
  validateDomain(L);
  // 壁温：null → NaN（绝热）
  for (const side of ['rear', 'front', 'top', 'bottom']) {
    L.chassis.wallTempC[side] = numOrNaN(L.chassis.wallTempC[side]);
  }
  const mig = migrateV48(L);
  if (info) info.migration = mig;
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
  // CPU 塔式散热器：null 或 []（MATLAB isempty，例如 cpu.fan = [] 存为 "fan":[]）按没写处理
  const isEmpty = (v: unknown) => v === null || (Array.isArray(v) && v.length === 0);
  // v4.8 字段：null 或 []（MATLAB isempty）按没写处理（同 layout_zshare / layout_panel_u / layout_heat_coef）
  if (L.chassis && isEmpty(L.chassis.panelU)) delete L.chassis.panelU;
  if (isEmpty(L.zShare)) delete L.zShare;
  else if (L.zShare && typeof L.zShare === 'object' && !Array.isArray(L.zShare)) {
    for (const k of Object.keys(L.zShare)) if (isEmpty(L.zShare[k])) delete L.zShare[k];
  }
  for (const c of ['cpu', 'gpu']) {
    const th = L[c]?.thermal;
    if (th && typeof th === 'object') for (const k of ['h_free', 'h_forced', 'h_exp', 'passiveFlowShare']) if (isEmpty(th[k])) delete th[k];
  }
  if (L.cpu) {
    for (const k of ['fan', 'tower']) if (isEmpty(L.cpu[k])) delete L.cpu[k];
    if (L.cpu.fan) for (const k of ['count']) if (isEmpty(L.cpu.fan[k])) delete L.cpu.fan[k];
    if (L.cpu.tower) for (const k of ['stacks', 'gapMm']) if (isEmpty(L.cpu.tower[k])) delete L.cpu.tower[k];
  }
  // 机箱风扇：缺转速字段的补默认值
  if (L.caseFans !== undefined) {
    L.caseFans = asArray<Raw>(L.caseFans).map(
      (f: Raw): CaseFan => ({
        mount: f.mount,
        alongMm: f.alongMm,
        type: f.type,
        model: typeof f.model === 'string' ? fanModelAlias(f.model) : f.model,
        // 缺字段补默认值；显式的 null（MATLAB 读为 []）不补，由校验报错（同 layout_json）
        speedMode: f.speedMode === undefined ? 'auto' : f.speedMode,
        manualPct: f.manualPct === undefined ? 60 : f.manualPct,
      }),
    );
  }
  validateFans(L);
  if (L.cpu) {
    try {
      layoutCpuTower(L as Layout);
    } catch (e) {
      throw new LayoutError('layout_json:invalid', `CPU 散热器：${(e as Error).message}`);
    }
  }
  // 温控曲线：数组规整、取值检查、档位名与曲线不符时记为 custom（见 layoutFanCurves）；dvfs 检查（同 layout_json）
  const fc = L.fanCurves;
  const fcEmpty = fc === undefined || fc === null || fc === '' || (Array.isArray(fc) && fc.length === 0);
  if (fcEmpty) delete L.fanCurves;
  try {
    if (!fcEmpty) L.fanCurves = layoutFanCurves(L as Layout);
    if (L.cpu) layoutDvfs(L as Layout, 'cpu');
    if (L.gpu) layoutDvfs(L as Layout, 'gpu');
    layoutZShare(L as Layout);
    layoutPanelU(L as Layout);
    if (L.cpu) layoutHeatCoef(L.cpu.thermal, 'cpu');
    if (L.gpu) layoutHeatCoef(L.gpu.thermal, 'gpu');
    // 同 MATLAB jsondecode：[] 为缺省、单元素数组为标量；ioBlock 也接受 0/1（MATLAB 里可写成数）
    const scalar = (v: unknown) => (Array.isArray(v) && v.length <= 1 ? v[0] : v);
    const gp = L.gpu as Raw | undefined;
    if (gp) {
      let v = scalar(gp.ioBlock);
      if (v === 0 || v === 1) v = v === 1;
      if (v === undefined || v === null) delete gp.ioBlock;
      else if (typeof v !== 'boolean') throw new LayoutError('layout_json:gpu', 'gpu.ioBlock（挡板端封闭）应为 true 或 false');
      else gp.ioBlock = v;
    }
    const sh = L.shroud as Raw | undefined;
    if (sh) {
      const v = scalar(sh.lengthMm);
      if (v === undefined || v === null) delete sh.lengthMm;
      else if (!(typeof v === 'number' && Number.isFinite(v) && v > 0))
        throw new LayoutError('layout_json:shroud', 'shroud.lengthMm（电源仓挡板长度）应为 > 0 的数');
      else sh.lengthMm = v;
    }
  } catch (e) {
    throw new LayoutError('layout_json:invalid', (e as Error).message);
  }
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

/** 读取时的版本迁移结果：none 不需要；v48 v4.7 配置已升级为 v4.8 模型；legacy 改过热参数的 v4.7 配置，按 v4.7 模型计算 */
export type LayoutMigration = 'none' | 'v48' | 'legacy';

/** 界面上标在配置名后面的说明 */
export function migrationNote(m: LayoutMigration): string {
  return m === 'v48' ? '（v4.7 配置，已升级）' : m === 'legacy' ? '（v4.7 配置，热参数改过，按 v4.7 模型计算）' : '';
}

/**
 * 读取 v4.7 及以前保存的配置（没有 chassis.panelU、含 CPU/GPU/电源）。热参数（CPU、GPU）与 GPU 鳍片阻力都是旧默认值时
 * 整体升级为 v4.8 模型（同 layout_json.m）：四面壁温都是 25°C 的定温壁 → 绝热；补 chassis.panelU、zShare；热参数与 GPU 鳍片
 * 换成新默认值（GPU 面积按 gpuFinArea(h)）。改过其中任何一项时整个文件保持原样——缺 v4.8 字段即按 v4.7 模型计算，
 * 不把新旧标定混在一起。基准布局（方腔、风道、空域）没有元件，不迁移。
 */
function migrateV48(L: Raw): LayoutMigration {
  if (!L.chassis || L.chassis.panelU !== undefined || !(L.cpu || L.gpu || L.psu)) return 'none';
  // 数值按相对 1e−9 比较（MATLAB jsonencode 写 15 位有效数字）
  const eq = (x: unknown, y: number | string) =>
    typeof y === 'number' ? typeof x === 'number' && Math.abs(x - y) <= 1e-9 * Math.abs(y) : x === y;
  const same = (a: Raw, b: Record<string, number | string>) =>
    !!a && typeof a === 'object' && Object.keys(a).length === Object.keys(b).length && Object.keys(b).every((k) => eq(a[k], b[k]));
  const h = L.gpu?.heatsink?.h;
  const oldDefaults =
    (!L.cpu || same(L.cpu.thermal, { R_junction_to_case: 0.15, R_tim: 0.04, R_base: 0.05, fin_thickness_mm: 0.4, A_fin_total_m2: 0.15 })) &&
    (!L.gpu ||
      (same(L.gpu.thermal, { R_junction_to_case: 0.08, R_tim: 0.02, R_base: 0.02, fin_thickness_mm: 0.35, A_fin_total_m2: (0.5 * h) / 47 }) &&
        same(L.gpu.porous, { zetaThru: 4, zetaCross: 10, thru: 'x' })));
  if (!oldDefaults) return 'legacy';
  const D = layoutDefault();
  const wt = L.chassis.wallTempC;
  if (['rear', 'front', 'top', 'bottom'].every((k) => wt[k] === 25)) {
    for (const k of ['rear', 'front', 'top', 'bottom']) wt[k] = NaN;
  }
  L.chassis.panelU = { ...D.chassis.panelU! };
  if (L.zShare === undefined) L.zShare = { ...D.zShare! };
  if (L.cpu) L.cpu.thermal = { ...D.cpu!.thermal };
  if (L.gpu) {
    L.gpu.thermal = { ...D.gpu!.thermal, A_fin_total_m2: gpuFinArea(h) };
    L.gpu.porous = { ...D.gpu!.porous };
  }
  return 'v48';
}

/**
 * 计算域与机箱尺寸的合理范围（网页版额外的检查，MATLAB 版不查）：域边长 / 基准格距为 20–400 格
 * （默认 560 / 2 = 280），机箱在域内。超大的域会让浏览器长时间卡在构建上，0 或负数会构建出空网格。
 * chassis.sizeMm、originMm 可为数或 1–2 个数的数组（[深 高]、[x y]，见 chassis.ts）。
 */
function validateDomain(L: Raw): void {
  const num = (x: unknown) => typeof x === 'number' && Number.isFinite(x);
  const pair = (v: unknown): [number, number] | null =>
    num(v) ? [v as number, v as number] : Array.isArray(v) && (v.length === 1 || v.length === 2) && v.every(num) ? pairMm(v) : null;
  const d = L?.domain;
  const c = L?.chassis;
  let bad = '';
  if (!d || !num(d.sizeMm) || !num(d.baseCellMm) || d.sizeMm <= 0 || d.baseCellMm <= 0) bad = 'domain.sizeMm、domain.baseCellMm 应为正数';
  else if (d.sizeMm / d.baseCellMm < 20 || d.sizeMm / d.baseCellMm > 400) bad = `计算域 ${d.sizeMm} mm / 格距 ${d.baseCellMm} mm 应为 20–400 格`;
  else {
    const sz = pair(c?.sizeMm);
    const org = pair(c?.originMm);
    if (!c || !sz || !org || !(sz[0] > 0 && sz[1] > 0) || !(org[0] >= 0 && org[1] >= 0) || org[0] + sz[0] > d.sizeMm || org[1] + sz[1] > d.sizeMm)
      bad = 'chassis.originMm、chassis.sizeMm 应使机箱位于计算域内（各为数或 [x y] 两个数）';
  }
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
  if (!num(ac.finDb) || ac.finDb < 0) throw new LayoutError('acoustics:value', 'acoustics.finDb 应为 ≥ 0 的数');
  if (!num(ac.floorDb)) throw new LayoutError('acoustics:value', 'acoustics.floorDb 应为有限的数');
  if (!num(ac.intermittentDb) || ac.intermittentDb < 0) throw new LayoutError('acoustics:value', 'acoustics.intermittentDb 应为 ≥ 0 的数');
  if (!num(ac.cycleWindowS) || ac.cycleWindowS <= 0) throw new LayoutError('acoustics:value', 'acoustics.cycleWindowS 应为 > 0 的数');
  for (const k of Object.keys(ac.positionDb)) {
    if (!num(ac.positionDb[k])) throw new LayoutError('acoustics:value', `acoustics.positionDb.${k} 应为有限的数`);
  }
  return ac as Acoustics;
}
