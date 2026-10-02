// 机箱风扇布局的静态检查与标称风量（移植自 layout_fan_report.m；不需要求解器）。
import { FAN_CATALOG, hasModel } from './fans';
import type { Layout } from './types';
import { chassisSizeMm } from './chassis';

export interface FanReport {
  warnings: string[]; // 同壁重叠、相邻壁角部相碰、超出壁面、与电源重叠
  intakeCfm: number; // 进气风扇标称自由风量之和（自动转速按满速计）
  exhaustCfm: number;
  pressure: string;
  intakeCfmIdle: number; // 自动转速按温控下限（20%）计
  exhaustCfmIdle: number;
  pressureIdle: string;
  nIntake: number;
  nExhaust: number;
}

/** 由机箱风扇标称进/排风量判断机箱压力状态（fan_pressure_label） */
export function pressureLabel(qin: number, qout: number): string {
  if (qin <= 0 && qout <= 0) return '无机箱风扇';
  if (qin > 1.1 * qout) return '正压';
  if (qin < 0.9 * qout) return '负压';
  return '平衡';
}

const MOUNT_CN: Record<string, string> = { front: '前', rear: '后', top: '顶', bottom: '底' };

/** MATLAB %g（这里的参数是 mm 坐标，整数或短小数） */
const g = (x: number) => String(Number(x.toPrecision(6)));
/** MATLAB %.0f */
const f0 = (x: number) => x.toFixed(0);

export function layoutFanReport(L: Layout): FanReport {
  const R: FanReport = {
    warnings: [],
    intakeCfm: 0,
    exhaustCfm: 0,
    pressure: '',
    intakeCfmIdle: 0,
    exhaustCfmIdle: 0,
    pressureIdle: '',
    nIntake: 0,
    nExhaust: 0,
  };
  const F = L.caseFans ?? [];
  if (!F.length) {
    R.pressure = pressureLabel(0, 0);
    R.pressureIdle = R.pressure;
    return R;
  }
  const [Sx, Sy] = chassisSizeMm(L); // 机箱深（x）、高（y）[mm]
  const wallMm = L.domain.baseCellMm; // 机箱壁厚约 1 格
  const lo: number[] = [];
  const hi: number[] = [];
  F.forEach((f, k) => {
    if (!hasModel(f.model)) throw new Error(`未知风扇型号：${String(f.model)}`);
    const sp = FAN_CATALOG[f.model];
    lo[k] = f.alongMm - sp.size / 2;
    hi[k] = f.alongMm + sp.size / 2;
    const len = f.mount === 'front' || f.mount === 'rear' ? Sy : Sx;
    if (lo[k] < wallMm - 0.5 || hi[k] > len - wallMm + 0.5)
      R.warnings.push(`${MOUNT_CN[f.mount]}壁 ${f.model}（中心 ${g(f.alongMm)} mm）超出壁面，求解时会被夹到壁内`);
    const frac = f.speedMode === 'manual' ? [f.manualPct / 100, f.manualPct / 100] : [1, 0.2];
    const q = frac.map((fr) => (sp.cfm_max * (sp.rpm_min + (sp.rpm_max - sp.rpm_min) * fr)) / sp.rpm_max);
    if (f.type === 'intake') {
      R.intakeCfm += q[0];
      R.intakeCfmIdle += q[1];
      R.nIntake++;
    } else {
      R.exhaustCfm += q[0];
      R.exhaustCfmIdle += q[1];
      R.nExhaust++;
    }
  });
  // 同壁重叠（> 15 mm）
  for (let i = 0; i < F.length; i++) {
    for (let j = i + 1; j < F.length; j++) {
      if (F[i].mount !== F[j].mount) continue;
      const ov = Math.min(hi[i], hi[j]) - Math.max(lo[i], lo[j]);
      if (ov > 15) R.warnings.push(`${MOUNT_CN[F[i].mount]}壁两台风扇重叠 ${f0(ov)} mm（中心 ${g(F[i].alongMm)} / ${g(F[j].alongMm)} mm）`);
    }
  }
  // 相邻壁在角部相碰：框架（沿壁跨度 × 厚 25 mm）的矩形相交
  const d = 25;
  const box = (mount: string, a0: number, a1: number): number[] => {
    switch (mount) {
      case 'front':
        return [Sx - d, Sx, a0, a1];
      case 'rear':
        return [0, d, a0, a1];
      case 'top':
        return [a0, a1, 0, d];
      default:
        return [a0, a1, Sy - d, Sy];
    }
  };
  for (let i = 0; i < F.length; i++) {
    for (let j = i + 1; j < F.length; j++) {
      if (F[i].mount === F[j].mount) continue;
      const A = box(F[i].mount, lo[i], hi[i]);
      const B = box(F[j].mount, lo[j], hi[j]);
      const ox = Math.min(A[1], B[1]) - Math.max(A[0], B[0]);
      const oy = Math.min(A[3], B[3]) - Math.max(A[2], B[2]);
      if (ox > 0 && oy > 0)
        R.warnings.push(`${MOUNT_CN[F[i].mount]}壁与${MOUNT_CN[F[j].mount]}壁风扇在角部相碰（中心 ${g(F[i].alongMm)} / ${g(F[j].alongMm)} mm）`);
    }
  }
  // 与电源重叠（电源贴后壁/底壁）
  if (L.psu?.body) {
    const b = L.psu.body;
    F.forEach((f, k) => {
      let ov = 0;
      if (f.mount === 'bottom') ov = Math.min(hi[k], b.x + b.w) - Math.max(lo[k], b.x);
      else if (f.mount === 'rear') ov = Math.min(hi[k], b.y + b.h) - Math.max(lo[k], b.y);
      if (ov > 0) R.warnings.push(`${MOUNT_CN[f.mount]}壁风扇（中心 ${g(f.alongMm)} mm）与电源重叠 ${f0(ov)} mm`);
    });
  }
  R.pressure = pressureLabel(R.intakeCfm, R.exhaustCfm);
  R.pressureIdle = pressureLabel(R.intakeCfmIdle, R.exhaustCfmIdle);
  return R;
}
