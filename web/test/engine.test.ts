// 仿真引擎（Worker 内的逻辑）：命令处理、分段推进、帧内容、跑到稳态与中止、出错处理。
import { describe, expect, it } from 'vitest';
import { SimEngine, turbUpdateEveryFor } from '../src/worker/engine';
import { layoutBenchmark } from '../src/model/layoutBenchmark';
import { layoutDefault } from '../src/model/layoutDefault';
import type { WorkerMessage } from '../src/worker/protocol';
import { Solver } from '../src/solver/solver';

function setup(layout = layoutBenchmark('duct', 20)) {
  const msgs: WorkerMessage[] = [];
  let t = 0;
  const e = new SimEngine((m) => msgs.push(m), () => (t += 1));
  e.frameIntervalMs = 0;
  e.handle({ type: 'init', layout, gridScale: 0.5, powers: { cpu: 125, gpu: 250, psu: 450 }, autoFan: true, fanPct: 40 });
  return { e, msgs };
}

const frames = (msgs: WorkerMessage[]) => msgs.filter((m): m is Extract<WorkerMessage, { type: 'frame' }> => m.type === 'frame');

describe('SimEngine', () => {
  it('init 发送静态信息与首帧；预览档湍流隔步更新', () => {
    const { e, msgs } = setup(layoutDefault());
    expect(msgs[0].type).toBe('static');
    const info = (msgs[0] as Extract<WorkerMessage, { type: 'static' }>).info;
    expect(info.W).toBe(140);
    expect(info.turbUpdateEvery).toBe(2);
    expect(turbUpdateEveryFor(1)).toBe(1);
    expect(info.fans.length).toBe(e.solver!.fans.length);
    expect(info.markers.length).toBe(e.solver!.geo.openings.length);
    expect(info.cpu && info.gpu && info.psu).toBeTruthy();
    expect(info.insideIdx.length).toBeGreaterThan(1000);
    const f = frames(msgs)[0];
    expect(f.fields.T.length).toBe(140 * 140);
    expect(f.status.iteration).toBe(0);
    expect(f.status.running).toBe(false);
  });

  it('run → tick 推进并出帧；pause 停止；推进结果与直接用求解器相同', () => {
    const { e, msgs } = setup();
    e.handle({ type: 'run' });
    let guard = 0;
    while (e.solver!.iteration < 6 && guard++ < 100) e.tick();
    e.handle({ type: 'pause' });
    expect(e.busy).toBe(false);
    expect(e.tick()).toBe(false);
    const n = e.solver!.iteration;
    const ref = new Solver(layoutBenchmark('duct', 20), { gridScale: 0.5, powers: { cpu: 125, gpu: 250, psu: 450 } });
    ref.turbUpdateEvery = 2;
    ref.stepMultiple(n);
    expect(Array.from(e.solver!.uF)).toEqual(Array.from(ref.uF));
    const last = frames(msgs).at(-1)!;
    expect(last.status.iteration).toBe(n);
    expect(last.status.running).toBe(false);
  });

  it('setPower / setFan 作用于求解器', () => {
    const { e } = setup(layoutDefault());
    e.handle({ type: 'setPower', name: 'cpu', watts: 200 });
    expect(e.solver!.thermalNetworks.cpu!.power).toBe(200);
    e.handle({ type: 'setPower', name: 'psu', watts: 600 });
    expect(e.solver!.powerW.psu).toBe(600);
    expect(e.solver!.thermalNetworks.psu!.power).toBeCloseTo(e.solver!.psuLossW(600), 12);
    e.handle({ type: 'setFan', auto: false, pct: 70 });
    expect(e.solver!.autoFanEnabled).toBe(false);
    expect(e.solver!.fanSpeedRatio).toBe(70);
  });

  it('跑到稳态：分段推进直到最大步数，状态消息；中途可停止；重置回到 0 步', () => {
    const { e, msgs } = setup();
    e.handle({ type: 'steady', opts: { maxSteps: 12, chunk: 5, tolT: -1, tolFlow: -1 } });
    let guard = 0;
    while (e.tick() && guard++ < 200);
    expect(e.solver!.iteration).toBe(12);
    const st = frames(msgs).at(-1)!.status.steady!;
    expect(st.active).toBe(false);
    expect(st.message).toBe('未完全收敛（12 步）');
    e.handle({ type: 'steady', opts: { maxSteps: 100, chunk: 50, tolT: -1, tolFlow: -1 } });
    const it0 = e.solver!.iteration;
    e.tick();
    e.tick();
    e.handle({ type: 'stopSteady' });
    expect(e.busy).toBe(false);
    const stopped = frames(msgs).at(-1)!.status.steady!;
    expect(stopped.aborted).toBe(true);
    // 未满一块时停止：消息里的步数为实际推进的步数
    expect(stopped.message).toBe(`已停止（${e.solver!.iteration - it0} 步）`);
    expect(e.solver!.iteration - it0).toBeGreaterThan(0);
    e.handle({ type: 'reset' });
    expect(e.solver!.iteration).toBe(0);
    expect(frames(msgs).at(-1)!.status.steady).toBeNull();
  });

  it('推进出错时停止并报告，不抛出', () => {
    const { e, msgs } = setup();
    e.handle({ type: 'run' });
    e.solver!.fluidStep = () => {
      throw new Error('线性求解未收敛：pressure（第 1 步）');
    };
    expect(e.tick()).toBe(false);
    expect(e.busy).toBe(false);
    expect(msgs.some((m) => m.type === 'error' && m.message.includes('未收敛'))).toBe(true);
  });
});
