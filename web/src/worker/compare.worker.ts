// 对比计算 Worker：按 CompareRunner 的口径分段推进自定义方案（与仿真 Worker 分开，互不阻塞），逐个场景回报进度与结果。
import { COMPARE_SCENARIOS, CompareRunner } from '../compare/protocol';
import { makeThumb } from '../compare/thumb';
import type { CompareCommand, CompareMessage } from './compareProtocol';

const ctx = self as unknown as {
  postMessage(m: CompareMessage, transfer?: Transferable[]): void;
  onmessage: ((e: MessageEvent<CompareCommand>) => void) | null;
};

interface Job {
  id: number;
  cmd: Extract<CompareCommand, { type: 'start' }>;
  k: number; // 当前场景下标
  runner: CompareRunner | null;
  lastPost: number;
  cancelled: boolean;
}

let job: Job | null = null;
const channel = new MessageChannel();
let scheduled = false;

function schedule(): void {
  if (scheduled || !job) return;
  scheduled = true;
  channel.port2.postMessage(0);
}

/** 推进约 100 ms（至少一步），然后让出给命令 */
function tick(): void {
  const j = job;
  if (!j || j.cancelled) return;
  try {
    const keys = j.cmd.scenarios;
    if (!j.runner) {
      const sc = COMPARE_SCENARIOS.find((s) => s.key === keys[j.k])!;
      j.runner = new CompareRunner(j.cmd.layout, sc.powers, j.cmd.protocol);
    }
    const r = j.runner;
    const t0 = performance.now();
    while (!r.done && performance.now() - t0 < 100) r.advance(1);
    const now = performance.now();
    if (now - j.lastPost > 300 || r.done) {
      j.lastPost = now;
      ctx.postMessage({ type: 'progress', id: j.id, scenario: keys[j.k], index: j.k, count: keys.length, done: r.doneSteps, total: r.totalSteps });
    }
    if (!r.done) return schedule();
    if (r.diverged || !r.auto || !r.autoField) throw new Error('计算发散');
    const g = r.solver.geo.CASE2D.outer;
    const th = makeThumb(r.autoField, { x: g.x, y: g.y, w: g.w, h: g.h }, j.cmd.protocol.gridScale >= 1 ? 2 : 1);
    ctx.postMessage(
      { type: 'case', id: j.id, scenario: keys[j.k], auto: r.auto, sweep: r.sweep, thumb: th },
      [th.T.buffer, th.speed.buffer, th.solid.buffer],
    );
    j.k++;
    j.runner = null;
    if (j.k >= keys.length) {
      ctx.postMessage({ type: 'done', id: j.id });
      job = null;
      return;
    }
    schedule();
  } catch (err) {
    ctx.postMessage({ type: 'error', id: j.id, message: err instanceof Error ? err.message : String(err) });
    job = null;
  }
}

channel.port1.onmessage = () => {
  scheduled = false;
  tick();
};

ctx.onmessage = (e) => {
  const c = e.data;
  if (c.type === 'start') {
    if (job) job.cancelled = true;
    job = { id: c.id, cmd: c, k: 0, runner: null, lastPost: 0, cancelled: false };
    schedule();
  } else if (c.type === 'cancel') {
    if (job && job.id === c.id) {
      job.cancelled = true;
      job = null;
      ctx.postMessage({ type: 'cancelled', id: c.id });
    }
  }
};
