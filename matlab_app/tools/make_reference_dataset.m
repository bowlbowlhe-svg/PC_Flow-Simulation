function make_reference_dataset(cases, outDir)
%MAKE_REFERENCE_DATASET 生成网页版移植的"标准答案"数据集（tests/reference/*.json）。
%   make_reference_dataset()                   生成全部算例（Octave 单线程约 3 小时，可分组并行）
%   make_reference_dataset({'fixed_default'})  只生成指定算例
%   make_reference_dataset(cases, outDir)      写到其它目录。在另一平台（例如 MATLAB）上生成对照
%                                              数据时请用单独目录（如 'tests/reference/matlab'），
%                                              不要覆盖仓库里的数据
%   算例：
%     fixed_default  默认布局与功率，预览网格 140²，湍流逐步更新，从静止推进 200 步
%     fixed_duct     直风道基准（ζ = 20），预览网格，200 步
%                    两者都含：几何导出（障碍类型、面掩码、阻力系数、最近流体格、壁距、
%                    风扇盘、开口、共轭传热区域、海绵环）、第 1/10/13/200 步的完整状态快照
%                    （温度、面速度、两次投影压力、k、ω、ν_eff、固体温度、风扇与热网络状态），
%                    以及第 200 步的显示量（格心速度 m/s、静压 Pa）
%     steady_*       默认布局三种功率（gaming/default/heavy）与 4 个预设（front_top、positive、
%                    negative、bottom_top）在 280² 固定推进 3000 步（15 s），取 1000 步之后的
%                    均值、标准差、极值与全程轨迹（steady_long_run）
%     bench          基准：方腔 Nu（Ra = 1e4/1e5）、风道工作点流量（ζ = 5/20/60），含所用布局
%   每个文件记录生成环境（MATLAB/Octave 版本）与仿真器版本；JSON 以 UTF-8 写入；
%   列表类字段（机箱风扇、通风口、风扇、开口等）即使只有一个元素也写成数组。
    all = {'fixed_default', 'fixed_duct', 'steady_gaming', 'steady_default', 'steady_heavy', ...
           'steady_front_top', 'steady_positive', 'steady_negative', 'steady_bottom_top', 'bench'};
    if nargin < 1 || isempty(cases), cases = all; end
    if ischar(cases), cases = {cases}; end
    if nargin < 2 || isempty(outDir)
        outDir = fullfile(fileparts(fileparts(mfilename('fullpath'))), 'tests', 'reference');
    end
    if ~exist(outDir, 'dir'), mkdir(outDir); end
    for k = 1:numel(cases)
        t0 = tic;
        c = cases{k};
        switch c
            case 'fixed_default'
                R = fixedCase(layout_default(), [125 250 450], 0.5, [1 10 13 200]);
            case 'fixed_duct'
                R = fixedCase(layout_benchmark('duct', 20), [0 0 0], 0.5, [1 10 13 200]);
            case 'steady_gaming',     R = steadyCase(layout_default(), [100 200 500], c);
            case 'steady_default',    R = steadyCase(layout_default(), [125 250 450], c);
            case 'steady_heavy',      R = steadyCase(layout_default(), [180 320 850], c);
            case 'steady_front_top',  R = steadyCase(layout_apply_preset(layout_default(), 'front_top'), [125 250 450], c);
            case 'steady_positive',   R = steadyCase(layout_apply_preset(layout_default(), 'positive'), [125 250 450], c);
            case 'steady_negative',   R = steadyCase(layout_apply_preset(layout_default(), 'negative'), [125 250 450], c);
            case 'steady_bottom_top', R = steadyCase(layout_apply_preset(layout_default(), 'bottom_top'), [125 250 450], c);
            case 'bench',             R = benchCase();
            otherwise, error('make_reference_dataset:case', '未知算例：%s', c);
        end
        R.case = c;
        R.generator = envInfo();
        f = fullfile(outDir, [c '.json']);
        writeJson(f, R);
        fprintf('[%s] 已写入 %s（%.0f s）\n', c, f, toc(t0));
    end
end

function R = fixedCase(L, P, gridScale, snapSteps)
    s = CFDSolverFEM(P(1), P(2), P(3), L, gridScale);
    s.turbUpdateEvery = 1;
    snaps = cell(1, numel(snapSteps));
    for k = 1:numel(snapSteps)
        s.stepMultiple(snapSteps(k) - s.iteration);
        snaps{k} = snapshot(s);
    end
    W = s.GRID.W;
    [uc, vc] = s.getCellVelocity();
    R = struct('kind', 'fixed', 'layout', listifyLayout(L), 'powers', P, 'gridScale', gridScale, ...
        'DT', s.DT, 'steps', snapSteps(end), 'W', W, 'H', s.GRID.H, 'cellMm', s.GRID.cell_size_mm, ...
        'VEL_SCALE', s.VEL_SCALE, 'turbUpdateEvery', 1, ...
        'scalars', scalars(s), ...
        'fields', struct('note', ['第 steps 步的显示量。列优先（线性索引 (x−1)·W + y，y 为行向下），' ...
            'u/v 为格心速度 m/s（v 向下为正），障碍格的速度为 0、静压为 null；' ...
            'obstacle 为 0/1（障碍类型见 geometry.obstacleType）；障碍格的 T 为显示值（见 ALGORITHM §3）'], ...
            'T', r6(s.T_fluid), 'u', r6(uc * s.VEL_SCALE), 'v', r6(vc * s.VEL_SCALE), ...
            'P', r6(s.pressureFieldPa()), 'obstacle', double(s.obstacle > 0)), ...
        'geometry', geometry(s), ...
        'snapshots', {snaps});
end

function S = snapshot(s)
    % 推进到某步后的完整状态（网格单位，与求解器内部一致）
    S = struct('step', s.iteration, ...
        'note', ['uF 为 W×(H+1) 的 u 面、vF 为 (W+1)×H 的 v 面（列优先，网格速度，×VEL_SCALE 得 m/s）；' ...
                 'p 为第二次（阻力耦合）投影压力、pProj1 为第一次投影压力（网格单位，' ...
                 'P[Pa] = ρ·VEL_SCALE·Δx·(p + pProj1)/DT）；k [m²/s²]、omega [1/s]；' ...
                 'nuStep 为本步的 ν_eff、nuAssembled 为当前速度扩散算子装配时的 ν_eff [m²/s]；' ...
                 'alphaAssembled / nuTAssembled 为温度、k-ω 扩散算子装配时的 α_eff、ν_t，' ...
                 'asmStep 为各算子上次装配时的 iteration；betaRefU/betaRefV 为阻力耦合算子的参考 β' ...
                 '（betaRefStep 为其装配时的 iteration）；Tsolid 为固体温度 [°C]。连同 scalars 里的风扇与' ...
                 '热网络状态，可从快照续算'], ...
        'T', r6(s.T_fluid), 'uF', r6(s.uF), 'vF', r6(s.vF), 'p', r6(s.p), 'pProj1', r6(s.pProj1), ...
        'k', r6(s.turbK), 'omega', r6(s.turbOmega), 'nuStep', r6(s.nuFieldStep), ...
        'nuAssembled', r6(s.nuFieldAssembled), 'alphaAssembled', r6(s.alphaFieldAssembled), ...
        'nuTAssembled', r6(s.nuTAssembled), ...
        'asmStep', struct('nu', s.nuAsmStep, 'alpha', s.alphaAsmStep, 'nuT', s.nuTAsmStep), ...
        'betaRefU', r6(s.betaRefU(:)), 'betaRefV', r6(s.betaRefV(:)), 'betaRefStep', s.betaRefStep, ...
        'Tsolid', r6(s.T_solid), 'scalars', scalars(s));
end

function G = geometry(s)
    F = s.allFans();
    fans = cell(1, numel(F));
    for k = 1:numel(F)
        f = F{k};
        fans{k} = struct('id', f.id, 'role', f.role, 'mount', f.mount, 'type', f.type, 'model', f.model, ...
            'rows', f.rows, 'cols', f.cols, 'normal', f.normal, 'grilleZeta', f.grilleZeta);
    end
    ops = cell(1, numel(s.openings));
    for k = 1:numel(s.openings)
        o = s.openings(k);
        ops{k} = struct('mount', o.mount, 'kind', o.kind, 'idx', o.idx(:)', 'zeta', o.zeta);
    end
    obs = s.obstacle > 0;
    nf = s.nearestFluidIdx;
    nfObs = zeros(size(obs)); nfObs(obs) = nf(obs);
    G = struct('note', ['线性索引从 1 起（列优先）；rows/cols 为格行/列范围 [起 止]；normal 为送风方向' ...
            '（x 向右、y 向下）；nearestFluid 只在障碍格有值（其余为 0），平局取线性索引最小；' ...
            'wallDistanceM 为格心到最近障碍格心的欧氏距离'], ...
        'obstacleType', double(s.obstacle), 'obstacleCodes', s.OBSTACLE, ...
        'uFaceActive', double(s.uFaceActive), 'vFaceActive', double(s.vFaceActive), ...
        'uDragCoef', r6(s.uDragCoef), 'vDragCoef', r6(s.vDragCoef), ...
        'uGrilleFace', double(s.uGrilleFace), 'vGrilleFace', double(s.vGrilleFace), ...
        'nearestFluid', nfObs(:), 'wallDistanceM', r6(s.wallDistanceM), ...
        'spongeRing', s.spongeRingIdx(:), 'inside', s.insideMask(:), ...
        'dirichletIdx', s.dirichletIdx(:), 'dirichletT', s.dirichletT(:), ...
        'heatObsIdx', s.heatObsIdx(:), ...
        'cht', struct('cpuInlet', s.cpuInletIdx(:), 'cpuFin', s.cpuFinIdx(:), ...
            'gpuInlet', s.gpuInletIdx(:), 'gpuFin', s.gpuFinIdx(:), ...
            'psuInlet', s.psuInletIdx(:), 'psuInterior', s.psuInteriorIdx(:)), ...
        'fans', {fans}, 'openings', {ops});
end

function R = steadyCase(L, P, tag)
    t0 = tic;
    S = steady_long_run(L, P, 1, struct('progressFcn', @(i) prog(i, tag, t0)));
    s = S.solver;
    stat = @(v) cell2struct(num2cell(v), S.columns, 2);
    R = struct('kind', 'steady', 'layout', listifyLayout(L), 'powers', P, 'gridScale', 1, 'DT', s.DT, ...
        'steps', S.steps, 'avgFrom', S.avgFrom, ...
        'note', ['稳态结果取 avgFrom 步之后每一步瞬时值的统计（不依赖判稳时刻）；' ...
                 'history 每 10 步一行 [步数, 各列瞬时值]，列名见 columns'], ...
        'columns', {S.columns}, 'mean', stat(S.mean), 'std', stat(S.std), 'min', stat(S.min), ...
        'max', stat(S.max), 'history', r6(S.history), 'scalars', scalars(s));
end

function stop = prog(info, tag, t0)
    stop = false;
    if mod(info.steps, 500) == 0
        fprintf('  [%s] %d 步（%.0f s）\n', tag, info.steps, toc(t0));
    end
end

function R = benchCase()
    R = struct('kind', 'bench', ...
        'note', ['方腔：DT = 0.02 s、1500 步，Nu 取热壁右侧第一列流体的平均温度梯度；' ...
                 '风道：DT = 0.005 s、600 步，流量为推进结束时穿盘中面的流量']);
    cav = {};
    for Ra = [1e4 1e5]
        L = layout_benchmark('cavity', Ra);
        s = CFDSolverFEM(0, 0, 0, L, 1, 0.02);
        s.stepMultiple(1500);
        W = s.GRID.W; co = s.CASE2D.outer;
        rows = (co.y + 1 : co.y + co.h - 2)';
        Th = L.chassis.wallTempC.rear;
        Nu = mean(Th - s.T_fluid(co.x*W + rows)) / L.benchmark.dT * (co.w - 1);
        cav{end+1} = struct('Ra', Ra, 'W', W, 'H', s.GRID.H, 'Nu', Nu, 'layout', listifyLayout(L)); %#ok<AGROW>
    end
    duct = {};
    for z = [5 20 60]
        L = layout_benchmark('duct', z);
        s = CFDSolverFEM(0, 0, 0, L, 1, 0.005);
        s.stepMultiple(600);
        duct{end+1} = struct('zeta', z, 'W', s.GRID.W, 'H', s.GRID.H, ...
            'cfm', s.diskFlow(s.fans{1}) / s.CFM_TO_M3S, 'layout', listifyLayout(L)); %#ok<AGROW>
    end
    R.cavity = cav;
    R.duct = duct;
end

function S = scalars(s)
    tn = s.thermalNetworks; nm = fieldnames(tn);
    S = struct('iteration', s.iteration);
    for k = 1:numel(nm)
        n = tn.(nm{k});
        S.(['Tj_' nm{k}]) = n.T_junction;
        S.(['Tsink_' nm{k}]) = n.T_sink_base;
        S.(['power_' nm{k}]) = n.actual_power;
        S.(['hConv_' nm{k}]) = n.h_conv;
        S.(['freq_' nm{k}]) = n.freq_ratio;
        S.(['throttled_' nm{k}]) = n.throttled;
        S.(['overTemp_' nm{k}]) = n.overTemp;
    end
    t = s.computeAirflowTemperatures();
    S.internalAmbient = t.internalAmbient;
    S.totalCFM = t.totalCFM;
    [S.noiseDb, ~] = s.totalNoise();
    fl = s.fanStatusList();
    F = s.allFans();
    fans = cell(1, numel(fl));
    for k = 1:numel(fl)
        f = F{k};
        fans{k} = struct('name', fl(k).name, 'rpm', fl(k).rpm, 'cfm', fl(k).cfm, 'dp', fl(k).dp, ...
            'noiseDb', fl(k).noiseDb, 'lastQ_m3s', f.lastQ, 'lastQRatio', f.lastQRatio, ...
            'flowFactor', f.lastFlowFactor, 'noiseQRatio', f.noiseQRatio, 'stopped', fl(k).stopped);
    end
    S.fans = fans;
    M = s.openingMarkers();
    ops = cell(1, numel(M));
    for k = 1:numel(M)
        ops{k} = struct('mount', M(k).mount, 'kind', M(k).kind, 'cfm', M(k).cfm);
    end
    S.openings = ops;
    P = s.pressureFieldPa();
    v = P(s.insideMask);
    S.meanInteriorPressurePa = mean(v(isfinite(v)));
end

function L = listifyLayout(L)
    % 列表字段写成 cell，jsonencode 后单元素也是数组
    for nm = {'caseFans', 'vents', 'solidBlocks', 'porousBlocks'}
        if isfield(L, nm{1}) && isstruct(L.(nm{1}))
            L.(nm{1}) = num2cell(L.(nm{1})(:)');
        end
    end
    if isfield(L, 'shroud') && isfield(L.shroud, 'gaps') && isstruct(L.shroud.gaps)
        L.shroud.gaps = num2cell(L.shroud.gaps(:)');
    end
end

function writeJson(f, R)
    fid = fopen(f, 'w');
    if fid < 0, error('make_reference_dataset:open', '无法写入：%s', f); end
    fwrite(fid, unicode2native(jsonencode(R), 'UTF-8'));
    fclose(fid);
end

function v = r6(x)
    % 6 位有效数字，减小文件体积（保持原尺寸）
    if isempty(x), v = x; return; end
    v = reshape(str2double(cellstr(num2str(x(:), '%.6g'))), size(x));
end

function e = envInfo()
    if exist('OCTAVE_VERSION', 'builtin')
        e = struct('platform', 'Octave', 'version', OCTAVE_VERSION, 'simulator', pcflow_version());
    else
        e = struct('platform', 'MATLAB', 'version', version, 'simulator', pcflow_version());
    end
end
