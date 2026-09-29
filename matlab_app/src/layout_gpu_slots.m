function s = layout_gpu_slots(L)
%LAYOUT_GPU_SLOTS 布局中显卡占用的扩展槽数（整卡厚度 / 20.32 mm）；无显卡时为 NaN。
%   有 gpu.slots 字段时直接返回；旧布局按 PCB + 散热片 + 风扇盘厚度折算，取到 0.5 槽。
    if ~isfield(L, 'gpu') || isempty(L.gpu)
        s = NaN;
    elseif isfield(L.gpu, 'slots') && ~isempty(L.gpu.slots)
        s = L.gpu.slots;
    else
        s = round((L.gpu.pcb.h + L.gpu.heatsink.h + L.fanDiskMm) / 20.32 * 2) / 2;
    end
end
