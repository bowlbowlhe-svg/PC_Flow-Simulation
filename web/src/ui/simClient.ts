// 主线程侧的 Worker 封装：发送命令，保存最新的静态信息与帧，通知订阅者。
import type { Command, FrameFields, StaticInfo, Status, WorkerMessage } from '../worker/protocol';

export interface SimState {
  info: StaticInfo | null;
  fields: FrameFields | null;
  status: Status | null;
  error: string | null;
  /** 每收到一帧加一（渲染用） */
  frameNo: number;
  /** 每次重建求解器加一 */
  buildNo: number;
}

export class SimClient {
  private worker: Worker;
  state: SimState = { info: null, fields: null, status: null, error: null, frameNo: 0, buildNo: 0 };
  private listeners = new Set<(s: SimState) => void>();

  constructor() {
    this.worker = new Worker(new URL('../worker/sim.worker.ts', import.meta.url), { type: 'module' });
    this.worker.onmessage = (e: MessageEvent<WorkerMessage>) => this.onMessage(e.data);
    this.worker.onerror = (e) => {
      this.state = { ...this.state, error: e.message || '仿真线程出错' };
      this.emit();
    };
  }

  private onMessage(m: WorkerMessage): void {
    switch (m.type) {
      case 'static':
        this.state = { ...this.state, info: m.info, buildNo: this.state.buildNo + 1, error: null };
        break;
      case 'frame':
        this.state = { ...this.state, fields: m.fields, status: m.status, frameNo: this.state.frameNo + 1 };
        break;
      case 'error':
        this.state = { ...this.state, error: m.message };
        break;
    }
    this.emit();
  }

  send(cmd: Command): void {
    this.worker.postMessage(cmd);
  }

  clearError(): void {
    this.state = { ...this.state, error: null };
    this.emit();
  }

  subscribe(fn: (s: SimState) => void): () => void {
    this.listeners.add(fn);
    return () => this.listeners.delete(fn);
  }

  private emit(): void {
    for (const fn of this.listeners) fn(this.state);
  }

  dispose(): void {
    this.worker.terminate();
    this.listeners.clear();
  }
}
