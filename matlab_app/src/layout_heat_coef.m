function hc = layout_heat_coef(th, what)
%LAYOUT_HEAT_COEF 鳍片对流系数参数（v4.8.0；规格 §4）：h = h_free + h_forced·min(V, 6)^h_exp [W/m²K]，
%   V 为鳍片区穿流方向的风速分量。
%   hc = layout_heat_coef(thermal, 'cpu') 返回 struct(h_free, h_forced, h_exp, passiveFlowShare, legacy)。
%   h_free、h_forced、h_exp 三个都不给（或为空）时为旧模型（legacy：h = 30 + 130·V，V 取风速模，同 v4.7）；只给一部分时报错。
%   passiveFlowShare：该元件有内置风扇但都没转（显卡低温停转）时，换热风速只计这一比例——静止的扇叶与风扇罩挡住
%   鳍片进风，机箱气流大多从卡旁空隙绕过（缺省 1）。
%   取值检查 h_free 0.1–500、h_forced 0–1000、h_exp 0.2–1.5、passiveFlowShare 0–1。
    keys = {'h_free', 'h_forced', 'h_exp'};
    given = cellfun(@(k) isfield(th, k) && ~isempty(th.(k)), keys);
    if any(given) && ~all(given)
        error('layout_heat_coef:field', '%s.thermal 的 h_free、h_forced、h_exp 要么都给，要么都不给（旧模型）', what);
    end
    if all(given)
        hc = struct('h_free', th.h_free, 'h_forced', th.h_forced, 'h_exp', th.h_exp, 'passiveFlowShare', 1, 'legacy', false);
    else
        hc = struct('h_free', 30, 'h_forced', 130, 'h_exp', 1, 'passiveFlowShare', 1, 'legacy', true);
    end
    if isfield(th, 'passiveFlowShare') && ~isempty(th.passiveFlowShare), hc.passiveFlowShare = th.passiveFlowShare; end
    ok = @(v, lo, hi) isnumeric(v) && isscalar(v) && v >= lo && v <= hi;
    if ~ok(hc.h_free, 0.1, 500) || ~ok(hc.h_forced, 0, 1000) || ~ok(hc.h_exp, 0.2, 1.5) || ~ok(hc.passiveFlowShare, 0, 1)
        error('layout_heat_coef:value', '%s.thermal 的 h_free 应为 0.1–500、h_forced 0–1000、h_exp 0.2–1.5、passiveFlowShare 0–1', what);
    end
end
