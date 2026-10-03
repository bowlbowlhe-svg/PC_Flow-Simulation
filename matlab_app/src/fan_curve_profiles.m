function C = fan_curve_profiles(name)
%FAN_CURVE_PROFILES 自动温控的风扇曲线档位：'quiet'（静音）| 'standard'（标准，默认）| 'performance'（性能）。
%   C = fan_curve_profiles(name) 返回布局 fanCurves 字段的内容：
%     profile  档位名
%     caseFan  机箱风扇：传感器 = CPU、GPU 结温较高者（字段名不用 case：它是 MATLAB 关键字）
%     cpu      CPU 塔扇：传感器 = CPU 结温
%     gpu      显卡风扇：传感器 = GPU 结温；低温停转（结温 < stopBelowC 时停转，停转后升到 ≥ startAboveC 才重新转）
%     psu      电源风扇：传感器 = 电源温度；半被动（负载率 < passiveLoad 且温度 < passiveMaxC 时停转，
%              停转后升到 ≥ passiveRestartC 才重新转）
%   每条曲线 T [°C] → duty（占满速转速的比例），点间线性插值、两端取端点值。
%   转速 = max(rpm_min, duty · rpm_max)：常见 PWM 风扇的转速大致与占空比成正比，低端受最低转速限制。
%   标准档的机箱与塔扇曲线即 v4.5 及以前的温控曲线（55/70/80/85°C → 20/50/80/100%，最低 20%）。
    if nargin < 1 || isempty(name), name = 'standard'; end
    crv = @(T, d) struct('T', T, 'duty', d);
    switch name
        case 'quiet'
            cs  = crv([25 60 75 85 90], [0.20 0.20 0.45 0.75 1.00]);
            g   = crv([60 75 83 90],    [0.30 0.45 0.70 1.00]); g.stopBelowC = 55; g.startAboveC = 60;
            p   = crv([25 60 75 85 90], [0.20 0.20 0.45 0.75 1.00]);
        case 'standard'
            cs  = crv([25 55 70 80 85], [0.20 0.20 0.50 0.80 1.00]);
            g   = crv([55 70 80 87],    [0.30 0.50 0.75 1.00]); g.stopBelowC = 50; g.startAboveC = 55;
            p   = crv([25 55 70 80 85], [0.20 0.20 0.50 0.80 1.00]);
        case 'performance'
            cs  = crv([25 45 60 70 80], [0.30 0.35 0.60 0.85 1.00]);
            g   = crv([50 65 75 85],    [0.35 0.60 0.85 1.00]); g.stopBelowC = 45; g.startAboveC = 50;
            p   = crv([25 45 60 70 80], [0.30 0.35 0.60 0.85 1.00]);
        otherwise
            error('fan_curve_profiles:unknown', '未知风扇曲线档位：%s（应为 quiet/standard/performance）', name);
    end
    p.passiveLoad = 0.4; p.passiveMaxC = 60; p.passiveRestartC = 65;
    C = struct('profile', name, 'caseFan', cs, 'cpu', cs, 'gpu', g, 'psu', p);
end
