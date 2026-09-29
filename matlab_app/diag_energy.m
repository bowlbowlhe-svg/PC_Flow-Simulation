% 能量计账诊断：定位 v2.7 账本幻源/幻汇
s = CFDSolverFEM();
W = s.GRID.W; H = s.GRID.H;
cell_m = s.GRID.cell_size_mm / 1000;
rhoCpCell = s.AIR_DENSITY * s.AIR_CP * cell_m^2 * s.CHASSIS_DEPTH_M;
fluidM = s.obstacle == 0;

E0 = sum(s.T_fluid(fluidM) - 25) * rhoCpCell;
fprintf('初始流体储能 E0 = %.1f J\n', E0);

for blk = 1:8
    % 在 stepMultiple 前无法逐步钩子，改用单步推进循环不可得——
    % 直接推进 50 步，比较储能增量与账本积分
    stepsBlk = 50;
    accOut0 = s.accResetOut; accClamp0 = s.accClamp; accSteps0 = s.accSteps;
    accAdv0 = s.accAdvect; accDiff0 = s.accDiffuse;
    s.stepMultiple(stepsBlk);
    E = sum(s.T_fluid(fluidM) - 25) * rhoCpCell;
    dE = E - E0; E0 = E;
    % 本块实测汇/源积分
    sinkOut = (s.accResetOut - accOut0) * rhoCpCell;       % J（负=失热）
    srcClamp = (s.accClamp - accClamp0) * rhoCpCell;       % J
    srcAdv   = (s.accAdvect - accAdv0) * rhoCpCell;        % J（平流步）
    srcDiff  = (s.accDiffuse - accDiff0) * rhoCpCell;      % J（扩散求解步，精确）
    nSteps = s.accSteps - accSteps0;
    % 高斯注入（全功率）：actual_power × 时间
    Qinj = s.thermalNetworks.cpu.actual_power + s.thermalNetworks.gpu.actual_power + ...
           s.thermalNetworks.psu.actual_power;
    srcGauss = Qinj * s.DT * nSteps;
    % 对照：中位数 α 的 Q_wall 估计（与扩散步精确计账对比）
    c = s.computeConservationCheck();
    ledgerBlk = srcGauss + srcAdv + srcDiff + sinkOut + srcClamp;
    fprintf('%4d步: dE=%+7.1f J | gauss=%+.0f adv=%+.0f diff=%+.0f out=%+.0f clamp=%+.0f | 账本=%+7.1f J | 差=%+7.1f J\n', ...
        blk*stepsBlk, dE, srcGauss, srcAdv, srcDiff, sinkOut, srcClamp, ledgerBlk, dE - ledgerBlk);
    fprintf('   minT(fluid)=%.2f  Tmed(int)=%.1f  Tmean(int)=%.1f  Q_wallEst=%.0fW diff实测=%.0fW\n', ...
        min(s.T_fluid(fluidM)), median(s.T_fluid(s.insideMask)), mean(s.T_fluid(s.insideMask)), ...
        c.Q_wall, srcDiff/(nSteps*s.DT));
end
