function L = layout_set_gpu_slots(L, slots)
%LAYOUT_SET_GPU_SLOTS 按显卡占用的扩展槽数设置显卡厚度。
%   整卡厚度 = slots × 20.32 mm（PCIe 槽距）= PCB（含背板）+ 散热片 + 风扇盘；
%   显卡从 PCIe 槽（PCB 上沿）向下长，散热片高度 = 整卡厚度 − PCB 厚 − 风扇盘厚（取整到 mm）。
%   鳍片有效面积随散热片高度线性缩放（gpu_fin_area：3.5 槽、47 mm 为 0.45 m²；热参数没有 h 参数的旧模型布局
%   仍按旧标定 0.5·h/47，不把新旧标定混在一起）：厚卡散热能力更强，但显卡风扇到挡板的进风间隙变小。
%   可选 2–4.5 槽。显卡风扇下沿到电源仓挡板须留 ≥ 10 mm 进风间隙，否则报错。
%   读取当前槽数用 layout_gpu_slots。
    if ~isfield(L, 'gpu') || isempty(L.gpu)
        error('layout_set_gpu_slots:noGpu', '布局中没有显卡');
    end
    if ~isnumeric(slots) || ~isscalar(slots) || slots < 2 || slots > 4.5
        error('layout_set_gpu_slots:range', '显卡厚度应为 2–4.5 槽');
    end
    g = L.gpu;
    h = round(slots * 20.32 - g.pcb.h - L.fanDiskMm);
    g.heatsink.y = g.pcb.y + g.pcb.h;
    g.heatsink.h = h;
    g.slots = slots;
    if layout_heat_coef(g.thermal, 'gpu').legacy
        g.thermal.A_fin_total_m2 = 0.5 * h / 47;      % v4.7 及以前的标定（配旧式 h = 30 + 130·V）
    else
        g.thermal.A_fin_total_m2 = gpu_fin_area(h);
    end
    if isfield(L, 'shroud') && ~isempty(L.shroud)
        gap = L.shroud.yMm - (g.heatsink.y + h + L.fanDiskMm);
        if gap < 10
            error('layout_set_gpu_slots:gap', ...
                '%g 槽显卡的风扇下沿距电源仓挡板只有 %.0f mm（至少 10 mm），放不下', slots, gap);
        end
    end
    L.gpu = g;
end
