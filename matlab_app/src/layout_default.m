function L = layout_default(name)
%LAYOUT_DEFAULT 默认 ATX 机箱布局配置。
%   L = layout_default() 返回 'atx_balanced' 布局：紧凑 ATX 机箱，只比主板略大，
%   主板贴后壁（I/O 与扩展槽在后面板），前部留出前进风风扇的空间，电源在底部电源仓。
%
%   坐标约定（侧视 2D，x-y 平面）：
%     - 长度单位 mm；坐标相对机箱原点（机箱左上角外侧），
%       x 向右（后面板 → 前面板），y 向下（顶 → 底）。
%     - 矩形 struct('x',左,'y',上,'w',宽,'h',高)。
%     - 求解器按网格格距换算为格：格 = round(mm / 格距)；机箱壁占机箱边缘 1 格。
%     - chassis.sizeMm 为标量（见方）或 [深 高]，chassis.originMm 为标量（x = y）或 [x y]。
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
    % 计算域 560 mm 见方（基准网格 280×280、格距 2 mm）。机箱深 320 mm（后 → 前）× 高 400 mm：
    % ATX 主板 244 mm 深，前部 72 mm 放前进风风扇；高度含顶部风扇空间与底部电源仓。
    % 机箱居中，前后各留 120 mm、上下各留 80 mm 外部空气；机箱 Z 向有效深度 0.15 m（2D 换算用）。
    % 机箱壁：wallTempC 为数值时是定温壁（Dirichlet，°C），NaN 为绝热；panelU 为壁向室内空气的总传热系数
    % [W/m²K]（内侧对流 + 钢板/玻璃 + 外侧自然对流与辐射，钢板机柜约 5.5），edge = 四周壁，side = 两块侧板（v4.8.0）。
    L.domain = struct('sizeMm', 560, 'baseCellMm', 2);
    L.chassis = struct('enabled', true, 'originMm', [120 80], 'sizeMm', [320 400], 'depthM', 0.15, ...
        'wallTempC', struct('rear', NaN, 'front', NaN, 'top', NaN, 'bottom', NaN), ...
        'panelU', struct('edge', 5, 'side', 5));

    % ---- 默认功率 [W]（psu 为电源输出负载）----
    L.power = struct('cpu', 125, 'gpu', 250, 'psu', 450);

    % ---- 自动温控风扇曲线（档位见 fan_curve_profiles：quiet / standard / performance）----
    % 机箱风扇跟 CPU/GPU 较高者，塔扇跟 CPU，显卡风扇跟 GPU（低温停转），电源风扇跟电源温度（低负载半被动）。
    L.fanCurves = fan_curve_profiles('standard');

    % ---- 风扇通用参数 ----
    % 盘厚 12 mm；机箱风扇开口格栅阻力 ζ（Δp = ζ·½ρv²，Idelchik 手册近似）
    L.fanDiskMm = 12;
    L.grille = struct('intakeZeta', 2.0, 'exhaustZeta', 0.8);

    % ---- 噪音模型经验参数（见 acoustics_default、fan_noise_terms）----
    L.acoustics = acoustics_default();

    % ---- CPU：底座（只显示，不挡风）+ 双塔风冷（两组鳍片，多孔介质，穿流方向 x）+ 塔扇 ----
    % 侧视看到的是塔的侧面：前后两组鳍片（各 44 mm 厚、120 mm 高，与 120 风扇同高），中间 24 mm 间隙放风扇。
    % 塔扇 1 个（装在中间）或 2 个（前侧 + 中间），用 layout_set_cpu_fans 切换；都从前向后吹，
    % 热风直接对着后排风扇；鳍片后端距后排风扇执行盘约 22 mm，下沿距显卡 PCB 16 mm。
    % 2D 侧视里底座画在两组鳍片之间；真实机箱里底座贴主板、鳍片在它外侧，所以底座不是障碍（v4.4.0 起）。
    % 热阻：带顶盖的小面积芯片结-壳热阻较大；鳍片对流 h = h_free + h_forced·V^h_exp（V 为鳍片区穿流方向风速，
    % 见 DetailedThermalNetwork），A 与 h 为按公开评测标定的有效值（双塔风冷 125 W 时比环境高约 44 K、200 W 约 52–61 K）。
    % 穿流 ζ 为整个散热器（两组鳍片合计），横流 ζ 也施加在中间间隙（风扇框围住，空气不从间隙上下漏走）。
    L.cpu = struct();
    L.cpu.base = rect(68, 112, 48, 48);
    L.cpu.fins = rect(36, 76, 112, 120);           % 鳍片外廓（两组鳍片 + 中间间隙）
    L.cpu.tower = struct('stacks', 2, 'gapMm', 24);
    L.cpu.porous = struct('zetaThru', 8, 'zetaCross', 60, 'thru', 'x');
    L.cpu.thermal = struct('R_junction_to_case', 0.12, 'R_tim', 0.04, 'R_base', 0.04, ...
        'fin_thickness_mm', 0.4, 'A_fin_total_m2', 0.3, 'h_free', 5, 'h_forced', 48, 'h_exp', 0.8);
    L.cpu.tjmax = 100;
    L.cpu.throttleTemp = 95;                       % 温度墙：超过后降频把结温压在这里（见 DetailedThermalNetwork）
    L.cpu.dvfs = layout_dvfs(struct(), 'cpu');     % 加速频率随温度、功率随频率与温度（漏电）的参数
    L.cpu.fan = struct('model', 'Tower120', 'count', 2);

    % ---- GPU：插在主板上的显卡，侧视只露卡厚。PCB 薄条 + 鳍片（多孔，穿流 y）+ 卡下 3 风扇 ----
    % 3 槽时显卡风扇下沿到电源仓挡板留 41 mm 进风（4 槽 21 mm）。风扇向上吹入鳍片；鳍片片垂直于卡长（热管沿卡长），热风从卡的
    % 顶边（侧板方向）与插槽边排出：显卡只占主板到侧板距离的 zShare.gpu（约 80%），卡旁的空隙在 2D 里与 PCB、
    % 散热片重合，所以 PCB 是多孔区（ζ = zeta_partial(0.8) = 26），散热片穿流 y（鳍片 + 空隙）、横流 x 只能走空隙（ζ 25）。
    % 热阻：大面积 GPU 核心 + 均热板；公开评测里三风扇卡 250–300 W 游戏时核心约 60–69°C（开放平台，机箱内高 3–5°C），
    % 风扇约 1300–1600 rpm；风扇停转时被动散热只够约 45 W（3 槽；游戏负载下风扇会起转）。
    % 厚度按扩展槽数：整卡 = slots × 20.32 mm = PCB（含背板）12 + 散热片 + 风扇盘 12，
    % 默认 3 槽（约 61 mm，主流三风扇显卡常见；v4.9.0 起，之前为 4 槽）；改厚度用 layout_set_gpu_slots（从 PCIe 槽向下长）。
    % 挡板端在后面板：显卡贴着机箱尾部（v4.9.0）。从后壁到鳍片后端约 26 mm 是挡板与视频接口区（ioBlock = true：
    % 整卡厚度的实心障碍，显卡与后壁之间不过风）；PCB 与鳍片从后壁起 28 mm 处开始，前端伸出主板前缘约 16 mm。
    % v4.8.0 及以前这一段不是障碍，散热片后端的热风可沿后壁上行到后排风扇（缺 ioBlock 的旧配置仍按此计算）。
    L.gpu = struct();
    L.gpu.slots = 3;
    L.gpu.pcb = rect(28, 212, 226, 12);
    L.gpu.ioBlock = true;                          % 挡板端（后壁到鳍片后端）为实心障碍
    L.gpu.heatsink = rect(28, 224, 236, 37);
    L.gpu.porous = struct('zetaThru', 4, 'zetaCross', 25, 'thru', 'y');
    L.gpu.thermal = struct('R_junction_to_case', 0.03, 'R_tim', 0.015, 'R_base', 0.015, ...
        'fin_thickness_mm', 0.35, 'A_fin_total_m2', gpu_fin_area(37), ...   % 鳍片面积随厚度缩放
        'h_free', 3, 'h_forced', 48, 'h_exp', 0.8, 'passiveFlowShare', 0.1);
    L.gpu.tjmax = 95;
    L.gpu.throttleTemp = 87;
    L.gpu.dvfs = layout_dvfs(struct(), 'gpu');
    L.gpu.fans = struct('model', 'GPU80', 'xs', [68 146 224]);

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
    % 主板 ATX 244 × 305 mm，后缘贴后壁；下沿约 27 mm 在电源仓挡板后，主板区只画挡板以上部分。
    L.ram = [rect(190, 48, 4, 32); rect(196, 48, 4, 32); ...
             rect(202, 48, 4, 32); rect(208, 48, 4, 32)];
    L.vrm = rect(34, 44, 28, 20);
    % 准三维修正：零件占主板到侧板距离（约 175 mm）的比例。显卡高约 140 mm、DDR5 约 35–44 mm、VRM 散热片约 30 mm；
    % 小于 1 的零件旁边有空隙可以过风，按多孔区处理（见 layout_zshare、zeta_partial）
    L.zShare = struct('gpu', 0.8, 'ram', 0.2, 'vrm', 0.2);
    L.chipset = rect(174, 306, 20, 8);            % 仅显示（位于主板平面，不挡气流）
    L.motherboardTray = rect(4, 36, 244, 278);    % 仅显示

    % ---- 电源仓挡板（v4.9.0）：盖住电源的水平隔板，从后壁到电源前端外 16 mm（lengthMm = 184，电源长 164 mm），
    %      与后壁、底板和电源外壳构成电源仓；前方敞开，底部与前下方进风可直达显卡。电源有自己的外壳与风道（底部进风、
    %      后部排风），与机箱气流本来就隔开。之前为全宽隔板、前端开孔（缺 lengthMm 的旧配置仍按全宽）。----
    L.shroud = struct('yMm', 314, 'hMm', 16, 'lengthMm', 184, 'gaps', struct('x0Mm', {}, 'x1Mm', {}));

    % ---- 机箱风扇（型号见 fan_catalog，安装位见 fan_slots）----
    % mount 为所在壁面，alongMm 为风扇中心沿壁坐标（前/后壁为 y，顶/底壁为 x）。
    % 默认：前中、前下进气（F2、F3），后部排气（R1），顶后排气（T1，在 CPU 散热器正上方）。
    % 各预设的散热与噪音对比见 README。
    L.caseFans = [ ...
        caseFan('front', 220, 'intake',  'P12'); ...
        caseFan('front', 338, 'intake',  'P12'); ...
        caseFan('rear',  124, 'exhaust', 'P12'); ...
        caseFan('top',   100, 'exhaust', 'Stock120')];
end

function r = rect(x, y, w, h)
    r = struct('x', x, 'y', y, 'w', w, 'h', h);
end

function f = caseFan(mount, alongMm, type, model)
    f = struct('mount', mount, 'alongMm', alongMm, 'type', type, 'model', model, ...
               'speedMode', 'auto', 'manualPct', 60);
end
