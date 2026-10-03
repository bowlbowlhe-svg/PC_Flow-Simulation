function gen_paths_fixtures(outFile)
%GEN_PATHS_FIXTURES 生成求解器分支路径的回归对照数据（web/test/fixtures/paths.json）。
%   用法（在 matlab_app 目录下）：
%     OMP_NUM_THREADS=1 octave-cli --no-gui --eval "setup_paths(); addpath('../web/test/gen'); gen_paths_fixtures"
%   标准答案数据集只覆盖默认布局与风道（k-ω、湍流逐步更新、自动温控）。这里补充其余分支的小算例（≤ 20 步）：
%   方腔（层流、DT 0.02、压力参考点）、LVEL、层流、湍流每 3 步更新、手动转速与全局转速、环境温度/定温壁/物性覆盖/
%   节流/超温/中途改功率/精确模式、只有电源、无电源、散热体被固体覆盖（NaN 语义）、全装预设、2 槽显卡 + LVEL、空域、
%   被动通风口（矩形机箱各壁的沿壁夹紧）、CPU 塔扇（双塔 1 扇、单塔推拉、v4.4.0 及以前的单塔 1 扇旧布局）、
%   办公功率 + 静音曲线（显卡风扇低温停转、电源半被动）、性能曲线 + 自定义频率/漏电参数（降频、显卡风扇重新起转）、
%   散热片与进风带全被固体盖住（结温 NaN 时温控曲线取最低占空比）。
%   每个快照记录各场的指纹（和、绝对值和、平方和、极值、固定权重的加权和、均匀抽样点与机箱内 200 个抽样点，全精度）、
%   装配步、热网络与风扇状态。
%   场景定义取自 W0/W1 审计脚本（audit_run.m）。
    if nargin < 1
        here = fileparts(mfilename('fullpath'));
        outFile = fullfile(here, '..', 'fixtures', 'paths.json');
    end
    names = {'cavity', 'lvel', 'laminar140', 'tue3', 'manual', 'misc', 'onlypsu', 'nopsu', 'blockfins', ...
             'full140', 'gpu2slot', 'empty', 'vents', 'cpu1fan', 'cpupushpull', 'cpulegacy', 'office', 'dvfs', 'blockinlet'};
    C = cell(1, numel(names));
    for c = 1:numel(names)
        t0 = tic;
        C{c} = runCase(names{c});
        fprintf('[%s] %.1f s\n', names{c}, toc(t0));
    end
    R = struct('generator', struct('tool', 'octave', 'version', version(), 'script', 'web/test/gen/gen_paths_fixtures.m'), ...
        'cases', {C});
    fid = fopen(outFile, 'w');
    fwrite(fid, unicode2native(jsonencode(R), 'UTF-8'));
    fclose(fid);
    fprintf('已写入 %s\n', outFile);
end

function R = runCase(caseName)
    P = [125 250 450]; gs = 0.5; DT = 0.005; snaps = [1 5 10];
    props = struct(); actions = {};
    L = layout_default();
    switch caseName
        case 'cavity'
            L = layout_benchmark('cavity', 1e5); P = [0 0 0]; gs = 1; DT = 0.02; snaps = [1 10 20];
        case 'lvel'
            L.turbulenceModel = 'lvel';
        case 'laminar140'
            L.turbulenceModel = 'laminar';
        case 'tue3'
            props.turbUpdateEvery = 3; snaps = [1 6 7 13 20];
        case 'manual'
            L.caseFans(1).speedMode = 'manual'; L.caseFans(1).manualPct = 85;
            L.caseFans(3).speedMode = 'manual'; L.caseFans(3).manualPct = 30;
            props.autoFanEnabled = false; props.fanSpeedRatio = 70; snaps = [1 10 15];
        case 'misc'
            L.ambientC = 35;
            L.chassis.wallTempC.top = NaN; L.chassis.wallTempC.rear = 30;
            L.air = struct('nu', 1.7e-5, 'Pr', 0.7, 'beta', 3.2e-3, 'g', 9.8);
            L.cpu.throttleTemp = 36; L.gpu.throttleTemp = 37; L.psu.warnTemp = 36;
            P = [300 400 800];
            props.forceReassemble = true;
            actions = {struct('step', 8, 'name', 'cpu', 'watts', 200), struct('step', 8, 'name', 'psu', 'watts', 300)};
            snaps = [1 5 8 12 20];
        case 'onlypsu'
            L = rmfield(L, {'cpu', 'gpu'}); snaps = [1 10 15];
        case 'nopsu'
            L = rmfield(L, {'psu', 'shroud'}); snaps = [1 10];
        case 'blockfins'
            % 固体块盖住 CPU 散热片：散热体没有流体格（MATLAB 的 max 忽略 NaN，风速取 0）
            L.solidBlocks = L.cpu.fins; snaps = [1 3 5];
        case 'full140'
            L = layout_apply_preset(L, 'full'); snaps = [1 10 15];
        case 'gpu2slot'
            L = layout_set_gpu_slots(L, 2); L.turbulenceModel = 'lvel'; props.turbUpdateEvery = 2; snaps = [1 10 15];
        case 'empty'
            L = layout_benchmark('empty'); P = [0 0 0]; gs = 1; snaps = [1 3];
        case 'vents'
            % 被动通风口：沿壁范围按各壁长度夹紧（矩形机箱：顶/底壁 320 mm、前/后壁 400 mm）
            L.vents = [struct('mount', 'rear', 'alongMm', 250, 'lengthMm', 80, 'zeta', 3); ...
                       struct('mount', 'top', 'alongMm', 290, 'lengthMm', 80, 'zeta', 1.5); ...
                       struct('mount', 'front', 'alongMm', 60, 'lengthMm', 40, 'zeta', 2)];
            snaps = [1 5 10];
        case 'cpu1fan'
            % 双塔 1 个塔扇（中间）：进风带在鳍片前
            L = layout_set_cpu_fans(L, 1); snaps = [1 5 10];
        case 'cpupushpull'
            % 单塔推拉：鳍片为一个多孔区，前 + 后两个塔扇
            L.cpu = rmfield(L.cpu, 'tower'); snaps = [1 5 10];
        case 'cpulegacy'
            % v4.4.0 及以前的布局：无 tower、无 count（单塔 1 个前置塔扇），鳍片 120×104 mm
            L.cpu = rmfield(L.cpu, 'tower'); L.cpu.fan = rmfield(L.cpu.fan, 'count');
            L.cpu.fins = struct('x', 34, 'y', 86, 'w', 120, 'h', 104); L.cpu.base = struct('x', 70, 'y', 114, 'w', 48, 'h', 48);
            snaps = [1 5 10];
        case 'office'
            % 办公功率 + 静音曲线：显卡风扇低温停转、电源半被动停转
            P = [40 35 200]; L.fanCurves = fan_curve_profiles('quiet'); snaps = [1 5 10];
        case 'dvfs'
            % 性能曲线 + 自定义频率/漏电参数 + 低温度墙：降频、显卡风扇过 startAboveC 后重新起转
            P = [250 400 1000]; L.fanCurves = fan_curve_profiles('performance');
            L.cpu.dvfs = struct('softStartC', 30, 'softSlope', 0.01, 'minFreq', 0.6, 'powerExp', 2.5, ...
                                'leakShare', 0.2, 'leakRefC', 60, 'leakDoubleC', 20);
            L.cpu.throttleTemp = 45; L.gpu.dvfs = struct('minFreq', 0.7);
            snaps = [1 10 20 30];
        case 'blockinlet'
            % 固体块盖住 CPU 散热片与进风带：CPU 结温为 NaN，塔扇按温控曲线最低占空比（NaN 语义）；
            % 机箱风扇的传感器 max(CPU, GPU) 按 MATLAB max 忽略 NaN，跟随 GPU
            L.solidBlocks = struct('x', L.cpu.fins.x - 5, 'y', L.cpu.fins.y - 5, 'w', L.cpu.fins.w + 60, 'h', L.cpu.fins.h + 10);
            snaps = [1 3 5];
    end
    s = CFDSolverFEM(P(1), P(2), P(3), L, gs, DT);
    fn = fieldnames(props);
    for k = 1:numel(fn), s.(fn{k}) = props.(fn{k}); end
    snapsOut = cell(1, numel(snaps));
    for k = 1:numel(snaps)
        while s.iteration < snaps(k)
            for a = 1:numel(actions)
                if actions{a}.step == s.iteration, s.setComponentPower(actions{a}.name, actions{a}.watts); end
            end
            s.fluidStep();
        end
        snapsOut{k} = snapshot(s);
    end
    R = struct('name', caseName, 'powers', P, 'gridScale', gs, 'DT', DT, 'props', props, ...
        'actions', {actions}, 'layout', listifyLayout(L), 'snaps', {snapsOut});
end

function S = snapshot(s)
    S = struct('iteration', s.iteration, 'asmNu', s.nuAsmStep, 'asmAlpha', s.alphaAsmStep, 'asmNuT', s.nuTAsmStep, ...
        'betaRefStep', s.betaRefStep);
    F = struct('T', s.T_fluid, 'Tsolid', s.T_solid, 'uF', s.uF, 'vF', s.vF, 'p', s.p, 'pProj1', s.pProj1, ...
        'k', s.turbK, 'omega', s.turbOmega, 'nuStep', s.nuFieldStep, 'nuAssembled', s.nuFieldAssembled, ...
        'alphaAssembled', s.alphaFieldAssembled);
    if ~isempty(s.nuTAssembled), F.nuTAssembled = s.nuTAssembled; end
    if ~isempty(s.betaRefU), F.betaRefU = s.betaRefU(:); F.betaRefV = s.betaRefV(:); end
    fn = fieldnames(F);
    fp = struct();
    ins = sort(s.insideMask(:));
    inIdx = ins(unique(max(1, round(linspace(1, numel(ins), 200)))));
    for k = 1:numel(fn)
        fp.(fn{k}) = fingerprint(F.(fn{k}), s.GRID.TOTAL, inIdx);
    end
    S.fields = fp;
    tn = s.thermalNetworks; nm = fieldnames(tn);
    nets = struct();
    for j = 1:numel(nm)
        n = tn.(nm{j});
        nets.(nm{j}) = struct('Tj', n.T_junction, 'Tsink', n.T_sink_base, 'power', n.power, 'actual', n.actual_power, ...
            'h', n.h_conv, 'freq', n.freq_ratio, 'thd', n.throttled, 'over', n.overTemp);
    end
    S.nets = nets;
    Fa = s.allFans(); fans = cell(1, numel(Fa));
    for j = 1:numel(Fa)
        f = Fa{j};
        fans{j} = struct('rpm', f.getRPM(s), 'dp', f.lastDp, 'Q', f.lastQ, 'qr', f.lastQRatio, ...
            'ff', f.lastFlowFactor, 'nq', f.noiseQRatio, 'disk', s.diskFlow(f), 'stp', f.isStopped(s));
    end
    S.fans = fans;
end

function fp = fingerprint(x, nCells, inIdx)
    % 指纹：和、绝对值和、平方和、极值、加权和 Σ wᵢxᵢ（wᵢ = mod(7919·i, 997)/997 − 0.5，整数运算、两边逐位相同），
    % 抽样点：均匀 23 点，格心场另加机箱内均匀 200 点
    x = double(x(:));
    n = numel(x);
    idx = unique(max(1, round(linspace(1, n, 23))));
    if n == nCells, idx = unique([idx(:); inIdx(:)])'; end
    fin = isfinite(x);
    w = mod(7919 * (1:n)', 997) / 997 - 0.5;
    xf = x(fin); wf = w(fin);
    fp = struct('n', n, 'nNaN', sum(isnan(x)), 'sum', sum(xf), 'sumAbs', sum(abs(xf)), 'sumSq', sum(xf.^2), ...
        'max', max(xf), 'min', min(xf), 'proj', sum(wf .* xf), 'projAbs', sum(abs(wf .* xf)), ...
        'idx', idx, 'sample', x(idx).');
end

function L = listifyLayout(L)
    for nm = {'caseFans', 'vents', 'solidBlocks', 'porousBlocks'}
        if isfield(L, nm{1}) && isstruct(L.(nm{1}))
            L.(nm{1}) = num2cell(L.(nm{1})(:)');
        end
    end
    if isfield(L, 'shroud') && isfield(L.shroud, 'gaps') && isstruct(L.shroud.gaps)
        L.shroud.gaps = num2cell(L.shroud.gaps(:)');
    end
end
