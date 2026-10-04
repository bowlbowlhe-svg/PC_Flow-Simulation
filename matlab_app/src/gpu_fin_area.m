function A = gpu_fin_area(heatsinkMm)
%GPU_FIN_AREA 显卡鳍片有效换热面积 [m²]，随散热片高度线性缩放：3.5 槽（散热片 47 mm）为 0.45 m²。
%   与鳍片对流系数（layout_heat_coef）一起按公开评测标定的有效值（v4.8.0；v4.7 及以前为 0.5 m²，配旧式 h）。
    A = 0.45 * heatsinkMm / 47;
end
