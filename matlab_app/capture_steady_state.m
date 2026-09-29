function capture_steady_state(scenarioName, cpuPower, gpuPower, psuPower, outDir)
%CAPTURE_STEADY_STATE 推进到稳态并保存四视图截图 + 关键指标
% 用法: capture_steady_state('default', 125, 250, 450, fullfile(pwd,'snapshots'))

    if nargin < 5, outDir = fullfile(pwd, 'snapshots'); end
    if ~exist(outDir, 'dir'), mkdir(outDir); end
    addpath(fileparts(mfilename('fullpath')));

    fprintf('=== Scenario: %s (CPU=%dW GPU=%dW PSU=%dW) ===\n', scenarioName, cpuPower, gpuPower, psuPower);
    s = CFDSolverFEM(cpuPower, gpuPower, psuPower, 'atx_balanced');
    s.autoFanEnabled = true;

    nSteps = 400;
    batchSize = 50;
    for k = 1:(nSteps/batchSize)
        s.stepMultiple(batchSize);
        d = s.calculateCFDDiagnostics();
        fprintf('  step=%d Tcpu=%.1f Tgpu=%.1f Tpsu=%.1f Re=%.0f Nu=%.1f\n', ...
            s.iteration, s.thermalNetworks.cpu.T_junction, ...
            s.thermalNetworks.gpu.T_junction, s.thermalNetworks.psu.T_junction, ...
            d.Re, d.Nu);
    end

    W = s.GRID.W; H = s.GRID.H;
    obs2d = reshape(s.obstacle, W, H) > 0;
    [uCg, vCg] = s.getCellVelocity();  % v3.0: 统一读取口
    views = {'velocity', 'temperature', 'vorticity', 'solid'};
    cmaps = {'jet', 'hot', 'cool', 'parula'};
    clims = {[0 3], [20 80], [-2 2], [20 90]};
    titles = {'Velocity (m/s)', 'Temperature (deg C)', 'Vorticity', 'Solid Temperature (deg C)'};

    fig = figure('Visible','off', 'Position',[100 100 800 800], 'Color', [0.05 0.05 0.08]);
    for vi = 1:length(views)
        clf(fig);
        switch views{vi}
            case 'velocity'
                field = reshape(sqrt(uCg.^2 + vCg.^2), W, H) * s.VEL_SCALE;
                field(obs2d) = NaN;
            case 'temperature'
                field = reshape(s.T_fluid, W, H);
            case 'vorticity'
                field = reshape(s.computeVorticity(), W, H);
            case 'solid'
                field = reshape(s.T_solid, W, H);
        end
        ax = axes(fig, 'Position', [0.08 0.08 0.82 0.85]);
        imagesc(ax, [1 W], [1 H], field);
        axis(ax, 'image');
        ax.YDir = 'reverse';
        colormap(ax, cmaps{vi});
        ax.CLim = clims{vi};
        cb = colorbar(ax, 'eastoutside');
        cb.Color = [0.9 0.9 0.9];
        title(ax, sprintf('%s - %s (iter=%d)', scenarioName, titles{vi}, s.iteration), 'Color', [0.95 0.95 0.95]);
        ax.XColor = [0.6 0.6 0.6]; ax.YColor = [0.6 0.6 0.6];
        ax.Color = [0.05 0.05 0.08];
        if strcmp(views{vi},'velocity')
            hold(ax,'on');
            umat = reshape(uCg, W, H); vmat = reshape(vCg, W, H);
            umat(obs2d) = NaN; vmat(obs2d) = NaN;
            try
                hs = streamslice(ax, 1:W, 1:H, umat, vmat, 1.5);
                set(hs,'Color',[1 1 1],'LineWidth',0.6);
            catch, end
            hold(ax,'off');
        end
        outPath = fullfile(outDir, sprintf('%s_%s.png', scenarioName, views{vi}));
        exportgraphics(fig, outPath, 'Resolution', 110);
        fprintf('  Saved: %s\n', outPath);
    end
    close(fig);

    scores  = s.calculateScores();
    diag    = s.calculateCFDDiagnostics();
    temps   = s.computeAirflowTemperatures();
    summary = sprintf(['scenario=%s\nCPU_power=%dW GPU_power=%dW PSU_power=%dW\n',...
        'Tj_cpu=%.1f Tj_gpu=%.1f Tj_psu=%.1f (deg C)\n',...
        'cpu_throttle=%.1f%% gpu_throttle=%.1f%% psu_throttle=%.1f%%\n',...
        'Re=%.0f Gr=%.2e Ra=%.2e Nu=%.1f\n',...
        'flowRegime=%s\n',...
        'intake=%.1f internalAmbient=%.1f topExhaust=%.1f rearExhaust=%.1f\n',...
        'totalCFM=%.1f deadZoneRatio=%.3f\n',...
        'maxFluidV(grid)=%.2f maxPhys(m/s)=%.2f\n',...
        'score_total=%d cooling=%d noise_dB=%d\n'], ...
        scenarioName, cpuPower, gpuPower, psuPower, ...
        s.thermalNetworks.cpu.T_junction, s.thermalNetworks.gpu.T_junction, s.thermalNetworks.psu.T_junction, ...
        s.thermalNetworks.cpu.throttling_ratio*100, s.thermalNetworks.gpu.throttling_ratio*100, s.thermalNetworks.psu.throttling_ratio*100, ...
        diag.Re, diag.Gr, diag.Ra, diag.Nu, diag.flowRegime, ...
        temps.intake, temps.internalAmbient, temps.topExhaust, temps.rearExhaust, ...
        temps.totalCFM, s.deadZoneRatio, ...
        max(sqrt(uCg.^2+vCg.^2)), max(sqrt(uCg.^2+vCg.^2))*s.VEL_SCALE, ...
        scores.total, scores.cooling, scores.noiseDb);

    fid = fopen(fullfile(outDir, sprintf('%s_summary.txt', scenarioName)), 'w');
    fwrite(fid, summary, 'char');
    fclose(fid);
    fprintf('\n%s\n', summary);
end
