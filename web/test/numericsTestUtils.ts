/**
 * 数值例程测试的公用工具：读取 Octave 对照数据、十六进制双精度解码、逐位比较、测试矩阵构建与带状 Cholesky 直接解。
 */
import { readFileSync } from 'node:fs';
import { type CSR, fromTriplets } from '../src/numerics/sparse';

export interface GridCase {
  name: string; n1: number; n2: number; o1: number; o2: number; nq: number;
  V: string; q1: string; q2: string; linear: string; cubic: string; makima: string;
}
export interface EdtCase {
  name: string; W: number; H: number; mask: string; allFalse: boolean;
  D2: number[] | null; idx: number[] | null;
}
export interface PchipCase { name: string; n: number; x: string; y: string; q: string; v: string }
export interface SparseCase {
  name: string; m: number; n: number; I: number[]; J: number[]; V: string; x: string; y: string;
  nnz: number; Ai: number[]; Aj: number[]; Av: string; Ax: string; rowSum: string; Aty: string;
}
export interface NumericsFixtures {
  generator: Record<string, string>;
  gridInterp2: GridCase[];
  edt: EdtCase[];
  pchip: PchipCase[];
  sparse: SparseCase[];
}

let cached: NumericsFixtures | null = null;
export function loadFixtures(): NumericsFixtures {
  if (!cached) {
    const url = new URL('./fixtures/numerics.json', import.meta.url);
    cached = JSON.parse(readFileSync(url, 'utf8')) as NumericsFixtures;
  }
  return cached;
}

/** num2hex 串（每 16 个十六进制字符一个大端双精度，首尾相接）→ Float64Array。 */
export function hexToF64(s: string): Float64Array {
  if (s.length % 16 !== 0) throw new Error('hex 长度不是 16 的倍数');
  const n = s.length / 16;
  const out = new Float64Array(n);
  const dv = new DataView(new ArrayBuffer(8));
  for (let k = 0; k < n; k++) {
    dv.setUint32(0, parseInt(s.slice(16 * k, 16 * k + 8), 16));
    dv.setUint32(4, parseInt(s.slice(16 * k + 8, 16 * k + 16), 16));
    out[k] = dv.getFloat64(0);
  }
  return out;
}

export function maskFromString(s: string): Uint8Array {
  const m = new Uint8Array(s.length);
  for (let k = 0; k < s.length; k++) m[k] = s.charCodeAt(k) === 49 ? 1 : 0;
  return m;
}

/** 逐位比较（NaN 与 NaN 视为相同，不比 payload；+0 与 −0 视为不同）。返回不一致的描述（空 = 全部一致）。 */
export function bitwiseMismatches(actual: ArrayLike<number>, expected: ArrayLike<number>, maxReport = 5): string[] {
  const out: string[] = [];
  if (actual.length !== expected.length) return [`length ${actual.length} ≠ ${expected.length}`];
  let count = 0;
  for (let k = 0; k < expected.length; k++) {
    if (!Object.is(actual[k], expected[k])) {
      count++;
      if (out.length < maxReport) {
        out.push(`[${k}] got ${actual[k]} expected ${expected[k]} (diff ${actual[k] - expected[k]})`);
      }
    }
  }
  if (count > maxReport) out.push(`… ${count} mismatches in total`);
  return out;
}

/** 简单确定性伪随机数（mulberry32）。 */
export function rng(seed: number): () => number {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

/** W×H 格上的五点 Dirichlet 泊松矩阵（对角 4、邻位 −1），列优先编号 x·W + y。 */
export function poisson2d(W: number, H: number): CSR {
  const I: number[] = [];
  const J: number[] = [];
  const V: number[] = [];
  for (let x = 0; x < H; x++) {
    for (let y = 0; y < W; y++) {
      const k = x * W + y;
      I.push(k); J.push(k); V.push(4);
      if (y > 0) { I.push(k); J.push(k - 1); V.push(-1); }
      if (y < W - 1) { I.push(k); J.push(k + 1); V.push(-1); }
      if (x > 0) { I.push(k); J.push(k - W); V.push(-1); }
      if (x < H - 1) { I.push(k); J.push(k + W); V.push(-1); }
    }
  }
  return fromTriplets(W * H, W * H, I, J, V);
}

/**
 * 仿压力算子 −L_p：流体格之间的格间面权重 1（障碍面不进算子 → Neumann），
 * 钉扎集合 = 障碍格 + 宽 ringWidth 的外圈流体格 + 不与外圈连通的流体连通域各一格（行列清零、对角 1）。
 * 与 CFDSolverFEM.buildPressureOperator 的结构相同（全部格间面激活时）。
 */
export function pressureLike(obs: Uint8Array, W: number, H: number, ringWidth = 3): { A: CSR; pinned: Uint8Array } {
  const N = W * H;
  const pinned = new Uint8Array(N);
  const fluid = (k: number) => obs[k] === 0;
  for (let x = 0; x < H; x++) {
    for (let y = 0; y < W; y++) {
      const k = x * W + y;
      const ring = y < ringWidth || y >= W - ringWidth || x < ringWidth || x >= H - ringWidth;
      if (!fluid(k) || ring) pinned[k] = 1;
    }
  }
  // 与外圈连通性：从外圈流体格出发 BFS
  const lab = new Int32Array(N).fill(-1);
  const stack: number[] = [];
  const nb = (k: number): number[] => {
    const y = k % W;
    const x = (k - y) / W;
    const r: number[] = [];
    if (y > 0) r.push(k - 1);
    if (y < W - 1) r.push(k + 1);
    if (x > 0) r.push(k - W);
    if (x < H - 1) r.push(k + W);
    return r;
  };
  let comp = 0;
  const ringComp = new Set<number>();
  for (let k = 0; k < N; k++) {
    if (!fluid(k) || lab[k] >= 0) continue;
    lab[k] = comp;
    stack.push(k);
    let touchesRing = false;
    while (stack.length) {
      const c = stack.pop()!;
      if (pinned[c]) touchesRing = true;
      for (const g of nb(c)) if (fluid(g) && lab[g] < 0) { lab[g] = comp; stack.push(g); }
    }
    if (touchesRing) ringComp.add(comp);
    else pinned[k] = 1; // 孤立连通域的参考格（取线性索引最小者）
    comp++;
  }
  const I: number[] = [];
  const J: number[] = [];
  const V: number[] = [];
  for (let k = 0; k < N; k++) {
    if (pinned[k]) { I.push(k); J.push(k); V.push(1); continue; }
    let dsum = 0;
    for (const g of nb(k)) {
      if (!fluid(g)) continue; // 贴障碍面不参与
      dsum += 1;
      if (!pinned[g]) { I.push(k); J.push(g); V.push(-1); }
    }
    I.push(k); J.push(k); V.push(dsum);
  }
  return { A: fromTriplets(N, N, I, J, V), pinned };
}

/**
 * 带状对称正定矩阵的 Cholesky 直接解（测试用参照解），半带宽 bw（|i − j| ≤ bw）。
 * 存储 L 的带（每行 bw+1 个），O(n·bw²)。
 */
export function bandCholeskySolve(A: CSR, b: ArrayLike<number>, bw: number): Float64Array {
  const n = A.nRows;
  const w = bw + 1;
  const L = new Float64Array(n * w); // L[i*w + (j − i + bw)]，j ∈ [i−bw, i]
  for (let i = 0; i < n; i++) {
    for (let p = A.rowPtr[i]; p < A.rowPtr[i + 1]; p++) {
      const j = A.colIdx[p];
      if (j <= i) {
        if (i - j > bw) throw new Error('bandwidth exceeded');
        L[i * w + (j - i + bw)] = A.values[p];
      }
    }
  }
  for (let i = 0; i < n; i++) {
    const j0 = Math.max(0, i - bw);
    for (let j = j0; j <= i; j++) {
      let s = L[i * w + (j - i + bw)];
      const k0 = Math.max(j0, j - bw);
      for (let k = k0; k < j; k++) s -= L[i * w + (k - i + bw)] * L[j * w + (k - j + bw)];
      if (j === i) {
        if (!(s > 0)) throw new Error('not SPD');
        L[i * w + bw] = Math.sqrt(s);
      } else {
        L[i * w + (j - i + bw)] = s / L[j * w + bw];
      }
    }
  }
  const y = new Float64Array(n);
  for (let i = 0; i < n; i++) {
    let s = b[i];
    for (let k = Math.max(0, i - bw); k < i; k++) s -= L[i * w + (k - i + bw)] * y[k];
    y[i] = s / L[i * w + bw];
  }
  const x = new Float64Array(n);
  for (let i = n - 1; i >= 0; i--) {
    let s = y[i];
    for (let k = i + 1; k <= Math.min(n - 1, i + bw); k++) s -= L[k * w + (i - k + bw)] * x[k];
    x[i] = s / L[i * w + bw];
  }
  return x;
}

export function norm2(v: ArrayLike<number>): number {
  let s = 0;
  for (let i = 0; i < v.length; i++) s += v[i] * v[i];
  return Math.sqrt(s);
}
