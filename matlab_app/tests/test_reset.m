function pass = test_reset(steps, gridScale, tol)
%TEST_RESET reset() 后与新建求解器一致。
%   路径 A：新建 → 推进 → 开计账窗口 → 推进 → 改功率 → reset → 推进 steps 步
%   路径 B：用改后的功率新建 → 推进 steps 步
%   比较全部场、结温、噪音（总量与各扇）与守恒校核量。tol 为相对容差（默认 1e-12；传 0 要求逐位一致）。
    if nargin < 1 || isempty(steps), steps = 20; end
    if nargin < 2 || isempty(gridScale), gridScale = 0.5; end
    if nargin < 3 || isempty(tol), tol = 1e-12; end

    a = CFDSolverFEM(125, 250, 450, 'atx_balanced', gridScale);
    a.stepMultiple(steps);
    a.resetEnergyAccounting();
    a.stepMultiple(steps);
    a.setComponentPower('cpu', 100);
    a.setComponentPower('gpu', 200);
    a.setComponentPower('psu', 500);
    a.reset();
    a.stepMultiple(steps);

    b = CFDSolverFEM(100, 200, 500, 'atx_balanced', gridScale);
    b.stepMultiple(steps);

    ca = a.computeConservationCheck(); cb = b.computeConservationCheck();
    pairs = {'T_fluid', a.T_fluid, b.T_fluid; 'T_solid', a.T_solid, b.T_solid; ...
             'uF', a.uF, b.uF; 'vF', a.vF, b.vF; 'p', a.p, b.p; ...
             'turbK', a.turbK, b.turbK; 'turbOmega', a.turbOmega, b.turbOmega; ...
             'Tj', tjOf(a), tjOf(b); ...
             'noise', noiseOf(a), noiseOf(b); ...
             'closurePct', ca.closurePct, cb.closurePct; 'balanceOpPct', ca.balanceOpPct, cb.balanceOpPct};
    pass = true;
    worst = 0;
    for k = 1:size(pairs, 1)
        x = pairs{k,2}(:); y = pairs{k,3}(:);
        d = max(abs(x - y)) / max(1, max(abs(y)));
        worst = max(worst, d);
        if d > tol
            fprintf('[reset] %s 相对差 %.3g > %.1g：FAIL\n', pairs{k,1}, d, tol);
            pass = false;
        end
    end
    if pass
        fprintf('[reset] reset 后 %d 步与新建求解器一致（最大相对差 %.3g）：PASS\n', steps, worst);
    end
end

function n = noiseOf(s)
    [db, per] = s.totalNoise();
    n = [db, per];
end

function tj = tjOf(s)
    tn = s.thermalNetworks;
    tj = [tn.cpu.T_junction tn.gpu.T_junction tn.psu.T_junction];
end
