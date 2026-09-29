function s = fan_pressure_label(qin, qout)
%FAN_PRESSURE_LABEL 由机箱风扇标称进/排风量判断机箱压力状态。
%   进 > 排 ×1.1 → '正压'；进 < 排 ×0.9 → '负压'；否则 '平衡'。
%   正压时多余进风从缝隙/被动开口排出，灰尘少；负压时从缝隙吸入。
    if qin <= 0 && qout <= 0
        s = '无机箱风扇';
    elseif qin > 1.1 * qout
        s = '正压';
    elseif qin < 0.9 * qout
        s = '负压';
    else
        s = '平衡';
    end
end
