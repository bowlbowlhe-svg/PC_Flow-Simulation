function generate_snapshots(steadyStateSteps)
%GENERATE_SNAPSHOTS 无界面跑三场景并输出快照（仅 MATLAB：用到 exportgraphics/streamslice）
%   每场景推进 steadyStateSteps 步至稳态，输出 4 张场景图 + 文本摘要：
%     <scen>_velocity.png  <scen>_temperature.png
%     <scen>_vorticity.png <scen>_solid.png
%     <scen>_summary.txt
%   场景：default (125/250/450 W) / gaming (100/200/500) / heavy (180/320/850)
%
%   用法：
%     generate_snapshots          % 默认 1000 步（约 5 s 物理时间，接近稳态）
%     generate_snapshots(800)     % 自定义步数

    if nargin < 1, steadyStateSteps = 1000; end

    scenarios = {...
        struct('name','default','cpu',125,'gpu',250,'psu',450),...
        struct('name','gaming', 'cpu',100,'gpu',200,'psu',500),...
        struct('name','heavy',  'cpu',180,'gpu',320,'psu',850)...
    };

    outDir = fullfile(fileparts(fileparts(mfilename('fullpath'))), 'snapshots');
    if ~exist(outDir, 'dir'), mkdir(outDir); end

    fprintf('=== Snapshot generation (steadyState=%d steps) ===\n', steadyStateSteps);
    for k = 1:numel(scenarios)
        s = scenarios{k};
        fprintf('\n[%d/%d] %s: CPU=%dW GPU=%dW PSU=%dW\n',...
            k, numel(scenarios), s.name, s.cpu, s.gpu, s.psu);
        tic;
        solver = CFDSolverFEM(s.cpu, s.gpu, s.psu, 'atx_balanced');
        result = solver.stepMultiple(steadyStateSteps);
        elapsed = toc;
        fprintf('  steady-state reached in %.1fs (%d steps, %.1f ms/step)\n',...
            elapsed, steadyStateSteps, 1000*elapsed/steadyStateSteps);

        renderSnapshot(solver, result, s, outDir);
        writeSummary(solver, result, s, outDir);
    end
    fprintf('\n=== Done. snapshots → %s ===\n', outDir);
end


function renderSnapshot(solver, result, s, outDir)
    W = solver.GRID.W; H = solver.GRID.H;
    velScale = solver.VEL_SCALE;
    [uCg, vCg] = solver.getCellVelocity();

    % 字段布局：reshape(linear, W, H) 给出 M(y, x) — y 在第 1 维（行），x 在第 2 维（列）
    % 因 obstacle 用 (x-1)*W + y 线性索引存储。imagesc 默认 row→Y / col→X 已对齐。
    velMagGrid = reshape(sqrt(uCg.^2 + vCg.^2), W, H);
    velMagMs   = velMagGrid * velScale;
    Tfluid = reshape(solver.T_fluid, W, H);
    Tsolid = reshape(solver.T_solid, W, H);
    vort   = reshape(result.vort, W, H);
    obs2d  = reshape(solver.obstacle, W, H) > 0;
    outside2d = false(W, H);
    if ~isempty(solver.outsideMask)
        outside2d(solver.outsideMask) = true;
    end
    nanMask = obs2d | outside2d;

    % 显示用 3×3 均值平滑（仅可视化；不改动求解器状态）
    % 半拉格朗日 cubic 平流会在剪切层引入网格尺度高频，平滑后流场结构更清晰
    velMagMs = smoothField(velMagMs, nanMask);
    vort     = smoothField(vort,     nanMask);
    Tfluid   = smoothField(Tfluid,   nanMask);

    umat = reshape(uCg, W, H) * velScale;
    vmat = reshape(vCg, W, H) * velScale;
    umat(nanMask) = NaN; vmat(nanMask) = NaN;

    velMagMs(nanMask) = NaN;
    % 温度场障碍格显示元件温度 T_solid；机箱外区域透明
    Tfluid(obs2d) = Tsolid(obs2d);
    Tfluid(outside2d) = NaN;
    Tsolid(outside2d) = NaN;      % 散热器格不在 outside，因此只挡外缓冲即可
    vort(nanMask)   = NaN;

    plotField(velMagMs, turbo(256), [0 2.0], '速度场 (m/s)', '速度 (m/s)',...
        sprintf('%s/%s_velocity.png', outDir, s.name), umat, vmat, true, [], []);

    plotField(Tfluid, hot(256), [20 80], '温度场 (°C)', '温度 (°C)',...
        sprintf('%s/%s_temperature.png', outDir, s.name), [], [], false, [35 50 65 80], [0 1 1]);

    plotField(vort, cool(256), [-60 60], '涡量场 (1/s)', '涡量 (1/s)',...
        sprintf('%s/%s_vorticity.png', outDir, s.name), [], [], false, 0, [1 1 0]);

    plotField(Tsolid, parula(256), [20 90], '固体温度 (°C)', '固体温度 (°C)',...
        sprintf('%s/%s_solid.png', outDir, s.name), [], [], false, [40 60 80], [1 1 1]);
end


function out = smoothField(field, maskNaN)
    % 3×3 mean filter；NaN 单元在计算时排除，平滑后写回 NaN
    K = ones(3,3) / 9;
    f = field;
    f(maskNaN) = 0;
    valid = ~maskNaN;
    num = conv2(f,           K, 'same');
    den = conv2(double(valid), K, 'same');
    out = num ./ max(den, eps);
    out(maskNaN) = NaN;
end


function plotField(field, cmap, clim, ttl, cbLabel, fname, umat, vmat, showStream, contourLevels, contourColor)
    fig = figure('Visible','off','Color',[0.05 0.05 0.1],...
                 'Position',[100 100 700 700],'PaperPositionMode','auto');
    ax = axes(fig, 'Color', [0.05 0.05 0.1]);
    hold(ax, 'on');
    [W, H] = size(field);
    % field(y, x)：直接 imagesc 不转置（与 App.updateVisualizations 一致）
    % NaN 处用 AlphaData 透明化（colormap 在端点处的色不会泄漏到 NaN 区域）
    alphaData = ones(W, H);
    alphaData(isnan(field)) = 0;
    fieldDraw = field;
    fieldDraw(isnan(field)) = clim(1);  % 占位避免 imagesc 警告
    h = imagesc(ax, [1 W], [1 H], fieldDraw);
    set(h, 'AlphaData', alphaData);
    set(ax, 'Color', [0.05 0.05 0.1]);
    colormap(ax, cmap);
    caxis(ax, clim);
    cb = colorbar(ax);
    cb.Label.String = cbLabel;
    cb.Color = [0.8 0.8 0.8];

    if ~isempty(contourLevels) && (max(field(:)) - min(field(:))) > 0.5
        contour(ax, 1:W, 1:H, field, contourLevels,...
            'LineColor', contourColor, 'LineWidth', 1.2);
    end
    if showStream && ~isempty(umat) && ~isempty(vmat)
        hs = streamslice(ax, 1:W, 1:H, umat, vmat, 0.7);
        if ~isempty(hs), set(hs, 'Color', [1 1 1], 'LineWidth', 0.6); end
    end

    set(ax, 'YDir','reverse','XColor',[0.8 0.8 0.8],'YColor',[0.8 0.8 0.8]);
    axis(ax,'image');
    xlim(ax,[1 W]); ylim(ax,[1 H]);
    title(ax, ttl, 'Color', [0.8 0.8 1]);
    exportgraphics(fig, fname, 'Resolution', 120);
    close(fig);
end


function writeSummary(solver, result, s, outDir)
    cpuNet = solver.thermalNetworks.cpu;
    gpuNet = solver.thermalNetworks.gpu;
    psuNet = solver.thermalNetworks.psu;
    diag   = result.diag;
    temps  = result.temps;
    scores = solver.calculateScores();

    [uCg2, vCg2] = solver.getCellVelocity();
    vel    = sqrt(uCg2.^2 + vCg2.^2);
    maxV   = max(vel);
    fname = sprintf('%s/%s_summary.txt', outDir, s.name);
    fid   = fopen(fname, 'w');
    fprintf(fid, 'version=%s\n', pcflow_version());
    fprintf(fid, 'scenario=%s\n', s.name);
    fprintf(fid, 'CPU_power=%dW GPU_power=%dW PSU_power=%dW\n', s.cpu, s.gpu, s.psu);
    fprintf(fid, 'Tj_cpu=%.1f Tj_gpu=%.1f Tj_psu=%.1f (deg C)\n',...
        cpuNet.T_junction, gpuNet.T_junction, psuNet.T_junction);
    fprintf(fid, 'cpu_throttle=%.1f%% gpu_throttle=%.1f%% psu_throttle=%.1f%%\n',...
        cpuNet.throttling_ratio*100, gpuNet.throttling_ratio*100, psuNet.throttling_ratio*100);
    fprintf(fid, 'Re=%.0f Gr=%.2e Ra=%.2e Nu=%.1f\n', diag.Re, diag.Gr, diag.Ra, diag.Nu);
    fprintf(fid, 'flowRegime=%s\n', diag.flowRegime);
    fprintf(fid, 'intake=%.1f internalAmbient=%.1f topExhaust=%.1f rearExhaust=%.1f\n',...
        temps.intake, temps.internalAmbient, temps.topExhaust, temps.rearExhaust);
    fprintf(fid, 'totalCFM=%.1f deadZoneRatio=%.3f\n', temps.totalCFM, result.deadRatio);
    fprintf(fid, 'maxFluidV(grid)=%.2f maxPhys(m/s)=%.2f\n', maxV, maxV*solver.VEL_SCALE);
    fprintf(fid, 'score_total=%d cooling=%d noise_dB=%d\n',...
        scores.total, scores.cooling, scores.noiseDb);
    fclose(fid);
    fprintf('  → %s_summary.txt   Tj=[%.1f / %.1f / %.1f]  throttle=[%.0f%% %.0f%% %.0f%%]\n',...
        s.name, cpuNet.T_junction, gpuNet.T_junction, psuNet.T_junction,...
        cpuNet.throttling_ratio*100, gpuNet.throttling_ratio*100, psuNet.throttling_ratio*100);
end
