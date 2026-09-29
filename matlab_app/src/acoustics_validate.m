function acoustics_validate(ac)
%ACOUSTICS_VALIDATE 噪音参数检查（布局 acoustics 与默认值合并后）。
%   字段必须是 acoustics_default 中已有的（拼写错误会报错），数值须有限，
%   0 < stallQ ≤ 1，stallDb ≥ 0，grilleRefZeta > 0。
    def = acoustics_default();
    extra = setdiff(fieldnames(ac), fieldnames(def));
    if ~isempty(extra)
        error('acoustics:field', 'acoustics 中有未知字段：%s', strjoin(extra', ', '));
    end
    extra = setdiff(fieldnames(ac.positionDb), fieldnames(def.positionDb));
    if ~isempty(extra)
        error('acoustics:field', 'acoustics.positionDb 中有未知字段：%s', strjoin(extra', ', '));
    end
    num = @(x) isnumeric(x) && isscalar(x) && isfinite(x);
    if ~num(ac.stallQ) || ac.stallQ <= 0 || ac.stallQ > 1
        error('acoustics:value', 'acoustics.stallQ 应为 (0, 1] 的数');
    end
    if ~num(ac.stallDb) || ac.stallDb < 0
        error('acoustics:value', 'acoustics.stallDb 应为 ≥ 0 的数');
    end
    if ~num(ac.grilleRefZeta) || ac.grilleRefZeta <= 0
        error('acoustics:value', 'acoustics.grilleRefZeta 应为 > 0 的数');
    end
    fn = fieldnames(ac.positionDb);
    for k = 1:numel(fn)
        if ~num(ac.positionDb.(fn{k}))
            error('acoustics:value', 'acoustics.positionDb.%s 应为有限的数', fn{k});
        end
    end
end
