function L = layout_default(name)
%LAYOUT_DEFAULT 默认 ATX 中塔布局配置。
%   L = layout_default() 返回 'atx_balanced' 布局。
%
%   坐标约定（侧视 2D，x-y 平面）：
%     - 长度单位 mm；元件坐标相对机箱原点（机箱左上角外侧），
%       x 向右（后面板 → 前面板），y 向下（顶 → 底）。
%     - 矩形 struct('x',左,'y',上,'w',宽,'h',高)。
%     - 求解器按网格格距换算为格坐标：格 = round(mm / 格距)。
%   配置只含数据，不含网格细节，可直接 jsonencode 保存。

    if nargin < 1 || isempty(name), name = 'atx_balanced'; end
    if ~strcmp(name, 'atx_balanced')
        error('layout_default:unknown', '未知布局：%s', name);
    end

    L = struct();
    L.name = name;

    % ---- 计算域与机箱 ----
    % 计算域 560 mm 见方（基准网格 280×280、格距 2 mm），机箱 400 mm 见方，
    % 四周各留 80 mm 外部空气区；机箱 Z 向有效深度 0.15 m（2D 换算用）。
    L.domain = struct('sizeMm', 560, 'baseCellMm', 2);
    L.chassis = struct('originMm', 80, 'sizeMm', 400, 'depthM', 0.15);

    % ---- 默认功率 [W] ----
    L.power = struct('cpu', 125, 'gpu', 250, 'psu', 450);

    % ---- CPU：底座（固体）+ 塔式鳍片（多孔介质，穿流方向 x）----
    L.cpu = struct();
    L.cpu.base = rect(194, 114, 48, 48);
    L.cpu.fins = rect(158, 86, 120, 104);
    L.cpu.porous = struct('zetaThru', 8, 'zetaCross', 60, 'thru', 'x');
    L.cpu.thermal = struct('R_junction_to_case', 0.08, 'R_tim', 0.04, 'R_base', 0.05, ...
        'R_fins_base', 0.08, 'efficiency', 0.88, 'fin_thickness_mm', 0.4, ...
        'A_fin_total_m2', 0.15);
    L.cpu.tjmax = 100;
    L.cpu.throttleTemp = 85;

    % ---- GPU：垂直插卡，侧视只露卡厚。PCB 薄条（固体）+ 鳍片（多孔，穿流 x）----
    L.gpu = struct();
    L.gpu.pcb = rect(160, 246, 216, 12);
    L.gpu.heatsink = rect(150, 258, 236, 48);
    L.gpu.porous = struct('zetaThru', 8, 'zetaCross', 20, 'thru', 'x');
    L.gpu.thermal = struct('R_junction_to_case', 0.12, 'R_tim', 0.06, 'R_base', 0.05, ...
        'R_fins_base', 0.10, 'efficiency', 0.85, 'fin_thickness_mm', 0.35, ...
        'A_fin_total_m2', 0.50);
    L.gpu.tjmax = 110;
    L.gpu.throttleTemp = 100;

    % ---- 电源：机身 + 风扇口（均为固体）----
    L.psu = struct();
    L.psu.body = rect(10, 330, 164, 66);
    L.psu.fan = rect(124, 330, 32, 66);
    L.psu.efficiency = 0.90;
    L.psu.tjmax = 85;
    L.psu.throttleTemp = 85;

    % ---- 主板上的其它元件（内部固体障碍，绝热）----
    L.ram = [rect(314, 48, 4, 32); rect(320, 48, 4, 32); ...
             rect(326, 48, 4, 32); rect(332, 48, 4, 32)];
    L.vrm = rect(158, 44, 28, 20);
    L.chipset = rect(264, 306, 20, 8);
    L.motherboardTray = rect(150, 36, 248, 274);   % 仅显示用

    % ---- 电源仓挡板：全宽水平隔板 ----
    L.shroud = struct('yMm', 314, 'hMm', 16);

    % ---- 机箱风扇（型号见 RealFan.FAN_DATABASE）----
    % x/y 为风扇挂载点（mm，相对机箱原点）；mount 为所在壁面。
    L.caseFans = [ ...
        struct('mount', 'front', 'x', 396, 'y', 250, 'type', 'intake',  'model', 'P12'); ...
        struct('mount', 'rear',  'x', 8,   'y', 124, 'type', 'exhaust', 'model', 'P12')];

    % ---- 内置风扇 ----
    % top：机箱顶部排气扇（y 取顶壁所在格）；cpu_tower：塔扇（位置取鳍片中心）；
    % gpu_bottom：显卡散热器下方三风扇。
    fanSpec = @(sz, rmin, rmax, cfm, nIdle, nMax) struct('size', sz, 'rpm_min', rmin, ...
        'rpm_max', rmax, 'cfm_max', cfm, 'noise_idle', nIdle, 'noise_max', nMax);
    L.topFan = struct('id', 'top_fan_0', 'x', 160, 'spec', fanSpec(120, 600, 2200, 65, 18, 32));
    L.cpuFan = struct('id', 'cpu_tower_fan', 'spec', fanSpec(120, 800, 2200, 60, 17, 31));
    L.gpuFans = struct('xs', [196 266 336], 'y', 308, 'spec', fanSpec(92, 800, 2600, 58, 16, 34));
end

function r = rect(x, y, w, h)
    r = struct('x', x, 'y', y, 'w', w, 'h', h);
end
