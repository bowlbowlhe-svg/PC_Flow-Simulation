function pass = test_steady()
%TEST_STEADY 预览档（140² 网格、湍流隔步更新）跑到稳态，并与精确档参考值对照。
%   参考值：v3.5.0 默认场景 280² 网格 1600 步（CPU/GPU/电源 67.3/64.1/48.3°C，
%   机箱风量 34 CFM）。要求：runToSteady 判定收敛；结温偏差 ≤ 3°C；风量偏差 ≤ 15%。
%   这是回归护栏：物理或数值改动若使预览档明显偏离精确档，会在这里暴露。
    ref = struct('tj', [67.3 64.1 48.3], 'cfm', 34.2);
    s = CFDSolverFEM(125, 250, 450, 'atx_balanced', 0.5);
    s.turbUpdateEvery = 2;
    t0 = tic;
    info = s.runToSteady();
    el = toc(t0);
    last = info.history(end, :);
    tj = last(1:3); cfm = last(end);
    dTj = tj - ref.tj;
    dQ = (cfm - ref.cfm) / ref.cfm;
    pass = info.converged && all(abs(dTj) <= 3) && abs(dQ) <= 0.15;
    if pass, st = 'PASS'; else, st = 'FAIL'; end
    fprintf(['[steady] 预览档 %d 步收敛=%d（%.0f s）：结温 %.1f/%.1f/%.1f（参考差 %+.1f/%+.1f/%+.1f），' ...
             '风量 %.1f CFM（%+.0f%%）：%s\n'], info.steps, info.converged, el, tj, dTj, cfm, 100*dQ, st);
end
