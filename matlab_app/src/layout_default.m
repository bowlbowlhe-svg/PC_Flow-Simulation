function L = layout_default(name)
%LAYOUT_DEFAULT 默认 ATX 中塔布局配置。
%   L = layout_default() 返回 'atx_balanced' 布局。
%
%   坐标约定（侧视 2D，x-y 平面）：
%     - 长度单位 mm；坐标相对机箱原点（机箱左上角外侧），
%       x 向右（后面板 → 前面板），y 向下（顶 → 底）。
%     - 矩形 struct('x',左,'y',上,'w',宽,'h',高)。
%     - 求解器按网格格距换算为格：格 = round(mm / 格距)；机箱壁占机箱边缘 1 格。
%   配置只含数据（数值、字符串、struct），可直接 jsonencode 保存。
%   可选字段（缺省即不存在）：cpu / gpu / psu / ram / vrm / solidBlocks /
%   porousBlocks / vents / air / caseFans。

    if nargin < 1 || isempty(name), name = 'atx_balanced'; end
    if ~strcmp(name, 'atx_balanced')
        error('layout_default:unknown', '未知布局：%s', name);
    end

    L = struct();
    L.name = name;
    L.ambientC = 25;
    L.turbulenceModel = 'komega';

    % ---- 计算域与机箱 ----
    % 计算域 560 mm 见方（基准网格 280×280、格距 2 mm），机箱 400 mm 见方，
    % 四周各留 80 mm 外部空气；机箱 Z 向有效深度 0.15 m（2D 换算用）。
    % 机箱壁温度：数值为 Dirichlet 温度 [°C]，NaN 为绝热。
    L.domain = struct('sizeMm', 560, 'baseCellMm', 2);
    L.chassis = struct('enabled', true, 'originMm', 80, 'sizeMm', 400, 'depthM', 0.15, ...
        'wallTempC', struct('rear', 25, 'front', 25, 'top', 25, 'bottom', 25));

    % ---- 默认功率 [W]（psu 为电源输出负载）----
    L.power = struct('cpu', 125, 'gpu', 250, 'psu', 450);

    % ---- 风扇通用参数 ----
    % 盘厚 12 mm；机箱风扇开口格栅阻力 ζ（Δp = ζ·½ρv²，Idelchik 手册近似）
    L.fanDiskMm = 12;
    L.grille = struct('intakeZeta', 2.0, 'exhaustZeta', 0.8);

    % ---- 噪音模型经验参数（见 acoustics_default、fan_noise_terms）----
    L.acoustics = acoustics_default();

    % ---- CPU：底座（固体）+ 塔式鳍片（多孔介质，穿流方向 x）+ 塔扇 ----
    % 热阻：带顶盖的小面积芯片结-壳热阻较大（公开评测里 120mm 单塔风冷
    % 满载总热阻约 0.25–0.4 K/W）。塔扇装在鳍片前侧，从前向后吹。
    L.cpu = struct();
    L.cpu.base = rect(194, 114, 48, 48);
    L.cpu.fins = rect(158, 86, 120, 104);
    L.cpu.porous = struct('zetaThru', 8, 'zetaCross', 60, 'thru', 'x');
    L.cpu.thermal = struct('R_junction_to_case', 0.15, 'R_tim', 0.04, 'R_base', 0.05, ...
        'fin_thickness_mm', 0.4, 'A_fin_total_m2', 0.15);
    L.cpu.tjmax = 100;
    L.cpu.throttleTemp = 95;
    L.cpu.fan = struct('model', 'Tower120', 'side', 'front');

    % ---- GPU：插在主板上的显卡，侧视只露卡厚。PCB 薄条（固体）+ 鳍片（多孔，穿流 x）+ 卡下 3 风扇 ----
    % 4 槽时显卡风扇下沿到电源仓挡板留 21 mm 进风。鳍片阻力取偏低值：真实显卡的热风
    % 还会从侧板方向（Z 向）排出，2D 侧视只能走卡的两端，降低阻力以作补偿。
    % 热阻：大面积 GPU 核心 + 均热板，公开评测里三风扇卡 250–320 W 核心温度
    % 约 65–75°C（总热阻约 0.12–0.16 K/W）。风扇向上吹入鳍片。
    % 厚度按扩展槽数：整卡 = slots × 20.32 mm = PCB（含背板）12 + 散热片 + 风扇盘 12，
    % 默认 4 槽（约 81 mm，高端显卡常见）；改厚度用 layout_set_gpu_slots（从 PCIe 槽向下长）。
    L.gpu = struct();
    L.gpu.slots = 4;
    L.gpu.pcb = rect(160, 212, 216, 12);
    L.gpu.heatsink = rect(150, 224, 236, 57);
    L.gpu.porous = struct('zetaThru', 4, 'zetaCross', 10, 'thru', 'x');
    L.gpu.thermal = struct('R_junction_to_case', 0.08, 'R_tim', 0.02, 'R_base', 0.02, ...
        'fin_thickness_mm', 0.35, 'A_fin_total_m2', gpu_fin_area(57));   % 鳍片面积随厚度缩放
    L.gpu.tjmax = 95;
    L.gpu.throttleTemp = 87;
    L.gpu.fans = struct('model', 'GPU80', 'xs', [190 268 346]);

    % ---- 电源：自带风道。风扇朝下经机箱底部进风，热风从后面板排出 ----
    % 外壳为 1 格固体，内部为多孔介质（元件阻力）；损耗 = 负载·(1/η − 1)，
    % η 按 80 PLUS 金牌典型曲线随负载率插值。
    L.psu = struct();
    L.psu.body = rect(4, 334, 164, 66);
    L.psu.ratedW = 850;
    L.psu.effCurve = struct('load', [0.1 0.2 0.5 1.0], 'eff', [0.82 0.87 0.90 0.87]);
    L.psu.porous = struct('zetaThru', 6, 'zetaCross', 6, 'thru', 'x');
    L.psu.fan = struct('model', 'PSU120', 'xMm', 86);
    L.psu.intakeZeta = 2.0;    % 底部防尘网
    L.psu.exhaustZeta = 1.0;   % 后部蜂窝格栅
    L.psu.R_internal = 0.25;   % 内部热点到进风的固定热阻 [K/W]（加对流项后总热阻约 0.3–0.4 K/W）
    L.psu.warnTemp = 85;       % 过温告警阈值 [°C]

    % ---- 主板上的其它元件（内部固体障碍，绝热）----
    L.ram = [rect(314, 48, 4, 32); rect(320, 48, 4, 32); ...
             rect(326, 48, 4, 32); rect(332, 48, 4, 32)];
    L.vrm = rect(158, 44, 28, 20);
    L.chipset = rect(264, 306, 20, 8);            % 仅显示（位于主板平面，不挡气流）
    L.motherboardTray = rect(150, 36, 248, 274);  % 仅显示

    % ---- 电源仓挡板：全宽水平隔板，前端留缺口（多数机箱在前部开孔）----
    L.shroud = struct('yMm', 314, 'hMm', 16, 'gaps', struct('x0Mm', 360, 'x1Mm', 398));

    % ---- 机箱风扇（型号见 fan_catalog，安装位见 fan_slots）----
    % mount 为所在壁面，alongMm 为风扇中心沿壁坐标（前/后壁为 y，顶/底壁为 x）。
    % 默认：前中、前下进气（F2、F3），后部排气（R1），顶后排气（T1）。
    % 只装一台前进气时，装在前中（正对显卡上半部与 CPU 塔扇进风）GPU 偏热，
    % 装在前下（正对显卡风扇进风）CPU 偏热（见 README 预设对比）。
    L.caseFans = [ ...
        caseFan('front', 220, 'intake',  'P12'); ...
        caseFan('front', 338, 'intake',  'P12'); ...
        caseFan('rear',  124, 'exhaust', 'P12'); ...
        caseFan('top',   140, 'exhaust', 'Stock120')];
end

function r = rect(x, y, w, h)
    r = struct('x', x, 'y', y, 'w', w, 'h', h);
end

function f = caseFan(mount, alongMm, type, model)
    f = struct('mount', mount, 'alongMm', alongMm, 'type', type, 'model', model, ...
               'speedMode', 'auto', 'manualPct', 60);
end
