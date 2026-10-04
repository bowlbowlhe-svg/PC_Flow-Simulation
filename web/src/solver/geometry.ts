// 几何构建（规格 §2；移植自 CFDSolverBase 的 initGeometry / initObstacles / initFans / initOpenings /
// updateObstacleSets / computeInsideOutsideMasks / initCHTRegions / computeFaceMasks / buildPorousDrag，
// 以及 CFDSolverFEM.assemblePressureMatrix 里的压力参考点）。
//
// 约定：格坐标沿用 MATLAB 的 1 基（x 为列 1..H、y 为行 1..W）；所有数组与索引列表为 0 基线性索引
// idx = (x−1)·W + (y−1)，列优先。索引列表的顺序与 MATLAB 一致（find/setdiff 为升序，rectCells 为 x 外层、y 内层）。
import type { Acoustics, Layout, Mount, Porous, Rect, ThruDir } from '../model/types';
import { FAN_CATALOG, FAN_SLOTS, hasModel, type FanSpec } from '../model/fans';
import { chassisOriginMm, chassisSizeMm } from '../model/chassis';
import { mround } from '../model/mround';
import { mergeAcoustics } from '../model/layoutJson';
import { edtNearest } from '../numerics/edtNearest';
import { layoutCpuTower, type CpuFanPos, type CpuTower } from '../model/cpuTower';
import { layoutPanelU, layoutZShare, partialZeta, type ZShareFull } from '../model/quasi3d';
import { AIR_CP, AIR_DENSITY } from './constants';

export const OBSTACLE = Object.freeze({
  WALL: 1,
  MOTHERBOARD: 2,
  CPU_BASE: 3, // v4.4.0 起不再写入（底座只显示、不挡风），保留码表
  CPU_FINS: 4,
  GPU_PCB: 5,
  GPU_HEATSINK: 6,
  PSU_CASE: 7,
  PSU_FAN: 8,
  RAM_SLOT: 9,
  VRM: 10,
  CHIPSET: 11,
  PSU_SHROUD: 12,
  BLOCK: 13,
});

export interface PorousZone {
  rect: Rect; // 格坐标
  zetaThru: number;
  zetaCross: number;
  thru: ThruDir;
}

export type FanRole = 'case' | 'cpu' | 'gpu' | 'psu';

export interface FanGeom {
  id: string;
  role: FanRole;
  /** CPU 塔扇位置（其它风扇为空串） */
  pos: CpuFanPos | '';
  mount: Mount | 'internal';
  type: 'intake' | 'exhaust';
  model: string;
  spec: FanSpec;
  speedMode: 'auto' | 'manual';
  manualPct: number;
  sensor: 'max' | 'cpu' | 'gpu' | 'psu';
  rows: [number, number]; // 盘占据的格行 [r0 r1]（1 基）
  cols: [number, number];
  normal: [number, number]; // 送风方向（x 向右、y 向下）
  thickM: number;
  positionDb: number;
  grilleZeta: number;
}

export type OpeningKind = 'fan' | 'vent' | 'psu_intake' | 'psu_exhaust';

export interface Opening {
  mount: Mount;
  idx: Int32Array; // 0 基
  kind: OpeningKind;
  fan: number; // 机箱风扇序号（1 基，同 MATLAB）；非风扇为 0
  zeta: number;
}

export interface Geometry {
  layout: Layout;
  acoustics: Acoustics;
  W: number;
  H: number;
  N: number;
  cellMm: number;
  gridScale: number;
  DT: number;
  VEL_SCALE: number;
  diffScale: number;
  caseOffsetX: number;
  caseOffsetY: number;
  CASE2D: { outer: Rect; enabled: boolean; motherboardTray?: Rect };
  /** finArea 为鳍片外廓（双塔含中间间隙）；stacks 为各组鳍片（后组在前），gap 为双塔中间放塔扇的间隙 */
  cpu?: { base: Rect; finArea: Rect; stacks: Rect[]; gap?: Rect; tower: CpuTower };
  gpu?: { pcb: Rect; heatsink: Rect };
  psu?: { body: Rect; interior: Rect };
  ram: Rect[];
  vrm?: Rect;
  chipset?: Rect;
  shroud?: { y: number; h: number };
  fanDiskCells: number;
  obstacle: Uint8Array;
  porousZones: PorousZone[];
  fans: FanGeom[]; // 机箱风扇在前、内置风扇在后（同 allFans()）
  /** 机箱风扇安装位（FAN_SLOTS 顺序）按 120 mm 风扇的执行盘格范围（界面安装位标记用，同 wallFanSpan） */
  slotSpans: { id: string; mount: Mount; cols: [number, number]; rows: [number, number] }[];
  nCaseFans: number;
  openings: Opening[];
  obsIdx: Int32Array;
  heatObsIdx: Int32Array;
  caseWallIdx: Int32Array;
  dirichletIdx: Int32Array;
  dirichletT: Float64Array;
  adiabaticObsIdx: Int32Array;
  insideMask: Int32Array;
  outsideMask: Int32Array;
  spongeRingIdx: Int32Array;
  liveOutsideMask: Int32Array;
  wallDistanceM: Float64Array;
  nearestFluidIdx: Int32Array; // 每格最近流体格（0 基）
  cpuFinIdx: Int32Array;
  cpuInletIdx: Int32Array;
  gpuFinIdx: Int32Array;
  gpuInletIdx: Int32Array;
  psuInteriorIdx: Int32Array;
  psuInletIdx: Int32Array;
  /** 鳍片换热用的风速分量（多孔区穿流方向）：CPU、GPU */
  cpuThru: ThruDir;
  gpuThru: ThruDir;
  /** 零件 Z 向占比（准三维修正；< 1 的零件为多孔区） */
  zShare: ZShareFull;
  /** 机箱壁散热（§3.9）：散热格（0 基）与每步衰减因子 exp(−κ·DT) */
  wallLossIdx: Int32Array;
  wallLossDecay: Float64Array;
  uFaceActive: Uint8Array; // W×(H+1)
  vFaceActive: Uint8Array; // (W+1)×H
  uFaceRing: Uint8Array;
  vFaceRing: Uint8Array;
  uDragCoef: Float64Array;
  vDragCoef: Float64Array;
  uGrilleFace: Uint8Array;
  vGrilleFace: Uint8Array;
  farFieldPresIdx: Int32Array;
  presRefIdx: Int32Array;
}

export class GeometryError extends Error {}

const floor = Math.floor;

/** 构建几何。gridScale：1 = 280²×2 mm，0.5 = 140²×4 mm，2 = 560²×1 mm */
export function buildGeometry(L: Layout, gridScale = 1, DT = 0.005): Geometry {
  const cellMm = L.domain.baseCellMm / gridScale;
  const W = mround(L.domain.sizeMm / cellMm);
  const H = W;
  const N = W * H;
  const toCell = (mm: number) => mround(mm / cellMm);
  const [orgX, orgY] = chassisOriginMm(L);
  const caseOffsetX = mround(orgX / cellMm);
  const caseOffsetY = mround(orgY / cellMm);
  const VEL_SCALE = (W - 2) * (cellMm / 1000);
  const diffScale = 1 / (cellMm / 1000) ** 2;
  const rectToGrid = (rm: Rect): Rect => ({
    x: caseOffsetX + toCell(rm.x),
    y: caseOffsetY + toCell(rm.y),
    w: Math.max(1, toCell(rm.w)),
    h: Math.max(1, toCell(rm.h)),
  });
  const lin = (x: number, y: number) => (x - 1) * W + (y - 1);
  const rectCells = (r: Rect): number[] => {
    const out: number[] = [];
    const x0 = Math.max(1, r.x);
    const x1 = Math.min(H, r.x + r.w - 1);
    const y0 = Math.max(1, r.y);
    const y1 = Math.min(W, r.y + r.h - 1);
    for (let x = x0; x <= x1; x++) for (let y = y0; y <= y1; y++) out.push(lin(x, y));
    return out;
  };
  const acoustics = mergeAcoustics(L.acoustics);

  // ---- initGeometry ----
  const ox = caseOffsetX;
  const oy = caseOffsetY;
  const [szX, szY] = chassisSizeMm(L);
  const outer: Rect = { x: ox + 1, y: oy + 1, w: toCell(szX), h: toCell(szY) };
  /** 壁沿长 [格]（含两端壁格）：前/后壁为机箱高，顶/底壁为机箱深 */
  const wallLen = (mount: string) => (mount === 'front' || mount === 'rear' ? outer.h : outer.w);
  const CASE2D: Geometry['CASE2D'] = { outer, enabled: L.chassis.enabled };
  if (L.motherboardTray) CASE2D.motherboardTray = rectToGrid(L.motherboardTray);
  const cL = outer.x;
  const cR = outer.x + outer.w - 1;
  const cT = outer.y;
  const cB = outer.y + outer.h - 1;
  let cpu: Geometry['cpu'];
  if (L.cpu) {
    // 塔式散热器的鳍片组与双塔中间间隙（同 MATLAB cpuTowerCells）：双塔间隙 g = toCell(gapMm) 格居中，
    // 两组鳍片等宽 sw = floor((fin.w − g)/2)，奇数格并入间隙
    const fin = rectToGrid(L.cpu.fins);
    const tower = layoutCpuTower(L);
    let stacks: Rect[] = [fin];
    let gap: Rect | undefined;
    if (tower.stacks === 2) {
      const g = toCell(tower.gapMm);
      const sw = floor((fin.w - g) / 2);
      if (g < 1 || sw < 1) {
        throw new GeometryError(`双塔散热器在当前网格上放不下（鳍片外廓宽 ${fin.w} 格、间隙 ${g} 格）`);
      }
      const rr = (x: number, w: number): Rect => ({ x, y: fin.y, w, h: fin.h });
      stacks = [rr(fin.x, sw), rr(fin.x + fin.w - sw, sw)];
      gap = rr(fin.x + sw, fin.w - 2 * sw);
    }
    cpu = { base: rectToGrid(L.cpu.base), finArea: fin, stacks, gap, tower };
  }
  const gpu = L.gpu ? { pcb: rectToGrid(L.gpu.pcb), heatsink: rectToGrid(L.gpu.heatsink) } : undefined;
  let psu: Geometry['psu'];
  if (L.psu) {
    // 电源贴后壁/底壁：与壁内侧的间隙 ≤ 6 mm 时对齐到壁内侧
    const b = rectToGrid(L.psu.body);
    const snapCells = 6 / cellMm;
    if (b.x - (cL + 1) <= snapCells) {
      b.w = b.w + (b.x - (cL + 1));
      b.x = cL + 1;
    }
    if (cB - 1 - (b.y + b.h - 1) <= snapCells) b.h = cB - 1 - b.y + 1;
    psu = { body: b, interior: { x: b.x + 1, y: b.y + 1, w: b.w - 2, h: b.h - 2 } };
  }
  const ram = (L.ram ?? []).map(rectToGrid);
  const vrm = L.vrm ? rectToGrid(L.vrm) : undefined;
  const chipset = L.chipset ? rectToGrid(L.chipset) : undefined;
  const shroud = L.shroud ? { y: oy + toCell(L.shroud.yMm), h: toCell(L.shroud.hMm) } : undefined;

  // ---- initObstacles ----
  const obstacle = new Uint8Array(N);
  const porousZones: PorousZone[] = [];
  if (CASE2D.enabled) {
    for (let y = cT; y <= cB; y++) {
      obstacle[lin(cL, y)] = OBSTACLE.WALL;
      obstacle[lin(cR, y)] = OBSTACLE.WALL;
    }
    for (let x = cL; x <= cR; x++) {
      obstacle[lin(x, cT)] = OBSTACLE.WALL;
      obstacle[lin(x, cB)] = OBSTACLE.WALL;
    }
  }
  const setIfFree = (idx: number[], type: number) => {
    for (const i of idx) if (obstacle[i] === 0) obstacle[i] = type;
  };
  const addZone = (rect: Rect, pz: Porous) =>
    porousZones.push({ rect, zetaThru: pz.zetaThru, zetaCross: pz.zetaCross, thru: pz.thru });
  if (cpu && L.cpu) {
    // CPU 底座只显示、不挡风（v4.4.0 起，同 MATLAB）：2D 侧视里底座画在鳍片中间，真实机箱里它贴主板、在鳍片内侧。
    // 各组鳍片为一个多孔区，穿流 ζ 按组数均分；双塔中间间隙只有横向阻力（塔扇框围住），没有穿流阻力
    const pz = L.cpu.porous;
    for (const st of cpu.stacks) {
      porousZones.push({ rect: st, zetaThru: pz.zetaThru / cpu.stacks.length, zetaCross: pz.zetaCross, thru: pz.thru });
    }
    if (cpu.gap) porousZones.push({ rect: cpu.gap, zetaThru: 0, zetaCross: pz.zetaCross, thru: 'x' });
  }
  // 准三维修正：只占机箱部分深度的零件（显卡、内存、VRM 散热片）旁边还有空隙可以过风，占比 z < 1 时按多孔区
  // （ζ = partialZeta(z)，两个方向相同）处理，z = 1 时为固体障碍（旧模型）
  const zShare = layoutZShare(L);
  const partial = (rect: Rect, z: number, type: number) => {
    if (z >= 1) setIfFree(rectCells(rect), type);
    else {
      const zeta = partialZeta(z);
      porousZones.push({ rect, zetaThru: zeta, zetaCross: zeta, thru: 'x' });
    }
  };
  if (gpu && L.gpu) {
    partial(gpu.pcb, zShare.gpu, OBSTACLE.GPU_PCB);
    if (L.gpu.ioBlock) {
      // 挡板端（v4.9.0）：后壁内侧到 PCB/鳍片后端、PCB 上沿到显卡风扇下沿为实心障碍，显卡与后壁之间不过风（同 CFDSolverBase）
      const x0 = outer.x + 1;
      const x1 = Math.min(gpu.pcb.x, gpu.heatsink.x) - 1;
      const yb = gpu.heatsink.y + gpu.heatsink.h - 1 + Math.max(1, toCell(L.fanDiskMm));
      if (x1 >= x0) setIfFree(rectCells({ x: x0, y: gpu.pcb.y, w: x1 - x0 + 1, h: yb - gpu.pcb.y + 1 }), OBSTACLE.BLOCK);
    }
    addZone(gpu.heatsink, L.gpu.porous);
  }
  if (psu && L.psu) {
    const inner = new Set(rectCells(psu.interior));
    const shell = rectCells(psu.body)
      .filter((i) => !inner.has(i))
      .sort((a, b) => a - b); // setdiff 升序
    setIfFree(shell, OBSTACLE.PSU_CASE);
    addZone(psu.interior, L.psu.porous);
  }
  if (shroud && L.shroud) {
    let idx = rectCells({ x: outer.x, y: shroud.y, w: outer.w, h: shroud.h });
    const len = L.shroud.lengthMm;
    if (len !== undefined && len !== null) {
      // 电源仓挡板：从后壁起 lengthMm 长（同 CFDSolverBase）
      const xEnd = caseOffsetX + toCell(len);
      idx = idx.filter((i) => floor(i / W) + 1 <= xEnd);
    }
    for (const gp of L.shroud.gaps ?? []) {
      const x0 = caseOffsetX + toCell(gp.x0Mm);
      const x1 = caseOffsetX + toCell(gp.x1Mm);
      idx = idx.filter((i) => {
        const xx = floor(i / W) + 1;
        return xx < x0 || xx > x1;
      });
    }
    setIfFree(idx, OBSTACLE.PSU_SHROUD);
  }
  for (const r of ram) partial(r, zShare.ram, OBSTACLE.RAM_SLOT);
  if (vrm) partial(vrm, zShare.vrm, OBSTACLE.VRM);
  for (const sb of L.solidBlocks ?? []) setIfFree(rectCells(rectToGrid(sb)), OBSTACLE.BLOCK);
  for (const pb of L.porousBlocks ?? []) addZone(rectToGrid(pb.rect), pb);

  // ---- initFans ----
  const t = Math.max(1, toCell(L.fanDiskMm));
  const thickM = (t * cellMm) / 1000;
  const fans: FanGeom[] = [];
  const specOf = (model: string): FanSpec => {
    if (!hasModel(model)) throw new GeometryError(`未知风扇型号：${model}`);
    const sp = FAN_CATALOG[model];
    return sp;
  };
  const wallFanSpan = (mount: Mount, alongMm: number, sizeMm: number): { cols: [number, number]; rows: [number, number] } => {
    const n = toCell(sizeMm);
    const c = toCell(alongMm);
    let a0 = c - floor(n / 2);
    a0 = Math.max(2, Math.min(wallLen(mount) - n, a0)); // 夹在壁内侧范围
    const a1 = a0 + n - 1;
    switch (mount) {
      case 'front':
        return { cols: [cR - t, cR - 1], rows: [outer.y - 1 + a0, outer.y - 1 + a1] };
      case 'rear':
        return { cols: [cL + 1, cL + t], rows: [outer.y - 1 + a0, outer.y - 1 + a1] };
      case 'top':
        return { rows: [cT + 1, cT + t], cols: [outer.x - 1 + a0, outer.x - 1 + a1] };
      case 'bottom':
        return { rows: [cB - t, cB - 1], cols: [outer.x - 1 + a0, outer.x - 1 + a1] };
    }
  };
  (L.caseFans ?? []).forEach((cf, k) => {
    const sp = specOf(cf.model);
    const { cols, rows } = wallFanSpan(cf.mount, cf.alongMm, sp.size);
    const sgn = cf.type === 'intake' ? -1 : 1;
    const normal: [number, number] =
      cf.mount === 'front' ? [sgn, 0] : cf.mount === 'rear' ? [-sgn, 0] : cf.mount === 'top' ? [0, -sgn] : [0, sgn];
    fans.push({
      id: `case_${cf.mount}_${k + 1}`,
      role: 'case',
      pos: '',
      mount: cf.mount,
      type: cf.type,
      model: cf.model,
      spec: sp,
      speedMode: cf.speedMode,
      manualPct: cf.manualPct,
      sensor: 'max',
      rows,
      cols,
      normal,
      thickM,
      positionDb: acoustics.positionDb[cf.mount],
      grilleZeta: 0,
    });
  });
  const nCaseFans = fans.length;
  const builtIn = (id: string, role: FanRole, model: string, sensor: FanGeom['sensor']): FanGeom => ({
    id,
    role,
    pos: '',
    mount: 'internal',
    type: 'exhaust',
    model,
    spec: specOf(model),
    speedMode: 'auto',
    manualPct: 60,
    sensor,
    rows: [1, 1],
    cols: [1, 1],
    normal: [1, 0],
    thickM,
    positionDb: 0,
    grilleZeta: 0,
  });
  if (cpu && L.cpu && L.cpu.fan) {
    // 塔扇（自前向后）：前 = 鳍片前侧，后 = 鳍片后侧（单塔推拉），中 = 双塔中间间隙内居中（盘厚不超过间隙）。都从前向后吹
    const fin = cpu.finArea;
    const model = L.cpu.fan.model;
    const n = toCell(specOf(model).size);
    const cy = mround(fin.y + (fin.h - 1) / 2);
    const r0 = cy - floor(n / 2);
    for (const pos of cpu.tower.pos) {
      const f = builtIn(`cpu_fan_${pos}`, 'cpu', model, 'cpu');
      f.pos = pos;
      let tt = t;
      let c0: number;
      if (pos === 'front') c0 = fin.x + fin.w;
      else if (pos === 'rear') c0 = fin.x - t;
      else {
        const g = cpu.gap!;
        tt = Math.min(t, g.w);
        c0 = g.x + floor((g.w - tt) / 2);
      }
      if (c0 <= outer.x || c0 + tt - 1 >= outer.x + outer.w - 1) {
        const posCN = { front: '前', mid: '中', rear: '后' }[pos];
        throw new GeometryError(`CPU 塔扇（${posCN}）放不下：执行盘第 ${c0}–${c0 + tt - 1} 列压到机箱壁（壁内为第 ${outer.x + 1}–${outer.x + outer.w - 2} 列）`);
      }
      f.rows = [r0, r0 + n - 1];
      f.cols = [c0, c0 + tt - 1];
      f.normal = [-1, 0];
      f.thickM = (tt * cellMm) / 1000;
      f.positionDb = acoustics.positionDb.cpu;
      fans.push(f);
    }
  }
  if (gpu && L.gpu && L.gpu.fans) {
    const hs = gpu.heatsink;
    let prevC1 = -Infinity;
    L.gpu.fans.xs.forEach((xMm, i) => {
      const f = builtIn(`gpu_fan_${i}`, 'gpu', L.gpu!.fans.model, 'gpu');
      const n = toCell(f.spec.size);
      const c = caseOffsetX + toCell(xMm);
      const c0 = Math.max(c - floor(n / 2), prevC1 + 1, hs.x); // 不重叠、不伸出散热片左端
      const c1 = Math.min(c0 + n - 1, hs.x + hs.w - 1); // 不伸出散热片右端
      if (c1 < c0) throw new GeometryError(`显卡风扇 ${i + 1} 在散热片上放不下（散热片宽 ${hs.w} 格）`);
      f.cols = [c0, c1];
      prevC1 = c1;
      f.rows = [hs.y + hs.h, hs.y + hs.h + t - 1]; // 散热片下方
      f.normal = [0, -1]; // 向上吹入鳍片
      f.positionDb = acoustics.positionDb.gpu;
      fans.push(f);
    });
  }
  if (psu && L.psu && L.psu.fan) {
    const inn = psu.interior;
    const f = builtIn('psu_fan', 'psu', L.psu.fan.model, 'psu');
    const n = toCell(f.spec.size);
    const c = caseOffsetX + toCell(L.psu.fan.xMm);
    const c0 = Math.max(inn.x, c - floor(n / 2));
    const c1 = Math.min(inn.x + inn.w - 1, c0 + n - 1);
    f.cols = [c0, c1];
    f.rows = [inn.y + inn.h - t, inn.y + inn.h - 1]; // 电源内部底部
    f.normal = [0, -1]; // 自底部向上吸入
    f.positionDb = acoustics.positionDb.psu;
    fans.push(f);
  }
  const findFan = (role: FanRole) => fans.slice(nCaseFans).find((f) => f.role === role);

  // ---- initOpenings ----
  const wallSpanCells = (mount: Mount, a0: number, a1: number): Int32Array => {
    const out = new Int32Array(Math.max(0, a1 - a0 + 1));
    for (let a = a0, j = 0; a <= a1; a++, j++) {
      out[j] = mount === 'front' ? lin(cR, a) : mount === 'rear' ? lin(cL, a) : mount === 'top' ? lin(a, cT) : lin(a, cB);
    }
    return out;
  };
  const openings: Opening[] = [];
  for (let k = 0; k < nCaseFans; k++) {
    const f = fans[k];
    const m = f.mount as Mount;
    const span = m === 'front' || m === 'rear' ? f.rows : f.cols;
    const z = f.type === 'intake' ? L.grille.intakeZeta : L.grille.exhaustZeta;
    f.grilleZeta = z;
    openings.push({ mount: m, idx: wallSpanCells(m, span[0], span[1]), kind: 'fan', fan: k + 1, zeta: z });
  }
  for (const v of L.vents ?? []) {
    // MATLAB 对未知安装位报错（wallSpanCells 无匹配分支）
    if (!['front', 'rear', 'top', 'bottom'].includes(v.mount)) throw new GeometryError(`未知通风口安装位：${String(v.mount)}`);
    const n = toCell(v.lengthMm);
    const c = toCell(v.alongMm);
    const a0 = Math.max(2, c - floor(n / 2));
    const a1 = Math.min(wallLen(v.mount) - 1, a0 + n - 1);
    const span = v.mount === 'front' || v.mount === 'rear' ? [outer.y - 1 + a0, outer.y - 1 + a1] : [outer.x - 1 + a0, outer.x - 1 + a1];
    openings.push({ mount: v.mount, idx: wallSpanCells(v.mount, span[0], span[1]), kind: 'vent', fan: 0, zeta: v.zeta });
  }
  let psuInletRaw: number[] = [];
  if (psu && L.psu) {
    const b = psu.body;
    const inn = psu.interior;
    let pfCols: [number, number];
    const pf = findFan('psu');
    if (pf) pfCols = pf.cols;
    else {
      // 无风扇时进风口取机身中段 120 mm
      const n = toCell(120);
      const c0 = inn.x + floor((inn.w - n) / 2);
      pfCols = [Math.max(inn.x, c0), Math.min(inn.x + inn.w - 1, c0 + n - 1)];
    }
    for (let x = pfCols[0]; x <= pfCols[1]; x++) obstacle[lin(x, b.y + b.h - 1)] = 0; // 底部进风孔
    for (let y = inn.y; y <= inn.y + inn.h - 1; y++) obstacle[lin(b.x, y)] = 0; // 后部出风孔
    for (let x = pfCols[0]; x <= pfCols[1]; x++) psuInletRaw.push(lin(x, b.y + b.h - 1));
    if (b.y + b.h === cB) {
      openings.push({ mount: 'bottom', idx: wallSpanCells('bottom', pfCols[0], pfCols[1]), kind: 'psu_intake', fan: 0, zeta: L.psu.intakeZeta });
    }
    if (b.x === cL + 1) {
      openings.push({ mount: 'rear', idx: wallSpanCells('rear', inn.y, inn.y + inn.h - 1), kind: 'psu_exhaust', fan: 0, zeta: L.psu.exhaustZeta });
    }
  }
  for (const op of openings) for (const i of op.idx) obstacle[i] = 0;

  // ---- updateObstacleSets ----
  const findIdx = (pred: (i: number) => boolean): Int32Array => {
    const out: number[] = [];
    for (let i = 0; i < N; i++) if (pred(i)) out.push(i);
    return Int32Array.from(out);
  };
  const obsIdx = findIdx((i) => obstacle[i] > 0);
  const heatObsIdx = findIdx((i) => obstacle[i] === OBSTACLE.GPU_PCB || obstacle[i] === OBSTACLE.PSU_CASE);
  const caseWallIdx = findIdx((i) => obstacle[i] === OBSTACLE.WALL);
  // 定温壁：顶/底壁优先占角格，NaN 壁为绝热
  const dirIdx: number[] = [];
  const dirT: number[] = [];
  if (CASE2D.enabled) {
    const wt = L.chassis.wallTempC;
    const sides: [keyof typeof wt, number[]][] = [
      ['top', range(cL, cR).map((x) => lin(x, cT))],
      ['bottom', range(cL, cR).map((x) => lin(x, cB))],
      ['rear', range(cT + 1, cB - 1).map((y) => lin(cL, y))],
      ['front', range(cT + 1, cB - 1).map((y) => lin(cR, y))],
    ];
    for (const [side, cells] of sides) {
      const Tw = wt[side];
      if (Tw === null || Tw === undefined || Number.isNaN(Tw)) continue;
      for (const c of cells) {
        if (obstacle[c] === OBSTACLE.WALL) {
          dirIdx.push(c);
          dirT.push(Tw);
        }
      }
    }
  }
  const dirichletIdx = Int32Array.from(dirIdx);
  const dirichletT = Float64Array.from(dirT);
  const dirSet = new Set(dirIdx);
  const adiabaticObsIdx = Int32Array.from(Array.from(obsIdx).filter((i) => !dirSet.has(i)));

  // ---- computeInsideOutsideMasks ----
  const inRect = (i: number) => {
    const x = floor(i / W) + 1;
    const y = (i % W) + 1;
    return x >= outer.x && x <= outer.x + outer.w - 1 && y >= outer.y && y <= outer.y + outer.h - 1;
  };
  const fluid = (i: number) => obstacle[i] === 0;
  const insideMask = findIdx((i) => inRect(i) && fluid(i));
  const outsideMask = findIdx((i) => !inRect(i) && fluid(i));
  const sw = Math.max(1, mround(1)); // spongeWidth = 1
  const inRing = (i: number) => {
    const x = floor(i / W) + 1;
    const y = (i % W) + 1;
    return y <= sw || y >= W - sw + 1 || x <= sw || x >= H - sw + 1;
  };
  const spongeRingIdx = findIdx((i) => inRing(i) && fluid(i));
  const liveOutsideMask = findIdx((i) => !inRect(i) && fluid(i) && !inRing(i));
  const cellM = cellMm / 1000;
  const wallDistanceM = new Float64Array(N);
  if (obsIdx.length > 0) {
    const { D } = edtNearest(Uint8Array.from(obstacle, (v) => (v > 0 ? 1 : 0)), W, H);
    for (let i = 0; i < N; i++) wallDistanceM[i] = D[i] * cellM;
  } else {
    wallDistanceM.fill(Math.max(W, H) * cellM);
  }
  let nearestFluidIdx: Int32Array = new Int32Array(0);
  if (obsIdx.length < N) {
    nearestFluidIdx = edtNearest(Uint8Array.from(obstacle, (v) => (v === 0 ? 1 : 0)), W, H).idx;
  }

  // ---- initCHTRegions ----
  const keepFluid = (idx: number[]) => Int32Array.from(idx.filter((i) => obstacle[i] === 0));
  const nIn = Math.max(2, toCell(10)); // 进风采样带厚 10 mm
  let cpuFinIdx = new Int32Array(0);
  let cpuInletIdx = new Int32Array(0);
  let gpuFinIdx = new Int32Array(0);
  let gpuInletIdx = new Int32Array(0);
  let psuInteriorIdx = new Int32Array(0);
  let psuInletIdx = new Int32Array(0);
  if (cpu) {
    // 散热体 = 各组鳍片（双塔中间间隙没有鳍片，不注热；按外廓的列主序）；进风带在前置塔扇前，无前置塔扇时在鳍片前
    const gapSet = new Set(cpu.gap ? rectCells(cpu.gap) : []);
    cpuFinIdx = keepFluid(rectCells(cpu.finArea).filter((i) => !gapSet.has(i)));
    const cf = fans.find((f) => f.role === 'cpu' && f.pos === 'front');
    const fin = cpu.finArea;
    cpuInletIdx = cf
      ? keepFluid(rectCells({ x: cf.cols[1] + 1, y: cf.rows[0], w: nIn, h: cf.rows[1] - cf.rows[0] + 1 }))
      : keepFluid(rectCells({ x: fin.x + fin.w, y: fin.y, w: nIn, h: fin.h }));
  }
  if (gpu) {
    const hs = gpu.heatsink;
    gpuFinIdx = keepFluid(rectCells(hs));
    const gf = findFan('gpu');
    const r0 = gf ? gf.rows[1] + 1 : hs.y + hs.h;
    gpuInletIdx = keepFluid(rectCells({ x: hs.x, y: r0, w: hs.w, h: nIn }));
  }
  if (psu) {
    psuInteriorIdx = keepFluid(rectCells(psu.interior));
    psuInletIdx = keepFluid(psuInletRaw);
  }
  if (cpu && cpuInletIdx.length === 0) cpuInletIdx = cpuFinIdx;
  if (gpu && gpuInletIdx.length === 0) gpuInletIdx = gpuFinIdx;
  if (psu && psuInletIdx.length === 0) psuInletIdx = psuInteriorIdx;

  // ---- 机箱壁散热（§3.9，v4.8.0；缺 chassis.panelU 时没有）----
  // 机箱内（壁内侧、电源外壳以外）的流体格经两块侧板向室内散热，κ_side = 2·U_side/(ρc_p·depthM)；与非定温壁格相邻的
  // 每条边再加 κ_edge = U_edge/(ρc_p·Δx)。每步 T ← T_amb + (T − T_amb)·exp(−κ·DT)
  const panelU = layoutPanelU(L);
  const wlIdx: number[] = [];
  const wlDecay: number[] = [];
  if (CASE2D.enabled && (panelU.edge > 0 || panelU.side > 0)) {
    const rc = AIR_DENSITY * AIR_CP;
    const kEdge = panelU.edge / (rc * cellM);
    const kSide = (2 * panelU.side) / (rc * L.chassis.depthM);
    const pb = psu?.body;
    const isWallLoss = (j: number) => obstacle[j] === OBSTACLE.WALL && !dirSet.has(j);
    for (let x = cL + 1; x <= cR - 1; x++) {
      for (let y = cT + 1; y <= cB - 1; y++) {
        const i = lin(x, y);
        if (obstacle[i] !== 0) continue;
        if (pb && x >= pb.x && x <= pb.x + pb.w - 1 && y >= pb.y && y <= pb.y + pb.h - 1) continue;
        const n = +isWallLoss(lin(x, y - 1)) + +isWallLoss(lin(x, y + 1)) + +isWallLoss(lin(x - 1, y)) + +isWallLoss(lin(x + 1, y));
        const k = n * kEdge + kSide;
        if (k > 0) {
          wlIdx.push(i);
          wlDecay.push(Math.exp(-k * DT));
        }
      }
    }
  }

  // ---- computeFaceMasks ----
  const uFaceActive = new Uint8Array(W * (H + 1));
  const vFaceActive = new Uint8Array((W + 1) * H);
  const uFaceRing = new Uint8Array(W * (H + 1));
  const vFaceRing = new Uint8Array((W + 1) * H);
  const ring = new Uint8Array(N);
  for (const i of spongeRingIdx) ring[i] = 1;
  const f0 = (y: number, x: number) => obstacle[(x - 1) * W + (y - 1)] === 0; // 1 基 (y,x)
  const r0f = (y: number, x: number) => ring[(x - 1) * W + (y - 1)] === 1;
  for (let xf = 1; xf <= H + 1; xf++) {
    for (let y = 1; y <= W; y++) {
      const k = (xf - 1) * W + (y - 1);
      let act: boolean;
      let rg: boolean;
      if (xf === 1) {
        act = f0(y, 1);
        rg = r0f(y, 1);
      } else if (xf === H + 1) {
        act = f0(y, H);
        rg = r0f(y, H);
      } else {
        act = f0(y, xf - 1) && f0(y, xf);
        rg = r0f(y, xf - 1) || r0f(y, xf);
      }
      uFaceActive[k] = act ? 1 : 0;
      uFaceRing[k] = act && rg ? 1 : 0;
    }
  }
  for (let x = 1; x <= H; x++) {
    for (let yf = 1; yf <= W + 1; yf++) {
      const k = (x - 1) * (W + 1) + (yf - 1);
      let act: boolean;
      let rg: boolean;
      if (yf === 1) {
        act = f0(1, x);
        rg = r0f(1, x);
      } else if (yf === W + 1) {
        act = f0(W, x);
        rg = r0f(W, x);
      } else {
        act = f0(yf - 1, x) && f0(yf, x);
        rg = r0f(yf - 1, x) || r0f(yf, x);
      }
      vFaceActive[k] = act ? 1 : 0;
      vFaceRing[k] = act && rg ? 1 : 0;
    }
  }

  // ---- buildPorousDrag ----
  const uDragCoef = new Float64Array(W * (H + 1));
  const vDragCoef = new Float64Array((W + 1) * H);
  const uGrilleFace = new Uint8Array(W * (H + 1));
  const vGrilleFace = new Uint8Array((W + 1) * H);
  const uAt = (y: number, xf: number) => (xf - 1) * W + (y - 1);
  const vAt = (yf: number, x: number) => (x - 1) * (W + 1) + (yf - 1);
  for (const zn of porousZones) {
    const r = zn.rect;
    const x0 = Math.max(2, r.x);
    const x1 = Math.min(H - 1, r.x + r.w - 1);
    const y0 = Math.max(2, r.y);
    const y1 = Math.min(W - 1, r.y + r.h - 1);
    if (x1 < x0 || y1 < y0) continue;
    const nx = x1 - x0 + 1;
    const ny = y1 - y0 + 1;
    const [zU, zV] = zn.thru === 'x' ? [zn.zetaThru, zn.zetaCross] : [zn.zetaCross, zn.zetaThru];
    const cU = (zU * VEL_SCALE * DT) / (2 * nx * cellM);
    const cV = (zV * VEL_SCALE * DT) / (2 * ny * cellM);
    for (let y = y0; y <= y1; y++) {
      for (let xf = x0; xf <= x1 + 1; xf++) {
        const w = xf === x0 || xf === x1 + 1 ? 0.5 : 1;
        const k = uAt(y, xf);
        uDragCoef[k] = Math.max(uDragCoef[k], cU * w);
      }
    }
    for (let yf = y0; yf <= y1 + 1; yf++) {
      const w = yf === y0 || yf === y1 + 1 ? 0.5 : 1;
      for (let x = x0; x <= x1; x++) {
        const k = vAt(yf, x);
        vDragCoef[k] = Math.max(vDragCoef[k], cV * w);
      }
    }
  }
  for (const op of openings) {
    if (op.zeta <= 0 || op.idx.length === 0) continue;
    const c = (op.zeta * VEL_SCALE * DT) / (2 * cellM);
    for (const i of op.idx) {
      const yy = (i % W) + 1;
      const xx = floor(i / W) + 1;
      if (op.mount === 'rear') {
        uDragCoef[uAt(yy, xx + 1)] = c;
        uGrilleFace[uAt(yy, xx + 1)] = 1;
      } else if (op.mount === 'front') {
        uDragCoef[uAt(yy, xx)] = c;
        uGrilleFace[uAt(yy, xx)] = 1;
      } else if (op.mount === 'top') {
        vDragCoef[vAt(yy + 1, xx)] = c;
        vGrilleFace[vAt(yy + 1, xx)] = 1;
      } else {
        vDragCoef[vAt(yy, xx)] = c;
        vGrilleFace[vAt(yy, xx)] = 1;
      }
    }
  }

  // ---- 压力参考点（assemblePressureMatrix / isolatedFluidRefs）----
  const farFieldPresIdx = spongeRingIdx.slice(); // 海绵环格均为流体，setdiff(ring, obs) = ring（升序）
  const presRefIdx = isolatedFluidRefs(obstacle, W, H, farFieldPresIdx);

  return {
    layout: L,
    acoustics,
    W,
    H,
    N,
    cellMm,
    gridScale,
    DT,
    VEL_SCALE,
    diffScale,
    caseOffsetX,
    caseOffsetY,
    CASE2D,
    cpu,
    gpu,
    psu,
    ram,
    vrm,
    chipset,
    shroud,
    fanDiskCells: t,
    obstacle,
    porousZones,
    zShare,
    fans,
    nCaseFans,
    openings,
    obsIdx,
    heatObsIdx,
    caseWallIdx,
    dirichletIdx,
    dirichletT,
    adiabaticObsIdx,
    insideMask,
    outsideMask,
    spongeRingIdx,
    liveOutsideMask,
    wallDistanceM,
    nearestFluidIdx,
    slotSpans: FAN_SLOTS.map((sl) => ({ id: sl.id, mount: sl.mount, ...wallFanSpan(sl.mount, sl.alongMm, 120) })),
    cpuFinIdx,
    cpuInletIdx,
    gpuFinIdx,
    gpuInletIdx,
    psuInteriorIdx,
    psuInletIdx,
    cpuThru: L.cpu?.porous.thru ?? 'x',
    gpuThru: L.gpu?.porous.thru ?? 'x',
    wallLossIdx: Int32Array.from(wlIdx),
    wallLossDecay: Float64Array.from(wlDecay),
    uFaceActive,
    vFaceActive,
    uFaceRing,
    vFaceRing,
    uDragCoef,
    vDragCoef,
    uGrilleFace,
    vGrilleFace,
    farFieldPresIdx,
    presRefIdx,
  };
}

function range(a: number, b: number): number[] {
  const out: number[] = [];
  for (let i = a; i <= b; i++) out.push(i);
  return out;
}

/**
 * 不与远场海绵环连通的流体连通域（4 邻域）各取线性索引最小的一格作压力参考（升序，0 基）。
 * MATLAB 用最小标号传播到不动点，结果即各连通域的最小索引；这里用 BFS 得到相同结果。
 */
function isolatedFluidRefs(obstacle: Uint8Array, W: number, H: number, ring: Int32Array): Int32Array {
  const N = W * H;
  const label = new Int32Array(N).fill(-1);
  const stack: number[] = [];
  for (let s = 0; s < N; s++) {
    if (obstacle[s] !== 0 || label[s] >= 0) continue;
    label[s] = s; // 升序遍历，首个未标记格即连通域最小索引
    stack.push(s);
    while (stack.length) {
      const i = stack.pop()!;
      const y = i % W;
      const x = Math.floor(i / W);
      const nb = [y > 0 ? i - 1 : -1, y < W - 1 ? i + 1 : -1, x > 0 ? i - W : -1, x < H - 1 ? i + W : -1];
      for (const j of nb) {
        if (j >= 0 && obstacle[j] === 0 && label[j] < 0) {
          label[j] = s;
          stack.push(j);
        }
      }
    }
  }
  const ringComps = new Set<number>();
  for (const i of ring) ringComps.add(label[i]);
  const comps = new Set<number>();
  for (let i = 0; i < N; i++) if (label[i] >= 0) comps.add(label[i]);
  return Int32Array.from([...comps].filter((c) => !ringComps.has(c)).sort((a, b) => a - b));
}
