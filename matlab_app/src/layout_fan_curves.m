function C = layout_fan_curves(L)
%LAYOUT_FAN_CURVES 布局的自动温控风扇曲线（fanCurves 字段；缺省为 fan_curve_profiles('standard')）。
%   检查各曲线：T 严格递增、duty ∈ [0,1]、两者等长且至少 2 点、均为有限的数；显卡停转阈 stopBelowC ≤ startAboveC；
%   电源半被动 0 ≤ passiveLoad ≤ 1、passiveMaxC ≤ passiveRestartC（均为有限的数）。取值不合法时报错。
%   档位名 profile 只在曲线与该档（quiet/standard/performance）完全相同时保留，否则记为 'custom'。
    if ~isfield(L, 'fanCurves') || isempty(L.fanCurves)
        C = fan_curve_profiles('standard');
        return;
    end
    C = L.fanCurves;
    if ~isstruct(C) || ~isscalar(C)
        error('layout_fan_curves:field', 'fanCurves 应为包含 caseFan/cpu/gpu/psu 曲线的结构体');
    end
    num = @(x) isnumeric(x) && isreal(x) && isscalar(x) && isfinite(x);
    for k = {'caseFan', 'cpu', 'gpu', 'psu'}
        if ~isfield(C, k{1}) || ~isstruct(C.(k{1})) || ~isscalar(C.(k{1})) || ...
                ~isfield(C.(k{1}), 'T') || ~isfield(C.(k{1}), 'duty')
            error('layout_fan_curves:field', 'fanCurves 缺少 %s 曲线（需要 T 与 duty）', k{1});
        end
        c = C.(k{1});
        if ~isnumeric(c.T) || ~isnumeric(c.duty) || ~isreal(c.T) || ~isreal(c.duty)
            error('layout_fan_curves:value', 'fanCurves.%s：T 应严格递增，duty 应在 0–1，两者等长且至少 2 点', k{1});
        end
        c.T = double(c.T(:)'); c.duty = double(c.duty(:)');
        if numel(c.T) < 2 || numel(c.T) ~= numel(c.duty) || any(~isfinite(c.T)) || any(diff(c.T) <= 0) || ...
                any(~isfinite(c.duty)) || any(c.duty < 0) || any(c.duty > 1)
            error('layout_fan_curves:value', 'fanCurves.%s：T 应严格递增，duty 应在 0–1，两者等长且至少 2 点', k{1});
        end
        C.(k{1}) = c;
    end
    g = C.gpu;
    if isfield(g, 'stopBelowC') && ~isempty(g.stopBelowC) && ...
            (~num(g.stopBelowC) || ~isfield(g, 'startAboveC') || ~num(g.startAboveC) || g.startAboveC < g.stopBelowC)
        error('layout_fan_curves:value', 'fanCurves.gpu：低温停转需要 startAboveC ≥ stopBelowC（有限的数）');
    end
    p = C.psu;
    if isfield(p, 'passiveLoad') && ~isempty(p.passiveLoad) && ...
            (~num(p.passiveLoad) || p.passiveLoad < 0 || p.passiveLoad > 1 || ~isfield(p, 'passiveMaxC') || ...
             ~isfield(p, 'passiveRestartC') || ~num(p.passiveMaxC) || ~num(p.passiveRestartC) || ...
             p.passiveRestartC < p.passiveMaxC)
        error('layout_fan_curves:value', 'fanCurves.psu：半被动需要 0 ≤ passiveLoad ≤ 1、passiveRestartC ≥ passiveMaxC（有限的数）');
    end
    % 档位名：与该档曲线逐项相同才保留（避免"标着性能、按静音运行"）
    prof = 'custom';
    if isfield(C, 'profile') && ischar(C.profile) && any(strcmp(C.profile, {'quiet', 'standard', 'performance'}))
        if sameCurves(C, fan_curve_profiles(C.profile)), prof = C.profile; end
    end
    C.profile = prof;
end

function tf = sameCurves(A, B)
    tf = true;
    opt = {'stopBelowC', 'startAboveC', 'passiveLoad', 'passiveMaxC', 'passiveRestartC'};
    for k = {'caseFan', 'cpu', 'gpu', 'psu'}
        a = A.(k{1}); b = B.(k{1});
        if ~isequal(a.T, b.T) || ~isequal(a.duty, b.duty), tf = false; return; end
        for j = 1:numel(opt)
            ha = isfield(a, opt{j}) && ~isempty(a.(opt{j}));
            hb = isfield(b, opt{j}) && ~isempty(b.(opt{j}));
            if ha ~= hb || (ha && a.(opt{j}) ~= b.(opt{j})), tf = false; return; end
        end
    end
end
