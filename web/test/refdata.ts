// 读取 matlab_app/tests/reference 下的标准答案数据集（测试用）。
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
export const REF_DIR = join(here, '..', '..', 'matlab_app', 'tests', 'reference');

// eslint-disable-next-line @typescript-eslint/no-explicit-any
export type Ref = any;

const cache = new Map<string, Ref>();

export function loadRef(name: string): Ref {
  let r = cache.get(name);
  if (!r) {
    r = JSON.parse(readFileSync(join(REF_DIR, `${name}.json`), 'utf8'));
    cache.set(name, r);
  }
  return r;
}

/** 数据集里 null 表示 NaN */
export function numArr(a: (number | null)[]): Float64Array {
  return Float64Array.from(a, (v) => (v === null ? NaN : v));
}

/** 6 位有效数字存储的舍入容差 */
export function close6(a: number, b: number): boolean {
  if (Number.isNaN(a) && Number.isNaN(b)) return true;
  return Math.abs(a - b) <= 5e-6 * Math.max(Math.abs(a), Math.abs(b)) + 1e-300;
}

/** 分段推进并让出事件循环（长时间同步计算会让 vitest 的进程间通信超时） */
export async function stepYielding(s: { stepMultiple(n: number): unknown }, n: number, chunk = 10): Promise<void> {
  for (let done = 0; done < n; ) {
    const k = Math.min(chunk, n - done);
    s.stepMultiple(k);
    done += k;
    await new Promise((r) => setImmediate(r));
  }
}
