function pass = test_cavity(Ra, nSteps, dt)
%TEST_CAVITY 差分加热方腔自然对流基准（de Vahl Davis 1983）。
%   方腔左壁热、右壁冷、上下绝热，层流 Boussinesq。比较热壁平均 Nusselt 数：
%     Ra = 1e4：Nu = 2.243；Ra = 1e5：Nu = 4.519（基准解）。
%   同时检验浮力、动量/热扩散尺度、投影与平流的整体一致性。容差 ±10%。
    if nargin < 1 || isempty(Ra), Ra = 1e5; end
    if nargin < 2 || isempty(nSteps), nSteps = 1500; end
    if nargin < 3 || isempty(dt), dt = 0.02; end
    ref = containers_ref(Ra);
    L = layout_benchmark('cavity', Ra);
    s = CFDSolverFEM(0, 0, 0, L, 1, dt);
    W = s.GRID.W;
    co = s.CASE2D.outer;
    cL = co.x; cR = co.x + co.w - 1;
    rows = (co.y + 1 : co.y + co.h - 2)';
    nC = co.w - 1;                        % 冷热壁中心间距 [格]
    dT = L.benchmark.dT;
    Th = L.chassis.wallTempC.rear; Tc = L.chassis.wallTempC.front;
    nuHist = zeros(1, 0);
    for blk = 1:ceil(nSteps / 100)
        for k = 1:100, s.fluidStep(); end
        Thot  = s.T_fluid(cL*W + rows);           % 热壁右侧第一列流体
        Tcold = s.T_fluid((cR-2)*W + rows);       % 冷壁左侧第一列流体
        NuH = mean(Th - Thot) / dT * nC;
        NuC = mean(Tcold - Tc) / dT * nC;
        nuHist(end+1) = NuH; %#ok<AGROW>
        fprintf('  step %5d  Nu_hot %.3f  Nu_cold %.3f\n', s.iteration, NuH, NuC);
    end
    NuH = nuHist(end);
    drift = abs(nuHist(end) - nuHist(max(1, end-2))) / max(abs(NuH), eps);
    err = (NuH - ref) / ref;
    ok = abs(err) <= 0.10 && abs(NuH - NuC) / NuH < 0.05 && drift < 0.02;
    if ok, st = 'PASS'; else, st = 'FAIL'; end
    fprintf('[cavity] Ra=%.0e：Nu_hot = %.3f（基准 %.3f，偏差 %+.1f%%），冷热壁差 %.1f%%，末段漂移 %.2f%%：%s\n', ...
        Ra, NuH, ref, 100*err, 100*abs(NuH-NuC)/NuH, 100*drift, st);
    pass = ok;
end

function ref = containers_ref(Ra)
    switch Ra
        case 1e3, ref = 1.118;
        case 1e4, ref = 2.243;
        case 1e5, ref = 4.519;
        case 1e6, ref = 8.800;
        otherwise, error('test_cavity:Ra', '无该 Ra 的基准值');
    end
end
