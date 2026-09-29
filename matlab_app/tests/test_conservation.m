function pass = test_conservation(steadyStateSteps)
%TEST_CONSERVATION 能量/质量守恒回归测试（默认场景 125/250/450W）。
%   热身 N 步 → 计量窗口 1（N 步）→ 计量窗口 2（N 步）。
%   判据 A（全域逐步计账）：|closure| ≤ 5%。
%   判据 B（已达稳态）：窗口 2 储能速率 |·| ≤ 2% 注入功率，且两窗口末的结温差 ≤ 0.5°C、
%          机箱风量相对差 ≤ 3%。v4.2 前冻结算子按中位数重装，280² 下 850 步前后有一次假的状态
%          跳变（窗口 2 储能 +2.7%、CPU +1.7°C），旧判据放宽后把它掩盖了；现在按系数场重装，
%          600 步内即稳定。
%   判据 B2（机箱内区算子级平衡）：|balanceOpPct| ≤ 5%，捕获改温算子漏计账。
%   判据 C（双轨合理性带宽）：Tint_alg − 15 ≤ Tint_cfd ≤ Tint_alg + 45 [°C]，
%          捕获符号错误/失控类回归。
%   其余为报告项（开口焓流、壁面导热、开口风量、远场环通量等）。
%
%   用法： pass = test_conservation        % 默认 400 步/窗口（共 1200 步）
%          pass = test_conservation(800)

    if nargin < 1, steadyStateSteps = 400; end

    fprintf('=== 守恒回归测试（默认场景，热身 %d 步 + 计量窗口 2×%d 步）===\n', ...
        steadyStateSteps, steadyStateSteps);
    s = CFDSolverFEM();
    t0 = tic;
    s.stepMultiple(steadyStateSteps);   % 热身
    s.resetEnergyAccounting();
    s.stepMultiple(steadyStateSteps);   % 计量窗口 1
    c1 = s.computeConservationCheck();
    snap1 = stateSnap(s);
    s.resetEnergyAccounting();
    s.stepMultiple(steadyStateSteps);   % 计量窗口 2
    fprintf('推进完成（%.1fs）\n', toc(t0));

    c = s.computeConservationCheck();
    t = s.lastTemps;
    snap2 = stateSnap(s);

    fprintf('\n--- 判据 A：全域逐步计账 ---\n');
    fprintf('高斯注入 Q_gaussian       = %+7.1f W\n', c.Q_gaussian);
    fprintf('平流步 Q_R_advect         = %+7.1f W\n', c.Q_R_advect);
    fprintf('扩散求解步 Q_R_diffuse    = %+7.1f W\n', c.Q_R_diffuse);
    fprintf('远场海绵环重置 Q_R_out    = %+7.1f W\n', c.Q_R_out);
    fprintf('温度钳位 Q_R_clamp        = %+7.1f W（扩散后 %+.1f / 平流后 %+.1f / 削顶 %+.1f / 抬底 %+.1f）\n', ...
        c.Q_R_clamp, c.Q_R_clampSolve, c.Q_R_clampAdvect, c.Q_R_clampCap, c.Q_R_clampFloor);
    fprintf('账本残差 = %+7.1f W（%+.1f%%），窗口储能速率 = %+7.1f W\n', c.ledgerW, c.ledgerPct, c.storageRateW);
    fprintf('闭合残差 = %+7.1f W（%+.1f%%，应≈0）\n', c.closureW, c.closurePct);

    fprintf('\n--- 判据 B：已达稳态 ---\n');
    fprintf('窗口1 储能速率 = %+.1f W（%+.1f%%），窗口2 = %+.1f W（%+.1f%%）\n', ...
        c1.storageRateW, 100*c1.storageRateW/max(c1.Q_injected,eps), ...
        c.storageRateW, 100*c.storageRateW/max(c.Q_injected,eps));
    dTj = max(abs(snap2.tj - snap1.tj));
    dQ = abs(snap2.cfm - snap1.cfm) / max(snap1.cfm, 1);
    fprintf('两窗口末：结温 %s → %s °C（最大差 %.2f），风量 %.1f → %.1f CFM（%+.1f%%）\n', ...
        sprintf('%.2f ', snap1.tj), sprintf('%.2f ', snap2.tj), dTj, snap1.cfm, snap2.cfm, 100*dQ);

    fprintf('\n--- 判据 C：双轨温度 ---\n');
    fprintf('代数热平衡内温 = %.1f°C，CFD 内部均温 = %.1f°C，偏差 %+.1f°C\n', ...
        t.internalAmbientAlg, t.internalAmbientCFD, t.internalDiscrepancy);

    fprintf('\n--- 报告项 ---\n');
    fprintf('开口焓流 Q_exhaust = %.0f W，定温壁导热 Q_wall = %.1f W，开口平面扩散 = %+.1f W\n', ...
        c.Q_exhaust, c.Q_wall, c.Q_openingDiff);
    for m = {'top','rear','front','bottom'}
        f = c.flux.(m{1});
        fprintf('%-6s net %+7.1f CFM（出 %.0f / 入 %.0f），Tmean %.1f°C\n', ...
            m{1}, f.cfm, f.cfmOut, f.cfmIn, f.Tmean);
    end
    fprintf('开口净不平衡 = %+.1f%%，全域质量账 = %+.1f%%\n', c.massImbalancePct, c.domainMassPct);
    fprintf('远场环净通量 = %+.1f CFM（毛 %.0f），远场焓流 %+.0f W\n', ...
        c.farFieldCfm, c.farFieldGrossCfm, c.farFieldHeatW);
    fprintf('采样口径机箱平衡：储能速率 %+7.1f W，残差 %+7.1f W（%+.1f%%）\n', ...
        c.storageRateCaseW, c.residualCorrW, c.residualCorrPct);
    fprintf('内区算子账：注入 %+7.1f（名义 %+.1f）+ 平流 %+7.1f + 扩散 %+7.1f + 钳位 %+7.1f − 储能 %+7.1f = %+7.2f W（%+.2f%%）\n', ...
        c.Q_injectCase, c.Q_gaussian, c.Q_advectCase, c.Q_diffuseCase, c.Q_clampCase, ...
        c.storageRateCaseW, c.balanceOpW, c.balanceOpPct);
    fprintf('结温 CPU/GPU/PSU = %.1f / %.1f / %.1f °C\n', s.thermalNetworks.cpu.T_junction, ...
        s.thermalNetworks.gpu.T_junction, s.thermalNetworks.psu.T_junction);

    fprintf('\n--- 判定 ---\n');
    pass = true;
    okA = abs(c.closurePct) <= 5;
    fprintf('A 全域闭合 %+.1f%%（≤5%%）：%s\n', c.closurePct, passStr(okA));
    rate2Pct = 100*c.storageRateW/max(c.Q_injected,eps);
    okB = abs(rate2Pct) <= 2 && dTj <= 0.5 && dQ <= 0.03;
    fprintf('B 已达稳态 窗口2 储能 %+.1f%%（±2%%）、结温漂移 %.2f°C（≤0.5）、风量漂移 %.1f%%（≤3%%）：%s\n', ...
        rate2Pct, dTj, 100*dQ, passStr(okB));
    okB2 = abs(c.balanceOpPct) <= 5;
    fprintf('B2 内区算子平衡 %+.2f%%（±5%%）：%s\n', c.balanceOpPct, passStr(okB2));
    okC = t.internalDiscrepancy >= -15 && t.internalDiscrepancy <= 45;
    fprintf('C 双轨偏差 %+.1f°C（[−15, +45]）：%s\n', t.internalDiscrepancy, passStr(okC));
    pass = okA && okB && okB2 && okC;
    fprintf('=== 守恒测试 %s ===\n', passStr(pass));
end

function st = stateSnap(s)
    nm = fieldnames(s.thermalNetworks);
    st.tj = cellfun(@(n) s.thermalNetworks.(n).T_junction, nm)';
    t = s.computeAirflowTemperatures();
    st.cfm = t.totalCFM;
end

function s = passStr(ok)
    if ok, s = 'PASS'; else, s = 'FAIL'; end
end
