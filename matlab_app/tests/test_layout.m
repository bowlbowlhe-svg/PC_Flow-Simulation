function pass = test_layout()
%TEST_LAYOUT 布局配置工具链：安装位读写、预设、JSON 往返、安装检查。
%   1) 默认布局的安装位读出 → 写回，机箱风扇不变；
%   2) 每个预设都能构建求解器，机箱风扇数与预设一致；
%   3) JSON 往返：默认布局逐字段一致；含 NaN 壁温（绝热）的方腔布局往返后可构建；
%   4) 安装检查：同壁重叠、超出壁面能报出，标称风量与压力状态正确。
    errs = {};
    L0 = layout_default();

    % 1) 安装位往返
    st = layout_slots('get', L0);
    L1 = layout_slots('set', L0, st);
    errs = check(errs, isequal(sortFans(L1.caseFans), sortFans(L0.caseFans)), '安装位读出写回后机箱风扇应不变');
    errs = check(errs, sum(~strcmp({st.type}, 'none')) == numel(L0.caseFans), '默认布局的风扇都应在安装位上');

    % 2) 预设
    P = fan_presets();
    for k = 1:numel(P)
        L = layout_apply_preset(L0, P(k).name);
        s = CFDSolverFEM([], [], [], L, 0.5);
        errs = check(errs, numel(s.fans) == size(P(k).fans, 1), sprintf('预设 %s 风扇数', P(k).name));
        nFanOpen = sum(strcmp({s.openings.kind}, 'fan'));
        errs = check(errs, nFanOpen == numel(s.fans), sprintf('预设 %s 每台机箱风扇应有开口', P(k).name));
    end

    % 3) JSON 往返
    f = [tempname() '.json'];
    layout_json('save', L0, f);
    L2 = layout_json('load', f);
    errs = check(errs, isequal(L2, L0), '默认布局 JSON 往返应逐字段一致');
    Lc = layout_benchmark('cavity', 1e4);
    layout_json('save', Lc, f);
    Lc2 = layout_json('load', f);
    errs = check(errs, isnan(Lc2.chassis.wallTempC.top), 'NaN 壁温往返后应仍为 NaN');
    raw = jsondecode(fileread(f));                % 不经 normalize 直接构建也不应失败
    try
        CFDSolverFEM(0, 0, 0, raw, 0.5);
    catch ME
        errs{end+1} = ['未规整的 JSON 布局构建失败：' ME.message];
    end
    delete(f);

    % 4) 安装检查
    R = layout_fan_report(L0);
    errs = check(errs, isempty(R.warnings), '默认布局不应有安装警告');
    errs = check(errs, abs(R.intakeCfm - 112) < 0.1 && abs(R.exhaustCfm - 121) < 0.1 && strcmp(R.pressure, '平衡'), ...
        '默认布局满速标称进/排 112/121 CFM、平衡');
    % 低速：P12 520 rpm → 16.18 CFM；Stock120 920 rpm → 27.18 CFM
    errs = check(errs, abs(R.intakeCfmIdle - 32.36) < 0.05 && abs(R.exhaustCfmIdle - 43.36) < 0.05 && ...
        strcmp(R.pressureIdle, '负压'), '默认布局低速标称进/排 32.4/43.4 CFM、负压');
    L3 = L0;
    L3.caseFans(end+1) = L3.caseFans(1);
    L3.caseFans(end).alongMm = L3.caseFans(1).alongMm - 60;     % 同壁重叠 60 mm
    L3.caseFans(end+1) = L3.caseFans(1);
    L3.caseFans(end).alongMm = 380;                             % 超出前壁
    R3 = layout_fan_report(L3);
    errs = check(errs, numel(R3.warnings) >= 2, '应报出重叠与超出壁面');

    pass = isempty(errs);
    for k = 1:numel(errs), fprintf('  - %s\n', errs{k}); end
    if pass, stt = 'PASS'; else, stt = 'FAIL'; end
    fprintf('[layout] 安装位 / %d 个预设 / JSON 往返 / 安装检查：%s\n', numel(P), stt);
end

function errs = check(errs, cond, msg)
    if ~cond, errs{end+1} = msg; end
end

function F = sortFans(F)
    key = arrayfun(@(f) sprintf('%s%06.1f', f.mount, f.alongMm), F, 'UniformOutput', false);
    [~, i] = sort(key);
    F = F(i);
end
