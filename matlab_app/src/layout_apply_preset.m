function L = layout_apply_preset(L, presetName)
%LAYOUT_APPLY_PRESET 按预设名重写布局的全部机箱风扇。
    P = fan_presets();
    k = find(strcmp({P.name}, presetName), 1);
    if isempty(k), error('layout_apply_preset:unknown', '未知预设：%s', presetName); end
    L.caseFans = L.caseFans([]);           % 清空（含不在安装位上的风扇）
    states = layout_slots('get', L);
    for i = 1:numel(states)
        states(i).type = 'none';
    end
    fans = P(k).fans;
    for j = 1:size(fans, 1)
        i = find(strcmp({states.id}, fans{j,1}), 1);
        states(i).type = fans{j,2};
        states(i).model = fans{j,3};
        states(i).speedMode = 'auto';
    end
    L = layout_slots('set', L, states);
end
