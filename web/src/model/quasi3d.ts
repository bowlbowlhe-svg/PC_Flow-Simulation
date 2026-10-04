// 准三维修正与机箱壁传热（v4.8.0；移植自 layout_zshare.m、layout_panel_u.m、layout_heat_coef.m，规格 §2.4、§3.9、§4）。
// 布局里缺这些字段时按旧模型计算（整个深度都挡住、壁面只按 wallTempC、鳍片 h = 30 + 130·V 且风速取风速模），
// 与 v4.7 逐位相同；读取 v4.7 及以前保存的配置时，热参数都是旧默认值的整体换成 v4.8 模型（见 layoutJson.ts 的 migrateV48）。
import type { ComponentThermal, Layout, PanelU, ZShare } from './types';
import { LayoutError } from './gpuSlots';

/** 零件 Z 向占比：1 = 整个深度都挡住（障碍），< 1 = 剩余 1 − z 的深度可以过风（多孔区） */
export interface ZShareFull {
  gpu: number;
  ram: number;
  vrm: number;
}

/** 缺省（旧模型）：整个深度都挡住 */
export const ZSHARE_FULL: Readonly<ZShareFull> = Object.freeze({ gpu: 1, ram: 1, vrm: 1 });

/** 部分遮挡的上限：z > 0.95 时 ζ 迅速发散（0.95 → 551），这时应按固体（z = 1）处理 */
export const ZSHARE_MAX_PARTIAL = 0.95;

/** 布局的 Z 向占比（缺字段取 1），并检查取值：0 < z ≤ 0.95 或 z = 1 */
export function layoutZShare(L: Layout): ZShareFull {
  const raw = L.zShare as unknown;
  if (raw !== undefined && raw !== null && (typeof raw !== 'object' || Array.isArray(raw))) {
    throw new LayoutError('layout_zshare:value', 'zShare 应为含 gpu/ram/vrm 字段的对象');
  }
  const z = (raw ?? {}) as ZShare;
  const out: ZShareFull = { gpu: z.gpu ?? 1, ram: z.ram ?? 1, vrm: z.vrm ?? 1 };
  for (const k of ['gpu', 'ram', 'vrm'] as const) {
    const v = out[k];
    if (typeof v !== 'number' || !((v > 0 && v <= ZSHARE_MAX_PARTIAL) || v === 1)) {
      throw new LayoutError('layout_zshare:value', `zShare.${k} 应为 (0, 0.95] 的数或 1（整个深度都挡住）`);
    }
  }
  const extra = Object.keys(z).filter((k) => !['gpu', 'ram', 'vrm'].includes(k));
  if (extra.length) throw new LayoutError('layout_zshare:field', `zShare 中有未知字段：${extra.join(', ')}`);
  return out;
}

/**
 * 只挡住 Z 向深度一部分（占比 z）的零件的阻力系数（以来流速度计）：突缩 + 突扩
 * ζ = (0.5·z + z²)/(1 − z)²（开口比 σ = 1 − z）。z = 0.7 → 9.3，0.2 → 0.22。
 */
export function partialZeta(z: number): number {
  return (0.5 * z + z * z) / ((1 - z) * (1 - z));
}

/** 机箱壁总传热系数：缺省（旧模型）无壁面散热，只按 wallTempC 处理 */
export function layoutPanelU(L: Layout): PanelU {
  const p = L.chassis.panelU;
  if (p === undefined || p === null) return { edge: 0, side: 0 };
  for (const k of ['edge', 'side'] as const) {
    const v = p[k];
    if (typeof v !== 'number' || !(v >= 0 && v <= 50)) throw new LayoutError('layout_panel_u:value', `chassis.panelU.${k} 应为 0–50 的数（W/m²K）`);
  }
  const extra = Object.keys(p).filter((k) => !['edge', 'side'].includes(k));
  if (extra.length) throw new LayoutError('layout_panel_u:field', `chassis.panelU 中有未知字段：${extra.join(', ')}`);
  return { edge: p.edge, side: p.side };
}

/**
 * 鳍片对流系数参数：h = h_free + h_forced·min(V, 6)^h_exp，V 为鳍片区穿流方向的风速分量。h_free、h_forced、h_exp
 * 三个都不给时为旧模型（legacy：h = 30 + 130·V，V 取风速模，同 v4.7）；只给一部分时报错。
 * passiveFlowShare：该元件有内置风扇但都没转（显卡低温停转）时，换热风速只计这一比例——静止的扇叶与风扇罩挡住鳍片进风，
 * 机箱气流大多从卡旁空隙绕过（缺省 1）
 */
export interface HeatCoef {
  h_free: number;
  h_forced: number;
  h_exp: number;
  passiveFlowShare: number;
  legacy: boolean;
}

export function layoutHeatCoef(th: ComponentThermal, what: string): HeatCoef {
  const given = (['h_free', 'h_forced', 'h_exp'] as const).filter((k) => th[k] !== undefined && th[k] !== null);
  if (given.length !== 0 && given.length !== 3) {
    throw new LayoutError('layout_heat_coef:field', `${what}.thermal 的 h_free、h_forced、h_exp 要么都给，要么都不给（旧模型）`);
  }
  const legacy = given.length === 0;
  const out: HeatCoef = {
    h_free: legacy ? 30 : th.h_free!,
    h_forced: legacy ? 130 : th.h_forced!,
    h_exp: legacy ? 1 : th.h_exp!,
    passiveFlowShare: th.passiveFlowShare ?? 1,
    legacy,
  };
  const ok = (v: number, lo: number, hi: number) => typeof v === 'number' && v >= lo && v <= hi;
  if (!ok(out.h_free, 0.1, 500) || !ok(out.h_forced, 0, 1000) || !ok(out.h_exp, 0.2, 1.5) || !ok(out.passiveFlowShare, 0, 1)) {
    throw new LayoutError('layout_heat_coef:value', `${what}.thermal 的 h_free 应为 0.1–500、h_forced 0–1000、h_exp 0.2–1.5、passiveFlowShare 0–1`);
  }
  return out;
}
