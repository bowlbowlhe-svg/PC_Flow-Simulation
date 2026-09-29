function pass = test_noise()
%TEST_NOISE 噪音模型：分项公式、datasheet 端点、能量叠加、位置修正（各安装壁与内置风扇）、
%   封闭机箱内风扇的工作点修正、acoustics 部分覆盖与取值检查、"主要噪音来源"提示。
    errs = {};
    ac = acoustics_default();

    % 1) 分项公式
    p = fan_noise_terms(20, 1.0, 0, 0, ac);
    errs = check(errs, p.total == 20 && p.op == 0 && p.grille == 0, '自由出风、无格栅应无修正');
    p = fan_noise_terms(20, 0, 0, 0, ac);
    errs = check(errs, abs(p.op - ac.stallDb) < 1e-12, '堵死（q=0）应 +stallDb');
    p = fan_noise_terms(20, ac.stallQ/2, 0, 0, ac);
    errs = check(errs, abs(p.op - ac.stallDb/4) < 1e-12, 'q = stallQ/2 应 +stallDb/4');
    p = fan_noise_terms(20, 1, ac.grilleRefZeta, -3, ac);
    errs = check(errs, abs(p.grille - 10*log10(2)) < 1e-12 && abs(p.total - (20 + 10*log10(2) - 3)) < 1e-12, ...
        'ζ = ζref 应 +3.01 dB，位置修正直接相加');

    % 2) 单扇 datasheet 端点：P12 手动 100% 自由出风 = noise_max
    stub = struct('acoustics', ac, 'autoFanEnabled', false, 'fanSpeedRatio', 100);
    f = Fan(struct('id', 'x', 'role', 'case', 'model', 'P12', 'speedMode', 'manual', 'manualPct', 100));
    cat = fan_catalog();
    errs = check(errs, abs(f.getNoise(stub) - cat.P12.noise_max) < 1e-12, 'P12 满速自由出风应等于 datasheet 最大噪音');
    f.manualPct = 0;
    errs = check(errs, abs(f.getNoise(stub) - cat.P12.noise_idle) < 1e-12, 'P12 最低转速应等于 datasheet 怠速噪音');

    % 3) 能量叠加与位置修正（无元件的机箱，只有机箱风扇；未推进时 q = 1）
    L = layout_default();
    L = rmfield(L, {'cpu', 'gpu', 'psu'});
    one = L; one.caseFans = one.caseFans(1); one.caseFans.speedMode = 'manual'; one.caseFans.manualPct = 100;
    two = one; two.caseFans(2) = one.caseFans; two.caseFans(2).alongMm = 100;
    s1 = CFDSolverFEM(0, 0, 0, one, 0.5);
    s2 = CFDSolverFEM(0, 0, 0, two, 0.5);
    L1 = s1.totalNoise(); L2 = s2.totalNoise();
    expect1 = cat.P12.noise_max + 10*log10(1 + L.grille.intakeZeta / ac.grilleRefZeta) + ac.positionDb.front;
    errs = check(errs, abs(L1 - expect1) < 1e-9, sprintf('单台前进气应为 %.2f dB（实际 %.2f）', expect1, L1));
    errs = check(errs, abs(L2 - L1 - 10*log10(2)) < 1e-9, sprintf('两台相同风扇应 +3.01 dB（实际 %+.2f）', L2 - L1));
    rear = one; rear.caseFans.mount = 'rear'; rear.caseFans.alongMm = 124; rear.caseFans.type = 'exhaust';
    s3 = CFDSolverFEM(0, 0, 0, rear, 0.5);
    expect3 = cat.P12.noise_max + 10*log10(1 + L.grille.exhaustZeta / ac.grilleRefZeta) + ac.positionDb.rear;
    errs = check(errs, abs(s3.totalNoise() - expect3) < 1e-9, '后排气应含格栅与位置修正');

    % 4) 堵死的风扇：封闭机箱里只有一台进气风扇，净流量≈0 → 工作点修正趋向 +stallDb
    %    （流量比低通 τ = 0.5 s，推进 300 步 = 1.5 s 时约为稳态修正的 60–80%）
    s1.stepMultiple(300);
    [~, ~, parts] = s1.totalNoise();
    q = s1.fans{1}.noiseQRatio;
    errs = check(errs, q < 0.15 && parts(1).op > 0.5 * ac.stallDb, ...
        sprintf('封闭机箱内风扇 q 应≈0、工作点修正应接近 +%g dB（q = %.2f，修正 %+.1f dB）', ac.stallDb, q, parts(1).op));

    % 5) 默认场景：各扇位置与格栅修正按安装位置取值
    s = CFDSolverFEM([], [], [], [], 0.5);
    s.stepMultiple(100);
    fl = s.fanStatusList();
    allF = s.allFans();
    posOk = true; grOk = true;
    for k = 1:numel(fl)
        f = allF{k};
        if strcmp(f.role, 'case'), want = ac.positionDb.(f.mount); else, want = ac.positionDb.(f.role); end
        posOk = posOk && fl(k).noise.pos == want;
        if ~strcmp(f.role, 'case'), grOk = grOk && fl(k).noise.grille == 0; end
    end
    errs = check(errs, posOk, '各扇位置修正应按安装壁 / 内置位置取值');
    errs = check(errs, grOk, '内置风扇不应有格栅修正');

    % 6) acoustics 部分覆盖：只改 stallDb 与后壁位置，其余保持默认；非法参数报错
    Lp = layout_default();
    Lp.acoustics = struct('stallDb', 8, 'positionDb', struct('rear', -6));
    sp = CFDSolverFEM([], [], [], Lp, 0.5);
    errs = check(errs, sp.acoustics.stallDb == 8 && sp.acoustics.positionDb.rear == -6 && ...
        sp.acoustics.positionDb.front == ac.positionDb.front && sp.acoustics.stallQ == ac.stallQ, ...
        'acoustics 部分覆盖应只改指定字段');
    bad = {struct('grilleRefZeta', 0), struct('stalQ', 0.4), struct('positionDb', struct('frnt', 0))};
    for k = 1:numel(bad)
        Lb = layout_default(); Lb.acoustics = bad{k};
        try
            CFDSolverFEM([], [], [], Lb, 0.5);
            errs{end+1} = sprintf('非法 acoustics（第 %d 例）应报错', k); %#ok<AGROW>
        catch
        end
    end

    % 7) 只有一台风扇（无元件）时占比 100%，诊断提示主要噪音来源
    recs = s1.getRecommendations();
    titles = cellfun(@(r) r.title, recs, 'UniformOutput', false);
    fl1 = s1.fanStatusList();
    errs = check(errs, abs(fl1(1).sharePct - 100) < 1e-9 && any(strcmp(titles, '主要噪音来源')), ...
        '单台风扇应占 100% 并提示主要噪音来源');

    pass = isempty(errs);
    for k = 1:numel(errs), fprintf('  - %s\n', errs{k}); end
    if pass, st = 'PASS'; else, st = 'FAIL'; end
    fprintf('[noise] 分项公式 / datasheet 端点 / 叠加 / 位置 / 堵死风扇 %+.1f dB / 占比：%s\n', parts(1).op, st);
end

function errs = check(errs, cond, msg)
    if ~cond, errs{end+1} = msg; end
end
