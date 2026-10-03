function m = fan_model_alias(m)
%FAN_MODEL_ALIAS 旧型号名 → 新型号名（读取 v4.5 及以前保存的配置用）。
%   RX120、RX140 的数据并非真实型号，v4.6.0 起换成 Phanteks T30-120、M25 Gen2 140。
    switch m
        case 'RX120', m = 'T30';
        case 'RX140', m = 'M25_140';
    end
end
