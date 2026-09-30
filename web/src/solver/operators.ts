// 线性系统矩阵的直接装配（5 点模板，直接生成 CSR，行内列号递增）。
// 与 MATLAB CFDSolverFEM 的 assembleFaceDiffusion / buildWeightedLaplacian / buildPressureOperator
// 数学上相同（规格 §3.2、§3.3、§3.8、§3.9）；矩阵均为对称正定，用 PCG 求解。
import type { CSR } from '../numerics/sparse';

/** 按行收集 (列, 值) 后生成 CSR；每行列号需递增 */
class RowBuilder {
  private rowPtr: Int32Array;
  private cols: Int32Array;
  private vals: Float64Array;
  private n = 0;
  private row = 0;
  constructor(
    private readonly nRows: number,
    maxPerRow: number,
  ) {
    this.rowPtr = new Int32Array(nRows + 1);
    this.cols = new Int32Array(nRows * maxPerRow);
    this.vals = new Float64Array(nRows * maxPerRow);
  }
  push(c: number, v: number) {
    this.cols[this.n] = c;
    this.vals[this.n] = v;
    this.n++;
  }
  endRow() {
    this.row++;
    this.rowPtr[this.row] = this.n;
  }
  build(): CSR {
    if (this.row !== this.nRows) throw new Error('RowBuilder: 行数不符');
    return {
      nRows: this.nRows,
      nCols: this.nRows,
      rowPtr: this.rowPtr,
      colIdx: this.cols.slice(0, this.n),
      values: this.vals.slice(0, this.n),
    };
  }
}

/**
 * 面点阵隐式扩散 LHS（仅激活面子矩阵）：A = I/dt − gs·L_face。
 * 面粘性：格间面 = 两邻格 ν 的平均，域边界面 = 相邻格的 ν。激活邻面链接权重 0.5(w_f + w_g)；
 * 未激活邻面与越界方向按 Dirichlet 0，权重取本面粘性 w_f（计入对角）。
 * isU：u 面 W×(H+1)；否则 v 面 (W+1)×H。返回矩阵与激活面列表（0 基面索引，升序）。
 */
export function faceDiffusionMatrix(
  nuField: Float64Array,
  isU: boolean,
  W: number,
  H: number,
  faceActive: Uint8Array,
  dt: number,
  gs: number,
): { A: CSR; actIdx: Int32Array } {
  const nR = isU ? W : W + 1;
  const nC = isU ? H + 1 : H;
  const nTot = nR * nC;
  const wM = new Float64Array(nTot);
  if (isU) {
    for (let xf = 0; xf < nC; xf++) {
      for (let y = 0; y < W; y++) {
        const k = xf * W + y;
        if (xf === 0) wM[k] = nuField[y];
        else if (xf === H) wM[k] = nuField[(H - 1) * W + y];
        else wM[k] = 0.5 * (nuField[(xf - 1) * W + y] + nuField[xf * W + y]);
      }
    }
  } else {
    for (let x = 0; x < H; x++) {
      for (let yf = 0; yf < nR; yf++) {
        const k = x * nR + yf;
        if (yf === 0) wM[k] = nuField[x * W];
        else if (yf === W) wM[k] = nuField[x * W + W - 1];
        else wM[k] = 0.5 * (nuField[x * W + yf - 1] + nuField[x * W + yf]);
      }
    }
  }
  const loc = new Int32Array(nTot).fill(-1);
  let nA = 0;
  for (let k = 0; k < nTot; k++) if (faceActive[k]) loc[k] = nA++;
  const actIdx = new Int32Array(nA);
  for (let k = 0; k < nTot; k++) if (loc[k] >= 0) actIdx[loc[k]] = k;
  const rb = new RowBuilder(nA, 5);
  const invDt = 1 / dt;
  for (let a = 0; a < nA; a++) {
    const f = actIdx[a];
    const r = f % nR;
    const c = Math.floor(f / nR);
    const wF = wM[f];
    let sumW = 0;
    // 邻面按线性索引递增：左（−nR）、上（−1）、下（+1）、右（+nR）
    const nbr = [c > 0 ? f - nR : -1, r > 0 ? f - 1 : -1, r < nR - 1 ? f + 1 : -1, c < nC - 1 ? f + nR : -1];
    const offs: [number, number][] = [];
    for (const g of nbr) {
      if (g < 0) {
        sumW += wF;
        continue;
      }
      if (faceActive[g]) {
        const w = 0.5 * (wF + wM[g]);
        sumW += w;
        offs.push([loc[g], -gs * w]);
      } else sumW += wF;
    }
    const diagV = invDt + gs * sumW;
    // 按列号递增写入（含对角）
    let placed = false;
    for (const [col, v] of offs) {
      if (!placed && col > a) {
        rb.push(a, diagV);
        placed = true;
      }
      rb.push(col, v);
    }
    if (!placed) rb.push(a, diagV);
    rb.endRow();
  }
  return { A: rb.build(), actIdx };
}

/**
 * 全网格加权扩散 LHS：A = I/dt − gs·Lw（温度与 k、ω）。
 * Lw：格间链接权重 0.5(w_i + w_j)，域外缺失邻居按 w_i 计入对角（伪 Dirichlet，ghost 值另在 RHS 处理）。
 *   mode 'neumann'（k、ω）：障碍邻居不链接（Neumann），障碍行为钉扎行（对角 1/dt）。
 *   mode 'temperature'：绝热障碍邻居不链接（Neumann）；定温壁邻居的链接计入对角（Dirichlet，
 *   耦合项在 RHS 恢复，见 dirichletCorrection）；障碍行为钉扎行。
 * isObs：障碍标记；isDir：定温壁标记（temperature 模式）。
 */
export function cellDiffusionMatrix(
  wField: Float64Array,
  W: number,
  H: number,
  isObs: Uint8Array,
  isDir: Uint8Array | null,
  dt: number,
  gs: number,
): CSR {
  const N = W * H;
  const rb = new RowBuilder(N, 5);
  const invDt = 1 / dt;
  for (let i = 0; i < N; i++) {
    if (isObs[i]) {
      rb.push(i, invDt);
      rb.endRow();
      continue;
    }
    const y = i % W;
    const x = Math.floor(i / W);
    const wi = wField[i];
    let sumW = 0;
    const nbr = [x > 0 ? i - W : -1, y > 0 ? i - 1 : -1, y < W - 1 ? i + 1 : -1, x < H - 1 ? i + W : -1];
    const offs: [number, number][] = [];
    for (const j of nbr) {
      if (j < 0) {
        sumW += wi; // 域外缺失邻居
        continue;
      }
      const w = 0.5 * (wi + wField[j]);
      if (!isObs[j]) {
        sumW += w;
        offs.push([j, -gs * w]);
      } else if (isDir && isDir[j]) sumW += w; // 定温壁：Dirichlet
      // 其余障碍：Neumann（不链接）
    }
    const diagV = invDt + gs * sumW;
    let placed = false;
    for (const [col, v] of offs) {
      if (!placed && col > i) {
        rb.push(i, diagV);
        placed = true;
      }
      rb.push(col, v);
    }
    if (!placed) rb.push(i, diagV);
    rb.endRow();
  }
  return rb.build();
}

/**
 * 压力泊松 LHS（取负后对称正定）：A = −D·diag(w)·G。格间激活面链接权重 w（u 面 W×(H+1)、v 面 (W+1)×H），
 * 贴障碍面不参与（Neumann）。钉扎格（障碍、远场海绵环、孤立连通域参考点）为单位行。
 */
export function pressureMatrix(
  W: number,
  H: number,
  uAct: Uint8Array,
  vAct: Uint8Array,
  wU: Float64Array | null,
  wV: Float64Array | null,
  isPin: Uint8Array,
): CSR {
  const N = W * H;
  const rb = new RowBuilder(N, 5);
  for (let i = 0; i < N; i++) {
    if (isPin[i]) {
      rb.push(i, 1);
      rb.endRow();
      continue;
    }
    const y = i % W;
    const x = Math.floor(i / W);
    let sumW = 0;
    // 邻格（线性索引递增）：左 u 面 xf=x、上 v 面 yf=y、下 v 面 yf=y+1、右 u 面 xf=x+1（0 基面索引）
    const cand: [number, number][] = [];
    if (x > 0) {
      const f = x * W + y;
      if (uAct[f]) cand.push([i - W, wU ? wU[f] : 1]);
    }
    if (y > 0) {
      const f = x * (W + 1) + y;
      if (vAct[f]) cand.push([i - 1, wV ? wV[f] : 1]);
    }
    if (y < W - 1) {
      const f = x * (W + 1) + y + 1;
      if (vAct[f]) cand.push([i + 1, wV ? wV[f] : 1]);
    }
    if (x < H - 1) {
      const f = (x + 1) * W + y;
      if (uAct[f]) cand.push([i + W, wU ? wU[f] : 1]);
    }
    const offs: [number, number][] = [];
    for (const [j, w] of cand) {
      sumW += w;
      if (!isPin[j]) offs.push([j, -w]);
    }
    let placed = false;
    for (const [col, v] of offs) {
      if (!placed && col > i) {
        rb.push(i, sumW);
        placed = true;
      }
      rb.push(col, v);
    }
    if (!placed) rb.push(i, sumW);
    rb.endRow();
  }
  return rb.build();
}
