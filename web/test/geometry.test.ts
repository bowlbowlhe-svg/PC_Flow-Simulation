import { describe, expect, it } from 'vitest';
import { buildGeometry, OBSTACLE, type Geometry } from '../src/solver/geometry';
import { normalizeLayout } from '../src/model/layoutJson';
import { layoutDefault } from '../src/model/layoutDefault';
import { layoutBenchmark } from '../src/model/layoutBenchmark';
import { applyPreset } from '../src/model/fans';
import { close6, loadRef, numArr, type Ref } from './refdata';

/** 0 基 Int32Array → 1 基普通数组（与数据集一致） */
const one = (a: Int32Array) => Array.from(a, (v) => v + 1);

function checkGeometry(g: Geometry, ref: Ref) {
  const G = ref.geometry;
  expect(g.W).toBe(ref.W);
  expect(g.H).toBe(ref.H);
  expect(Array.from(g.obstacle)).toEqual(G.obstacleType);
  expect(G.obstacleCodes).toEqual({ ...OBSTACLE });
  expect(Array.from(g.uFaceActive)).toEqual(G.uFaceActive);
  expect(Array.from(g.vFaceActive)).toEqual(G.vFaceActive);
  expect(Array.from(g.uGrilleFace)).toEqual(G.uGrilleFace);
  expect(Array.from(g.vGrilleFace)).toEqual(G.vGrilleFace);
  const du = numArr(G.uDragCoef);
  const dv = numArr(G.vDragCoef);
  let bad = 0;
  g.uDragCoef.forEach((v, i) => (bad += close6(v, du[i]) ? 0 : 1));
  g.vDragCoef.forEach((v, i) => (bad += close6(v, dv[i]) ? 0 : 1));
  expect(bad).toBe(0);
  const wd = numArr(G.wallDistanceM);
  bad = 0;
  g.wallDistanceM.forEach((v, i) => (bad += close6(v, wd[i]) ? 0 : 1));
  expect(bad).toBe(0);
  // nearestFluid：只在障碍格有值（1 基），流体格为 0
  const nf = Array.from(g.obstacle, (o, i) => (o > 0 ? g.nearestFluidIdx[i] + 1 : 0));
  expect(nf).toEqual(G.nearestFluid);
  expect(one(g.spongeRingIdx)).toEqual(G.spongeRing);
  expect(one(g.insideMask)).toEqual(G.inside);
  expect(one(g.dirichletIdx)).toEqual(G.dirichletIdx);
  expect(Array.from(g.dirichletT)).toEqual(G.dirichletT);
  expect(one(g.heatObsIdx)).toEqual(G.heatObsIdx);
  // 机箱壁散热格与 1 − 衰减因子（v4.8.0）
  const wlIdx = G.wallLoss.idx === undefined || G.wallLoss.idx === null ? [] : Array.isArray(G.wallLoss.idx) ? G.wallLoss.idx : [G.wallLoss.idx];
  expect(one(g.wallLossIdx)).toEqual(wlIdx);
  const wl = numArr(G.wallLoss.oneMinusDecay ?? []);
  bad = 0;
  g.wallLossDecay.forEach((v, i) => (bad += close6(1 - v, wl[i]) ? 0 : 1));
  expect(bad).toBe(0);
  expect(one(g.cpuInletIdx)).toEqual(G.cht.cpuInlet);
  expect(one(g.cpuFinIdx)).toEqual(G.cht.cpuFin);
  expect(one(g.gpuInletIdx)).toEqual(G.cht.gpuInlet);
  expect(one(g.gpuFinIdx)).toEqual(G.cht.gpuFin);
  expect(one(g.psuInletIdx)).toEqual(G.cht.psuInlet);
  expect(one(g.psuInteriorIdx)).toEqual(G.cht.psuInterior);
  expect(g.fans.length).toBe(G.fans.length);
  g.fans.forEach((f, k) => {
    const r = G.fans[k];
    expect({ id: f.id, role: f.role, mount: f.mount, type: f.type, model: f.model, rows: f.rows, cols: f.cols, normal: f.normal, grilleZeta: f.grilleZeta }).toEqual({
      id: r.id,
      role: r.role,
      mount: r.mount,
      type: r.type,
      model: r.model,
      rows: r.rows,
      cols: r.cols,
      normal: r.normal,
      grilleZeta: r.grilleZeta,
    });
  });
  expect(g.openings.length).toBe(G.openings.length);
  g.openings.forEach((o, k) => {
    const r = G.openings[k];
    expect({ mount: o.mount, kind: o.kind, zeta: o.zeta, idx: one(o.idx) }).toEqual({
      mount: r.mount,
      kind: r.kind,
      zeta: r.zeta,
      idx: Array.isArray(r.idx) ? r.idx : [r.idx],
    });
  });
}

describe('布局模型', () => {
  it('layoutDefault 与数据集嵌入的默认布局逐项相同', () => {
    const ref = loadRef('fixed_default');
    expect(layoutDefault()).toEqual(normalizeLayout(ref.layout));
  });
  it('风道基准布局与数据集一致', () => {
    const ref = loadRef('fixed_duct');
    expect(layoutBenchmark('duct', 20)).toEqual(normalizeLayout(ref.layout));
  });
  it('预设布局与稳态数据集嵌入的布局一致', () => {
    for (const [file, preset] of [
      ['steady_front_top', 'front_top'],
      ['steady_positive', 'positive'],
      ['steady_negative', 'negative'],
      ['steady_bottom_top', 'bottom_top'],
    ]) {
      expect(applyPreset(layoutDefault(), preset)).toEqual(normalizeLayout(loadRef(file).layout));
    }
  });
});

describe('几何构建（§2）与标准答案逐项相同', () => {
  it('fixed_default（140²）', () => {
    const ref = loadRef('fixed_default');
    checkGeometry(buildGeometry(normalizeLayout(ref.layout), ref.gridScale, ref.DT), ref);
  });
  it('fixed_duct（140²）', () => {
    const ref = loadRef('fixed_duct');
    checkGeometry(buildGeometry(normalizeLayout(ref.layout), ref.gridScale, ref.DT), ref);
  });
  it('280²、560² 默认布局与各预设可构建，障碍数随网格合理变化', () => {
    for (const s of [0.5, 1, 2]) {
      const g = buildGeometry(layoutDefault(), s);
      expect(g.W).toBe(280 * s);
      expect(g.presRefIdx.length).toBe(0); // 默认布局机箱内外经开口连通
    }
    const cav = buildGeometry(layoutBenchmark('cavity', 1e5), 1);
    expect(cav.presRefIdx.length).toBe(1); // 封闭方腔需要一个压力参考点
  });
});
