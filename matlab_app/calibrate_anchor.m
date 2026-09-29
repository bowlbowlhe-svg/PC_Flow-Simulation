function calibrate_anchor(steps)
%CALIBRATE_ANCHOR 实测锚点标定（v2.6）
%   对默认场景（125/250/450W）做 flowEfficiency 二分搜索，使 GPU Tj 命中
%   文献锚点 85°C（README 引用 RTX 4080 250W 级箱内实测 Tj ≈ 75–85°C，取上限，
%   因仿真散热面积取保守端）。
%
%   注意：单点标定的作用是把"±25% 声明"收紧为"对该锚点 ±x%"，
%   不构成完整的实验验证。若锚点不可达（流量效率超出合理区间 0.4–1.6），
%   说明偏差不在流量环节，应转而检查散热器 h/A 参数。
%
%   用法： calibrate_anchor        % 每次评估 250 步
%          calibrate_anchor(400)   % 更稳态但更慢

    if nargin < 1, steps = 250; end

    targetTj = 85;      % 锚点：GPU Tj [°C]
    tol      = 1.0;     % 容差 [°C]
    lo = 0.4; hi = 1.6; % flowEfficiency 合理搜索区间
    maxIter  = 6;

    fprintf('=== 锚点标定：默认场景 GPU Tj → %.0f°C（flowEfficiency ∈ [%.1f, %.1f]，%d 步/次）===\n',...
        targetTj, lo, hi, steps);

    bestEff = NaN; bestTj = NaN;
    for it = 1:maxIter
        eff = 0.5*(lo+hi);
        s = CFDSolverFEM(125, 250, 450, 'atx_balanced');
        s.flowEfficiency = eff;
        s.stepMultiple(steps);
        tj = s.thermalNetworks.gpu.T_junction;
        fprintf('[%d] flowEfficiency=%.3f → Tj_gpu=%.1f°C\n', it, eff, tj);
        bestEff = eff; bestTj = tj;
        if abs(tj - targetTj) <= tol
            fprintf('锚点命中（|Δ| ≤ %.1f°C）\n', tol);
            break;
        end
        % eff ↑ → 流量 ↑ → T_internal ↓ → Tj ↓
        if tj > targetTj, lo = eff; else, hi = eff; end
    end

    fprintf('\n--- 标定结论 ---\n');
    if abs(bestTj - targetTj) <= tol
        fprintf('建议：CFDSolverBase.FLOW_EFFICIENCY 默认值 0.75 → %.2f\n', bestEff);
        fprintf('（修改常量后重跑 generate_snapshots 更新稳态表）\n');
    else
        fprintf('区间内不可达：最近点 flowEfficiency=%.2f 时 Tj_gpu=%.1f°C（目标 %.0f°C）\n',...
            bestEff, bestTj, targetTj);

        % 偏差定位：分解 GPU 热阻栈，量化各环节对温升的贡献
        s = CFDSolverFEM(125, 250, 450, 'atx_balanced');
        s.stepMultiple(steps);
        net = s.thermalNetworks.gpu;
        th  = s.GPU_HEATSINK.thermal;
        h   = net.h_conv;
        A   = th.A_fin_total_m2;
        fin_t = th.fin_thickness_mm / 1000;
        m     = sqrt(2*h/(200*fin_t));
        eta_f = tanh(m*0.025)/(m*0.025);
        eta_o = 1 - (1-eta_f)*0.8;
        R_conv  = 1/(h*A*eta_o);
        R_fixed = th.R_junction_to_case + th.R_tim + th.R_base;
        Trise   = net.T_junction - s.lastTemps.internalAmbient;
        fprintf('\n--- 偏差定位（GPU 热阻栈分解） ---\n');
        fprintf('GPU 温升 ΔT = %.1fK（相对内部环境 %.1f°C）：\n', Trise, s.lastTemps.internalAmbient);
        fprintf('  固定热阻栈 R_jc+TIM+base = %.2f K/W → 贡献 %.1fK（%.0f%%）\n',...
            R_fixed, R_fixed*net.actual_power, 100*R_fixed*net.actual_power/Trise);
        fprintf('  对流环节   R_conv = %.4f K/W（h=%.0f W/m²K, A=%.2f m²）→ 贡献 %.1fK\n',...
            R_conv, h, A, R_conv*net.actual_power);
        fprintf('结论：温升由固定热阻栈主导时，风道/流量侧调整无法命中锚点；\n');
        fprintf('缩小差距需要 GPU 厂商结-壳热阻实测数据，而非继续调风道参数。\n');
    end
end
