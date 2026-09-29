function test_turbulence(nSteps)
%TEST_TURBULENCE v2.10 k-ω 两方程湍流模型专项测试
%   四项判据：
%   1) 正性/有界：k、ω 全程无 NaN/负值；k ≥ nuTFloor，ω 在 [1e-6, 1e8] 保险区间内
%   2) 湍流强度量级：射流/剪切区 ν_t/ν 达 O(10^2)（LVEL 被 30× cap 锁死，
%      这是两方程模型的核心升级证据）；同时要求中位数不超 2000× 保险帽
%   3) 与 LVEL 对照：同场景同步数，报告 Tint_cfd、Tj、ν_t 中位数差异；
%      v3.0 起判据 = k-ω 剪切区 ν_t（p95）超过 LVEL 的 30× 混合长帽
%     （干净 MAC 场下体域中位数回近分子级是真实响应，非模型失效）
%   4) 回退一致性：turbulenceModel='lvel' 时 ν_eff 中位数 = 30×ν（v2.9 口径）
%
%   用法： test_turbulence        % 默认 400 步
%         test_turbulence(200)
    if nargin < 1, nSteps = 400; end
    fprintf('=== k-ω 湍流模型测试（默认场景 125/250/450W，%d 步）===\n', nSteps);

    nFail = 0;

    % ---------- k-ω 路径 ----------
    s = CFDSolverFEM(125,250,450,'atx_balanced',1,0.005);
    s.stepMultiple(nSteps);

    k = s.turbK; w = s.turbOmega;
    fluidIdx = find(s.obstacle == 0);
    nu = s.computeNuEff();
    nuTratio = (nu - s.AIR.nu) / s.AIR.nu;

    % 判据 1：正性/有界
    okPos = all(isfinite(k)) && all(isfinite(w)) && ...
            min(k) >= s.nuTFloor && min(w) >= 1e-6 && max(w) <= 1e8;
    if okPos
        fprintf('[1] 正性/有界：k∈[%.1e, %.2e]，ω∈[%.1e, %.2e]，无 NaN：PASS\n', ...
            min(k), max(k), min(w), max(w));
    else
        fprintf('[1] 正性/有界：k∈[%.1e, %.2e]，ω∈[%.1e, %.2e]：FAIL\n', ...
            min(k), max(k), min(w), max(w));
        nFail = nFail + 1;
    end

    % 判据 2：射流区 ν_t/ν 达 O(10^2)，且全场中位数不超保险帽
    p95 = prctile(nuTratio(fluidIdx), 95);
    med = median(nuTratio(fluidIdx));
    if p95 >= 100 && med <= 2000
        fprintf('[2] ν_t/ν：中位数 %.0f，p95 %.0f（≥100 达 O(10^2)）：PASS\n', med, p95);
    else
        fprintf('[2] ν_t/ν：中位数 %.0f，p95 %.0f：FAIL（p95<100 或中位数超帽）\n', med, p95);
        nFail = nFail + 1;
    end

    % 判据 3：与 LVEL 对照（同场景同步数）
    sL = CFDSolverFEM(125,250,450,'atx_balanced',1,0.005);
    sL.turbulenceModel = 'lvel';
    sL.stepMultiple(nSteps);
    inFluid = intersect(s.insideMask, fluidIdx);
    tintK = mean(s.T_fluid(inFluid));
    tintL = mean(sL.T_fluid(inFluid));
    nuL = sL.computeNuEff();
    medL = median(nuL(fluidIdx)) / s.AIR.nu;
    fprintf('[3] 对照：Tint_cfd  k-ω=%.1f°C vs LVEL=%.1f°C（%+.1f）\n', ...
        tintK, tintL, tintK - tintL);
    fprintf('    Tj k-ω = %.1f/%.1f/%.1f，LVEL = %.1f/%.1f/%.1f\n', ...
        s.thermalNetworks.cpu.T_junction, s.thermalNetworks.gpu.T_junction, s.thermalNetworks.psu.T_junction, ...
        sL.thermalNetworks.cpu.T_junction, sL.thermalNetworks.gpu.T_junction, sL.thermalNetworks.psu.T_junction);
    fprintf('    ν_eff 中位数/ν：k-ω=%.0f vs LVEL=%.0f\n', med + 1, medL);
    % v3.0 判据重建：交错网格消除并置错配的网格级应变噪声后，k-ω 生产
    % 集中于物理剪切区（射流核/近壁），体域中位数回到近分子级是干净场
    % 的真实响应——v2.10 的中位数 ~250× 实为错配噪声喂给生产项的虚高。
    % 两方程模型的核心升级证据改为：剪切区 ν_t（p95）超过 LVEL 的 30× 混合
    % 长帽——LVEL 对全场一刀切 cap，k-ω 能在该 cap 之上局部产生湍流。
    if p95 > medL
        fprintf('    k-ω 剪切区 ν_t（p95=%.0f）超过 LVEL 混合长帽（%.0f×）：PASS\n', p95, medL);
    else
        fprintf('    k-ω 剪切区 ν_t 未超过 LVEL cap（模型未生效？）：FAIL\n');
        nFail = nFail + 1;
    end

    % 判据 4：LVEL 回退路径 = v2.9 口径（ν_eff 中位数恒 30×ν）
    if abs(medL - 30) < 0.5
        fprintf('[4] LVEL 回退一致性：ν_eff 中位数 = %.1f×ν（v2.9 口径 30×）：PASS\n', medL);
    else
        fprintf('[4] LVEL 回退一致性：ν_eff 中位数 = %.1f×ν（应 30×）：FAIL\n', medL);
        nFail = nFail + 1;
    end

    if nFail == 0
        fprintf('\n=== 湍流模型测试全部通过（%d 步）===\n', nSteps);
    else
        fprintf('\n=== 湍流模型测试 %d 项失败 ===\n', nFail);
    end
end
