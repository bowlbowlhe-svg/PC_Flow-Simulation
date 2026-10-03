function L = layout_set_cpu_fans(L, n)
%LAYOUT_SET_CPU_FANS 设置 CPU 塔扇数量（1 或 2）。
%   双塔：1 扇装在两组鳍片中间，2 扇再加一个在前侧；单塔：1 扇在前侧，2 扇再加一个在后侧（推拉）。
%   布局里原来没有塔扇时按 Tower120 添加。读取当前结构用 layout_cpu_tower。
    if ~isfield(L, 'cpu') || isempty(L.cpu)
        error('layout_set_cpu_fans:noCpu', '布局中没有 CPU');
    end
    if ~isnumeric(n) || ~isscalar(n) || ~any(n == [1 2])
        error('layout_set_cpu_fans:range', 'CPU 塔扇数量应为 1 或 2');
    end
    if ~isfield(L.cpu, 'fan') || isempty(L.cpu.fan)
        L.cpu.fan = struct('model', 'Tower120', 'count', n);
    else
        L.cpu.fan.count = n;
    end
end
