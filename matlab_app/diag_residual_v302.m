function diag_residual_v302()
%DIAG_RESIDUAL_V302 v3.0.2 判据 B 残余缺口分解诊断（不改任何计账代码）
%   复刻 test_conservation 协议（400 热身 + 400 窗口1 + 400 窗口2），
%   对储能修正+开口扩散入账后的残余缺口做分项定位：
%     1) 开口平面扩散导热 Q_openingDiff（已入账，v3.0.2，与 Q_wall_case
%        同态的 ρcp_cell·gs·α_face·ΔT 口径）——并打印审计诊断原稿的
%        教科书物理通量口径（ρcp·α·ΔT·depth，=1/(cell_m²·gs)≈3.2 倍于
%        入账口径）作对照；
%     2) Q_wall_case 拆分：机箱内表面份额 vs 外表面份额（机箱外热射流格
%        向 25°C 壁的吸热——该部分热量已经 Q_exhaust 计过一次，对机箱级
%        平衡属虚高，审计嫌疑②）；
%     3) 剩余缺口按排除法归属跨薄壁半拉格朗日泄漏等待定位项（审计嫌疑①）。
    s = CFDSolverFEM();
    s.stepMultiple(400);
    s.resetEnergyAccounting();
    s.stepMultiple(400);
    s.resetEnergyAccounting();
    s.stepMultiple(400);
    c = s.computeConservationCheck();

    W = s.GRID.W; H = s.GRID.H;
    cell_m = s.GRID.cell_size_mm/1000;
    gs = (W-2)*(H-2);
    rhoCp  = s.AIR_DENSITY * s.AIR_CP;
    rhoCpCell = rhoCp * cell_m^2 * s.CHASSIS_DEPTH_M;
    alphaMol = s.AIR.nu / s.AIR.Pr;
    if isprop(s,'lastAlphaField') && ~isempty(s.lastAlphaField)
        aFv = s.lastAlphaField(:);
    else
        aFv = ones(s.GRID.TOTAL,1) * c.alphaEff;
    end
    Tmat = reshape(s.T_fluid, W, H);

    fprintf('=== v3.0.2 判据B缺口分解（默认场景，400+400+400 协议）===\n');
    fprintf('Q_injected = %.1f W\n', c.Q_injected);

    % ---- 1) 开口扩散：入账口径（同态）vs 教科书物理口径（审计原稿）----
    fprintf('\n--- 开口平面扩散导热 ---\n');
    fprintf('入账口径（ρcp_cell·gs·α_face·ΔT，与 Q_wall_case 同态）：\n');
    for m = {'top','rear','front','bottom'}
        fprintf('  %-6s %+8.2f W\n', m{1}, c.Q_openingDiffPer.(m{1}));
    end
    fprintf('  合计   %+8.2f W（cons.Q_openingDiff = %+.2f W，一致性校验）\n', ...
        c.Q_openingDiffPer.top + c.Q_openingDiffPer.rear + ...
        c.Q_openingDiffPer.front + c.Q_openingDiffPer.bottom, c.Q_openingDiff);
    qPhysTotal = 0;
    for m = {'top','rear','front','bottom'}
        name = m{1};
        idx = s.openingIdx.(name);
        if isempty(idx), continue; end
        switch name
            case 'top',    outIdx = idx - 1;
            case 'rear',   outIdx = idx - W;
            case 'front',  outIdx = idx + W;
            case 'bottom', outIdx = idx + 1;
        end
        aFace = 0.5*(aFv(idx) + aFv(outIdx));
        qPhysTotal = qPhysTotal + sum(rhoCp .* aFace .* ...
            (s.T_fluid(idx) - s.T_fluid(outIdx)) .* s.CHASSIS_DEPTH_M);
    end
    fprintf('教科书物理口径（ρcp·α·ΔT·depth，审计原稿）：%+.2f W（=%.2f×入账口径；理论因子 1/(cell_m²·gs)=%.3f）\n', ...
        qPhysTotal, qPhysTotal/max(c.Q_openingDiff,eps), 1/(cell_m^2*gs));

    % ---- 2) Q_wall_case 内/外表面拆分 ----
    fprintf('\n--- Q_wall_case 内/外表面拆分 ---\n');
    kFaceCell = rhoCpCell * gs * 0.5*(aFv + alphaMol);
    fluidM = reshape(s.obstacle == 0, W, H);
    caseM  = reshape(s.obstacle == s.OBSTACLE.WALL, W, H);
    faceCount = [zeros(1,H); caseM(1:W-1,:)] + [caseM(2:W,:); zeros(1,H)] + ...
                [zeros(W,1) caseM(:,1:H-1)] + [caseM(:,2:H) zeros(W,1)];
    dTpos = max(0, Tmat - 25) .* fluidM;
    qCell = (dTpos(:) .* faceCount(:)) .* kFaceCell;
    innerM = false(W,H); innerM(s.insideMask) = true;
    QwInner = sum(qCell(innerM(:)));
    QwOuter = sum(qCell(~innerM(:)));
    fprintf('  内表面份额（insideMask 流体格）  %+8.2f W\n', QwInner);
    fprintf('  外表面份额（机箱外射流格，嫌疑②）%+8.2f W（占 Q_wall_case=%.1fW 的 %.0f%%）\n', ...
        QwOuter, c.Q_wall_case, 100*QwOuter/max(c.Q_wall_case,eps));
    fprintf('  拆分合计 %+8.2f W（应=Q_wall_case %+8.2f W，一致性校验）\n', ...
        QwInner+QwOuter, c.Q_wall_case);

    % ---- 3) 缺口归属 ----
    fprintf('\n--- 缺口归属（储能修正+开口扩散入账后）---\n');
    fprintf('  raw residualPct = %+.1f%%\n', c.residualPct);
    fprintf('  storageRateCaseW = %+.1f W\n', c.storageRateCaseW);
    fprintf('  residualCorrW = %+.1f W（%+.1f%%）= 残余缺口\n', c.residualCorrW, c.residualCorrPct);
    fprintf('  外表面虚高使残差上偏 %+.1f W；扣除后残余 ~%+.1f W 归属跨薄壁\n', ...
        QwOuter, c.residualCorrW - QwOuter);
    fprintf('  半拉格朗日泄漏等待定位项（审计嫌疑①，按排除法）。\n');
    % ---- 4) 跨薄壁半拉格朗日泄漏：排除法定量 + 直接测量（符号佐证）----
    % 机制：advect 把障碍格值替换为最近流体格（nearestFluidIdx）——1 格薄壁
    % 壁格的最近流体可能在机箱另一侧，壁内侧流体格回溯落入壁格时插值到
    % 外侧空气，热量不经开口/壁面扩散计账直接穿壁。
    % 定量以排除法为准（residualCorrW − Q_wall外表面虚高）：残差预算已全分解。
    % 直接测量（复制温度平流步，内区能量增量 + 开口 donor 通量）只能作符号
    % 佐证：开口处半拉格朗日非守恒性与 donor 近似的口径差达数百 W 级，
    % 淹没泄漏信号，无法以此精确分离泄漏分量。
    fprintf('\n--- 跨薄壁半拉格朗日泄漏 ---\n');
    fprintf('  排除法定量 = %+.1f W（正=净流入机箱；residualCorrW − Q_wall外表面）\n', ...
        c.residualCorrW - QwOuter);
    K = 20; leakAcc = 0;
    inM = false(W,H); inM(s.insideMask) = true;
    dt0 = s.DT * (W-2);
    [Igrid, Jgrid] = meshgrid(1:W, 1:H);
    Xq0 = Jgrid'; Yq0 = Igrid';
    obsM = reshape(s.obstacle > 0, W, H);
    for k = 1:K
        Told = reshape(s.T_fluid, W, H);
        [uCg, vCg] = s.getCellVelocity();
        Xq = Xq0 - dt0 * reshape(uCg, W, H);
        Yq = Yq0 - dt0 * reshape(vCg, W, H);
        outDom = (Xq<1.5) | (Xq>W-0.5) | (Yq<1.5) | (Yq>H-0.5);
        Xq = max(1.5, min(W-0.5, Xq)); Yq = max(1.5, min(H-0.5, Yq));
        d0mat = Told; d0mat(obsM) = d0mat(s.nearestFluidIdx(obsM));
        s.gridInterpT.Values = d0mat;
        warning('off', 'MATLAB:griddedInterpolant:MeshgridEval2DWarnId');
        Tnew = s.gridInterpT(Yq, Xq);
        warning('on', 'MATLAB:griddedInterpolant:MeshgridEval2DWarnId');
        Tnew(outDom) = 25;
        dEin = sum(Tnew(inM) - Told(inM));      % K·cell（平流步内区能量增量）
        openFlux = 0;                            % 开口 donor 出箱通量 [K·cell/step]
        for m = {'top','rear','front','bottom'}
            name = m{1}; idx = s.openingIdx.(name);
            if isempty(idx), continue; end
            yy = mod(idx-1, W)+1; xx = ceil(idx/W);
            switch name
                case 'top',    fLin = (xx-1)*(W+1)+yy;     sgn = -1; isV = true;  outIdx = idx - 1;
                case 'rear',   fLin = (xx-1)*W+yy;         sgn = -1; isV = false; outIdx = idx - W;
                case 'front',  fLin = xx*W+yy;             sgn = +1; isV = false; outIdx = idx + W;
                case 'bottom', fLin = (xx-1)*(W+1)+yy + 1; sgn = +1; isV = true;  outIdx = idx + 1;
            end
            if isV, vn = sgn * s.vF(fLin); else, vn = sgn * s.uF(fLin); end
            vnStep = vn * s.VEL_SCALE * s.DT / cell_m;     % cells/step
            Tup = Told(idx); inFlow = vn < 0;
            Tup(inFlow) = Told(outIdx(inFlow));
            openFlux = openFlux + sum(vnStep .* Tup);
        end
        leakAcc = leakAcc + (dEin + openFlux);   % 泄漏（流入内区为正）
        s.stepMultiple(1);
    end
    leakW = rhoCpCell * (leakAcc/K) / s.DT;      % W
    fprintf('  直接测量（内区平流增益+开口donor口径差混合信号）= %+.1f W（%d 步平均）\n', leakW, K);
    fprintf('  注：混合信号含开口 SL/donor 口径差（数百 W 级主项）+ 真实跨壁泄漏；\n');
    fprintf('  符号与排除法一致（净流入）即佐证机制存在，定量以排除法为准。\n');

    % ---- 5) 钳位分项（v3.0.2）----
    fprintf('\n--- 钳位分项（Q_R_clamp = %+.1f W，应≈0）---\n', c.Q_R_clamp);
    fprintf('  扩散求解后 max25   %+7.2f W\n', c.Q_R_clampSolve);
    fprintf('  温度平流后 max25   %+7.2f W\n', c.Q_R_clampAdvect);
    fprintf('  共轭传热后 min200  %+7.2f W（削顶=汇）\n', c.Q_R_clampCap);
    fprintf('  共轭传热后 max25   %+7.2f W（抬底=源）\n', c.Q_R_clampFloor);

    fprintf('\n对照：farFieldHeatW = %+.1f W，Q_exhaust = %+.1f W，closurePct(A) = %+.1f%%\n', ...
        c.farFieldHeatW, c.Q_exhaust, c.closurePct);
    fprintf('Tj: cpu=%.1f gpu=%.1f psu=%.1f C\n', ...
        s.thermalNetworks.cpu.T_junction, s.thermalNetworks.gpu.T_junction, ...
        s.thermalNetworks.psu.T_junction);
end
