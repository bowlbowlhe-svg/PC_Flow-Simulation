function pass = test_compare()
%TEST_COMPARE 方案 × 场景批量对比（tools/compare_scenarios，与网页版对比展示页同口径）：
%   缩短的口径下两个算例的字段、场景功率、扫描顺序与转速、JSON 输出；办公场景显卡风扇停转、满载档评分；
%   plot_compare 画图（只在 MATLAB 下检查）。
    errs = {};
    p = struct('gridScale', 0.5, 'turbUpdateEvery', 2, 'autoSteps', 24, 'autoAvgFrom', 12, ...
               'sweepPct', [40 100], 'sweepSteps', 10, 'sweepAvgFrom', 4);
    f = [tempname() '.json'];
    R = compare_scenarios({'positive', 'balanced'}, {'office', 'heavy'}, p, f);
    errs = check(errs, numel(R) == 4 && isequal({R.preset}, {'positive', 'positive', 'balanced', 'balanced'}) && ...
        isequal({R.scenario}, {'office', 'heavy', 'office', 'heavy'}), '应按 预设 × 场景 顺序返回 4 个算例');
    a = R(1).auto;
    flds = {'cpu', 'gpu', 'psu', 'interior', 'cfm', 'noiseDb', 'perfPct', 'freqCpu', 'freqGpu', 'powerCpu', 'powerGpu', ...
            'score', 'perf', 'thermal', 'noise', 'airflow', 'airK', 'cls', 'fans'};
    errs = check(errs, all(isfield(a, flds)) && strcmp(a.cls, 'office') && strcmp(R(2).auto.cls, 'heavy'), ...
        '结果应含全部字段，办公/满载各落其档');
    st = cellfun(@(x) x.stopped, a.fans);
    roles = cellfun(@(x) x.role, a.fans, 'UniformOutput', false);
    errs = check(errs, sum(st & strcmp(roles, 'gpu')) == 3, '办公场景显卡风扇应低温停转');
    sw = R(2).sweep;
    errs = check(errs, numel(sw) == 2 && sw{1}.pct == 40 && sw{2}.pct == 100 && sw{2}.noiseDb > sw{1}.noiseDb, ...
        '扫描应依次为 40%、100%，转速越高越吵');
    fl = cellfun(@(x) x.rpm, sw{2}.fans);
    errs = check(errs, all(fl > 0) && ~any(cellfun(@(x) x.stopped, sw{2}.fans)), '全局手动转速下风扇不停转');
    errs = check(errs, abs(a.cfm) > 0 && isfinite(a.cpu) && a.cpu > 25, '均值应有限');
    txt = fileread(f);
    D = jsondecode(txt);
    errs = check(errs, isfield(D, 'protocol') && numel(D.cases) == 4 && D.protocol.autoSteps == 24, 'JSON 应含口径与 4 个算例');
    delete(f);
    % 画图（不显示窗口）。Octave 无界面环境下创建坐标轴会失败（字体渲染），只在 MATLAB 下检查
    if exist('OCTAVE_VERSION', 'builtin')
        fprintf('    （Octave 下跳过 plot_compare 的检查：无界面环境不能创建坐标轴）\n');
    else
        try
            fig = plot_compare(R, 'heavy', 'off');
            errs = check(errs, ishandle(fig), 'plot_compare 应返回图窗');
            close(fig);
        catch ME
            errs{end+1} = ['plot_compare 出错：' ME.message];
        end
    end
    def = compare_protocol_default();
    S = compare_scenario_list();
    errs = check(errs, def.gridScale == 1 && def.autoSteps == 1600 && isequal(def.sweepPct, [40 70 100]) && ...
        isequal(S(3).powers, [180 320 850]), '默认口径与场景功率应同网页版');
    try
        compare_scenarios({'balanced'}, {'nosuch'}, p);
        errs{end+1} = '未知场景应报错';
    catch ME
        errs = check(errs, strcmp(ME.identifier, 'compare_scenarios:scenario'), ['错误标识：' ME.identifier]);
    end
    pass = isempty(errs);
    for k = 1:numel(errs), fprintf('  - %s\n', errs{k}); end
    if pass, s = 'PASS'; else, s = 'FAIL'; end
    fprintf('[compare] 方案 × 场景批量对比（缩短口径）：%s\n', s);
end

function errs = check(errs, cond, msg)
    if ~cond, errs{end+1} = msg; end
end
