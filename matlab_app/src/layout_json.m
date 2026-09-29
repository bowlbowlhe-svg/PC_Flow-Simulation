function out = layout_json(action, varargin)
%LAYOUT_JSON 布局配置的 JSON 读写。
%   layout_json('save', L, file)   保存
%   L = layout_json('load', file)  读取并规整（JSON 的 null → NaN、单元素数组等）
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
            out = normalize(L);
        otherwise
            error('layout_json:action', '未知操作：%s', action);
    end
end

function L = normalize(L)
    % 壁温：JSON 里 NaN 存为 null，读回为 []
    sides = {'rear','front','top','bottom'};
    for k = 1:numel(sides)
        v = L.chassis.wallTempC.(sides{k});
        if isempty(v), L.chassis.wallTempC.(sides{k}) = NaN; end
    end
    % 数值数组（如 gpu.fans.xs）读回可能为列向量，统一为行向量
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
            g = struct('mount', f.mount, 'alongMm', f.alongMm, 'type', f.type, 'model', f.model, ...
                       'speedMode', 'auto', 'manualPct', 60);
            if isfield(f, 'speedMode'), g.speedMode = f.speedMode; end
            if isfield(f, 'manualPct'), g.manualPct = f.manualPct; end
            cf(end+1) = g; %#ok<AGROW>
        end
        L.caseFans = cf(:);
    end
    % 电源仓挡板缺口：空数组读回为 []
    if isfield(L, 'shroud') && isfield(L.shroud, 'gaps') && isempty(L.shroud.gaps)
        L.shroud.gaps = struct('x0Mm', {}, 'x1Mm', {});
    end
end
