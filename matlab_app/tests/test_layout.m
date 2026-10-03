function pass = test_layout()
%TEST_LAYOUT 布局配置工具链：安装位读写、预设、JSON 往返、安装检查。
%   1) 默认布局的安装位读出 → 写回，机箱风扇不变；
%   2) 每个预设都能构建求解器，机箱风扇数与预设一致；
%   3) JSON 往返：默认布局逐字段一致；含 NaN 壁温（绝热）的方腔布局往返后可构建；
%   4) 安装检查：同壁重叠、超出壁面能报出，标称风量与压力状态正确。
    errs = {};
    L0 = layout_default();

    % 1) 安装位往返
    st = layout_slots('get', L0);
    L1 = layout_slots('set', L0, st);
    errs = check(errs, isequal(sortFans(L1.caseFans), sortFans(L0.caseFans)), '安装位读出写回后机箱风扇应不变');
    errs = check(errs, sum(~strcmp({st.type}, 'none')) == numel(L0.caseFans), '默认布局的风扇都应在安装位上');

    % 2) 预设
    P = fan_presets();
    for k = 1:numel(P)
        L = layout_apply_preset(L0, P(k).name);
        s = CFDSolverFEM([], [], [], L, 0.5);
        errs = check(errs, numel(s.fans) == size(P(k).fans, 1), sprintf('预设 %s 风扇数', P(k).name));
        nFanOpen = sum(strcmp({s.openings.kind}, 'fan'));
        errs = check(errs, nFanOpen == numel(s.fans), sprintf('预设 %s 每台机箱风扇应有开口', P(k).name));
    end

    % 3) JSON 往返
    f = [tempname() '.json'];
    layout_json('save', L0, f);
    L2 = layout_json('load', f);
    errs = check(errs, isequal(L2, L0), '默认布局 JSON 往返应逐字段一致');
    Lc = layout_benchmark('cavity', 1e4);
    layout_json('save', Lc, f);
    Lc2 = layout_json('load', f);
    errs = check(errs, isnan(Lc2.chassis.wallTempC.top), 'NaN 壁温往返后应仍为 NaN');
    raw = jsondecode(fileread(f));                % 不经 normalize 直接构建也不应失败
    try
        CFDSolverFEM(0, 0, 0, raw, 0.5);
    catch ME
        errs{end+1} = ['未规整的 JSON 布局构建失败：' ME.message];
    end
    delete(f);

    % 4) 安装检查
    R = layout_fan_report(L0);
    errs = check(errs, isempty(R.warnings), '默认布局不应有安装警告');
    errs = check(errs, abs(R.intakeCfm - 112.6) < 0.01 && abs(R.exhaustCfm - 121.3) < 0.01 && strcmp(R.pressure, '平衡'), ...
        '默认布局满速标称进/排 112.6/121.3 CFM、平衡');
    % 低速（机箱风扇曲线最低占空比 20%）：P12 max(200, 0.2·1800) = 360 rpm → 11.26 CFM；
    % Stock120 max(600, 0.2·2200) = 600 rpm → 17.73 CFM
    errs = check(errs, abs(R.intakeCfmIdle - 22.52) < 0.01 && abs(R.exhaustCfmIdle - 28.99) < 0.01 && ...
        strcmp(R.pressureIdle, '负压'), '默认布局低速标称进/排 22.5/29.0 CFM、负压');
    L3 = L0;
    L3.caseFans(end+1) = L3.caseFans(1);
    L3.caseFans(end).alongMm = L3.caseFans(1).alongMm - 60;     % 同壁重叠 60 mm
    L3.caseFans(end+1) = L3.caseFans(1);
    L3.caseFans(end).alongMm = 380;                             % 超出前壁
    R3 = layout_fan_report(L3);
    errs = check(errs, numel(R3.warnings) >= 2, '应报出重叠与超出壁面');
    for k = 1:numel(P)                                          % 预设都应无安装警告
        Rk = layout_fan_report(layout_apply_preset(L0, P(k).name));
        errs = check(errs, isempty(Rk.warnings), sprintf('预设 %s 不应有安装警告', P(k).name));
    end
    Lc4 = L0;                                                    % 角部相碰：前壁靠顶的风扇与顶壁靠前的风扇
    Lc4.caseFans = [Lc4.caseFans(1); Lc4.caseFans(4)];
    Lc4.caseFans(1).alongMm = 70;  Lc4.caseFans(2).alongMm = 255;
    Rc = layout_fan_report(Lc4);
    errs = check(errs, numel(Rc.warnings) == 1 && any(contains_(Rc.warnings, '角部')), ...
        sprintf('前 70 / 顶 255 应只报角部相碰（%s）', strjoin(Rc.warnings, '；')));
    Lr = L0; Lr.caseFans(4).alongMm = 270;                      % 顶壁按机箱深（320 mm）判断超出
    Rr = layout_fan_report(Lr);
    errs = check(errs, any(contains_(Rr.warnings, '超出壁面')), '顶壁 270 mm 的风扇应超出 320 mm 深的机箱');

    % 4b) 显卡厚度：默认 4 槽与 layout_set_gpu_slots 一致；各槽数的散热片高度；放不下时报错
    errs = check(errs, isequal(layout_set_gpu_slots(L0, 4), L0) && layout_gpu_slots(L0) == 4, ...
        '默认布局应为 4 槽显卡');
    hs = arrayfun(@(sl) getfield(getfield(getfield(layout_set_gpu_slots(L0, sl), 'gpu'), 'heatsink'), 'h'), [2.5 3 3.5 4]);
    errs = check(errs, isequal(hs, [27 37 47 57]), sprintf('2.5/3/3.5/4 槽散热片高度应为 27/37/47/57 mm（%s）', mat2str(hs)));
    Lt = L0; Lt.shroud.yMm = 290;
    try
        layout_set_gpu_slots(Lt, 4);
        errs{end+1} = '显卡风扇与挡板间隙不足时应报错';
    catch
    end
    Lold = L0; Lold.gpu = rmfield(Lold.gpu, 'slots');
    errs = check(errs, layout_gpu_slots(Lold) == 4, '无 slots 字段的旧布局应按厚度折算槽数');

    % 4c) CPU 双塔散热器：默认双塔 2 扇（前 + 中）；1 扇装中间；单塔 1 扇前置、2 扇前 + 后；旧布局按单塔 1 扇
    tw = layout_cpu_tower(L0);
    errs = check(errs, tw.stacks == 2 && tw.gapMm == 24 && tw.fans == 2 && isequal(tw.pos, {'front', 'mid'}), ...
        '默认应为双塔、间隙 24 mm、2 个塔扇（前 + 中）');
    errs = check(errs, isequal(layout_set_cpu_fans(L0, 2), L0), 'layout_set_cpu_fans(L0, 2) 应不改默认布局');
    L1f = layout_set_cpu_fans(L0, 1);
    tw1 = layout_cpu_tower(L1f);
    errs = check(errs, tw1.fans == 1 && isequal(tw1.pos, {'mid'}), '双塔 1 扇应装在中间');
    try
        layout_set_cpu_fans(L0, 3);
        errs{end+1} = '塔扇数量 3 应报错';
    catch
    end
    Ls = L0; Ls.cpu = rmfield(Ls.cpu, 'tower');
    tws = layout_cpu_tower(Ls);
    errs = check(errs, tws.stacks == 1 && tws.gapMm == 0 && isequal(tws.pos, {'front', 'rear'}), '单塔 2 扇应为前 + 后');
    Lo = Ls; Lo.cpu.fan = rmfield(Lo.cpu.fan, 'count');
    two = layout_cpu_tower(Lo);
    errs = check(errs, two.fans == 1 && isequal(two.pos, {'front'}), '无 tower、无 count 的旧布局应为单塔 1 个前置塔扇');
    Lbad = L0; Lbad.cpu.tower.gapMm = 200;
    try
        layout_cpu_tower(Lbad);
        errs{end+1} = '间隙超过鳍片外廓宽时应报错';
    catch
    end
    for gs = [0.5 1]
        sv = CFDSolverFEM([], [], [], L0, gs);
        hs = sv.CPU_HEATSINK; fin = hs.fin_area; st = hs.stacks; gp = hs.gap;
        tag = sprintf('（网格 %d）', sv.GRID.W);
        errs = check(errs, numel(st) == 2 && st(1).w == st(2).w && st(1).x == fin.x && ...
            gp.x == st(1).x + st(1).w && st(2).x == gp.x + gp.w && st(2).x + st(2).w == fin.x + fin.w, ...
            ['双塔：两组鳍片等宽、间隙夹在中间、合起来正好是外廓' tag]);
        cf = sv.builtInFans(cellfun(@(f) strcmp(f.role, 'cpu'), sv.builtInFans));
        errs = check(errs, numel(cf) == 2 && strcmp(cf{1}.pos, 'front') && strcmp(cf{2}.pos, 'mid') && ...
            cf{1}.cols(1) == fin.x + fin.w && cf{2}.cols(1) >= gp.x && cf{2}.cols(2) <= gp.x + gp.w - 1 && ...
            isequal(cf{1}.rows, cf{2}.rows) && all([cf{1}.normal cf{2}.normal] == [-1 0 -1 0]), ...
            ['塔扇：前扇贴鳍片前侧、中扇在间隙内，同行、都向后吹' tag]);
        pz = sv.porousZones(1:3);
        errs = check(errs, isequal([pz.zetaThru], [4 4 0]) && isequal([pz.zetaCross], [60 60 60]) && ...
            isequal(pz(3).rect, gp), ['多孔区：两组鳍片穿流 ζ 各 4，间隙只有横流阻力' tag]);
        errs = check(errs, numel(sv.cpuFinIdx) == 2 * st(1).w * st(1).h && ...
            ~any(ismember(sv.cpuFinIdx, sv.rectCells(gp))), ['CPU 散热体应为两组鳍片、不含间隙' tag]);
        inX = ceil(sv.cpuInletIdx / sv.GRID.W);
        errs = check(errs, min(inX) == cf{1}.cols(2) + 1, ['进风带应在前扇前' tag]);
    end
    sv1 = CFDSolverFEM([], [], [], L1f, 0.5);
    cf1 = sv1.builtInFans(cellfun(@(f) strcmp(f.role, 'cpu'), sv1.builtInFans));
    fin1 = sv1.CPU_HEATSINK.fin_area;
    inX = ceil(sv1.cpuInletIdx / sv1.GRID.W);
    errs = check(errs, numel(cf1) == 1 && strcmp(cf1{1}.id, 'cpu_fan_mid') && min(inX) == fin1.x + fin1.w, ...
        '双塔 1 扇：只有中扇，进风带在鳍片前');
    svs = CFDSolverFEM([], [], [], Ls, 0.5);
    cfs = svs.builtInFans(cellfun(@(f) strcmp(f.role, 'cpu'), svs.builtInFans));
    fins = svs.CPU_HEATSINK.fin_area;
    errs = check(errs, numel(cfs) == 2 && cfs{2}.cols(2) == fins.x - 1 && isempty(svs.CPU_HEATSINK.gap) && ...
        svs.porousZones(1).zetaThru == 8 && isequal(svs.porousZones(1).rect, fins), ...
        '单塔推拉：后扇贴鳍片后侧，鳍片为一个多孔区（ζ 8）');
    fl = svs.fanStatusList();
    names = {fl.name};
    Lw = Ls; Lw.cpu.fins.x = 6;                                   % 单塔推拉：鳍片离后壁太近，后扇压到后壁
    try
        CFDSolverFEM([], [], [], Lw, 0.5);
        errs{end+1} = '后置塔扇压到后壁时应报错';
    catch ME
        errs = check(errs, strcmp(ME.identifier, 'CFDSolverBase:cpuFans'), ['后扇压壁的错误标识：' ME.identifier]);
    end
    Lfr = L0; Lfr.cpu.fins.x = 204;                               % 鳍片贴前壁：前扇压到前壁
    Ltw = L0; Ltw.cpu.tower.gapMm = 110;                          % 间隙太宽：两组鳍片在网格上放不下
    ids = {'CFDSolverBase:cpuFans', 'CFDSolverBase:cpuTower'};
    Lerr = {Lfr, Ltw};
    for k = 1:2
        try
            CFDSolverFEM([], [], [], Lerr{k}, 0.5);
            errs{end+1} = ['应报错：' ids{k}]; %#ok<AGROW>
        catch ME
            errs = check(errs, strcmp(ME.identifier, ids{k}), ['错误标识应为 ' ids{k} '：' ME.identifier]);
        end
    end
    Lgn = L0; Lgn.cpu.tower.gapMm = 8;                            % 间隙（预览 2 格）比执行盘（3 格）窄：盘厚截到间隙宽
    svg = CFDSolverFEM([], [], [], Lgn, 0.5);
    gpn = svg.CPU_HEATSINK.gap;
    cfm = svg.builtInFans(cellfun(@(q) strcmp(q.pos, 'mid'), svg.builtInFans));
    errs = check(errs, gpn.w == 2 && isequal(cfm{1}.cols, [gpn.x, gpn.x + 1]) && abs(cfm{1}.thickM - 0.008) < 1e-15, ...
        '间隙比执行盘窄时，中扇应占满间隙、盘厚 = 间隙宽');
    Ln = L0; Ln.cpu.fan = [];                                     % 无塔扇（JSON 里存为 "fan":[]）
    layout_json('save', Ln, f);
    Lnj = layout_json('load', f);
    delete(f);
    svn = CFDSolverFEM([], [], [], Lnj, 0.5);
    twn = layout_cpu_tower(Lnj);
    errs = check(errs, ~any(cellfun(@(q) strcmp(q.role, 'cpu'), svn.builtInFans)) && twn.fans == 0, ...
        'cpu.fan = [] 的布局应没有塔扇');
    errs = check(errs, any(strcmp(names, 'CPU 塔扇（后）')), '两台塔扇时风扇表名称应带位置');
    layout_json('save', L1f, f);
    Lj = layout_json('load', f);
    delete(f);
    errs = check(errs, isequal(layout_cpu_tower(Lj), tw1), 'JSON 往返应保留双塔与塔扇数量');

    % 4d) 风扇型号库与温控曲线（v4.6.0）：旧型号名 RX120/RX140 读为 T30/M25_140；三个曲线档位都能构建；
    %     曲线、dvfs 取值不合法时 JSON 读取报错；没有 fanCurves、dvfs 的旧布局按标准档与默认参数
    Lx = L0; Lx.caseFans(1).model = 'RX120'; Lx.caseFans(2).model = 'RX140';
    layout_json('save', Lx, f);
    Lxj = layout_json('load', f);
    errs = check(errs, strcmp(Lxj.caseFans(1).model, 'T30') && strcmp(Lxj.caseFans(2).model, 'M25_140'), ...
        '旧型号名 RX120/RX140 应读为 T30/M25_140');
    for pf = {'quiet', 'standard', 'performance'}
        Lc = L0; Lc.fanCurves = fan_curve_profiles(pf{1});
        layout_json('save', Lc, f);
        Lcj = layout_json('load', f);
        sc = CFDSolverFEM([], [], [], Lcj, 0.5);
        errs = check(errs, isequal(sc.fanCurves, Lc.fanCurves), ['曲线档位 ' pf{1} ' 应能 JSON 往返并构建']);
    end
    badCurves = {@(L) setfield(L, 'fanCurves', setfield(L.fanCurves, 'caseFan', struct('T', [50 40], 'duty', [0.2 0.5]))), ...
                 @(L) setfield(L, 'fanCurves', setfield(L.fanCurves, 'gpu', struct('T', [50 60], 'duty', [0.2 1.5]))), ...
                 @(L) setfield(L, 'cpu', setfield(L.cpu, 'dvfs', setfield(L.cpu.dvfs, 'minFreq', 0))), ...
                 @(L) setfield(L, 'gpu', setfield(L.gpu, 'dvfs', setfield(L.gpu.dvfs, 'leakShar', 0.1))), ...
                 @(L) setfield(L, 'fanCurves', setfield(L.fanCurves, 'caseFan', [])), ...
                 @(L) setfield(L, 'cpu', setfield(L.cpu, 'dvfs', 5)), ...
                 @(L) setfield(L, 'fanCurves', setfield(L.fanCurves, 'gpu', setfield(L.fanCurves.gpu, 'stopBelowC', 'x'))), ...
                 @(L) setfield(L, 'fanCurves', setfield(L.fanCurves, 'caseFan', setfield(L.fanCurves.caseFan, 'T', [25 NaN 70 80 85])))};
    for k = 1:numel(badCurves)
        layout_json('save', badCurves{k}(L0), f);
        try
            layout_json('load', f);
            errs{end+1} = sprintf('不合法的曲线/dvfs（第 %d 例）应报错', k); %#ok<AGROW>
        catch ME
            errs = check(errs, strcmp(ME.identifier, 'layout_json:invalid'), ['错误标识应为 layout_json:invalid：' ME.identifier]);
        end
    end
    % 档位名与曲线不符（标着性能、实为静音曲线）或为空时记为 custom
    Lm = L0; Lm.fanCurves = fan_curve_profiles('quiet'); Lm.fanCurves.profile = 'performance';
    layout_json('save', Lm, f);
    Lmj = layout_json('load', f);
    Le = L0; Le.fanCurves.profile = '';
    errs = check(errs, strcmp(Lmj.fanCurves.profile, 'custom') && strcmp(layout_fan_curves(Le).profile, 'custom') && ...
        strcmp(layout_fan_curves(L0).profile, 'standard'), '档位名与曲线不符或为空时应记为 custom');
    Lold = rmfield(L0, 'fanCurves'); Lold.cpu = rmfield(Lold.cpu, 'dvfs'); Lold.gpu = rmfield(Lold.gpu, 'dvfs');
    so = CFDSolverFEM([], [], [], Lold, 0.5);
    errs = check(errs, isequal(so.fanCurves, fan_curve_profiles('standard')) && ...
        isequal(so.CPU_HEATSINK.dvfs, layout_dvfs(L0, 'cpu')) && isequal(so.GPU_HEATSINK.dvfs, layout_dvfs(L0, 'gpu')), ...
        '没有 fanCurves、dvfs 的旧布局应按标准档与默认参数');

    % 5) JSON 字段取值检查
    Lb = L0; Lb.caseFans(1).type = 'Intake';
    layout_json('save', Lb, f);
    try
        layout_json('load', f);
        errs{end+1} = 'type 拼写错误的 JSON 应报错';
    catch ME
        errs = check(errs, strcmp(ME.identifier, 'layout_json:invalid'), ['错误标识应为 layout_json:invalid：' ME.identifier]);
    end
    delete(f);

    % 5b) 列表字段各项字段顺序不同 → jsondecode 给出 cell，读取时规整为列向 struct 数组；字段不一致时报错
    Ld = layout_benchmark('duct', 20);
    v = Ld.vents(1);
    fnv = fieldnames(v);
    v2 = orderfields(v, fnv(end:-1:1));             % 同样的字段，顺序相反
    Ld.vents = {v, v2};
    writeRaw(f, Ld);
    try
        Lr = layout_json('load', f);
        errs = check(errs, isstruct(Lr.vents) && isequal(size(Lr.vents), [2 1]), ...
            '字段顺序不同的 vents 应规整为 2×1 struct 数组');
        CFDSolverFEM(0, 0, 0, Lr, 0.5);
    catch ME
        errs{end+1} = ['字段顺序不同的 vents 读取/构建失败：' ME.message];
    end
    v3 = v; v3.extra = 1;
    Ld.vents = {v, v3};
    writeRaw(f, Ld);
    try
        layout_json('load', f);
        errs{end+1} = '字段不一致的 vents 应报错';
    catch ME
        errs = check(errs, strcmp(ME.identifier, 'layout_json:list'), ['错误标识应为 layout_json:list：' ME.identifier]);
    end
    delete(f);

    pass = isempty(errs);
    for k = 1:numel(errs), fprintf('  - %s\n', errs{k}); end
    if pass, stt = 'PASS'; else, stt = 'FAIL'; end
    fprintf('[layout] 安装位 / %d 个预设 / JSON 往返 / 安装检查：%s\n', numel(P), stt);
end

function errs = check(errs, cond, msg)
    if ~cond, errs{end+1} = msg; end
end

function tf = contains_(c, pat)
    tf = ~cellfun(@isempty, strfind(c, pat));
end

function F = sortFans(F)
    key = arrayfun(@(f) sprintf('%s%06.1f', f.mount, f.alongMm), F, 'UniformOutput', false);
    [~, i] = sort(key);
    F = F(i);
end

function writeRaw(f, L)
    % 不经 layout_json 直接写（构造 jsondecode 会给出 cell 的输入）
    fid = fopen(f, 'w');
    fwrite(fid, unicode2native(jsonencode(L), 'UTF-8'));
    fclose(fid);
end
