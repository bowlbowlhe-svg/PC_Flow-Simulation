function pass = test_turbulence(nSteps)
%TEST_TURBULENCE k-ω 湍流模型测试。
%   默认布局（125/250/450 W）：
%   1) 正性/有界：k、ω 无 NaN/负值，k ≥ nuTFloor，ω ∈ [1e-6, 1e8]
%   2) 剪切区 ν_t/ν 的 p99 超过 LVEL 的 30× 上限（模型生效）
%   3) 与 LVEL 对照（打印内温与结温）；回退一致性：turbulenceModel='lvel' 时 ν_eff 中位数 = 30×ν
%   v4.8.0 的默认几何（全宽电源仓挡板 + 38 mm 开孔：前下进风扇经开孔形成受限射流；显卡挡板端可过风）：
%   4) 量级：ν_t/ν 的 p95 ≥ 100（射流区达 O(10^2)），全场中位数不超 2000× 保险帽
%   v4.9.0 起默认电源仓挡板只盖住电源、前方敞开，没有这股窄缝射流，高 ν_t 区不到全场 5%（p95 约 22、p99 约 46），
%   所以量级判据改在固定的旧几何上做（与默认布局的改动无关）。
%
%   用法： pass = test_turbulence        % 默认 400 步
%          pass = test_turbulence(200)
    if nargin < 1, nSteps = 400; end
    fprintf('=== k-ω 湍流模型测试（125/250/450W，%d 步）===\n', nSteps);

    nFail = 0;

    % ---------- 默认布局：k-ω ----------
    s = CFDSolverFEM(125,250,450,'atx_balanced',1,0.005);
    s.stepMultiple(nSteps);
    [r, k, w, fluidIdx] = nuTRatio(s);

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

    % ---------- 默认布局：LVEL 对照与回退 ----------
    sL = CFDSolverFEM(125,250,450,'atx_balanced',1,0.005);
    sL.turbulenceModel = 'lvel';
    sL.stepMultiple(nSteps);
    nuL = sL.computeNuEff();
    medL = median(nuL(fluidIdx)) / s.AIR.nu;

    % 判据 2：剪切区 ν_t 超过 LVEL 混合长帽
    p99 = pct(r, 0.99);
    if p99 > medL
        fprintf('[2] 默认布局 ν_t/ν：中位数 %.0f、p95 %.0f、p99 %.0f，p99 超过 LVEL 混合长帽（%.0f×）：PASS\n', ...
            median(r), pct(r, 0.95), p99, medL);
    else
        fprintf('[2] 默认布局 ν_t/ν：p99 %.0f 未超过 LVEL 混合长帽（%.0f×，模型未生效？）：FAIL\n', p99, medL);
        nFail = nFail + 1;
    end

    % 判据 3：对照与回退一致性
    inFluid = intersect(s.insideMask, fluidIdx);
    fprintf('[3] 对照：Tint_cfd  k-ω=%.1f°C vs LVEL=%.1f°C（%+.1f）\n', ...
        mean(s.T_fluid(inFluid)), mean(sL.T_fluid(inFluid)), mean(s.T_fluid(inFluid)) - mean(sL.T_fluid(inFluid)));
    fprintf('    Tj k-ω = %.1f/%.1f/%.1f，LVEL = %.1f/%.1f/%.1f\n', ...
        s.thermalNetworks.cpu.T_junction, s.thermalNetworks.gpu.T_junction, s.thermalNetworks.psu.T_junction, ...
        sL.thermalNetworks.cpu.T_junction, sL.thermalNetworks.gpu.T_junction, sL.thermalNetworks.psu.T_junction);
    if abs(medL - 30) < 0.5
        fprintf('    LVEL 回退一致性：ν_eff 中位数 = %.1f×ν：PASS\n', medL);
    else
        fprintf('    LVEL 回退一致性：ν_eff 中位数 = %.1f×ν（应 30×）：FAIL\n', medL);
        nFail = nFail + 1;
    end

    % ---------- v4.8.0 的默认几何：射流区量级 ----------
    L48 = layout_set_gpu_slots(layout_default(), 4);
    L48.gpu = rmfield(L48.gpu, 'ioBlock');
    L48.gpu.pcb = struct('x', 38, 'y', 212, 'w', 216, 'h', 12);
    L48.shroud = rmfield(L48.shroud, 'lengthMm');
    L48.shroud.gaps = struct('x0Mm', 280, 'x1Mm', 318);
    % 以后改默认布局时这份"固定的旧几何"不能跟着变：核对关键字段与 v4.8.0 的默认值相同
    r = @(x, y, w, h) struct('x', x, 'y', y, 'w', w, 'h', h);
    ok48 = isequal(L48.gpu.pcb, r(38, 212, 216, 12)) && isequal(L48.gpu.heatsink, r(28, 224, 236, 57)) && ...
        abs(L48.gpu.thermal.A_fin_total_m2 - 0.45 * 57 / 47) < 1e-12 && L48.shroud.yMm == 314 && L48.shroud.hMm == 16 && ...
        isequal(L48.chassis.sizeMm, [320 400]) && L48.fanDiskMm == 12;
    if ~ok48
        fprintf('[4] v4.8.0 几何与当时的默认值不同（默认布局改了？请在这里写死旧几何）：FAIL\n');
        nFail = nFail + 1;
    end
    s48 = CFDSolverFEM(125,250,450,L48,1,0.005);
    s48.stepMultiple(nSteps);
    [r48, k48] = nuTRatio(s48);
    p95 = pct(r48, 0.95);
    med = median(r48);
    if p95 >= 100 && med <= 2000 && p95 > medL
        fprintf('[4] v4.8.0 几何 ν_t/ν：中位数 %.0f，p95 %.0f（≥100 达 O(10^2)，超过 LVEL 帽 %.0f×），k 最大 %.2f：PASS\n', ...
            med, p95, medL, max(k48));
    else
        fprintf('[4] v4.8.0 几何 ν_t/ν：中位数 %.0f，p95 %.0f：FAIL（p95<100、中位数超帽或未超过 LVEL 帽）\n', med, p95);
        nFail = nFail + 1;
    end

    pass = nFail == 0;
    if pass
        fprintf('=== 湍流模型测试全部通过（%d 步）===\n', nSteps);
    else
        fprintf('=== 湍流模型测试 %d 项失败 ===\n', nFail);
    end
end

function [r, k, w, fluidIdx] = nuTRatio(s)
    % 流体格的 ν_t/ν = (ν_eff − ν)/ν
    k = s.turbK; w = s.turbOmega;
    fluidIdx = find(s.obstacle == 0);
    nu = s.computeNuEff();
    r = (nu(fluidIdx) - s.AIR.nu) / s.AIR.nu;
end

function v = pct(x, q)
    % 分位数（不依赖统计工具箱）
    srt = sort(x(:));
    v = srt(max(1, round(q * numel(srt))));
end
