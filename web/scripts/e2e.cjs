// 界面端到端检查（Playwright + Chromium）：逐项操作并截图，打印关键文字与控制台错误。
// 用法：先 npm run build 并 npx vite preview（或 npm run build:single 后用 file:// 打开），然后
//   PW=$(npm root -g)/playwright OUT=/tmp/shots URL=http://localhost:4173/ node scripts/e2e.cjs
// Playwright 不在本项目依赖里：用全局安装的（PW 指向其目录）。
const { chromium } = require(process.env.PW);
const fs = require('fs');
const OUT = process.env.OUT;
(async () => {
  const b = await chromium.launch();
  const ctx = await b.newContext({ viewport: { width: 1360, height: 1150 }, acceptDownloads: true });
  const p = await ctx.newPage();
  const logs = [];
  p.on('console', (m) => { if (m.type() !== 'log') logs.push(`[${m.type()}] ${m.text()}`); });
  p.on('pageerror', (e) => logs.push(`[pageerror] ${e.message}`));
  const shot = (n) => p.screenshot({ path: `${OUT}/${n}.png` });
  const t0 = Date.now();
  const log = (s) => console.log(`${((Date.now() - t0) / 1000).toFixed(1)}s ${s}`);
  await p.goto(process.env.URL || 'http://localhost:4173/', { waitUntil: 'load' });
  await p.waitForSelector('canvas.field-canvas', { timeout: 30000 });
  log('loaded');
  // 1. 运行几秒
  await p.click('text=▶ 开始仿真');
  await p.waitForTimeout(8000);
  await p.click('text=⏸ 暂停仿真');
  log('ran: ' + (await p.innerText('.right .muted.small')));
  // 2. 布局页：点击主视图 B1 安装位（底中）→ 进气；表格改前上为排气
  await p.click('.tabs >> text=风扇布局');
  const cv = await p.$('canvas.field-canvas');
  const box = await cv.boundingBox();
  const cell = box.width / 140;
  // B1 底中：机箱外框为第 21–120 格，风扇盘在底壁内侧，点击区域向壁外延伸几格
  await p.mouse.click(box.x + (20 + 230 / 4) * cell, box.y + 121.5 * cell);
  await p.waitForTimeout(300);
  const selects = await p.$$('.slot-table tbody tr:nth-child(1) select');
  await selects[0].selectOption('exhaust');
  await p.waitForTimeout(300);
  log('layout info: ' + (await p.innerText('.layout-info')).replace(/\n/g, ' | '));
  log('warnings: ' + (await p.innerText('.warnings')).replace(/\n/g, ' | '));
  await shot('e2e_layout_edit');
  // 3. 保存方案 A（当前、未应用）→ 应用布局 → 运行 → 保存 B
  await p.click('.tabs >> text=方案对比');
  await p.click('text=保存当前');
  await p.click('.tabs >> text=风扇布局');
  await p.click('text=应用布局');
  await p.waitForTimeout(1500);
  await p.click('text=▶ 开始仿真');
  await p.waitForTimeout(6000);
  await p.click('text=⏸ 暂停仿真');
  await p.click('.tabs >> text=方案对比');
  await p.selectOption('.tab-body .row select >> nth=0', '1');
  await p.click('text=保存当前');
  await p.waitForTimeout(300);
  log('scenario table:\n' + (await p.innerText('.scenario-table')));
  await shot('e2e_scenarios');
  // 4. 温差视图（当前 − A）
  await p.click('text=显示温差');
  await p.waitForTimeout(1000);
  log('diff title: ' + (await p.innerText('.view-title')));
  await shot('e2e_diff');
  // 5. 风扇工作点图
  await p.selectOption('.toolbar select', 'pq');
  await p.waitForTimeout(800);
  await shot('e2e_pq');
  // 6. 导出 PNG、保存 JSON
  const [dl1] = await Promise.all([p.waitForEvent('download'), p.click('text=导出 PNG')]);
  const png = `${OUT}/${dl1.suggestedFilename()}`;
  await dl1.saveAs(png);
  log('png ' + fs.statSync(png).size + ' bytes');
  await p.click('.tabs >> text=风扇布局');
  const [dl2] = await Promise.all([p.waitForEvent('download'), p.click('text=保存配置（JSON）')]);
  const js = `${OUT}/${dl2.suggestedFilename()}`;
  await dl2.saveAs(js);
  const L = JSON.parse(fs.readFileSync(js, 'utf8'));
  log('json caseFans ' + L.caseFans.map((f) => `${f.mount}${f.alongMm}:${f.type}`).join(' '));
  // 7. 载入预设并载入 JSON
  await p.selectOption('.tab-body .row select >> nth=0', 'positive');
  await p.click('text=载入预设');
  log('after preset: ' + (await p.innerText('.layout-info')).replace(/\n/g, ' | '));
  await p.setInputFiles('input[type=file]', js);
  await p.waitForTimeout(1500);
  log('after json load: ' + (await p.innerText('.layout-info')).replace(/\n/g, ' | '));
  // 8. GIF 录制 2 秒
  await p.click('text=▶ 开始仿真');
  await p.click('text=● 录制 GIF');
  await p.waitForTimeout(2500);
  const [dl3] = await Promise.all([p.waitForEvent('download'), p.click('.toolbar >> text=停止录制')]);
  const gifPath = `${OUT}/${dl3.suggestedFilename()}`;
  await dl3.saveAs(gifPath);
  log('gif ' + fs.statSync(gifPath).size + ' bytes');
  await p.click('text=⏸ 暂停仿真');
  // 9. 精确模式、网格 280²、重置
  await p.check('text=精确模式');
  await p.selectOption('.grid-row select', '1');
  await p.waitForTimeout(4000);
  log('grid: ' + (await p.innerText('.view-title')));
  await p.click('text=重置');
  await p.selectOption('.grid-row select', '0.5');
  await p.waitForTimeout(2000);
  // 10. 跑到稳态几秒后停止
  await p.click('text=⏩ 跑到稳态');
  await p.waitForTimeout(5000);
  log('steady: ' + (await p.innerText('.run-btns')).replace(/\n/g, ' | '));
  await p.click('.run-btns >> text=停止');
  await p.waitForTimeout(800);
  log('after stop: ' + (await p.innerText('.right .muted.small')));
  await p.click('.tabs >> text=状态');
  await shot('e2e_final');
  // 窄屏
  await p.setViewportSize({ width: 390, height: 900 });
  await p.waitForTimeout(800);
  await p.screenshot({ path: `${OUT}/e2e_mobile.png`, fullPage: false });
  const overflow = await p.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
  log('mobile horizontal overflow px: ' + overflow);
  console.log(logs.join('\n') || '(no console errors)');
  await b.close();
})().catch((e) => { console.error('E2E FAILED', e); process.exit(1); });
