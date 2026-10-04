function [out, info] = layout_json(action, varargin)
%LAYOUT_JSON 布局配置的 JSON 读写。
%   layout_json('save', L, file)   保存
%   L = layout_json('load', file)  读取并规整（JSON 的 null → NaN、单元素数组等）
%   [L, info] = layout_json('load', file)  info.migration 为版本迁移结果：'none'；'v48'（v4.7 配置，热参数都是旧默认值，
%                                  已整体升级为 v4.8 模型）；'legacy'（v4.7 配置，改过热参数，保持原样按 v4.7 模型计算）
    info = struct('migration', 'none');
    switch action
        case 'save'
            L = varargin{1}; file = varargin{2};
            txt = jsonencode(L);
            fid = fopen(file, 'w');
            if fid < 0, error('layout_json:open', '无法写入：%s', file); end
            fwrite(fid, unicode2native(txt, 'UTF-8'));
            fclose(fid);
            out = file;
        case 'load'
            file = varargin{1};
            fid = fopen(file, 'r');
            if fid < 0, error('layout_json:open', '无法读取：%s', file); end
            raw = fread(fid, inf, 'uint8=>uint8')';
            fclose(fid);
            L = jsondecode(native2unicode(raw, 'UTF-8'));
            [out, info.migration] = normalize(L);
        otherwise
            error('layout_json:action', '未知操作：%s', action);
    end
end

function [L, mig] = normalize(L)
    % 壁温：JSON 里 NaN 存为 null，读回为 []
    sides = {'rear','front','top','bottom'};
    for k = 1:numel(sides)
        v = L.chassis.wallTempC.(sides{k});
        if isempty(v), L.chassis.wallTempC.(sides{k}) = NaN; end
    end
    [L, mig] = migrateV48(L);
    % 数值数组（如 gpu.fans.xs、矩形机箱的 sizeMm/originMm）读回可能为列向量，统一为行向量
    L.chassis.sizeMm = L.chassis.sizeMm(:)';
    L.chassis.originMm = L.chassis.originMm(:)';
    if isfield(L, 'gpu') && isfield(L.gpu, 'fans')
        L.gpu.fans.xs = L.gpu.fans.xs(:)';
    end
    if isfield(L, 'psu') && isfield(L.psu, 'effCurve')
        L.psu.effCurve.load = L.psu.effCurve.load(:)';
        L.psu.effCurve.eff = L.psu.effCurve.eff(:)';
    end
    % 机箱风扇：空数组读回为 []；缺转速字段的补默认值
    if isfield(L, 'caseFans')
        cf = struct('mount', {}, 'alongMm', {}, 'type', {}, 'model', {}, 'speedMode', {}, 'manualPct', {});
        for k = 1:numel(L.caseFans)
            if iscell(L.caseFans), f = L.caseFans{k}; else, f = L.caseFans(k); end
            g = struct('mount', f.mount, 'alongMm', f.alongMm, 'type', f.type, 'model', fan_model_alias(f.model), ...
                       'speedMode', 'auto', 'manualPct', 60);
            if isfield(f, 'speedMode'), g.speedMode = f.speedMode; end
            if isfield(f, 'manualPct'), g.manualPct = f.manualPct; end
            cf(end+1) = g; %#ok<AGROW>
        end
        L.caseFans = cf(:);
    end
    % 其它列表字段：各项字段不齐时 jsondecode 给出 cell，统一成 struct 数组
    for nm = {'vents', 'solidBlocks', 'porousBlocks'}
        if isfield(L, nm{1}) && iscell(L.(nm{1}))
            c = L.(nm{1});
            if isempty(c)
                L.(nm{1}) = [];
                continue;
            end
            try
                c = cellfun(@orderfields, c, 'UniformOutput', false);
                L.(nm{1}) = reshape([c{:}], [], 1);   % 与 jsondecode 的 struct 数组同为列向
            catch
                error('layout_json:list', '%s 的各项字段不一致', nm{1});
            end
        end
    end
    validateFans(L);
    if isfield(L, 'cpu') && ~isempty(L.cpu)
        try
            layout_cpu_tower(L);
        catch ME
            error('layout_json:invalid', 'CPU 散热器：%s', ME.message);
        end
    end
    try
        % 温控曲线：数组规整为行、检查取值、档位名与曲线不符时记为 custom（见 layout_fan_curves）
        if isfield(L, 'fanCurves') && ~isempty(L.fanCurves), L.fanCurves = layout_fan_curves(L); end
        if isfield(L, 'cpu') && ~isempty(L.cpu), layout_dvfs(L, 'cpu'); end
        if isfield(L, 'gpu') && ~isempty(L.gpu), layout_dvfs(L, 'gpu'); end
        layout_zshare(L);
        layout_panel_u(L);
        if isfield(L, 'cpu') && ~isempty(L.cpu), layout_heat_coef(L.cpu.thermal, 'cpu'); end
        if isfield(L, 'gpu') && ~isempty(L.gpu), layout_heat_coef(L.gpu.thermal, 'gpu'); end
    catch ME
        error('layout_json:invalid', '%s', ME.message);
    end
    % 电源仓挡板缺口：空数组读回为 []
    if isfield(L, 'shroud') && isfield(L.shroud, 'gaps') && isempty(L.shroud.gaps)
        L.shroud.gaps = struct('x0Mm', {}, 'x1Mm', {});
    end
end

function [L, mig] = migrateV48(L)
    % 读取 v4.7 及以前保存的配置（没有 chassis.panelU、含 CPU/GPU/电源）。热参数（CPU、GPU）与 GPU 鳍片阻力都是旧默认值时
    % 整体升级为 v4.8 模型：四面壁温都是 25°C 的定温壁 → 绝热；补 chassis.panelU、zShare；热参数与 GPU 鳍片换成新默认值
    % （GPU 面积按 gpu_fin_area(h)）。改过其中任何一项时整个文件保持原样——缺 v4.8 字段即按 v4.7 模型计算，不把新旧标定
    % 混在一起。基准布局（方腔、风道、空域）没有元件，不迁移。mig：'none' / 'v48'（已升级）/ 'legacy'（按 v4.7 模型）。
    mig = 'none';
    hasPart = any(cellfun(@(k) isfield(L, k) && ~isempty(L.(k)), {'cpu', 'gpu', 'psu'}));
    if isfield(L.chassis, 'panelU') || ~hasPart, return; end
    hasCpu = isfield(L, 'cpu') && ~isempty(L.cpu);
    hasGpu = isfield(L, 'gpu') && ~isempty(L.gpu);
    oldCpu = ~hasCpu || (isfield(L.cpu, 'thermal') && sameAs(L.cpu.thermal, ...
        struct('R_junction_to_case', 0.15, 'R_tim', 0.04, 'R_base', 0.05, 'fin_thickness_mm', 0.4, 'A_fin_total_m2', 0.15)));
    oldGpu = ~hasGpu;
    if hasGpu && isfield(L.gpu, 'thermal') && isfield(L.gpu, 'heatsink') && isfield(L.gpu, 'porous')
        h = L.gpu.heatsink.h;
        oldGpu = sameAs(L.gpu.thermal, struct('R_junction_to_case', 0.08, 'R_tim', 0.02, 'R_base', 0.02, ...
                     'fin_thickness_mm', 0.35, 'A_fin_total_m2', 0.5 * h / 47)) && ...
                 sameAs(L.gpu.porous, struct('zetaThru', 4, 'zetaCross', 10, 'thru', 'x'));
    end
    if ~(oldCpu && oldGpu)
        mig = 'legacy';
        return;
    end
    mig = 'v48';
    D = layout_default();
    sides = {'rear','front','top','bottom'};
    wt = L.chassis.wallTempC;
    if all(cellfun(@(k) isequal(wt.(k), 25), sides))
        for k = 1:numel(sides), L.chassis.wallTempC.(sides{k}) = NaN; end
    end
    L.chassis.panelU = D.chassis.panelU;
    if ~isfield(L, 'zShare'), L.zShare = D.zShare; end
    if hasCpu, L.cpu.thermal = D.cpu.thermal; end
    if hasGpu
        L.gpu.thermal = D.gpu.thermal;
        L.gpu.thermal.A_fin_total_m2 = gpu_fin_area(L.gpu.heatsink.h);
        L.gpu.porous = D.gpu.porous;
    end
end

function tf = sameAs(a, b)
    % 字段集合相同、数值相对差 ≤ 1e−9（jsonencode 写 15 位有效数字）、字符串相同
    tf = isstruct(a) && isscalar(a) && isempty(setxor(fieldnames(a), fieldnames(b)));
    if ~tf, return; end
    fn = fieldnames(b);
    for k = 1:numel(fn)
        x = a.(fn{k}); y = b.(fn{k});
        if ischar(y)
            ok = ischar(x) && strcmp(x, y);
        else
            ok = isnumeric(x) && isscalar(x) && abs(x - y) <= 1e-9 * abs(y);
        end
        if ~ok, tf = false; return; end
    end
end

function validateFans(L)
    % 机箱风扇字段取值检查（拼写错误等会在这里报出，而不是在求解器里被静默处理）
    if ~isfield(L, 'caseFans'), return; end
    cat = fan_catalog();
    for k = 1:numel(L.caseFans)
        f = L.caseFans(k);
        bad = '';
        if ~any(strcmp(f.mount, {'front', 'rear', 'top', 'bottom'}))
            bad = sprintf('mount = "%s"（应为 front/rear/top/bottom）', f.mount);
        elseif ~any(strcmp(f.type, {'intake', 'exhaust'}))
            bad = sprintf('type = "%s"（应为 intake/exhaust）', f.type);
        elseif ~isfield(cat, f.model)
            bad = sprintf('model = "%s"（不在 fan_catalog 中）', f.model);
        elseif ~any(strcmp(f.speedMode, {'auto', 'manual'}))
            bad = sprintf('speedMode = "%s"（应为 auto/manual）', f.speedMode);
        elseif ~isnumeric(f.manualPct) || ~isscalar(f.manualPct) || f.manualPct < 0 || f.manualPct > 100
            bad = 'manualPct 应为 0–100 的数';
        elseif ~isnumeric(f.alongMm) || ~isscalar(f.alongMm)
            bad = 'alongMm 应为数';
        end
        if ~isempty(bad)
            error('layout_json:invalid', '第 %d 台机箱风扇：%s', k, bad);
        end
    end
end
