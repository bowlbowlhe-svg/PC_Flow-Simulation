// 生成对比展示页的预计算数据（src/compare/data.json）：各风扇布局预设 × 办公/游戏/满载，按 src/compare/protocol.ts 的口径。
// 用法：
//   npm run compare-data -- run [预设名,…|all] [场景,…|all] 输出.json [--quick]   计算一部分（可分几个进程并行）
//   npm run compare-data -- merge 输出.json 部分1.json 部分2.json …               合并为界面用的数据文件
//   npm run compare-data -- thumbs 数据.json [预设名,…|all] [场景,…|all] 输出.json  只重算流场图：重跑自动温控阶段，
//       核对自动阶段的指标与数据文件按存储精度（2 位小数）全部相同后替换流场图（物理与口径不变、只改流场图时用；可分几个进程并行后 merge）
// --quick：140²、自动 60 步、扫描 2 档各 20 步（只用于检查流程）。精确口径每个算例约 4000 步（280²，约 35 分钟）。
import { readFileSync, writeFileSync } from 'node:fs';
import { deflateSync } from 'node:zlib';
import { applyPreset, FAN_PRESETS } from '../src/model/fans';
import { layoutDefault } from '../src/model/layoutDefault';
import { COMPARE_SCENARIOS, CompareRunner, DEFAULT_PROTOCOL, type CompareProtocol, type ScenarioKey } from '../src/compare/protocol';
import { makeFieldThumb, thumbPixels, type FieldThumb, type StoredThumb } from '../src/compare/thumb';
import { geoOverlay } from '../src/solver/geoOverlay';
import type { CompareCase, CompareData } from '../src/compare/data';

const QUICK: CompareProtocol = { gridScale: 0.5, turbUpdateEvery: 2, autoSteps: 60, autoAvgFrom: 30, sweepPct: [40, 100], sweepSteps: 20, sweepAvgFrom: 10 };

/** 最小 PNG 编码（8 位灰度或 RGB，每行用 Up 滤波，平滑场压得更小） */
function encodePng(w: number, h: number, px: Uint8Array, channels: 1 | 3): Buffer {
  const crcTable = new Int32Array(256).map((_, n) => {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    return c;
  });
  const crc = (buf: Buffer) => {
    let c = -1;
    for (const b of buf) c = crcTable[(c ^ b) & 0xff] ^ (c >>> 8);
    return (c ^ -1) >>> 0;
  };
  const chunk = (type: string, data: Buffer) => {
    const len = Buffer.alloc(4);
    len.writeUInt32BE(data.length);
    const td = Buffer.concat([Buffer.from(type, 'ascii'), data]);
    const c = Buffer.alloc(4);
    c.writeUInt32BE(crc(td));
    return Buffer.concat([len, td, c]);
  };
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(w, 0);
  ihdr.writeUInt32BE(h, 4);
  ihdr[8] = 8; // 位深
  ihdr[9] = channels === 3 ? 2 : 0; // RGB / 灰度
  const rb = channels * w;
  const raw = Buffer.alloc(h * (1 + rb));
  for (let r = 0; r < h; r++) {
    raw[r * (1 + rb)] = 2; // Up：与上一行之差
    for (let k = 0; k < rb; k++) raw[r * (1 + rb) + 1 + k] = (px[r * rb + k] - (r ? px[(r - 1) * rb + k] : 0)) & 0xff;
  }
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk('IHDR', ihdr),
    chunk('IDAT', deflateSync(raw, { level: 9 })),
    chunk('IEND', Buffer.alloc(0)),
  ]);
}

const r2 = (x: number) => (Number.isFinite(x) ? Math.round(x * 100) / 100 : null);

/** 流场图的存储格式（PNG + 几何；数值保留 2 位小数） */
function storeThumb(t: FieldThumb): StoredThumb {
  const { gray, rgb } = thumbPixels(t);
  const r = (o: unknown) => JSON.parse(JSON.stringify(o, (_k, v) => (typeof v === 'number' ? r2(v) : v)));
  return {
    v: 2,
    crop: t.crop,
    cellMm: t.cellMm,
    uvF: t.uvF,
    uw: t.uw,
    uh: t.uh,
    tPng: encodePng(t.crop.w, t.crop.h, gray, 1).toString('base64'),
    uvPng: encodePng(t.uw, t.uh, rgb, 3).toString('base64'),
    geo: t.geo,
    openings: r(t.openings),
  };
}

/** 自动温控阶段的时均场 → 流场图（280² 速度 2×2 块平均，140² 不平均；与界面后台计算一致） */
function thumbOf(r: CompareRunner, protocol: CompareProtocol): StoredThumb {
  return storeThumb(makeFieldThumb(r.autoField!, geoOverlay(r.solver), protocol.gridScale >= 1 ? 2 : 1));
}

function runCases(presets: string[], scens: ScenarioKey[], protocol: CompareProtocol): CompareCase[] {
  const out: CompareCase[] = [];
  for (const name of presets) {
    for (const key of scens) {
      const sc = COMPARE_SCENARIOS.find((s) => s.key === key)!;
      const L = applyPreset(layoutDefault(), name);
      const t0 = performance.now();
      const r = new CompareRunner(L, sc.powers, protocol);
      let last = t0;
      while (!r.advance(50)) {
        const now = performance.now();
        if (now - last > 120000) {
          last = now;
          console.log(`  ${name}/${key}: ${r.doneSteps}/${r.totalSteps} 步，${((now - t0) / r.doneSteps).toFixed(0)} ms/步`);
        }
      }
      if (r.diverged || !r.auto || !r.autoField) throw new Error(`${name}/${key} 发散`);
      out.push({ preset: name, scenario: key, auto: r.auto, sweep: r.sweep, thumb: thumbOf(r, protocol) });
      const a = r.auto;
      console.log(
        `${name}/${key}: CPU ${a.cpu.toFixed(1)} GPU ${a.gpu.toFixed(1)} 电源 ${a.psu.toFixed(1)} 内温 ${a.interior.toFixed(1)} 风量 ${a.cfm.toFixed(1)} ` +
          `噪音 ${a.noiseDb.toFixed(1)} 性能 ${a.perfPct}% 评分 ${a.score}（${a.cls}）；扫描 ` +
          r.sweep.map((p) => `${p.pct}%:${p.noiseDb.toFixed(1)}dB/${Math.max(p.cpu, p.gpu).toFixed(1)}°C`).join(' ') +
          `（${((performance.now() - t0) / 1000).toFixed(0)} s）`,
      );
    }
  }
  return out;
}

/** JSON 里保留 2 位小数（NaN → null）；扫描点不存风扇列表（全部风扇同一全局转速） */
function compact(c: CompareCase): CompareCase {
  const d: CompareCase = { ...c, sweep: c.sweep.map((q) => ({ ...q, fans: [] })) };
  return JSON.parse(JSON.stringify(d, (_k, v) => (typeof v === 'number' ? r2(v) : v)));
}

const [cmd, ...args] = process.argv.slice(2);
if (cmd === 'run') {
  const quick = args.includes('--quick');
  const pos = args.filter((a) => !a.startsWith('--'));
  const presets = !pos[0] || pos[0] === 'all' ? FAN_PRESETS.map((p) => p.name) : pos[0].split(',');
  const scens = (!pos[1] || pos[1] === 'all' ? COMPARE_SCENARIOS.map((s) => s.key) : pos[1].split(',')) as ScenarioKey[];
  const outPath = pos[2] ?? 'compare_part.json';
  const protocol = quick ? QUICK : DEFAULT_PROTOCOL;
  const cases = runCases(presets, scens, protocol).map(compact);
  writeFileSync(outPath, JSON.stringify({ protocol, cases }));
  console.log(`已写入 ${outPath}（${cases.length} 个算例）`);
} else if (cmd === 'merge') {
  const [outPath, ...parts] = args;
  const all = parts.map((p) => JSON.parse(readFileSync(p, 'utf8')) as { protocol: CompareProtocol; cases: CompareCase[] });
  const protocol = all[0].protocol;
  if (all.some((a) => JSON.stringify(a.protocol) !== JSON.stringify(protocol))) throw new Error('各部分的计算口径不同');
  const cases = all.flatMap((a) => a.cases);
  const data: CompareData = { version: 2, generated: new Date().toISOString().slice(0, 10), protocol, cases };
  writeFileSync(outPath, JSON.stringify(data));
  console.log(`已写入 ${outPath}（${cases.length} 个算例）`);
} else if (cmd === 'thumbs') {
  const [dataPath, presetArg, scenArg, outPath] = args;
  const src = JSON.parse(readFileSync(dataPath, 'utf8')) as CompareData;
  const protocol = src.protocol;
  const autoOnly: CompareProtocol = { ...protocol, sweepPct: [] };
  const want = (v: string, arg: string | undefined) => !arg || arg === 'all' || arg.split(',').includes(v);
  const cases: CompareCase[] = [];
  for (const c of src.cases) {
    if (!want(c.preset, presetArg) || !want(c.scenario, scenArg)) continue;
    const sc = COMPARE_SCENARIOS.find((s) => s.key === c.scenario)!;
    const t0 = performance.now();
    const r = new CompareRunner(applyPreset(layoutDefault(), c.preset), sc.powers, autoOnly);
    while (!r.advance(50));
    if (r.diverged || !r.auto || !r.autoField) throw new Error(`${c.preset}/${c.scenario} 发散`);
    // 自动阶段的指标须与数据文件按存储精度（2 位小数）全部相同，否则物理或口径已变，应整体重算
    const a = compact({ ...c, auto: r.auto, sweep: [] }).auto;
    const diff = Object.keys(a).filter((k) => JSON.stringify((a as unknown as Record<string, unknown>)[k]) !== JSON.stringify((c.auto as unknown as Record<string, unknown>)[k]));
    if (diff.length) throw new Error(`${c.preset}/${c.scenario} 自动阶段指标与数据文件不同：${diff.join(', ')}`);
    cases.push({ ...c, thumb: thumbOf(r, protocol) });
    console.log(`${c.preset}/${c.scenario}：自动阶段指标一致，流场图已重算（${((performance.now() - t0) / 1000).toFixed(0)} s）`);
  }
  writeFileSync(outPath, JSON.stringify({ protocol, cases }));
  console.log(`已写入 ${outPath}（${cases.length} 个算例）`);
} else {
  console.log('用法见文件头');
  process.exitCode = 1;
}
