function pass = test_fan_duct(zetaPlug, nSteps)
%TEST_FAN_DUCT 风扇-风道工作点基准。
%   120 mm 高直风道：前壁进气 P12 满速（格栅 ζ=2），中部多孔塞（ζ_plug），
%   后壁通风口（ζ=1），出口动能损失 ζ=1。系统曲线 Δp = K·½ρv²，
%   K = ζ_plug + 2 + 1 + 1。稳态流量应落在风扇 P-Q 曲线与系统曲线交点。
%   仿真流量取推进结束时（投影后）流场穿过风扇盘中面的流量（diskFlow）。
%   注意 Fan.lastQ 是本步施加风扇力之前的中间流场上测得的（工作点由它确定），约低 4%。
%   容差 ±5%。
    if nargin < 1 || isempty(zetaPlug), zetaPlug = 20; end
    if nargin < 2 || isempty(nSteps), nSteps = 600; end
    L = layout_benchmark('duct', zetaPlug);
    s = CFDSolverFEM(0, 0, 0, L, 1, 0.005);
    fan = s.fans{1};
    for blk = 1:ceil(nSteps / 100)
        for k = 1:100, s.fluidStep(); end
        fprintf('  step %4d  Q = %.2f CFM  Δp_fan = %.2f Pa\n', s.iteration, fan.lastQ / s.CFM_TO_M3S, fan.lastDp);
    end
    % 解析工作点
    b = L.benchmark;
    K = b.zetaPlug + b.zetaIn + b.zetaOut + 1;
    rho = s.AIR_DENSITY;
    qMax = fan.cfm_max * s.CFM_TO_M3S;           % 满速
    fanDp = @(q) fan.pmax_pa * interp1(fan.PQ_QGRID, fan.pq_curve, min(max(q,0),1), 'pchip');
    sysDp = @(q) K * 0.5 * rho * (q * qMax / b.areaM2).^2;
    lo = 0; hi = 1;
    for it = 1:60
        mid = 0.5*(lo+hi);
        if fanDp(mid) > sysDp(mid), lo = mid; else, hi = mid; end
    end
    qExp = 0.5*(lo+hi) * qMax;
    qSim = s.diskFlow(fan);
    err = (qSim - qExp) / qExp;
    pass = abs(err) <= 0.05;
    if pass, st = 'PASS'; else, st = 'FAIL'; end
    fprintf('[fan duct] ζ_plug=%g：仿真 %.2f CFM，解析 %.2f CFM（K=%.1f，Δp=%.2f Pa），偏差 %+.1f%%：%s\n', ...
        zetaPlug, qSim / s.CFM_TO_M3S, qExp / s.CFM_TO_M3S, K, fanDp(qExp/qMax), 100*err, st);
end
