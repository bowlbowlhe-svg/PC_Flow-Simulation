function A = gpu_fin_area(heatsinkMm)
%GPU_FIN_AREA 显卡鳍片总面积 [m²]，随散热片高度线性缩放：3.5 槽（散热片 47 mm）为 0.5 m²。
    A = 0.5 * heatsinkMm / 47;
end
