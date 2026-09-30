// 仿真 Worker：接收界面命令，用 MessageChannel 让推进与命令交替执行（每段约 30 ms），不阻塞界面。
import { SimEngine } from './engine';
import type { Command, WorkerMessage } from './protocol';

const ctx = self as unknown as {
  postMessage(m: WorkerMessage, transfer?: Transferable[]): void;
  onmessage: ((e: MessageEvent<Command>) => void) | null;
};

const engine = new SimEngine((m, transfer) => ctx.postMessage(m, transfer ?? []));
const channel = new MessageChannel();
let scheduled = false;

function schedule(): void {
  if (scheduled || !engine.busy) return;
  scheduled = true;
  channel.port2.postMessage(0);
}

channel.port1.onmessage = () => {
  scheduled = false;
  if (engine.tick()) schedule();
};

ctx.onmessage = (e) => {
  try {
    engine.handle(e.data);
  } catch (err) {
    ctx.postMessage({ type: 'error', message: err instanceof Error ? err.message : String(err) });
  }
  schedule();
};
