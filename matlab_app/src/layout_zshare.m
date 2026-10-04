function z = layout_zshare(L)
%LAYOUT_ZSHARE 零件占机箱 Z 向深度的比例（准三维修正，v4.8.0；规格 §2.4）。
%   z = layout_zshare(L) 返回 struct(gpu, ram, vrm)：显卡（整卡高度，插槽 → 侧板方向）、内存条、VRM 散热片
%   各占主板到侧板距离的比例。缺字段（或为空）取 1 = 整个深度都挡住（固体障碍，旧模型）；< 1 时零件旁边
%   还有 1 − z 的深度可以过风，按多孔区处理（阻力系数见 zeta_partial）。取值检查 0 < z ≤ 0.95 或 z = 1
%   （z > 0.95 时 ζ 迅速发散，0.95 → 551，应按固体处理）。
    z = struct('gpu', 1, 'ram', 1, 'vrm', 1);
    if ~isfield(L, 'zShare') || isempty(L.zShare), return; end
    s = L.zShare;
    if ~isstruct(s) || ~isscalar(s)
        error('layout_zshare:value', 'zShare 应为含 gpu/ram/vrm 字段的对象');
    end
    keys = {'gpu', 'ram', 'vrm'};
    for k = 1:numel(keys)
        if isfield(s, keys{k}) && ~isempty(s.(keys{k})), z.(keys{k}) = s.(keys{k}); end
        v = z.(keys{k});
        if ~isnumeric(v) || ~isscalar(v) || ~((v > 0 && v <= 0.95) || v == 1)
            error('layout_zshare:value', 'zShare.%s 应为 (0, 0.95] 的数或 1（整个深度都挡住）', keys{k});
        end
    end
    extra = setdiff(fieldnames(s), keys);
    if ~isempty(extra)
        error('layout_zshare:field', 'zShare 中有未知字段：%s', strjoin(extra(:)', ', '));
    end
end
