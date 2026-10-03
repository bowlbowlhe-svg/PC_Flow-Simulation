// 界面端到端检查（Playwright + Chromium）：逐项操作、断言结果并截图；任一断言失败则以非零状态退出。
// 用法：先 npm run build 并 npx vite preview（或 npm run release 后用 file:// 打开单文件版），然后
//   PW=$(npm root -g)/playwright OUT=/tmp/shots URL=http://localhost:4173/ node scripts/e2e.cjs
// Playwright 不在本项目依赖里：用全局安装的（PW 指向其目录）。
const { chromium } = require(process.env.PW);
const fs = require('fs');
const path = require('path');
const OUT = process.env.OUT || '/tmp/pcflow-e2e';
fs.mkdirSync(OUT, { recursive: true });

let failures = 0;
function check(cond, msg) {
  if (cond) console.log(`  ✓ ${msg}`);
  else {
    failures++;
    console.log(`  ✗ ${msg}`);
  }
}

(async () => {
  const b = await chromium.launch();
  const ctx = await b.newContext({ viewport: { width: 1360, height: 1150 }, acceptDownloads: true });
  const p = await ctx.newPage();
  const logs = [];
  p.on('console', (m) => {
    if (m.type() === 'error' || m.type() === 'warning') logs.push(`[${m.type()}] ${m.text()}`);
  });
  p.on('pageerror', (e) => logs.push(`[pageerror] ${e.message}`));
  const shot = (n) => p.screenshot({ path: `${OUT}/${n}.png` });
  const t0 = Date.now();
  const log = (s) => console.log(`${((Date.now() - t0) / 1000).toFixed(1)}s ${s}`);
  const text = (sel) => p.innerText(sel);
  const download = async (clickSel) => {
    const [dl] = await Promise.all([p.waitForEvent('download', { timeout: 60000 }), p.click(clickSel)]);
    const f = path.join(OUT, dl.suggestedFilename());
    await dl.saveAs(f);
    return f;
  };
  const writeJson = (name, obj) => {
    const f = path.join(OUT, name);
    fs.writeFileSync(f, JSON.stringify(obj));
    return f;
  };

  await p.goto(process.env.URL || 'http://localhost:4173/', { waitUntil: 'load' });
  await p.waitForSelector('canvas.field-canvas', { timeout: 30000 });
  log('页面载入');

  // 1. 运行几秒
  await p.click('text=▶ 开始仿真');
  await p.waitForTimeout(6000);
  check((await text('.right .muted.small')).includes('运行中'), '运行中状态');
  await p.click('text=⏸ 暂停仿真');
  const it1 = Number((await text('.right')).match(/（(\d+) 步）/)?.[1] ?? 0);
  check(it1 > 5, `推进了若干步（${it1}）`);

  // 2. 布局页：点击主视图 B1 安装位（底部）→ 进气；表格把 F1 改为排气
  await p.click('.tabs >> text=风扇布局');
  const box = await (await p.$('canvas.field-canvas')).boundingBox();
  const cell = box.width / 140;
  // B1 底部（中心 232 mm）：机箱外框 x 为第 31–110 格、y 为第 21–120 格，风扇盘在底壁内侧，点击区域向壁外延伸几格
  await p.mouse.click(box.x + (30 + 232 / 4) * cell, box.y + 121.5 * cell);
  await p.$$eval('.slot-table tbody tr:nth-child(1) select', (els) => {
    els[0].value = 'exhaust';
    els[0].dispatchEvent(new Event('change', { bubbles: true }));
  });
  check((await p.$eval('select.cpu-fans', (e) => e.value)) === '2', '默认双塔 2 个塔扇');
  await p.selectOption('select.cpu-fans', '1');
  await p.waitForTimeout(300);
  check((await text('.layout-info')).includes('待应用：自定义'), '编辑后显示"待应用：自定义"');
  check((await text('.tabs')).includes('风扇布局 •'), '标签页显示未应用标记');
  check((await p.$('.toolbar .pending-note')) !== null, '主视图下方提示"布局有未应用的修改"');
  await shot('e2e_layout_edit');

  // 3. 保存方案 A → 应用布局 → 运行 → 保存 B
  await p.click('.tabs >> text=方案对比');
  await p.click('text=保存当前');
  await p.click('.tabs >> text=风扇布局');
  await p.click('button:text-is("应用布局")');
  await p.waitForFunction(() => document.querySelector('.layout-info')?.textContent?.includes('当前：自定义'), null, { timeout: 30000 });
  check(true, '应用布局后显示"当前：自定义"');
  check((await p.$('.toolbar .pending-note')) === null, '应用后不再提示未应用的修改');
  await p.click('text=▶ 开始仿真');
  await p.waitForTimeout(4000);
  await p.click('text=⏸ 暂停仿真');
  await p.click('.tabs >> text=方案对比');
  await p.selectOption('.tab-body .row select >> nth=0', '1');
  await p.click('text=保存当前');
  const rows = await p.$$eval('.scenario-table tbody tr', (r) => r.length);
  check(rows === 18, `方案表 18 行（${rows}）`);
  const fansRow = await p.$$eval('.scenario-table tbody tr', (r) => r.find((x) => x.textContent.includes('机箱风扇数')).textContent);
  check(/机箱风扇数\s*6\s*4\s*6/.test(fansRow.replace(/\s+/g, ' ')), `风扇数：当前 6、A 4、B 6（${fansRow.replace(/\s+/g, ' ')}）`);
  const towerRow = await p.$$eval('.scenario-table tbody tr', (r) => r.find((x) => x.textContent.includes('CPU 散热器')).textContent.replace(/\s+/g, ' '));
  check(/双塔·1 扇\s*双塔·2 扇\s*双塔·1 扇/.test(towerRow), `CPU 散热器：当前 1 扇、A 2 扇、B 1 扇（${towerRow}）`);
  await shot('e2e_scenarios');

  // 4. 温差视图；重存参考方案后温差归零（W2–W4 审计：暂停中重存要立即重画）
  await p.click('text=显示温差');
  await p.waitForTimeout(800);
  check((await text('.view-title')).includes('温差：当前 − 方案 A'), '温差视图标题');
  await p.selectOption('.tab-body .row select >> nth=0', '0');
  await p.click('text=保存当前');
  await p.waitForTimeout(800);
  const nonGray = await p.evaluate(() => {
    const c = document.querySelector('canvas.field-canvas');
    const d = c.getContext('2d').getImageData(Math.floor(c.width * 0.5), Math.floor(c.height * 0.5), 1, 1).data;
    return Math.abs(d[0] - d[1]) + Math.abs(d[1] - d[2]);
  });
  check(nonGray < 20, `重存 A 后温差视图归零（中心像素色差 ${nonGray}）`);
  await shot('e2e_diff');

  // 5. 风扇工作点图、导出 PNG、保存 JSON
  await p.selectOption('.toolbar select', 'pq');
  await p.waitForTimeout(500);
  await shot('e2e_pq');
  const png = await download('text=导出 PNG');
  check(fs.statSync(png).size > 50000, `PNG ${fs.statSync(png).size} 字节`);
  await p.click('.tabs >> text=风扇布局');
  const js = await download('text=保存配置（JSON）');
  const L = JSON.parse(fs.readFileSync(js, 'utf8'));
  const fanStr = L.caseFans.map((f) => `${f.mount}${f.alongMm}:${f.type}`).join(' ');
  check(fanStr.includes('bottom232:intake') && fanStr.includes('front100:exhaust'), `保存的 JSON 含点击与表格的修改（${fanStr}）`);
  check(L.cpu.fan.count === 1 && L.cpu.tower.stacks === 2, `保存的 JSON 含塔扇数量（${JSON.stringify(L.cpu.fan)}）`);

  // 6. 载入预设再载入 JSON
  await p.selectOption('.tab-body .row select >> nth=0', 'positive');
  await p.click('text=载入预设');
  check((await text('.layout-info')).includes('待应用：正压'), '载入预设');
  await p.setInputFiles('input[type=file]', js);
  await p.waitForFunction(() => document.querySelector('.layout-info')?.textContent?.includes('当前：配置'), null, { timeout: 30000 });
  check(true, '载入 JSON 后显示"当前：配置 …"');
  // 6b. 单塔旧配置（v1.3 之前，无 cpu.tower、无 cpu.fan.count）：塔扇下拉项为"前侧 / 前 + 后"
  const Lst = JSON.parse(fs.readFileSync(js, 'utf8'));
  delete Lst.cpu.tower;
  delete Lst.cpu.fan.count;
  await p.setInputFiles('input[type=file]', writeJson('singletower.json', Lst));
  await p.waitForFunction(() => document.querySelector('.layout-info')?.textContent?.includes('singletower.json'), null, { timeout: 30000 });
  const towerOpts = await p.$$eval('select.cpu-fans option', (os) => os.map((o) => o.textContent).join(' / '));
  check(towerOpts === '1 个（前侧） / 2 个（前 + 后）' && (await p.$eval('select.cpu-fans', (e) => e.value)) === '1', `单塔配置的塔扇下拉项（${towerOpts}）`);

  // 7. 自定义挡板缺口往返（W2–W4 审计：不能被默认值覆盖）
  const Lgap = JSON.parse(fs.readFileSync(js, 'utf8'));
  Lgap.shroud.gaps = [{ x0Mm: 270, x1Mm: 310 }];
  await p.setInputFiles('input[type=file]', writeJson('customgap.json', Lgap));
  await p.waitForFunction(() => document.querySelector('.layout-info')?.textContent?.includes('customgap.json'), null, { timeout: 30000 });
  await p.$$eval('.slot-table tbody tr:nth-child(5) select', (els) => {
    els[0].value = 'exhaust';
    els[0].dispatchEvent(new Event('change', { bubbles: true }));
  });
  const js2 = await download('text=保存配置（JSON）');
  const L2 = JSON.parse(fs.readFileSync(js2, 'utf8'));
  check(JSON.stringify(L2.shroud.gaps) === JSON.stringify([{ x0Mm: 270, x1Mm: 310 }]), `自定义缺口保留（${JSON.stringify(L2.shroud.gaps)}）`);
  await p.click('text=撤销未应用的修改');

  // 8. 重建失败回滚（W2–W4 审计）：噪音参数无效的配置 → 报"重建失败"，布局名与网格不变，之后不在旧求解器上跑稳态
  const before = await text('.layout-info');
  const Lbad = JSON.parse(fs.readFileSync(js, 'utf8'));
  Lbad.acoustics = { stallQ: 2, stallDb: 6, grilleRefZeta: 2, positionDb: { front: 0, top: -1.5, bottom: -3, rear: -4.5, cpu: -2, gpu: -1, psu: -3 } };
  await p.setInputFiles('input[type=file]', writeJson('bad_acoustics.json', Lbad));
  await p.waitForSelector('.error', { timeout: 30000 });
  check((await text('.error')).includes('重建失败'), `报错：${(await text('.error')).slice(0, 60)}`);
  check((await text('.layout-info')).split('\n')[0] === before.split('\n')[0], '布局名未被改写');
  check(!(await text('.right .muted.small')).includes('运行中'), '载入失败回滚后仍暂停（恢复功率不自动继续仿真）');
  await p.click('.error');

  // 8b. 配置缺 power：沿用当前功率正常载入；power 不全：报"配置无效"，不载入（最终审计）
  const Lnp = JSON.parse(fs.readFileSync(js, 'utf8'));
  delete Lnp.power;
  await p.setInputFiles('input[type=file]', writeJson('nopower.json', Lnp));
  await p.waitForFunction(() => document.querySelector('.layout-info')?.textContent?.includes('nopower.json'), null, { timeout: 30000 });
  check(true, '缺 power 的配置正常载入');
  const Lpart = JSON.parse(fs.readFileSync(js, 'utf8'));
  Lpart.power = { cpu: 100 };
  await p.setInputFiles('input[type=file]', writeJson('partpower.json', Lpart));
  await p.waitForSelector('.error', { timeout: 30000 });
  check((await text('.error')).includes('配置无效'), `power 不全时报错：${(await text('.error')).slice(0, 50)}`);
  check(!(await text('.layout-info')).includes('partpower.json'), 'power 不全的配置未载入');
  await p.click('.error');
  // 8c. 计算域过大：读取时即报错
  const Lbig = JSON.parse(fs.readFileSync(js, 'utf8'));
  Lbig.domain.sizeMm = 8000;
  await p.setInputFiles('input[type=file]', writeJson('bigdomain.json', Lbig));
  await p.waitForSelector('.error', { timeout: 30000 });
  check((await text('.error')).includes('读取配置失败'), `超大计算域报错：${(await text('.error')).slice(0, 50)}`);
  await p.click('.error');

  // 9. GIF 录制约 2 秒
  await p.click('text=▶ 开始仿真');
  await p.click('text=● 录制 GIF');
  await p.waitForTimeout(2500);
  const gif = await download('.toolbar >> text=停止录制');
  check(fs.statSync(gif).size > 10000, `GIF ${fs.statSync(gif).size} 字节`);
  await p.click('text=⏸ 暂停仿真');

  // 10. 精确模式、网格 280²、重置、切回 140²
  await p.check('.grid-row input[type=checkbox]');
  await p.selectOption('.grid-row select', '1');
  await p.waitForFunction(() => document.querySelector('.view-title')?.textContent?.includes('280²'), null, { timeout: 60000 });
  check((await text('.view-title')).includes('精确模式'), '280² 精确模式');
  await p.click('text=重置');
  await p.selectOption('.grid-row select', '0.5');
  await p.waitForFunction(() => document.querySelector('.view-title')?.textContent?.includes('140²'), null, { timeout: 60000 });
  await p.uncheck('.grid-row input[type=checkbox]');

  // 11. 跑到稳态几秒后停止
  await p.click('text=⏩ 跑到稳态');
  await p.waitForTimeout(4000);
  check((await text('.run-btns')).includes('停止'), '跑到稳态中');
  await p.click('.run-btns >> text=停止');
  await p.waitForTimeout(800);
  const stopMsg = await text('.right .muted.small');
  const m = stopMsg.match(/已停止（(\d+) 步）/);
  check(m && Number(m[1]) > 0, `停止消息：${stopMsg}`);
  await p.click('.tabs >> text=状态');
  await shot('e2e_final');

  // 11b. 暂停时切换功率场景：自动继续仿真，温度随之变化（用户反馈：跑到稳态后点"满载"，状态没有变化）
  const cpuOf = async () => Number((await text('.tab-body')).match(/CPU (\d+)°C/)?.[1] ?? NaN);
  const cpu0 = await cpuOf();
  await p.click('.tabs >> text=功率与风扇');
  await p.click('.tab-body button:text-is("满载")');
  await p.waitForTimeout(500);
  check((await text('.right .muted.small')).includes('运行中'), '暂停时点"满载"后自动继续仿真');
  await p.waitForTimeout(4000);
  await p.click('text=⏸ 暂停仿真');
  await p.click('.tabs >> text=状态');
  await p.waitForTimeout(300);
  const cpu1 = await cpuOf();
  check(cpu1 >= cpu0 + 3, `满载后 CPU 结温上升（${cpu0} → ${cpu1}°C）`);

  // 12. 窄屏
  await p.setViewportSize({ width: 390, height: 900 });
  await p.waitForTimeout(800);
  await p.screenshot({ path: `${OUT}/e2e_mobile.png` });
  const overflow = await p.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
  check(overflow <= 0, `窄屏无横向溢出（${overflow}px）`);

  check(logs.length === 0, `控制台无错误${logs.length ? '：\n' + logs.join('\n') : ''}`);
  await b.close();
  log(failures ? `${failures} 项失败` : '全部通过');
  process.exit(failures ? 1 : 0);
})().catch((e) => {
  console.error('E2E 异常', e);
  process.exit(2);
});
