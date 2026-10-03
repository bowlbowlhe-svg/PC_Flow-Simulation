function gen_layout_fixtures(outFile)
%GEN_LAYOUT_FIXTURES 生成网页版布局工具函数的对照数据（web/test/fixtures/layout.json）。
%   用法（在 matlab_app 目录下）：
%     octave-cli --no-gui --eval "setup_paths(); addpath('../web/test/gen'); gen_layout_fixtures"
%   覆盖：layout_fan_report（默认、各预设、含超出壁面/同壁重叠/角部相碰/与电源重叠/手动转速的自造布局）、
%   layout_set_gpu_slots（2–4.5 槽的散热片尺寸与鳍片面积；放不下时的报错）、layout_slots 'get'、
%   layout_cpu_tower / layout_set_cpu_fans（双塔/单塔/旧布局的塔扇位置；取值不合法时的报错）。
    if nargin < 1
        here = fileparts(mfilename('fullpath'));
        outFile = fullfile(here, '..', 'fixtures', 'layout.json');
    end
    cases = {};
    L0 = layout_default();
    cases{end+1} = rep('default', L0);
    P = fan_presets();
    for k = 1:numel(P)
        cases{end+1} = rep(['preset_' P(k).name], layout_apply_preset(L0, P(k).name)); %#ok<AGROW>
    end
    L = L0;
    F = L.caseFans(1);
    add = @(F, mount, along, type, model, mode, pct) setfield(setfield(setfield(setfield(setfield(setfield(F, ...
        'mount', mount), 'alongMm', along), 'type', type), 'model', model), 'speedMode', mode), 'manualPct', pct);
    fans = [ ...
        add(F, 'top', 30, 'exhaust', 'P12', 'auto', 60); ...        % 超出壁面 + 与后壁角部
        add(F, 'rear', 40, 'intake', 'P14', 'manual', 35); ...      % 与顶壁角部相碰
        add(F, 'rear', 360, 'exhaust', 'P12', 'auto', 60); ...      % 与电源重叠
        add(F, 'front', 220, 'intake', 'P14', 'manual', 80); ...
        add(F, 'front', 250, 'intake', 'P12', 'auto', 60); ...      % 同壁重叠
        add(F, 'front', 345, 'intake', 'P12', 'auto', 60); ...      % 超出壁面 + 与底壁角部
        add(F, 'bottom', 230, 'intake', 'RX140', 'auto', 60); ... % 与电源重叠 8 mm
        add(F, 'bottom', 290, 'intake', 'P12', 'manual', 50); ...   % 超出壁面（底壁按机箱深 320 mm）+ 与前壁角部
        add(F, 'top', 270, 'exhaust', 'P12', 'auto', 60)];          % 超出壁面（顶壁按机箱深）
    L.caseFans = fans;
    cases{end+1} = rep('custom_warnings', L);
    Lq = L; Lq.chassis.sizeMm = 400; Lq.chassis.originMm = 80;  % 见方机箱（标量 sizeMm）：同样的风扇在 400 mm 壁上
    cases{end+1} = rep('custom_square400', Lq);
    L = L0; L.caseFans = L0.caseFans([]);
    cases{end+1} = rep('no_fans', L);

    gs = {};
    for s = [2 2.5 3 3.5 4 4.5]
        try
            Lg = layout_set_gpu_slots(L0, s);
            gs{end+1} = struct('slots', s, 'ok', true, 'gpu', Lg.gpu, 'read', layout_gpu_slots(Lg)); %#ok<AGROW>
        catch ME
            gs{end+1} = struct('slots', s, 'ok', false, 'id', ME.identifier, 'message', ME.message); %#ok<AGROW>
        end
    end
    % 挡板上移到放不下 4 槽
    Ls = L0; Ls.shroud.yMm = Ls.shroud.yMm - 30;
    try
        layout_set_gpu_slots(Ls, 4);
        err = struct('ok', true);
    catch ME
        err = struct('ok', false, 'id', ME.identifier, 'message', ME.message);
    end

    % CPU 塔式散热器：各算例的 cpu 字段（在默认布局上替换）与 layout_cpu_tower 的结果或报错
    ct = {};
    c0 = L0.cpu;
    noTower = rmfield(c0, 'tower');
    legacy = noTower; legacy.fan = rmfield(legacy.fan, 'count');
    noFan = rmfield(c0, 'fan');
    variants = {'default', c0; 'dual1', setfield(c0, 'fan', setfield(c0.fan, 'count', 1)); ...
        'pushpull', noTower; 'legacy', legacy; 'noFan', noFan; ...
        'stacks3', setfield(c0, 'tower', setfield(c0.tower, 'stacks', 3)); ...
        'gap0', setfield(c0, 'tower', setfield(c0.tower, 'gapMm', 0)); ...
        'gapWide', setfield(c0, 'tower', setfield(c0.tower, 'gapMm', 112)); ...
        'count3', setfield(c0, 'fan', setfield(c0.fan, 'count', 3)); ...
        'thruY', setfield(c0, 'porous', setfield(c0.porous, 'thru', 'y'))};
    for k = 1:size(variants, 1)
        Lc = L0; Lc.cpu = variants{k, 2};
        try
            t = layout_cpu_tower(Lc);
            ct{end+1} = struct('name', variants{k, 1}, 'cpu', Lc.cpu, 'ok', true, 'stacks', t.stacks, ...
                'gapMm', t.gapMm, 'fans', t.fans, 'pos', {t.pos}); %#ok<AGROW>
        catch ME
            ct{end+1} = struct('name', variants{k, 1}, 'cpu', Lc.cpu, 'ok', false, 'id', ME.identifier, ...
                'message', ME.message); %#ok<AGROW>
        end
    end
    L1 = layout_set_cpu_fans(L0, 1);
    L2 = layout_set_cpu_fans(setfield(L0, 'cpu', noFan), 2);
    setFans = struct('one', L1.cpu, 'addFan', L2.cpu);

    R = struct('generator', struct('tool', 'octave', 'version', version(), 'script', 'web/test/gen/gen_layout_fixtures.m'), ...
        'reports', {cases}, 'gpuSlots', {gs}, 'shroudTooHigh', err, 'shroudYMm', Ls.shroud.yMm, ...
        'cpuTower', {ct}, 'setCpuFans', setFans);
    fid = fopen(outFile, 'w');
    fwrite(fid, unicode2native(jsonencode(R), 'UTF-8'));
    fclose(fid);
    fprintf('已写入 %s\n', outFile);
end

function c = rep(name, L)
    R = layout_fan_report(L);
    S = layout_slots('get', L);
    Lj = L;
    Lj.caseFans = num2cell(L.caseFans);
    for f = {'vents', 'solidBlocks', 'porousBlocks'}
        if isfield(Lj, f{1}) && isstruct(Lj.(f{1})), Lj.(f{1}) = num2cell(Lj.(f{1})); end
    end
    if isfield(Lj, 'shroud') && isfield(Lj.shroud, 'gaps') && isstruct(Lj.shroud.gaps)
        Lj.shroud.gaps = num2cell(Lj.shroud.gaps);
    end
    c = struct('name', name, 'layout', Lj, 'report', R, 'slots', {num2cell(S)});
end
