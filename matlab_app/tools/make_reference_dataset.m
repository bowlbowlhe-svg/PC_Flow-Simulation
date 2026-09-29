function make_reference_dataset(cases)
%MAKE_REFERENCE_DATASET 生成网页版移植的"标准答案"数据集（tests/reference/*.json）。
%   make_reference_dataset()            生成全部算例（Octave 单线程约 40 分钟）
%   make_reference_dataset({'fixed_default'})   只生成指定算例（可多进程并行生成）
%   算例：
%     fixed_default  默认布局与功率，预览网格 140²，湍流逐步更新，从静止推进 200 步：
%                    完整场（温度、格心速度、静压）+ 标量（结温、风扇工作点、开口风量、噪音）
%     fixed_duct     直风道基准（ζ = 20），预览网格，200 步：完整场 + 风扇工作点
%     steady_*       默认布局三种功率（gaming/default/heavy）与 4 个预设（front_top、positive、
%                    negative、bottom_top）在 280² 跑到稳态：窗口均值与稳态时刻的标量
%     bench          基准：扩散比值、方腔 Nu（Ra = 1e4/1e5）、风道工作点（ζ = 5/20/60）
%   每个文件记录生成环境（MATLAB/Octave 版本）与仿真器版本。
    all = {'fixed_default', 'fixed_duct', 'steady_gaming', 'steady_default', 'steady_heavy', ...
           'steady_front_top', 'steady_positive', 'steady_negative', 'steady_bottom_top', 'bench'};
    if nargin < 1 || isempty(cases), cases = all; end
    if ischar(cases), cases = {cases}; end
    outDir = fullfile(fileparts(fileparts(mfilename('fullpath'))), 'tests', 'reference');
    if ~exist(outDir, 'dir'), mkdir(outDir); end
    for k = 1:numel(cases)
        t0 = tic;
        c = cases{k};
        switch c
            case 'fixed_default'
                R = fixedCase(layout_default(), [125 250 450], 0.5, 200);
            case 'fixed_duct'
                R = fixedCase(layout_benchmark('duct', 20), [0 0 0], 0.5, 200);
            case 'steady_gaming',     R = steadyCase(layout_default(), [100 200 500]);
            case 'steady_default',    R = steadyCase(layout_default(), [125 250 450]);
            case 'steady_heavy',      R = steadyCase(layout_default(), [180 320 850]);
            case 'steady_front_top',  R = steadyCase(layout_apply_preset(layout_default(), 'front_top'), [125 250 450]);
            case 'steady_positive',   R = steadyCase(layout_apply_preset(layout_default(), 'positive'), [125 250 450]);
            case 'steady_negative',   R = steadyCase(layout_apply_preset(layout_default(), 'negative'), [125 250 450]);
            case 'steady_bottom_top', R = steadyCase(layout_apply_preset(layout_default(), 'bottom_top'), [125 250 450]);
            case 'bench',             R = benchCase();
            otherwise, error('make_reference_dataset:case', '未知算例：%s', c);
        end
        R.case = c;
        R.generator = envInfo();
        f = fullfile(outDir, [c '.json']);
        fid = fopen(f, 'w');
        fwrite(fid, jsonencode(R));
        fclose(fid);
        fprintf('[%s] 已写入 %s（%.0f s）\n', c, f, toc(t0));
    end
end

function R = fixedCase(L, P, gridScale, nSteps)
    s = CFDSolverFEM(P(1), P(2), P(3), L, gridScale);
    s.turbUpdateEvery = 1;
    s.stepMultiple(nSteps);
    W = s.GRID.W;
    [uc, vc] = s.getCellVelocity();
    R = struct('kind', 'fixed', 'layout', L, 'powers', P, 'gridScale', gridScale, 'DT', s.DT, ...
        'steps', nSteps, 'W', W, 'H', s.GRID.H, 'cellMm', s.GRID.cell_size_mm, ...
        'scalars', scalars(s), ...
        'fields', struct('note', '列优先（线性索引 (x−1)·W + y），障碍格的速度为 0、静压为 null', ...
            'T', r6(s.T_fluid), 'u', r6(uc * s.VEL_SCALE), 'v', r6(vc * s.VEL_SCALE), ...
            'P', r6(s.pressureFieldPa()), 'obstacle', double(s.obstacle > 0)));
end

function R = steadyCase(L, P)
    s = CFDSolverFEM(P(1), P(2), P(3), L, 1);
    info = s.runToSteady();
    cols = info.columns;
    fin = struct();
    for k = 1:numel(cols), fin.(cols{k}) = info.final(k); end
    R = struct('kind', 'steady', 'layout', L, 'powers', P, 'gridScale', 1, 'DT', s.DT, ...
        'steps', info.steps, 'converged', info.converged, 'windowMean', fin, 'scalars', scalars(s));
end

function R = benchCase()
    R = struct('kind', 'bench');
    % 扩散：test_diffusion 的高斯包方差比值（温度标量路径）
    R.diffusion = 'test_diffusion：方差增长与解析解比值 1.000（容差 2%）';
    % 方腔（与 test_cavity 同口径：DT = 0.02 s、1500 步、热壁右侧第一列流体）
    for Ra = [1e4 1e5]
        L = layout_benchmark('cavity', Ra);
        s = CFDSolverFEM(0, 0, 0, L, 1, 0.02);
        s.stepMultiple(1500);
        W = s.GRID.W; co = s.CASE2D.outer;
        rows = (co.y + 1 : co.y + co.h - 2)';
        Th = L.chassis.wallTempC.rear;
        R.(sprintf('cavityNu_Ra%g', Ra)) = mean(Th - s.T_fluid(co.x*W + rows)) / L.benchmark.dT * (co.w - 1);
    end
    % 风道
    for z = [5 20 60]
        s = CFDSolverFEM(0, 0, 0, layout_benchmark('duct', z), 1, 0.005);
        s.stepMultiple(600);
        R.(sprintf('ductCfm_zeta%d', z)) = s.diskFlow(s.fans{1}) / s.CFM_TO_M3S;   % 推进结束时穿盘流量
    end
end

function S = scalars(s)
    tn = s.thermalNetworks; nm = fieldnames(tn);
    S = struct('iteration', s.iteration);
    for k = 1:numel(nm)
        S.(['Tj_' nm{k}]) = tn.(nm{k}).T_junction;
        S.(['power_' nm{k}]) = tn.(nm{k}).actual_power;
    end
    t = s.computeAirflowTemperatures();
    S.internalAmbient = t.internalAmbient;
    S.totalCFM = t.totalCFM;
    [S.noiseDb, ~] = s.totalNoise();
    fl = s.fanStatusList();
    S.fans = struct('name', {fl.name}, 'rpm', {fl.rpm}, 'cfm', {fl.cfm}, 'dp', {fl.dp}, 'noiseDb', {fl.noiseDb});
    M = s.openingMarkers();
    S.openings = struct('mount', {M.mount}, 'kind', {M.kind}, 'cfm', {M.cfm});
    P = s.pressureFieldPa();
    v = P(s.insideMask);
    S.meanInteriorPressurePa = mean(v(isfinite(v)));
end

function v = r6(x)
    % 6 位有效数字，减小文件体积
    v = str2double(cellstr(num2str(x(:), '%.6g')));
end

function e = envInfo()
    if exist('OCTAVE_VERSION', 'builtin')
        e = struct('platform', 'Octave', 'version', OCTAVE_VERSION, 'simulator', pcflow_version());
    else
        e = struct('platform', 'MATLAB', 'version', version, 'simulator', pcflow_version());
    end
end
