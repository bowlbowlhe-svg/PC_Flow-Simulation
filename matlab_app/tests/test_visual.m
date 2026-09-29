function pass = test_visual()
%TEST_VISUAL 可视化数据：粒子示踪、开口标注、配色表。
%   1) 粒子示踪：默认场景推进后撒点、走 100 帧，粒子不进入固体、全部在域内；
%      直风道基准里粒子整体沿风道方向（前 → 后，x 减小）移动。
%   2) 开口标注：每个开口一个标注、都在机箱外侧；各开口净风量之和≈0（质量守恒）。
%   3) 配色表：尺寸、取值范围、发散色中点为浅灰。
    errs = {};

    % 1) 粒子
    s = CFDSolverFEM([], [], [], [], 0.5);
    s.turbUpdateEvery = 2;
    s.stepMultiple(200);
    pt = ParticleTracer(1500, 8);
    pt.reset(s);
    for k = 1:100, pt.step(s, 0.02); end
    x = pt.X(:, 1); y = pt.Y(:, 1);
    inDom = x >= 1 & x <= s.GRID.H & y >= 1 & y <= s.GRID.W;
    idx = (round(x(inDom)) - 1) * s.GRID.W + round(y(inDom));
    errs = check(errs, all(inDom), '粒子应全部在计算域内');
    errs = check(errs, all(s.obstacle(idx) == 0), '粒子不应进入固体');
    [xs, ys] = pt.trailLines();
    errs = check(errs, numel(xs) == pt.n * (pt.trail + 2) && sum(isnan(xs)) == pt.n, '尾迹折线格式');

    d = CFDSolverFEM(0, 0, 0, layout_benchmark('duct', 20), 0.5);
    d.stepMultiple(300);
    pd = ParticleTracer(800, 4);
    pd.reset(d);
    ox = d.caseOffsetX; c = d.GRID.cell_size_mm;
    rows = (d.caseOffsetY + round(150/c)):(d.caseOffsetY + round(250/c));
    in = ismember(round(pd.Y(:, 1)), rows) & pd.X(:, 1) > ox + round(220/c) & pd.X(:, 1) < ox + round(360/c);
    x0 = pd.X(:, 1);
    pd.step(d, 0.02);
    dx = pd.X(in, 1) - x0(in);
    errs = check(errs, sum(in) > 50 && mean(dx) < 0, sprintf('风道内粒子应向后（x 减小）移动（平均 %+.2f 格/帧）', mean(dx)));

    % 2) 开口标注
    M = s.openingMarkers();
    co = s.CASE2D.outer;
    errs = check(errs, numel(M) == numel(s.openings), '每个开口一个标注');
    outside = arrayfun(@(m) m.x < co.x || m.x > co.x + co.w - 1 || m.y < co.y || m.y > co.y + co.h - 1, M);
    errs = check(errs, all(outside), '标注应在机箱外侧');
    q = [M.cfm];
    errs = check(errs, abs(sum(q)) < 0.05 * sum(abs(q)) / 2, sprintf('开口净风量之和应≈0（%+.2f / 总进出 %.1f CFM）', sum(q), sum(abs(q))/2));

    % 3) 配色表
    for nm = {'speed', 'heat', 'diverging'}
        cm = pcflow_colormap(nm{1}, 64);
        errs = check(errs, isequal(size(cm), [64 3]) && all(cm(:) >= 0 & cm(:) <= 1), ['配色表 ' nm{1}]);
    end
    cm = pcflow_colormap('diverging', 65);
    errs = check(errs, all(abs(cm(33, :) - 0.87) < 0.01), '发散色中点应为浅灰');
    hm = pcflow_colormap('heat', 256);
    lum = hm * [0.299; 0.587; 0.114];
    errs = check(errs, all(diff(lum) > -1e-3), '温度配色亮度应单调递增');

    pass = isempty(errs);
    for k = 1:numel(errs), fprintf('  - %s\n', errs{k}); end
    if pass, st = 'PASS'; else, st = 'FAIL'; end
    fprintf('[visual] 粒子（域内/非固体/风道方向）、开口标注（%d 个，净和 %+.2f CFM）、配色表：%s\n', ...
        numel(M), sum(q), st);
end

function errs = check(errs, cond, msg)
    if ~cond, errs{end+1} = msg; end
end
