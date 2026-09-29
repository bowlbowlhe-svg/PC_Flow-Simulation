function pass = test_visual()
%TEST_VISUAL 可视化数据：粒子示踪、开口标注、配色表。
%   1) 粒子示踪：默认场景推进后撒点、走 100 帧，粒子不进入固体、全部在域内、
%      不堆积在域边（距域边 3 格内 < 5%）、多数在机箱内（> 60%）；
%      直风道基准里粒子整体沿风道方向（前 → 后，x 减小）移动。
%   1b) 涡量符号约定：屏幕上逆时针的刚体旋转，求解器 ω < 0（主视图显示 −ω，红 = 逆时针）。
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
    nearEdge = mean(x < 4 | x > s.GRID.H - 3 | y < 4 | y > s.GRID.W - 3);
    co0 = s.CASE2D.outer;
    inCase = mean(x >= co0.x & x <= co0.x + co0.w - 1 & y >= co0.y & y <= co0.y + co0.h - 1);
    errs = check(errs, nearEdge < 0.05, sprintf('粒子不应堆积在域边（距域边 3 格内 %.1f%%）', 100*nearEdge));
    errs = check(errs, inCase > 0.6, sprintf('多数粒子应在机箱内（%.1f%%）', 100*inCase));

    % 1b) 涡量符号：屏幕逆时针旋转 u = c(y − yc)、v = −c(x − xc)（y 向下）→ ω = −2c
    e = CFDSolverFEM(0, 0, 0, layout_benchmark('empty'), 0.5);
    We = e.GRID.W; He = e.GRID.H; c = 0.01;
    [Yu, Xu] = ndgrid(1:We, 0.5:He+0.5);  e.uF = reshape(c * (Yu - (We+1)/2), [], 1);
    [Yv, Xv] = ndgrid(0.5:We+0.5, 1:He);  e.vF = reshape(-c * (Xv - (He+1)/2), [], 1);
    w = reshape(e.computeVorticity(), We, He);
    errs = check(errs, w(round(We/2), round(He/2)) < 0, '屏幕逆时针旋转时求解器涡量应为负');

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
    fprintf('[visual] 粒子（域边 %.1f%%、机箱内 %.0f%%、风道方向）、涡量符号、开口标注（%d 个，净和 %+.2f CFM）、配色表：%s\n', ...
        100*nearEdge, 100*inCase, numel(M), sum(q), st);
end

function errs = check(errs, cond, msg)
    if ~cond, errs{end+1} = msg; end
end
