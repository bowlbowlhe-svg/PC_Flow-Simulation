// 主线程侧的对比计算 Worker 封装（自定义方案的后台计算）。
import type { CompareCommand, CompareMessage } from '../worker/compareProtocol';
// 同仿真 Worker：内联进主包，单文件版也能用
import CompareWorker from '../worker/compare.worker.ts?worker&inline';

export class CompareClient {
  private worker: Worker | null = null;
  private seq = 0;
  private listener: ((m: CompareMessage) => void) | null = null;

  /** 开始计算（同一时刻只算一个；新的会取消旧的）。返回任务号 */
  start(cmd: Omit<Extract<CompareCommand, { type: 'start' }>, 'type' | 'id'>, onMessage: (m: CompareMessage) => void): number {
    if (!this.worker) {
      this.worker = new CompareWorker();
      this.worker.onmessage = (e: MessageEvent<CompareMessage>) => this.listener?.(e.data);
      this.worker.onerror = (e) => this.listener?.({ type: 'error', id: this.seq, message: e.message || '对比计算线程出错' });
    }
    const id = ++this.seq;
    this.listener = (m) => {
      if (m.id === id) onMessage(m);
    };
    this.worker.postMessage({ type: 'start', id, ...cmd } satisfies CompareCommand);
    return id;
  }

  cancel(id: number): void {
    this.worker?.postMessage({ type: 'cancel', id } satisfies CompareCommand);
  }

  dispose(): void {
    this.worker?.terminate();
    this.worker = null;
  }
}
