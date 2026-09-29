function s = struct_merge(s, o)
%STRUCT_MERGE 递归合并：o 中的字段覆盖 s，两边都是 struct 的字段逐字段合并。
    fn = fieldnames(o);
    for k = 1:numel(fn)
        if isfield(s, fn{k}) && isstruct(s.(fn{k})) && isstruct(o.(fn{k}))
            s.(fn{k}) = struct_merge(s.(fn{k}), o.(fn{k}));
        else
            s.(fn{k}) = o.(fn{k});
        end
    end
end
