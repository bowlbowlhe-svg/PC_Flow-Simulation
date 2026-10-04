function pass = test_thermal()
%TEST_THERMAL 元件热网络的频率与功率控制（DetailedThermalNetwork，v4.6.0 起）：
%   1) 散热良好：未触温度墙，频率 = 加速频率（随结温线性下降），功率 = 动态 φ³ + 漏电，稳态结温自洽；
%   2) 散热差：温度墙把结温压在降频阈（±0.05°C），频率低于加速频率；散热越好频率越高；
%   2b) 漏电强、散热差（R·P_nom > 120 K）：温度墙仍把结温压在降频阈，不在最低频率以上过热；
%   3) 极差：降到最低频率仍压不住，置过热；
%   4) 漏电：同频率下结温越高功率越大；
%   5) 电源：不降频，超过告警温度置 overTemp；
%   6) 求解器：高功率（300/500/1200 W）、全局手动 30% 转速推进后显卡触发温度墙，评分的性能项下降、建议提示降频。
    errs = {};
    L = layout_default();
    spec = struct('thermal', L.cpu.thermal, 'dvfs', layout_dvfs(L, 'cpu'));
    d = spec.dvfs;
    run = @(P, V, Tin) settle(DetailedThermalNetwork('cpu', P, L.cpu.tjmax, L.cpu.throttleTemp, spec), V, Tin);

    % 1) 散热良好
    n = run(125, 2.0, 30);
    phiSoft = 1 - d.softSlope * max(0, n.T_junction - d.softStartC);
    Pexp = 125 * ((1 - d.leakShare) * n.freq_ratio^d.powerExp + d.leakShare * 2^((n.T_junction - d.leakRefC) / d.leakDoubleC));
    errs = check(errs, ~n.throttled && abs(n.freq_ratio - phiSoft) < 1e-6 && abs(n.actual_power - Pexp) < 1e-9 && ...
        abs(n.T_junction - (30 + n.actual_power * n.R_total)) < 1e-4 && n.T_junction < L.cpu.throttleTemp, ...
        sprintf('散热良好：应只按加速频率降频、稳态自洽（Tj %.2f°C，φ %.4f）', n.T_junction, n.freq_ratio));

    % 2) 散热差：温度墙
    n2 = run(250, 0.3, 45);
    phiSoft2 = 1 - d.softSlope * max(0, n2.T_junction - d.softStartC);
    errs = check(errs, n2.throttled && abs(n2.T_junction - L.cpu.throttleTemp) < 0.05 && n2.freq_ratio < phiSoft2 - 0.01, ...
        sprintf('散热差：温度墙应把结温压在 %g°C（Tj %.3f°C，φ %.3f）', L.cpu.throttleTemp, n2.T_junction, n2.freq_ratio));
    n3 = run(250, 0.6, 45);
    errs = check(errs, n3.freq_ratio > n2.freq_ratio, sprintf('散热越好频率应越高（%.3f → %.3f）', n2.freq_ratio, n3.freq_ratio));

    % 2b) 漏电强：250 W、鳍片处风速 0.1 m/s、进风 40°C（R·P ≈ 119 K，按 T_limit 处漏电计的旧写法会越过降频阈过热）
    n5 = run(250, 0.1, 40);
    errs = check(errs, abs(n5.T_junction - L.cpu.throttleTemp) < 0.05 && ~n5.overTemp && n5.freq_ratio > d.minFreq + 0.02, ...
        sprintf('漏电强、散热差：应压在降频阈且不过热（Tj %.2f°C，φ %.3f）', n5.T_junction, n5.freq_ratio));

    % 3) 极差：最低频率仍压不住
    n4 = run(300, 0, 85);
    errs = check(errs, abs(n4.freq_ratio - d.minFreq) < 1e-6 && n4.overTemp && n4.T_junction > L.cpu.tjmax, ...
        sprintf('极差：应降到最低频率 %g 并置过热（φ %.3f，Tj %.1f°C）', d.minFreq, n4.freq_ratio, n4.T_junction));

    % 4) 漏电：同频率（关闭加速降频、远离温度墙）下进风越热功率越大
    spec0 = spec; spec0.dvfs.softSlope = 0;
    a = settle(DetailedThermalNetwork('cpu', 100, 200, 190, spec0), 2.0, 25);
    b = settle(DetailedThermalNetwork('cpu', 100, 200, 190, spec0), 2.0, 45);
    errs = check(errs, a.freq_ratio == 1 && b.freq_ratio == 1 && b.actual_power > a.actual_power + 1, ...
        sprintf('漏电：进风 25 → 45°C 功率应增大（%.1f → %.1f W）', a.actual_power, b.actual_power));

    % 5) 电源
    p = DetailedThermalNetwork('psu', 60, 100, 85, []);
    p.canThrottle = false; p.R_internal = 0.25;
    p = settle(p, 0.05, 40);
    errs = check(errs, p.freq_ratio == 1 && p.actual_power == 60 && p.overTemp == (p.T_junction > 85), '电源不应降频');

    % 6) 求解器：高功率
    s = CFDSolverFEM(300, 500, 1200, [], 0.5);
    s.autoFanEnabled = false; s.fanSpeedRatio = 30;     % 风扇慢转（v4.8 的显卡散热器在自动温控下 500 W 不触发温度墙）
    s.stepMultiple(400);
    g = s.thermalNetworks.gpu;
    sc = s.calculateScores();
    recs = s.getRecommendations();
    titles = cellfun(@(r) r.title, recs, 'UniformOutput', false);
    errs = check(errs, g.throttled && g.freq_ratio < 0.97 && abs(g.T_junction - s.layout.gpu.throttleTemp) < 2 && ...
        sc.perf < 100 && strcmp(sc.cls, 'heavy') && any(strcmp(titles, 'GPU触发温度墙降频')), ...
        sprintf('高功率：显卡应触发温度墙（Tj %.1f°C，φ %.3f，性能分 %d）', g.T_junction, g.freq_ratio, sc.perf));

    pass = isempty(errs);
    for k = 1:numel(errs), fprintf('  - %s\n', errs{k}); end
    if pass, st = 'PASS'; else, st = 'FAIL'; end
    fprintf('[thermal] 加速频率 / 温度墙 %.2f°C / 最低频率与过热 / 漏电 / 电源 / 求解器降频：%s\n', n2.T_junction, st);
end

function n = settle(n, V, Tin)
    for k = 1:4000
        n.solve(V, Tin, 0.005);
    end
end

function errs = check(errs, cond, msg)
    if ~cond, errs{end+1} = msg; end
end
