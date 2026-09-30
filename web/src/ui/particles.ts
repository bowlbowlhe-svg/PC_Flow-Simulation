// 流场粒子示踪（移植自 ParticleTracer.m；可视化用，不参与计算）。
// 粒子随格心速度场移动（双线性插值 + 中点法），记录最近 trail 帧的位置作为尾迹；每帧位移超过 3 格时细分子步。
// 进入固体、离开计算域、寿命到期或在静止空气里停留过久时，在随机流体格重生（多数在机箱内）。
// 坐标为 1 基格坐标：X 为列（向右），Y 为行（向下）。

export interface TracerGeometry {
  W: number;
  H: number;
  obstacle: Uint8Array;
  fluidIdx: Int32Array; // 可重生的流体格（不含海绵环），0 基
  insideIdx: Int32Array; // 机箱内的可重生流体格
}

export class ParticleTracer {
  n: number;
  readonly trail: number;
  maxAge = 150;
  insideFrac = 0.92;
  stillSpeed = 0.03; // m/s
  stillFrames = 25;
  /** 位置历史：X[k·(trail+1) + j]，j = 0 为最新 */
  X = new Float32Array(0);
  Y = new Float32Array(0);
  age = new Int32Array(0);
  still = new Int32Array(0);
  speed = new Float32Array(0);
  private geo: TracerGeometry | null = null;

  constructor(n = 1500, trail = 8) {
    this.n = n;
    this.trail = trail;
  }

  reset(geo: TracerGeometry, n = this.n): void {
    this.geo = geo;
    this.n = n;
    const m = this.trail + 1;
    this.X = new Float32Array(n * m);
    this.Y = new Float32Array(n * m);
    this.age = new Int32Array(n);
    this.still = new Int32Array(n);
    this.speed = new Float32Array(n);
    for (let k = 0; k < n; k++) {
      this.respawn(k);
      this.age[k] = Math.floor(Math.random() * this.maxAge);
    }
  }

  private respawn(k: number): void {
    const g = this.geo!;
    const pool = Math.random() < this.insideFrac && g.insideIdx.length ? g.insideIdx : g.fluidIdx;
    const c = pool[Math.floor(Math.random() * pool.length)];
    const x = Math.floor(c / g.W) + 1 + Math.random() - 0.5;
    const y = (c % g.W) + 1 + Math.random() - 0.5;
    const m = this.trail + 1;
    for (let j = 0; j < m; j++) {
      this.X[k * m + j] = x;
      this.Y[k * m + j] = y;
    }
    this.age[k] = 0;
    this.still[k] = 0;
    this.speed[k] = 0;
  }

  /**
   * 推进 dtSec 秒物理时间。uC/vC 为格心网格速度（列优先 W×H），velScale 为网格速度 → m/s，cellM 为格边长 [m]。
   */
  step(uC: Float32Array, vC: Float32Array, velScale: number, cellM: number, dtSec: number): void {
    const g = this.geo;
    if (!g || !this.n) return;
    const { W, H } = g;
    const s = (velScale * dtSec) / cellM; // 网格速度 → 格/帧
    let vmax = 0;
    for (let i = 0; i < uC.length; i++) vmax = Math.max(vmax, Math.abs(uC[i]), Math.abs(vC[i]));
    const nSub = Math.min(4, Math.max(1, Math.ceil((vmax * s) / 3)));
    const f = s / nSub;
    const sample = (x: number, y: number, out: number[]) => {
      // 坐标先夹进网格范围再双线性插值（interp2 linear，1 基）
      const xc = Math.min(Math.max(x, 1), H);
      const yc = Math.min(Math.max(y, 1), W);
      const x0 = Math.min(Math.floor(xc), H - 1);
      const y0 = Math.min(Math.floor(yc), W - 1);
      const tx = xc - x0;
      const ty = yc - y0;
      const i00 = (x0 - 1) * W + (y0 - 1);
      const i10 = i00 + W;
      const w00 = (1 - tx) * (1 - ty);
      const w01 = (1 - tx) * ty;
      const w10 = tx * (1 - ty);
      const w11 = tx * ty;
      out[0] = (uC[i00] * w00 + uC[i00 + 1] * w01 + uC[i10] * w10 + uC[i10 + 1] * w11) * f;
      out[1] = (vC[i00] * w00 + vC[i00 + 1] * w01 + vC[i10] * w10 + vC[i10 + 1] * w11) * f;
    };
    const m = this.trail + 1;
    const a = [0, 0];
    const b = [0, 0];
    for (let k = 0; k < this.n; k++) {
      const o = k * m;
      let x = this.X[o];
      let y = this.Y[o];
      let disp = 0;
      for (let q = 0; q < nSub; q++) {
        sample(x, y, a);
        sample(x + 0.5 * a[0], y + 0.5 * a[1], b);
        x += b[0];
        y += b[1];
        disp += Math.hypot(b[0], b[1]);
      }
      this.speed[k] = s > 0 ? (disp / s) * velScale : 0;
      this.X.copyWithin(o + 1, o, o + m - 1);
      this.Y.copyWithin(o + 1, o, o + m - 1);
      this.X[o] = x;
      this.Y[o] = y;
      this.age[k]++;
      if (this.speed[k] < this.stillSpeed) this.still[k]++;
      else this.still[k] = 0;
      const xi = Math.round(x);
      const yi = Math.round(y);
      const out = xi < 2 || xi > H - 1 || yi < 2 || yi > W - 1;
      const solid = !out && g.obstacle[(xi - 1) * W + (yi - 1)] > 0;
      if (out || solid || this.age[k] > this.maxAge || this.still[k] > this.stillFrames) this.respawn(k);
    }
  }
}
