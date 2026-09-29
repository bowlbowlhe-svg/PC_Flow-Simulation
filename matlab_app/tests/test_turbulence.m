function pass = test_turbulence(nSteps)
%TEST_TURBULENCE k-ω 湍流模型测试（默认场景）。
%   1) 正性/有界：k、ω 无 NaN/负值，k ≥ nuTFloor，ω ∈ [1e-6, 1e8]
%   2) 量级：剪切区 ν_t/ν 的 p95 ≥ 100，全场中位数不超 2000× 保险帽
%   3) 与 LVEL 对照：k-ω 剪切区 ν_t（p95）超过 LVEL 的 30× 上限
%   4) 回退一致性：turbulenceModel='lvel' 时 ν_eff 中位数 = 30×ν
%
%   用法： pass = test_turbulence        % 默认 400 步
%          pass = test_turbulence(200)
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
    srt = sort(nuTratio(fluidIdx));
    p95 = srt(max(1, round(0.95 * numel(srt))));   % 95 分位（不依赖统计工具箱）
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
    if p95 > medL
        fprintf('    k-ω 剪切区 ν_t（p95=%.0f）超过 LVEL 混合长帽（%.0f×）：PASS\n', p95, medL);
    else
        fprintf('    k-ω 剪切区 ν_t 未超过 LVEL cap（模型未生效？）：FAIL\n');
        nFail = nFail + 1;
    end

    % 判据 4：LVEL 回退路径 ν_eff 中位数恒为 30×ν
    if abs(medL - 30) < 0.5
        fprintf('[4] LVEL 回退一致性：ν_eff 中位数 = %.1f×ν：PASS\n', medL);
    else
        fprintf('[4] LVEL 回退一致性：ν_eff 中位数 = %.1f×ν（应 30×）：FAIL\n', medL);
        nFail = nFail + 1;
    end

    pass = nFail == 0;
    if pass
        fprintf('=== 湍流模型测试全部通过（%d 步）===\n', nSteps);
    else
        fprintf('=== 湍流模型测试 %d 项失败 ===\n', nFail);
    end
end
