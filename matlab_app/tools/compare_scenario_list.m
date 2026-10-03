function S = compare_scenario_list()
%COMPARE_SCENARIO_LIST 对比用的三个场景（同界面"办公 / 游戏 / 满载"按钮）：CPU、GPU、电源负载 [W]
    S = struct('key', {'office', 'gaming', 'heavy'}, 'label', {'办公', '游戏', '满载'}, ...
               'powers', {[40 35 200], [100 200 500], [180 320 850]});
end
