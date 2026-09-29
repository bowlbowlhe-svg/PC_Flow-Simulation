function pass = test_pressure()
%TEST_PRESSURE 压力视图的物理口径（pressureFieldPa）。
%   1) 直风道（精确网格 280²）：多孔塞（ζ = 20）前后的压降 vs ζ·½ρv²，v 取塞中面的实际
%      过流量 / 截面积，偏差 ≤ 8%（预览网格偏高较多，不用于此项）。
%   2) 正压预设（3 进 1 出）机箱内平均静压 > 0，负压预设（1 进 3 出）< 0。
    errs = {};
    L = layout_benchmark('duct', 20);
    s = CFDSolverFEM(0, 0, 0, L, 1, 0.005);
    s.stepMultiple(400);
    W = s.GRID.W; c = s.GRID.cell_size_mm;
    P = reshape(s.pressureFieldPa(), W, W);
    ox = s.caseOffsetX; oy = s.caseOffsetY;
    rows = oy + round(160/c) : oy + round(240/c);
    up = ox + round(210/c); dn = ox + round(170/c);       % 气流由前（x 大）向后
    dP = mean(P(rows, up)) - mean(P(rows, dn));
    xm = ox + round(190/c);                              % 塞中面（u 面列）的实际过流量
    uPlug = s.uF((xm - 1) * W + rows) * s.VEL_SCALE;
    v = abs(mean(uPlug));
    expect = L.benchmark.zetaPlug * 0.5 * s.AIR.rho * v^2;
    err = (dP - expect) / expect;
    errs = check(errs, abs(err) <= 0.08, sprintf('塞前后压降 %.2f Pa，ζ·½ρv² = %.2f Pa，偏差 %+.0f%%', dP, expect, 100*err));

    pin = zeros(1, 2); names = {'positive', 'negative'};
    for k = 1:2
        sk = CFDSolverFEM([], [], [], layout_apply_preset(layout_default(), names{k}), 0.5);
        sk.turbUpdateEvery = 2;
        sk.stepMultiple(400);
        Pk = sk.pressureFieldPa();
        v = Pk(sk.insideMask);
        pin(k) = mean(v(isfinite(v)));
    end
    errs = check(errs, pin(1) > 0 && pin(2) < 0, sprintf('正压/负压预设机箱内平均静压 %+.2f / %+.2f Pa', pin));

    pass = isempty(errs);
    for k = 1:numel(errs), fprintf('  - %s\n', errs{k}); end
    if pass, st = 'PASS'; else, st = 'FAIL'; end
    fprintf('[pressure] 塞压降 %.2f Pa（ζ·½ρv² %.2f，%+.0f%%）；正压/负压预设机箱内 %+.2f / %+.2f Pa：%s\n', ...
        dP, expect, 100*err, pin, st);
end

function errs = check(errs, cond, msg)
    if ~cond, errs{end+1} = msg; end
end
