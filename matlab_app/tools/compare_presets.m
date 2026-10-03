function R = compare_presets(gridScale, powers, names)
%COMPARE_PRESETS 无界面对比风扇布局预设：每个预设跑到稳态，汇总结温、噪音、风量、性能与评分。
%   R = compare_presets()                       预览网格（0.5）、默认功率、全部预设
%   R = compare_presets(1, [180 320 850])       精确网格、满载功率
%   R = compare_presets(0.5, [], {'balanced','front_top'})
%   返回 struct 数组（每预设一项），并打印对比表。
    if nargin < 1 || isempty(gridScale), gridScale = 0.5; end
    L0 = layout_default();
    if nargin < 2 || isempty(powers), powers = [L0.power.cpu L0.power.gpu L0.power.psu]; end
    P = fan_presets();
    if nargin < 3 || isempty(names), names = {P.name}; end
    R = struct('name', {}, 'label', {}, 'steps', {}, 'converged', {}, 'cpu', {}, 'gpu', {}, ...
               'psu', {}, 'interior', {}, 'cfm', {}, 'noiseDb', {}, 'intakeCfm', {}, 'exhaustCfm', {}, ...
               'perfPct', {}, 'score', {}, 'scoreCls', {}, 'seconds', {});
    for k = 1:numel(names)
        L = layout_apply_preset(L0, names{k});
        s = CFDSolverFEM(powers(1), powers(2), powers(3), L, gridScale);
        if gridScale < 1, s.turbUpdateEvery = 2; end
        t0 = tic;
        info = s.runToSteady();
        f = info.final;                          % 最近一个窗口的均值
        col = @(nm) f(strcmp(info.columns, nm));
        S = s.scenarioSummary();
        i = find(strcmp({P.name}, names{k}), 1);
        R(end+1) = struct('name', names{k}, 'label', P(i).label, 'steps', info.steps, ...
            'converged', info.converged, 'cpu', col('cpu'), 'gpu', col('gpu'), ...
            'psu', col('psu'), 'interior', col('interior'), 'cfm', col('cfm'), ...
            'noiseDb', S.noiseDb, 'intakeCfm', S.intakeCfm, 'exhaustCfm', S.exhaustCfm, ...
            'perfPct', S.perfPct, 'score', S.score, 'scoreCls', S.scoreCls, 'seconds', toc(t0)); %#ok<AGROW>
        fprintf(['[%d/%d] %-34s %4d 步  CPU %5.1f  GPU %5.1f  电源 %5.1f  内温 %5.1f  风量 %5.1f CFM  噪音 %4.1f dB  ' ...
                 '标称进/排 %.0f/%.0f  性能 %.1f%%  评分 %d（%s）\n'], ...
            k, numel(names), R(end).label, R(end).steps, R(end).cpu, R(end).gpu, R(end).psu, ...
            R(end).interior, R(end).cfm, R(end).noiseDb, R(end).intakeCfm, R(end).exhaustCfm, ...
            R(end).perfPct, R(end).score, R(end).scoreCls);
    end
end
