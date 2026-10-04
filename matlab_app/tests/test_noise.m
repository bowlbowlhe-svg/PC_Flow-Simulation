function pass = test_noise()
%TEST_NOISE 噪音模型：分项公式（含鳍片附加、可低于 0 dB、停转）、风扇定律、能量叠加、位置修正（各安装壁与内置风扇）、
%   封闭机箱内风扇的工作点修正、acoustics 部分覆盖与取值检查、"主要噪音来源"提示、
%   显卡低温停转与电源半被动（回差、办公场景停转、不计噪音）；v4.9.0：低转速底噪、时转时停的判定与感知噪音、
%   型号库噪音的实测口径。
    errs = {};
    ac = acoustics_default();
    ac0 = ac; ac0.floorDb = -300;               % 关掉底噪，单看气动各项

    % 1) 分项公式
    p = fan_noise_terms(20, 1.0, 0, 0, 0, ac0);
    errs = check(errs, p.total == 20 && p.op == 0 && p.grille == 0, '自由出风、无格栅应无修正');
    p = fan_noise_terms(20, 0, 0, 0, 0, ac0);
    errs = check(errs, abs(p.op - ac.stallDb) < 1e-12, '堵死（q=0）应 +stallDb');
    p = fan_noise_terms(20, ac.stallQ/2, 0, 0, 0, ac0);
    errs = check(errs, abs(p.op - ac.stallDb/4) < 1e-12, 'q = stallQ/2 应 +stallDb/4');
    p = fan_noise_terms(20, 1, ac.grilleRefZeta, 0, -3, ac0);
    errs = check(errs, abs(p.grille - 10*log10(2)) < 1e-12 && abs(p.total - (20 + 10*log10(2) - 3)) < 1e-12, ...
        'ζ = ζref 应 +3.01 dB，位置修正直接相加');
    p = fan_noise_terms(20, 1, 0, ac.finDb, 0, ac0);
    errs = check(errs, abs(p.total - (20 + ac.finDb)) < 1e-12 && p.fin == ac.finDb, '鳍片附加应直接相加');
    p = fan_noise_terms(-8, 1, 0, 0, -3, ac0);
    errs = check(errs, p.total == -11, '单扇可低于 0 dB(A)（只对总噪音取 0 下限，听不见的风扇不会叠加出声音）');
    p = fan_noise_terms(-Inf, 0, 0, 2, 0, ac);
    errs = check(errs, p.total == -Inf && p.floor == 0, '停转（转速主项 −Inf）总噪音应为 −Inf，没有底噪');
    % 底噪：与气动噪音按能量相加，位置修正加在相加之后
    p = fan_noise_terms(0, 1, 0, 0, -3, ac);
    want = 10*log10(1 + 10^(ac.floorDb/10));
    errs = check(errs, abs(p.total - (want - 3)) < 1e-12 && abs(p.floor - want) < 1e-12, ...
        sprintf('0 dB 的风扇加 %g dB 底噪应为 %.2f dB（再 −3 位置）', ac.floorDb, want));
    p = fan_noise_terms(30, 1, 0, 0, 0, ac);
    errs = check(errs, p.floor > 0 && p.floor < 0.05, '转速高时底噪几乎不起作用（30 dB 时 +0.03 dB）');

    % 2) 风扇定律：P12 手动 100% 自由出风 = noise_max；半速低 50·log10(2) = 15.05 dB；转速不低于 rpm_min
    stub = struct('acoustics', ac0, 'autoFanEnabled', false, 'fanSpeedRatio', 100);
    f = Fan(struct('id', 'x', 'role', 'case', 'model', 'P12', 'speedMode', 'manual', 'manualPct', 100));
    cat = fan_catalog();
    errs = check(errs, abs(f.getNoise(stub) - cat.P12.noise_max) < 1e-12, 'P12 满速自由出风应等于 datasheet 最大噪音');
    f.manualPct = 50;
    errs = check(errs, abs(f.getNoise(stub) - (cat.P12.noise_max - 50*log10(2))) < 1e-12 && f.getRPM(stub) == 900, ...
        'P12 半速应为 900 rpm、比满速低 15.05 dB');
    f.manualPct = 5;
    errs = check(errs, f.getRPM(stub) == cat.P12.rpm_min, '占空比过低时转速应为 rpm_min');
    % 型号库噪音为实测口径（Cybenetics，1 m）：在实测转速处按风扇定律折回应与实测相符
    meas = {'NF_A12', 2134, 31.3; 'P12', 1889, 28.6; 'P14', 1769, 31.9; 'T30', 2000, 32.1};
    for k = 1:size(meas, 1)
        sp = cat.(meas{k, 1});
        Lm = sp.noise_max + 50*log10(meas{k, 2} / sp.rpm_max);
        errs = check(errs, abs(Lm - meas{k, 3}) < 0.1, sprintf('%s %d rpm 应接近实测 %.1f dB(A)（%.2f）', ...
            meas{k, 1}, meas{k, 2}, meas{k, 3}, Lm));
    end

    % 3) 能量叠加与位置修正（无元件的机箱，只有机箱风扇；未推进时 q = 1）
    L = layout_default();
    L = rmfield(L, {'cpu', 'gpu', 'psu'});
    one = L; one.caseFans = one.caseFans(1); one.caseFans.speedMode = 'manual'; one.caseFans.manualPct = 100;
    two = one; two.caseFans(2) = one.caseFans; two.caseFans(2).alongMm = 100;
    s1 = CFDSolverFEM(0, 0, 0, one, 0.5);
    s2 = CFDSolverFEM(0, 0, 0, two, 0.5);
    L1 = s1.totalNoise(); L2 = s2.totalNoise();
    withFloor = @(a) 10*log10(10^(a/10) + 10^(ac.floorDb/10));
    expect1 = withFloor(cat.P12.noise_max + 10*log10(1 + L.grille.intakeZeta / ac.grilleRefZeta)) + ac.positionDb.front;
    errs = check(errs, abs(L1 - expect1) < 1e-9, sprintf('单台前进气应为 %.2f dB（实际 %.2f）', expect1, L1));
    errs = check(errs, abs(L2 - L1 - 10*log10(2)) < 1e-9, sprintf('两台相同风扇应 +3.01 dB（实际 %+.2f）', L2 - L1));
    rear = one; rear.caseFans.mount = 'rear'; rear.caseFans.alongMm = 124; rear.caseFans.type = 'exhaust';
    s3 = CFDSolverFEM(0, 0, 0, rear, 0.5);
    expect3 = withFloor(cat.P12.noise_max + 10*log10(1 + L.grille.exhaustZeta / ac.grilleRefZeta)) + ac.positionDb.rear;
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
    finOk = true;
    for k = 1:numel(fl)
        if any(strcmp(allF{k}.role, {'cpu', 'gpu'})), want = ac.finDb; else, want = 0; end
        finOk = finOk && fl(k).noise.fin == want;
    end
    errs = check(errs, finOk, '塔扇、显卡风扇应有鳍片附加噪音，其它风扇没有');

    % 6) acoustics 部分覆盖：只改 stallDb 与后壁位置，其余保持默认；非法参数报错
    Lp = layout_default();
    Lp.acoustics = struct('stallDb', 8, 'positionDb', struct('rear', -6));
    sp = CFDSolverFEM([], [], [], Lp, 0.5);
    errs = check(errs, sp.acoustics.stallDb == 8 && sp.acoustics.positionDb.rear == -6 && ...
        sp.acoustics.positionDb.front == ac.positionDb.front && sp.acoustics.stallQ == ac.stallQ, ...
        'acoustics 部分覆盖应只改指定字段');
    bad = {struct('grilleRefZeta', 0), struct('stalQ', 0.4), struct('positionDb', struct('frnt', 0)), ...
           struct('floorDb', NaN), struct('intermittentDb', -1), struct('cycleWindowS', 0)};
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

    % 8) 显卡低温停转、电源半被动：回差；办公场景（40/35/200 W）里都停转、不计入噪音
    C = fan_curve_profiles('standard');
    st = struct('autoFanEnabled', true, 'fanSpeedRatio', 40, 'fanCurves', C, 'acoustics', ac, 'iteration', 0, 'DT', 0.005);
    g = Fan(struct('id', 'g', 'role', 'gpu', 'model', 'GPU80', 'sensor', 'gpu'));
    seq = [45 52 56 52 49]; want = [true true false false true];
    got = false(size(seq));
    for k = 1:numel(seq)
        st.sensorTemp = @(~) seq(k);
        st.iteration = 100 * k;
        g.updateControl(st);
        got(k) = g.isStopped(st);
    end
    errs = check(errs, isequal(got, want), sprintf('显卡停转回差：45/52/56/52/49°C 应为 停/停/转/转/停（%s）', mat2str(got)));
    % 时转时停：上面 500 步（2.5 s）里停—转—停切换了 3 次 → 判为时转时停；感知噪音按最近一次转动的转速 + 间歇性修正
    errs = check(errs, isequal(g.toggleIter, [100 300 500]) && g.isCycling(st), ...
        sprintf('启停切换应记下步号 [100 300 500] 并判为时转时停（%s）', mat2str(g.toggleIter)));
    g.lastRunRpm = 1300;
    pr = fan_noise_terms(cat.GPU80.noise_max + 50*log10(1300 / cat.GPU80.rpm_max), g.noiseQRatio, 0, ac.finDb, 0, ac);
    errs = check(errs, abs(g.ratingNoise(st) - (pr.total + ac.intermittentDb)) < 1e-12, ...
        '停转中的时转时停风扇：感知噪音 = 最近转动转速下的声级 + intermittentDb');
    st.iteration = 500 + round(ac.cycleWindowS / st.DT) + 1;      % 窗口外
    errs = check(errs, ~g.isCycling(st) && g.ratingNoise(st) == -Inf, '超过 cycleWindowS 不再算时转时停');
    st.iteration = 600; st.autoFanEnabled = false;
    errs = check(errs, ~g.isCycling(st), '关闭自动温控时不算时转时停');
    st.autoFanEnabled = true;
    % 手动与自动温控来回切换不算启停：手动时清空记录，回到自动温控后的首次判定不记
    g3 = Fan(struct('id', 'g3', 'role', 'gpu', 'model', 'GPU80', 'sensor', 'gpu'));
    st.sensorTemp = @(~) 45;
    g3.updateControl(st, false);                                  % 初始化：停转
    for k = 1:3
        st.iteration = 600 + 10 * k; st.autoFanEnabled = false;
        g3.updateControl(st);                                     % 关闭自动温控：一直转
        st.autoFanEnabled = true;
        g3.updateControl(st);                                     % 回到自动温控：45°C 又停
    end
    errs = check(errs, isempty(g3.toggleIter) && g3.isStopped(st) && ~g3.isCycling(st), ...
        sprintf('手动与自动温控来回切换不应记为启停（%s）', mat2str(g3.toggleIter)));
    seq4 = [56 49 56 49 56 49];                                   % 6 次切换只留最近 4 次
    for k = 1:numel(seq4)
        st.sensorTemp = @(~) seq4(k); st.iteration = 1000 + k;
        g3.updateControl(st);
    end
    errs = check(errs, isequal(g3.toggleIter, 1003:1006) && g3.isCycling(st), ...
        sprintf('只保留最近 4 次切换的步号（%s）', mat2str(g3.toggleIter)));
    g2 = Fan(struct('id', 'g2', 'role', 'gpu', 'model', 'GPU80', 'sensor', 'gpu'));
    st.sensorTemp = @(~) 45;
    g2.updateControl(st, false);
    errs = check(errs, isempty(g2.toggleIter) && g2.isStopped(st), '初始化时的首次判定不记启停');
    st.sensorTemp = @(~) 45;
    errs = check(errs, g.getRPM(st) == 0 && g.getCFM(st) == 0 && g.baseNoise(st) == -Inf, '停转时转速、风量为 0，噪音 −Inf');
    ps = Fan(struct('id', 'p', 'role', 'psu', 'model', 'PSU120', 'sensor', 'psu'));
    st.psuLoadRatio = @() 0.2;
    seqP = [50 62 66 58]; wantP = [true true false true];     % 停转后要升到 65°C 才转，转动中降到 60°C 以下才停
    gotP = false(size(seqP));
    for k = 1:numel(seqP)
        st.sensorTemp = @(~) seqP(k);
        ps.updateControl(st);
        gotP(k) = ps.isStopped(st);
    end
    errs = check(errs, isequal(gotP, wantP), sprintf('电源半被动回差：50/62/66/58°C 应为 停/停/转/停（%s）', mat2str(gotP)));
    st.psuLoadRatio = @() 0.5; st.sensorTemp = @(~) 40;
    ps.updateControl(st);
    errs = check(errs, ~ps.isStopped(st), '负载率 ≥ 40% 时电源风扇应一直转');
    so = CFDSolverFEM(40, 35, 200, [], 0.5);
    fl0 = so.fanStatusList();                  % 推进前即按初始温度判定（与第 1 步相同）
    errs = check(errs, sum(strcmp({fl0([fl0.stopped]).role}, 'gpu')) == 3 && any(strcmp({fl0([fl0.stopped]).role}, 'psu')), ...
        '推进前的风扇状态应已按室温判定停转');
    so.stepMultiple(100);
    flo = so.fanStatusList();
    stopRoles = {flo([flo.stopped]).role};
    [dbo, perFano] = so.totalNoise();
    errs = check(errs, sum(strcmp(stopRoles, 'gpu')) == 3 && any(strcmp(stopRoles, 'psu')) && ...
        all(isinf(perFano([flo.stopped]))) && isfinite(dbo), '办公场景：3 台显卡风扇与电源风扇应停转、不计入噪音');
    errs = check(errs, ~any([flo.cycling]), '办公场景首次停转后不应判为时转时停');

    % 9) 求解器里的时转时停：显卡风扇在窗口内启停 2 次 → 状态表标出、感知噪音 > 物理噪音、评分噪音分降低、给出建议
    sc = CFDSolverFEM(100, 200, 500, [], 0.5);
    sc.stepMultiple(20);
    sc0 = sc.calculateScores();
    [db0, ~, ~, r0] = sc.totalNoise();
    gf = sc.findFan('gpu');
    gf.toggleIter = [sc.iteration - 50, sc.iteration - 10];
    [db1, ~, ~, r1] = sc.totalNoise();
    sc1 = sc.calculateScores();
    flc = sc.fanStatusList();
    recs = sc.getRecommendations();
    titles = cellfun(@(r) r.title, recs, 'UniformOutput', false);
    errs = check(errs, abs(r0 - db0) < 1e-12 && db1 == db0 && r1 > db0 + 0.1 && sc1.noise <= sc0.noise && ...
        sum([flc.cycling]) == 1 && any(strcmp(titles, '显卡风扇时转时停')), ...
        sprintf('时转时停：感知噪音 %.2f → %.2f dB（物理 %.2f），噪音分 %d → %d，应有提示', r0, r1, db1, sc0.noise, sc1.noise));

    pass = isempty(errs);
    for k = 1:numel(errs), fprintf('  - %s\n', errs{k}); end
    if pass, st = 'PASS'; else, st = 'FAIL'; end
    fprintf('[noise] 分项公式 / 风扇定律 / 叠加 / 位置 / 堵死风扇 %+.1f dB / 占比：%s\n', parts(1).op, st);
end

function errs = check(errs, cond, msg)
    if ~cond, errs{end+1} = msg; end
end
