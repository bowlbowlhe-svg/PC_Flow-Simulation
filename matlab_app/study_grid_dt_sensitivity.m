function results = study_grid_dt_sensitivity(steps)
%STUDY_GRID_DT_SENSITIVITY 网格/时间步敏感性研究（v2.6）
%   量化数值离散对结果的影响：网格 140²/280²/560² × DT 0.005/0.0025。
%   DT 减半时步数加倍，保证到达同一物理时间。
%   默认场景 125/250/450W，判定口径：
%     - Tj 随网格加密变化 <5%  → 网格收敛可接受
%     - 变化 5–15%             → 数值扩散显著，绝对温度只作定性参考
%     - 变化 >15%              → 结果主要由数值离散决定，需先修数值
%
%   用法： study_grid_dt_sensitivity        % 默认基准 400 步（DT 减半组 800 步）

    if nargin < 1, steps = 400; end

    configs = {...
        struct('scale',0.5,'dt',0.005),...
        struct('scale',1,  'dt',0.005),...
        struct('scale',2,  'dt',0.005),...
        struct('scale',1,  'dt',0.0025),...
        struct('scale',2,  'dt',0.0025)};

    n = numel(configs);
    results = repmat(struct('scale',0,'dt',0,'steps',0,'Tcpu',0,'Tgpu',0,'Tpsu',0,...
        'TinternalAlg',0,'TinternalCFD',0,'closurePct',0,'deadZonePct',0,...
        'nuMedRatio',0,'elapsed',0), n, 1);

    fprintf('=== 网格/时间步敏感性研究（基准 %d 步，物理时间 %.1fs）===\n', steps, steps*0.005);
    fprintf('%-6s %-7s %-6s | %-6s %-6s %-6s | %-8s %-8s | %-7s | %-6s\n', ...
        'scale','dt','steps','Tcpu','Tgpu','Tpsu','Tint_alg','Tint_cfd','clos%','dead%');

    for k = 1:n
        cfg = configs{k};
        stepsK = round(steps * 0.005 / cfg.dt);   % 同一物理时间
        tic;
        s = CFDSolverFEM(125, 250, 450, 'atx_balanced', cfg.scale, cfg.dt);
        s.stepMultiple(stepsK);
        el = toc;

        c = s.computeConservationCheck();
        t = s.lastTemps;
        nu = s.computeNuEff();

        r = struct('scale',cfg.scale,'dt',cfg.dt,'steps',stepsK,...
            'Tcpu',s.thermalNetworks.cpu.T_junction,...
            'Tgpu',s.thermalNetworks.gpu.T_junction,...
            'Tpsu',s.thermalNetworks.psu.T_junction,...
            'TinternalAlg',t.internalAmbient,'TinternalCFD',t.internalAmbientCFD,...
            'closurePct',c.closurePct,'deadZonePct',100*s.deadZoneRatio,...
            'nuMedRatio',median(nu)/s.AIR.nu,'elapsed',el);
        results(k) = r;
        fprintf('%-6.1f %-7.4f %-6d | %-6.1f %-6.1f %-6.1f | %-8.1f %-8.1f | %+7.1f | %-6.1f  (%.0fs)\n',...
            r.scale, r.dt, r.steps, r.Tcpu, r.Tgpu, r.Tpsu,...
            r.TinternalAlg, r.TinternalCFD, r.closurePct, r.deadZonePct, r.elapsed);
    end

    % 网格收敛判据：140²/280²/560² 同 DT 对比
    base = results(2); fine = results(3);
    dCpu = 100*(fine.Tcpu-base.Tcpu)/max(base.Tcpu-25,eps);
    dGpu = 100*(fine.Tgpu-base.Tgpu)/max(base.Tgpu-25,eps);
    fprintf('\n--- 网格收敛（280²→560²，相对温升变化）---\n');
    fprintf('CPU 温升变化 %+.1f%%，GPU 温升变化 %+.1f%%\n', dCpu, dGpu);
    if max(abs([dCpu dGpu])) < 5
        fprintf('判定：网格收敛可接受（<5%%）\n');
    elseif max(abs([dCpu dGpu])) < 15
        fprintf('判定：数值扩散显著（5–15%%），绝对温度只作定性参考\n');
    else
        fprintf('判定：结果主要由数值离散决定（>15%%），需先修数值方法\n');
    end

    % 时间步收敛判据：280² DT 减半对比
    rDt = results(4);
    dCpuT = 100*(rDt.Tcpu-base.Tcpu)/max(base.Tcpu-25,eps);
    dGpuT = 100*(rDt.Tgpu-base.Tgpu)/max(base.Tgpu-25,eps);
    fprintf('--- 时间步收敛（280²，DT 0.005→0.0025）---\n');
    fprintf('CPU 温升变化 %+.1f%%，GPU 温升变化 %+.1f%%\n', dCpuT, dGpuT);

    % 结果写文件备查
    outFile = fullfile(fileparts(mfilename('fullpath')), 'study_grid_dt_results.txt');
    fid = fopen(outFile, 'w');
    fprintf(fid, '网格/时间步敏感性研究（v3.2.0 口径：MAC 架构 + 开口面格栅采样 + 进气格栅 mean(|v|) + P-Q 开口面净流量 + 多孔介质穿流 + GPU 薄卡几何 + 风扇定律 Δp∝n²，%s）\n', datestr(now));
    fprintf(fid, 'scale dt steps Tcpu Tgpu Tpsu Tint_alg Tint_cfd clos%% dead%% nuMed/nu elapsed\n');
    for k = 1:n
        r = results(k);
        fprintf(fid, '%.1f %.4f %d %.1f %.1f %.1f %.1f %.1f %+.1f %.1f %.1f %.0f\n',...
            r.scale, r.dt, r.steps, r.Tcpu, r.Tgpu, r.Tpsu,...
            r.TinternalAlg, r.TinternalCFD, r.closurePct, r.deadZonePct,...
            r.nuMedRatio, r.elapsed);
    end
    fclose(fid);
    fprintf('\n结果已写入 %s\n', outFile);
end
