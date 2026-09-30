function gen_layout_fixtures(outFile)
%GEN_LAYOUT_FIXTURES 生成网页版布局工具函数的对照数据（web/test/fixtures/layout.json）。
%   用法（在 matlab_app 目录下）：
%     octave-cli --no-gui --eval "setup_paths(); addpath('../web/test/gen'); gen_layout_fixtures"
%   覆盖：layout_fan_report（默认、各预设、含超出壁面/同壁重叠/角部相碰/与电源重叠/手动转速的自造布局）、
%   layout_set_gpu_slots（2–4.5 槽的散热片尺寸与鳍片面积；放不下时的报错）、layout_slots 'get'。
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
        add(F, 'bottom', 300, 'intake', 'RX140', 'auto', 60); ... % 与电源重叠？
        add(F, 'bottom', 375, 'intake', 'P12', 'manual', 50)];      % 与前壁角部
    L.caseFans = fans;
    cases{end+1} = rep('custom_warnings', L);
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

    R = struct('generator', struct('tool', 'octave', 'version', version(), 'script', 'web/test/gen/gen_layout_fixtures.m'), ...
        'reports', {cases}, 'gpuSlots', {gs}, 'shroudTooHigh', err, 'shroudYMm', Ls.shroud.yMm);
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
