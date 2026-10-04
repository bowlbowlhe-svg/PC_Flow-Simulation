function U = layout_panel_u(L)
%LAYOUT_PANEL_U 机箱壁向室内空气的总传热系数 [W/m²K]（v4.8.0；规格 §3.9）。
%   U = layout_panel_u(L) 返回 struct(edge, side)：edge 为 2D 边界上的前/后/顶/底壁，side 为两块侧板。
%   缺 chassis.panelU 时为 0（没有壁面散热，只按 wallTempC 处理，旧模型）。取值检查 0–50。
    U = struct('edge', 0, 'side', 0);
    if ~isfield(L.chassis, 'panelU') || isempty(L.chassis.panelU), return; end
    p = L.chassis.panelU;
    keys = {'edge', 'side'};
    for k = 1:numel(keys)
        v = [];
        if isfield(p, keys{k}), v = p.(keys{k}); end
        if ~isnumeric(v) || ~isscalar(v) || ~(v >= 0 && v <= 50)
            error('layout_panel_u:value', 'chassis.panelU.%s 应为 0–50 的数（W/m²K）', keys{k});
        end
        U.(keys{k}) = v;
    end
    extra = setdiff(fieldnames(p), keys);
    if ~isempty(extra)
        error('layout_panel_u:field', 'chassis.panelU 中有未知字段：%s', strjoin(extra(:)', ', '));
    end
end
