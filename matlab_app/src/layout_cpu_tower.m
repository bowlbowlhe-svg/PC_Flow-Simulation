function t = layout_cpu_tower(L)
%LAYOUT_CPU_TOWER CPU 塔式散热器的结构：塔数、双塔中间间隙、塔扇数量与位置。
%   t = layout_cpu_tower(L) 返回 struct：
%     stacks  鳍片组数：1 单塔 / 2 双塔（cpu.tower.stacks，缺省 1）
%     gapMm   双塔两组鳍片之间放风扇的间隙 [mm]（cpu.tower.gapMm，单塔为 0）
%     fans    塔扇数量（cpu.fan.count，缺省 1；无 cpu.fan 时为 0）
%     pos     各塔扇位置（cellstr，自前向后）：
%             双塔 1 扇 → 中间；双塔 2 扇 → 前 + 中间；单塔 1 扇 → 前；单塔 2 扇 → 前 + 后（推拉）
%   cpu.fins 是全部鳍片的外廓（双塔含中间间隙）。没有 cpu.tower、cpu.fan.count 的旧布局
%   按单塔、1 个前置塔扇解释（v4.4.0 及以前的模型）。取值不合法时报错。
    if ~isfield(L, 'cpu') || isempty(L.cpu)
        error('layout_cpu_tower:noCpu', '布局中没有 CPU');
    end
    c = L.cpu;
    t = struct('stacks', 1, 'gapMm', 0, 'fans', 0, 'pos', {{}});
    if isfield(c, 'tower') && ~isempty(c.tower)
        if isfield(c.tower, 'stacks') && ~isempty(c.tower.stacks), t.stacks = c.tower.stacks; end
        if isfield(c.tower, 'gapMm') && ~isempty(c.tower.gapMm), t.gapMm = c.tower.gapMm; end
    end
    if ~isnumeric(t.stacks) || ~isscalar(t.stacks) || ~any(t.stacks == [1 2])
        error('layout_cpu_tower:stacks', 'cpu.tower.stacks 应为 1（单塔）或 2（双塔）');
    end
    if t.stacks == 1
        t.gapMm = 0;
    elseif ~isnumeric(t.gapMm) || ~isscalar(t.gapMm) || ~(t.gapMm > 0) || t.gapMm >= c.fins.w
        error('layout_cpu_tower:gap', 'cpu.tower.gapMm 应为大于 0、小于鳍片总宽 %g mm 的数', c.fins.w);
    end
    if t.stacks == 2 && isfield(c, 'porous') && ~strcmp(c.porous.thru, 'x')
        error('layout_cpu_tower:thru', '双塔散热器的鳍片穿流方向应为 x（cpu.porous.thru = ''x''）');
    end
    if isfield(c, 'fan') && ~isempty(c.fan)
        t.fans = 1;
        if isfield(c.fan, 'count') && ~isempty(c.fan.count), t.fans = c.fan.count; end
        if ~isnumeric(t.fans) || ~isscalar(t.fans) || ~any(t.fans == [1 2])
            error('layout_cpu_tower:fans', 'cpu.fan.count 应为 1 或 2');
        end
        if t.stacks == 2
            P = {{'mid'}, {'front', 'mid'}};
        else
            P = {{'front'}, {'front', 'rear'}};
        end
        t.pos = P{t.fans};
    end
end
