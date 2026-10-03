function R = compare_scenarios(presets, scenarios, protocol, outFile)
%COMPARE_SCENARIOS 风扇布局方案 × 场景（办公/游戏/满载）批量对比，与网页版"对比展示"页同口径
%   （web/src/compare/protocol.ts；规格见 docs/ALGORITHM.md §13）。
%   R = compare_scenarios()                                全部预设 × 三个场景，默认口径（280²，每个算例约 4000 步）
%   R = compare_scenarios({'balanced', 'positive'}, {'gaming'})
%   R = compare_scenarios([], [], struct('gridScale', 0.5))   改口径（缺的字段取默认）
%   R = compare_scenarios(..., 'out.json')                  另存为 JSON（字段同网页版 data.json 的 cases，不含缩略图）
%   只支持预设布局（网页版可另外加入自定义布局）；全局手动转速不改变布局里设为"手动"的单台风扇。
%   口径：每个算例从静止推进 autoSteps 步（自动温控），取第 autoAvgFrom 步之后每一步的均值（结温、机箱内均温、风量）
%   与阶段末的噪音、频率、评分；再依次关闭自动温控、全局手动转速 sweepPct(k)%，各接续推进 sweepSteps 步，
%   取第 sweepAvgFrom 步之后的均值（"同噪音 / 同温度"的公平比较用）。缺的元件为 NaN。
%   返回 struct 数组：preset、scenario、auto、sweep（各含 cpu、gpu、psu、interior、cfm、noiseDb、perfPct、freqCpu、
%   freqGpu、powerCpu、powerGpu、score、perf、thermal、noise、airflow、airK、cls、drift、fans；sweep 另含 pct）。
%   推进中出现非有限的温度（发散）时报错 compare_scenarios:diverged。
    def = compare_protocol_default();
    if nargin < 3 || isempty(protocol), p = def; else, p = struct_merge(def, protocol); end
    S = compare_scenario_list();
    P = fan_presets();
    if nargin < 1 || isempty(presets), presets = {P.name}; end
    if nargin < 2 || isempty(scenarios), scenarios = {S.key}; end
    if ischar(presets), presets = {presets}; end
    if ischar(scenarios), scenarios = {scenarios}; end
    R = struct('preset', {}, 'scenario', {}, 'auto', {}, 'sweep', {});
    for i = 1:numel(presets)
        for j = 1:numel(scenarios)
            sc = S(strcmp({S.key}, scenarios{j}));
            if isempty(sc), error('compare_scenarios:scenario', '未知场景：%s（应为 office/gaming/heavy）', scenarios{j}); end
            t0 = tic;
            L = layout_apply_preset(layout_default(), presets{i});
            s = CFDSolverFEM(sc.powers(1), sc.powers(2), sc.powers(3), L, p.gridScale);
            s.turbUpdateEvery = p.turbUpdateEvery;
            auto = runPhase(s, p.autoSteps, p.autoAvgFrom);
            sw = cell(1, numel(p.sweepPct));
            for k = 1:numel(p.sweepPct)
                s.autoFanEnabled = false;
                s.fanSpeedRatio = p.sweepPct(k);
                m = runPhase(s, p.sweepSteps, p.sweepAvgFrom);
                m.pct = p.sweepPct(k);
                sw{k} = m;
            end
            R(end+1) = struct('preset', presets{i}, 'scenario', sc.key, 'auto', auto, 'sweep', {sw}); %#ok<AGROW>
            fprintf('[%s/%s] CPU %5.1f  GPU %5.1f  电源 %5.1f  内温 %5.1f  风量 %5.1f CFM  噪音 %4.1f dB  性能 %.1f%%  评分 %d（%s）（%.0f s）\n', ...
                presets{i}, sc.key, auto.cpu, auto.gpu, auto.psu, auto.interior, auto.cfm, auto.noiseDb, auto.perfPct, ...
                auto.score, auto.cls, toc(t0));
        end
    end
    if nargin >= 4 && ~isempty(outFile)
        cases = cell(1, numel(R));
        for k = 1:numel(R), cases{k} = R(k); end
        fid = fopen(outFile, 'w');
        fwrite(fid, unicode2native(jsonencode(struct('protocol', p, 'cases', {cases})), 'UTF-8'));
        fclose(fid);
        fprintf('已写入 %s\n', outFile);
    end
end

function m = runPhase(s, steps, avgFrom)
    % 推进 steps 步：前 avgFrom 步一次推进，之后逐步推进并累加 [结温 cpu gpu psu, 内温, 风量]
    % 同时记录窗口内最高结温的漂移（后 1/4 均值 − 前 1/4 均值），判断是否已稳态
    if avgFrom > 0, s.stepMultiple(avgFrom); checkFinite(s); end
    acc = zeros(1, 5); n = 0;
    nW = steps - avgFrom; q = floor(nW / 4); tF = 0; tL = 0;
    for k = avgFrom + 1:steps
        s.stepMultiple(1);
        checkFinite(s);
        t = s.lastTemps;
        row = [tj(s, 'cpu') tj(s, 'gpu') tj(s, 'psu') t.internalAmbient t.totalCFM];
        acc = acc + row;
        tm = max(row(1:2));                        % max 忽略 NaN（缺元件）
        if n < q, tF = tF + tm; end
        if n >= nW - q, tL = tL + tm; end
        n = n + 1;
    end
    if q > 0, drift = (tL - tF) / q; else, drift = NaN; end
    mean5 = acc / max(n, 1);
    if n == 0, mean5(:) = NaN; end
    sc = s.calculateScores();
    [db, ~] = s.totalNoise();
    fl = s.fanStatusList();
    fans = cell(1, numel(fl));
    for k = 1:numel(fl)
        fans{k} = struct('name', fl(k).name, 'role', fl(k).role, 'rpm', fl(k).rpm, 'stopped', fl(k).stopped);
    end
    pw = @(nm) actualPower(s, nm);
    m = struct('cpu', mean5(1), 'gpu', mean5(2), 'psu', mean5(3), 'interior', mean5(4), 'cfm', mean5(5), ...
        'noiseDb', db, 'perfPct', sc.perfPct, 'freqCpu', sc.freqCpu, 'freqGpu', sc.freqGpu, ...
        'powerCpu', pw('cpu'), 'powerGpu', pw('gpu'), 'score', sc.total, 'perf', sc.perf, 'thermal', sc.thermal, ...
        'noise', sc.noise, 'airflow', sc.airflow, 'airK', sc.airK, 'cls', sc.cls, 'drift', drift, 'fans', {fans});
end

function T = tj(s, nm)
    if isfield(s.thermalNetworks, nm), T = s.thermalNetworks.(nm).T_junction; else, T = NaN; end
end

function P = actualPower(s, nm)
    if isfield(s.thermalNetworks, nm), P = s.thermalNetworks.(nm).actual_power; else, P = 0; end
end

function checkFinite(s)
    if ~all(isfinite(s.T_fluid))
        error('compare_scenarios:diverged', '计算发散（第 %d 步出现非有限的温度）', s.iteration);
    end
end
