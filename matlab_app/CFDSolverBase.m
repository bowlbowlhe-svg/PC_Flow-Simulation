classdef CFDSolverBase < handle
    %CFDSOLVERBASE PC风道CFD求解器公共基类
    % 公共基类：几何、热网络、风扇、评分、诊断等共享逻辑；由 CFDSolverFEM 实现 fluidStep
    
    properties (Constant)
        OBSTACLE = struct('WALL',1,'MOTHERBOARD',2,'CPU_BASE',3,'CPU_FINS',4,...
                          'GPU_PCB',5,'GPU_HEATSINK',6,'PSU_CASE',7,'PSU_FAN',8,...
                          'RAM_SLOT',9,'VRM',10,'CHIPSET',11,'PSU_SHROUD',12,'CABLE_BAR',13)
        AIR_DENSITY = 1.184
        AIR_CP = 1005
        CFM_TO_M3S = 0.0004719
        FLOW_EFFICIENCY = 0.75   % 流量效率缺省值（calibrate_anchor.m 标定锚点用）
        % 格栅/滤网系统阻力系数 ζ（ΔP = ζ·½ρv²，v2.6）
        % 进气：前面板开孔 + 防尘网典型 ζ≈2；排气：格栅 ζ≈0.8（Idelchik 手册近似）
        GRILLE_ZETA_INTAKE = 2.0
        GRILLE_ZETA_EXHAUST = 0.8
        % 机箱 Z 向深度（ATX mid-tower 内部约 200mm，扣除走线/侧板 ~150mm）
        CHASSIS_DEPTH_M = 0.15
    end
    
    properties
        DT = 0.005       % 时间步长 [s]（可在构造时覆盖，用于时间步敏感性研究）
        flowEfficiency = CFDSolverBase.FLOW_EFFICIENCY  % 实例级流量效率（标定时可覆盖）
        % 网格速度单位→物理 m/s 换算：u_phys = u_grid * (W-2)*cell_m
        % （由平流 dt0 = DT*(W-2) 推导；280×280×2mm 时 ≈0.556，对 gridScale 不敏感）
        VEL_SCALE = 0.554
        gridScale = 1    % 网格细化倍数：1=280×280×2mm，2=560×560×1mm，0.5=140×140×4mm
        GRID = struct('W',280,'H',280,'cell_size_mm',2,'TOTAL',78400)
        caseOffsetX = 40
        caseOffsetY = 40
        useGPU = false
        AIR
        p, T_fluid, T_solid
        % ===== v3.0：MAC 交错网格面场（唯一速度真源，P4 起；格心 u/v 过渡保留）=====
        % uF(y,xf)：x 法向面，W×(H+1)，向量化 (xf-1)*W+y；xf=1/H+1 为域边界面
        % vF(yf,x)：y 法向面，(W+1)×H，向量化 (x-1)*(W+1)+yf
        uF = []
        vF = []
        uFaceActive = []  % u 面激活掩码（两侧皆流体；域边界面取单侧邻格，远场开放）
        vFaceActive = []  % v 面激活掩码
        uFaceRing = []    % 邻接远场海绵环格的激活 u 面（阻尼用）
        vFaceRing = []    % 邻接远场海绵环格的激活 v 面
        obstacle
        iteration = 0
        fans = {}          % cell array of RealFan
        builtInFans = {}   % cell array of BuiltInFan
        thermalNetworks
        heatSources
        autoFanEnabled = true
        fanSpeedRatio = 40
        latestVorticity
        deadZoneRatio = 0
        lastDiag
        lastTemps
        % 几何定义 (grid坐标, 1-based)
        CASE2D
        CPU_HEATSINK
        GPU_HEATSINK
        PSU2D
        RAM_SLOTS
        VRM
        CHIPSET
        obsIdx = []        % 障碍物节点线性索引（由子类使用）
        heatObsIdx = []    % 散热器格（CPU/GPU/PSU 固体；v2.7.1 起 Neumann 绝热，T_fluid 仅显示 T_solid）
        wallObsIdx = []    % 机箱壁格（仅 OBSTACLE.WALL，Dirichlet T=25°C）
        adiabaticObsIdx = []  % 内部冷障碍格（主板/隔板/RAM/VRM/CHIPSET，Neumann 绝热，v2.7）
        % v3.1.0 多孔介质区（CPU 鳍片/GPU 散热片：不再是固体障碍，流体可穿流，
        % Darcy-Forchheimer 二次阻力逐面施加）
        porousZones = []   % struct 数组：rect / zetaThru / zetaCross / thru('x'|'y')
        uDragCoef = []     % u 面阻力系数（u ← u/(1+C|u|)），非多孔面为 0
        vDragCoef = []     % v 面阻力系数
        nearestFluidIdx = []  % 每个格子最近流体格的线性索引（v2.7：温度平流插值替换用）
        % 钳位/外缘重置能量计账（v2.7，累计 ΣΔT [K·cell]，守恒校核换算成功率）
        % 注：障碍格重置不计账——障碍格与流体的换热只经扩散（Q_pin/Q_wall 精确
        % 计量），平流路径已被 advect 的最近流体格替换切断，重置差是显示伪差。
        accResetOut  = 0   % 远场海绵环重置 25°C + 进气新风混合（v2.8 起仅 1 格环）
        accClamp     = 0   % 温度钳位（max 25 / min 200，数值能源，应≈0）
        % v3.0.2：钳位按计账点分项（定位 Q_R_clamp 净吸热来源，v3.0.1 审计附带观察）
        accClampSolve  = 0 % 扩散求解后 max(T,25)
        accClampAdvect = 0 % 温度平流后 max(T,25)
        accClampCap    = 0 % 共轭传热后 min(T,200)（削顶=汇）
        accClampFloor  = 0 % 共轭传热后 max(T,25)（抬底=源）
        accAdvect    = 0   % 温度平流步能量增量（应≈开口边界通量；诊断/账本用）
        accDiffuse   = 0   % 温度扩散求解步能量增量（应=Q_R_wall 逐步积分）
        accSteps     = 0
        accE0        = 0   % 计账清零时刻的流体储能 [J]（闭合判据的储能修正）
        accE0_case   = 0   % 同时刻机箱内部流体储能 [J]（v3.0.1：判据 B 储能修正基准）
        % v3.3.0：温度算子级机箱内区能量差累计 [K·cell]（B2 算子级口径）。
        % 采样口径 −30% 缺口经算子级插桩直测分解（1200 步回归窗）：高斯核尾
        % 越薄壁注入外围 35.5W（内区实收 335.7 vs 名义 371.2）+ 进气新风混合
        % −135.1W 真实冷却路径不在 Q_exhaust/Q_wall 采样口径内 + 开口面焓流
        % 采样高估 ~+50W 部分对冲；壁面 α 采样 30.7W 与算子扩散 −36.4W 实际
        % 接近（早期探针"壁面低估 ~−160W"归因系误并新风混合，已更正）；
        % 跨薄壁半拉格朗日泄漏证伪（~0W，内外 ΔT 仅 ~5K 限幅）。
        % 内区真值参考：平流 −154.3 / 扩散 −36.4 / 钳位 +0.7 / 储能 +10.6 W。
        accAdvectCase  = 0 % 平流步机箱内区 ΣΔT
        accDiffuseCase = 0 % 扩散求解步机箱内区 ΣΔT
        accClampCase   = 0 % 全部钳位点机箱内区 ΣΔT（Solve/Advect/Cap/Floor 合计）
        accBoundaryCase= 0 % 进气风扇新风混合（→25°C）机箱内区 ΣΔT（applyFanForces）
        accInjectCase  = 0 % 高斯热注入机箱内区 ΣΔT（核尾可越壁落外围格，不可假设=Q_gaussian）
        % v2.7 通风闭环校准：风扇动量源为任意强度，实测开口排气量系统性低于
        % datasheet 工作点（缓冲区阻尼 + cell-centered 采样 + 跨壁泄漏）。
        % flowGain 由慢积分控制器每步更新，使实测毛排气 CFM 收敛到风扇名义值。
        % v2.8：风机压升模型（改动 B）启用后闭环停用，flowGain 固定 1。
        flowGain = 1
        flowGainMax = 3     % 闭环增益上限（v2.8 起闭环停用，保留字段兼容）
        bufferDamping = 0.8 % [deprecated v2.8] 原外围全区阻尼；现仅 spongeDamping 作用于远场环
        spongeDamping = 0.8 % 远场海绵环（最外圈 spongeWidth 格）速度阻尼（每步保留比例，v2.8）
        spongeWidth = 1     % 海绵环厚度（格；v2.9 起可调，实验对照用）
        nuTCapFactor = 50   % LVEL ν_t 上限（×分子粘度；v2.7.1 起可调）
        omegaProj = 0.7     % 投影欠松弛系数（v2.9 起可调；障碍邻域算子错配防过冲）
        spongeDampPostProject = true  % v2.9：海绵环阻尼在投影后施加（false=投影前）
        % ===== v2.10：k-ω 两方程湍流模型（Wilcox 2006 + SST 式应力限制器）=====
        turbulenceModel = 'komega' % 'komega'（默认）| 'lvel'（回退到 v2.9 零方程路径）
        turbK = []        % 湍动能场 k [m²/s²]（N×1）
        turbOmega = []    % 比耗散率场 ω [1/s]（N×1）
        turbIntensity = 0.05  % 来流/初始湍流度 I
        turbRefVel = 2.0      % k₀ 参考速度 V_ref [m/s]（风扇名义速度量级）
        turbUpdateEvery = 1   % 湍流场更新子步（>1 时每 N 步更新一次，性能旋钮）
        nuTFloor = 1e-10      % k 下限（防除零/保正）
        insideMask = []    % 机箱内部线性索引（浮力/Re/死区诊断仍按机箱内统计）
        outsideMask = []   % 机箱外流体（v2.8 起为真实空气；仅远场海绵环特殊处理）
        spongeRingIdx = [] % 域最外圈 1 格流体格（v2.8 远场吸收层：阻尼+25°C 钉扎+p=0）
        liveOutsideMask = [] % 机箱外真实空气区 = outsideMask \ spongeRing（v2.8）
        wallDistanceM = [] % 每个 cell 到最近障碍物/壁面的距离 (m)；LVEL 湍流模型用
        % 各壁面开口的线性索引（initOpenBoundaries 记录；守恒校核/焓流积分用）
        openingIdx = struct('top',[],'rear',[],'front',[],'bottom',[])
        openBC = struct('intakeIdx',[],'intakeU',[],'intakeV',[],...
                        'exhaustIdx',[],'exhaustNbrIdx',[])  % 开口边界条件
    end
    
    methods
        function obj = CFDSolverBase(cpuPower, gpuPower, psuPower, layoutName, gridScale, dtVal)
            if nargin < 1, cpuPower  = 125; end
            if nargin < 2, gpuPower  = 250; end
            if nargin < 3, psuPower  = 450; end
            if nargin < 4, layoutName = 'atx_balanced'; end
            if nargin < 5 || isempty(gridScale), gridScale = 1; end
            if nargin < 6 || isempty(dtVal), dtVal = 0.005; end

            % 网格参数化：所有几何坐标按 gridScale 缩放（物理尺寸不变）
            obj.gridScale = gridScale;
            obj.DT = dtVal;
            Wg = round(280*gridScale);
            obj.GRID = struct('W',Wg,'H',Wg,'cell_size_mm',2/gridScale,'TOTAL',Wg*Wg);
            obj.caseOffsetX = round(40*gridScale);
            obj.caseOffsetY = round(40*gridScale);
            obj.VEL_SCALE = (obj.GRID.W-2) * (obj.GRID.cell_size_mm/1000);  % ≈0.552–0.558
            
            obj.AIR = struct('rho',1.184,'mu',1.81e-5,'nu',1.56e-5,...
                             'k',0.026,'cp',1005,'alpha',2.2e-5,'Pr',0.71,...
                             'beta',3.4e-3,'g',9.81);
            % GPU 检测：当前 280×280 网格规模下，稀疏求解的数据传输开销
            % 抵消了 GPU 加速收益，故默认关闭。若未来扩展至更大网格可启用。
            try
                g = gpuDevice;
                if ~isempty(g) && obj.useGPU
                    fprintf('GPU detected: %s (GPU acceleration enabled)\n', g.Name);
                end
            catch
                obj.useGPU = false;
            end
            obj.initGeometry();
            obj.initFields();
            obj.initObstacles();
            obj.initHeatSources(cpuPower, gpuPower, psuPower);
            obj.initBuiltInFans();
            obj.initFans(layoutName);
            obj.initOpenBoundaries();  % 风扇墙面开口（需在fans初始化后调用）
        end
        
        function initGeometry(obj)
            ox = obj.caseOffsetX;
            oy = obj.caseOffsetY;
            s  = obj.gridScale;
            sc = @(v) round(v * s);  % 280×280 基准坐标 → 当前网格坐标
            % ===== 机箱坐标：REAR=左, FRONT=右, TOP=上, BOTTOM=下 =====
            obj.CASE2D = struct('outer',struct('x',ox+1,'y',oy+1,'w',sc(200),'h',sc(200)),...
                                'motherboard_tray',struct('x',ox+sc(75),'y',oy+sc(18),'w',sc(124),'h',sc(137)));
            % A_fin_total_m2: 散热鳍片有效对流面积（基础面 + 所有鳍片双面）
            % CPU 塔式风冷（D15/AK620 级别）：~50 片 0.4mm 厚铝鳍 × 100×60mm = 0.6 m²，
            %   考虑鳍片间堵塞与边缘效应折算有效面积 ~0.15 m²
            % GPU 三风扇散热器（高端 RTX/RX 级）：均热板 + 大密度鳍片，厂家标称
            %   有效散热面积 0.5–1.0 m²（NVIDIA Founders 4090 标 ~0.8 m²）。
            %   仿真取保守端 0.5 m²，匹配 200–250W TDP 主流卡。
            obj.CPU_HEATSINK = struct(...
                'base',struct('x',ox+sc(97),'y',oy+sc(57),'w',sc(24),'h',sc(24)),...
                'fin_area',struct('x',ox+sc(79),'y',oy+sc(43),'w',sc(60),'h',sc(52)),...
                'thermal',struct('R_junction_to_case',0.08,'R_tim',0.04,'R_base',0.05,...
                                 'R_fins_base',0.08,'efficiency',0.88,'fin_thickness_mm',0.4,...
                                 'A_fin_total_m2',0.15));
            % v3.2.0：显卡几何按真实安装姿态重建——显卡垂直插于主板，侧视
            % （x-y 平面）只露出卡厚（2.5 槽 ≈50mm ≈24 格），不再画成 116mm
            % 高的整卡立面。自上而下：PCB+背板薄条（固体，结温显示）→ 鳍片区
            % （多孔介质）→ 卡下风扇（BuiltInFan，y=154，位置不变）。
            obj.GPU_HEATSINK = struct(...
                'pcb',struct('x',ox+sc(80),'y',oy+sc(123),'w',sc(108),'h',sc(6)),...
                'heatsink',struct('x',ox+sc(75),'y',oy+sc(129),'w',sc(118),'h',sc(24)),...
                'thermal',struct('R_junction_to_case',0.12,'R_tim',0.06,'R_base',0.05,...
                                 'R_fins_base',0.10,'efficiency',0.85,'fin_thickness_mm',0.35,...
                                 'A_fin_total_m2',0.50));
            obj.PSU2D = struct('body',struct('x',ox+sc(5),'y',oy+sc(165),'w',sc(82),'h',sc(33)),...
                               'fan',struct('x',ox+sc(62),'y',oy+sc(165),'w',sc(16),'h',sc(33)));
            obj.RAM_SLOTS = [struct('x',ox+sc(157),'y',oy+sc(24),'w',max(1,sc(2)),'h',sc(16));...
                             struct('x',ox+sc(160),'y',oy+sc(24),'w',max(1,sc(2)),'h',sc(16));...
                             struct('x',ox+sc(163),'y',oy+sc(24),'w',max(1,sc(2)),'h',sc(16));...
                             struct('x',ox+sc(166),'y',oy+sc(24),'w',max(1,sc(2)),'h',sc(16))];
            obj.VRM     = struct('heatsink',struct('x',ox+sc(79),'y',oy+sc(22),'w',sc(14),'h',sc(10)));
            obj.CHIPSET = struct('heatsink',struct('x',ox+sc(132),'y',oy+sc(153),'w',sc(10),'h',sc(4)));
        end
        
        function initFields(obj)
            N = obj.GRID.TOTAL;
            W = obj.GRID.W; H = obj.GRID.H;
            nUF = W*(H+1); nVF = (W+1)*H;   % v3.0 MAC 面场维度
            if obj.useGPU
                obj.p = gpuArray(zeros(N,1));
                obj.T_fluid = gpuArray(ones(N,1)*25);
                obj.T_solid = gpuArray(ones(N,1)*25);
                obj.obstacle = gpuArray(zeros(N,1,'uint8'));
                obj.latestVorticity = gpuArray(zeros(N,1));
                obj.uF = gpuArray(zeros(nUF,1));
                obj.vF = gpuArray(zeros(nVF,1));
            else
                obj.p = zeros(N,1);
                obj.T_fluid = ones(N,1)*25;
                obj.T_solid = ones(N,1)*25;
                obj.obstacle = zeros(N,1,'uint8');
                obj.latestVorticity = zeros(N,1);
                obj.uF = zeros(nUF,1);
                obj.vF = zeros(nVF,1);
            end
            obj.iteration = 0;
            % v2.7：重置能量计账与通风闭环增益
            obj.accResetOut = 0; obj.accClamp = 0; obj.accSteps = 0;
            obj.accAdvect = 0; obj.accDiffuse = 0;
            obj.accClampSolve = 0; obj.accClampAdvect = 0;
            obj.accClampCap = 0;  obj.accClampFloor = 0;
            obj.accAdvectCase = 0; obj.accDiffuseCase = 0; obj.accClampCase = 0;  % v3.3.0
            obj.accBoundaryCase = 0; obj.accInjectCase = 0;                      % v3.3.0
            obj.flowGain = 1;
            % v2.10：k-ω 湍流场初始化——k₀=1.5·(I·V_ref)²，ω₀=k₀/(β*·ν_t0)，ν_t0=ν
            betaStar = 0.09;
            k0 = 1.5 * (obj.turbIntensity * obj.turbRefVel)^2;   % [m²/s²]
            w0 = k0 / (betaStar * obj.AIR.nu);                    % ν_t0=ν → [1/s]
            obj.turbK = ones(N,1) * k0;
            obj.turbOmega = ones(N,1) * w0;
        end
        
        function initObstacles(obj)
            obj.obstacle(:) = 0;
            W = obj.GRID.W; H = obj.GRID.H;
            rectIdx = @(x,y,w,h) reshape(((x:min(W,x+w-1))'-1)*W + (y:min(H,y+h-1)), [], 1);
            ox = obj.caseOffsetX;
            oy = obj.caseOffsetY;
            cs = round(200*obj.gridScale);  % 机箱边长（格）
            caseLeft = ox + 1;
            caseRight = ox + cs;
            caseTop = oy + 1;
            caseBottom = oy + cs;
            
            % 1. 计算域最外层 1 格为远场海绵吸收层（v2.8）：不设固壁障碍，
            %    速度阻尼+温度 25°C 钉扎+压力 Dirichlet p=0（见 fluidStep /
            %    assemblePressureMatrix）；算子外圈为伪 Dirichlet，与吸收层语义自洽。
            %    机箱壁作为内部障碍物保留，见下文。
            
            % 2. 机箱外壳（内部边界，风扇位置后续打洞）
            %    索引约定：idx = (x-1)*W + y（reshape 后第一维为 y，第二维为 x）
            for j = caseTop:caseBottom
                obj.obstacle((caseLeft-1)*W + j) = obj.OBSTACLE.WALL;
            end
            for j = caseTop:caseBottom
                obj.obstacle((caseRight-1)*W + j) = obj.OBSTACLE.WALL;
            end
            for i = caseLeft:caseRight
                obj.obstacle((i-1)*W + caseTop) = obj.OBSTACLE.WALL;
            end
            for i = caseLeft:caseRight
                obj.obstacle((i-1)*W + caseBottom) = obj.OBSTACLE.WALL;
            end
            
            % CPU 底座
            cb = obj.CPU_HEATSINK.base;
            idx = rectIdx(cb.x,cb.y,cb.w,cb.h);
            obj.obstacle(idx(obj.obstacle(idx)==0)) = obj.OBSTACLE.CPU_BASE;
            % CPU 散热鳍片 —— v3.1.0 多孔介质化：不再是固体障碍，流体穿流，
            % Darcy-Forchheimer 阻力见 buildPorousDrag（穿流方向 = x，塔扇前后吹）
            % （先清空防 reset 重复注册）
            obj.porousZones = struct('rect',{},'zetaThru',{},'zetaCross',{},'thru',{});
            cf = obj.CPU_HEATSINK.fin_area;
            obj.porousZones = [obj.porousZones, ...
                struct('rect', cf, 'zetaThru', 8, 'zetaCross', 60, 'thru', 'x')];
            % GPU PCB
            gp = obj.GPU_HEATSINK.pcb;
            obj.obstacle(rectIdx(gp.x,gp.y,gp.w,gp.h)) = obj.OBSTACLE.GPU_PCB;
            % GPU 散热片 —— v3.1.0 多孔介质化；v3.2.0 几何按真实姿态改薄
            % （卡厚 ~48mm，见 initGeometry）且穿流方向改 x：鳍片槽道沿卡长
            % 走，卡下风扇向上吹入鳍片后转向卡的两端（±x）排出——与 CPU 塔扇
            % （thru=x，前后直吹）不同，GPU 横向 y 只承担进风转向，阻力稍高。
            % PCB 芯仍为固体；多孔区即 PCB 下方的鳍片段。
            gh = obj.GPU_HEATSINK.heatsink;
            obj.porousZones = [obj.porousZones, ...
                struct('rect', gh, 'zetaThru', 8, 'zetaCross', 20, 'thru', 'x')];
            % PSU 外壳
            psu = obj.PSU2D.body;
            obj.obstacle(rectIdx(psu.x,psu.y,psu.w,psu.h)) = obj.OBSTACLE.PSU_CASE;
            % PSU 风扇口
            pf = obj.PSU2D.fan;
            idx = rectIdx(pf.x,pf.y,pf.w,pf.h);
            obj.obstacle(idx(obj.obstacle(idx)==obj.OBSTACLE.PSU_CASE)) = obj.OBSTACLE.PSU_FAN;
            % PSU 隔板（全宽水平横向隔板，将机箱分为上层主板区和下层PSU区）
            idx = rectIdx(ox+1,oy+round(157*obj.gridScale),cs,round(8*obj.gridScale));
            obj.obstacle(idx(obj.obstacle(idx)==0)) = obj.OBSTACLE.PSU_SHROUD;
            % RAM 槽
            for r = 1:size(obj.RAM_SLOTS,1)
                ram = obj.RAM_SLOTS(r,:);
                idx = rectIdx(ram.x,ram.y,ram.w,ram.h);
                mask = obj.obstacle(idx)==0 | obj.obstacle(idx)==obj.OBSTACLE.MOTHERBOARD;
                obj.obstacle(idx(mask)) = obj.OBSTACLE.RAM_SLOT;
            end
            % VRM
            vrm = obj.VRM.heatsink;
            idx = rectIdx(vrm.x,vrm.y,vrm.w,vrm.h);
            mask = obj.obstacle(idx)==0 | obj.obstacle(idx)==obj.OBSTACLE.MOTHERBOARD;
            obj.obstacle(idx(mask)) = obj.OBSTACLE.VRM;
            % Chipset
            chip = obj.CHIPSET.heatsink;
            idx = rectIdx(chip.x,chip.y,chip.w,chip.h);
            mask = obj.obstacle(idx)==0 | obj.obstacle(idx)==obj.OBSTACLE.MOTHERBOARD;
            obj.obstacle(idx(mask)) = obj.OBSTACLE.CHIPSET;
            
            obj.obsIdx = find(obj.obstacle > 0);

            % 热散热器格（CPU 底座/GPU PCB/PSU 固体，温度由热网络决定）
            % v3.1.0：CPU_FINS/GPU_HEATSINK 已多孔介质化（不再是障碍），
            % heatTypes 中对应枚举不再出现于 obstacle，此处自动不含它们
            heatTypes = [obj.OBSTACLE.CPU_BASE, obj.OBSTACLE.CPU_FINS, ...
                         obj.OBSTACLE.GPU_PCB, obj.OBSTACLE.GPU_HEATSINK, ...
                         obj.OBSTACLE.PSU_CASE, obj.OBSTACLE.PSU_FAN];
            obj.heatObsIdx = find(ismember(obj.obstacle, heatTypes));
            % v2.7：冷障碍拆分为真冷壁（机箱壁，Dirichlet 25°C）与内部钉扎件
            % （主板/隔板/RAM 等，Neumann 绝热——它们不再是 25°C 无限大热沉）
            obj.wallObsIdx = find(obj.obstacle == obj.OBSTACLE.WALL);
            % v2.7.1：散热器也改为 Neumann 绝热——v2.7 全功率高斯注入已是唯一
            % 物理热源；若散热器仍 Dirichlet 钉扎 T_solid，钉扎格在近壁高 ν_t 区
            % 以不受功率约束的通量向流体二次注热（双重热源，实测系统级残差 +300%+）。
            obj.adiabaticObsIdx = find(obj.obstacle > 0 & obj.obstacle ~= obj.OBSTACLE.WALL);
            obj.computeInsideOutsideMasks();
            obj.buildPorousDrag();   % v3.1.0
        end

        function buildPorousDrag(obj)
            % v3.1.0 多孔介质阻力场（Darcy-Forchheimer 二次项）。
            % 鳍片区压降 Δp = ζ·½ρ|v|²，摊到区厚 L 上得体积加速度
            % a = ζ·|v|·v/(2L)；每步点阻尼 u ← u/(1+C·|u|)，
            % C = ζ·VEL_SCALE·DT/(2L)（无量纲，按网格速度计）。
            % 各向异性：穿流方向（thru）低阻 ζThru，横向高阻 ζCross，
            % 模拟鳍片通道的方向选择性。逐面隐式点弛豫是收缩映射，
            % 无条件稳定，无需进隐式扩散装配。
            % 面归属：u 面 (y,xf) 覆盖区 x0..x1 及其进/出面 xf=x0,x1+1
            % （y 限区内）；v 面同理。
            W = obj.GRID.W; H = obj.GRID.H;
            cellM = obj.GRID.cell_size_mm / 1000;
            uC = zeros(W, H+1);   % u 面 (y, xf)
            vC = zeros(W+1, H);   % v 面 (yf, x)
            for z = 1:numel(obj.porousZones)
                zn = obj.porousZones(z); r = zn.rect;
                x0 = max(2, r.x);         x1 = min(H-1, r.x + r.w - 1);
                y0 = max(2, r.y);         y1 = min(W-1, r.y + r.h - 1);
                if x1 < x0 || y1 < y0, continue; end
                Lx = max(1, r.w) * cellM; Ly = max(1, r.h) * cellM;
                if strcmp(zn.thru, 'x')
                    zU = zn.zetaThru; zV = zn.zetaCross;
                else
                    zU = zn.zetaCross; zV = zn.zetaThru;
                end
                cU = zU * obj.VEL_SCALE * obj.DT / (2 * Lx);
                cV = zV * obj.VEL_SCALE * obj.DT / (2 * Ly);
                uC(y0:y1, x0:x1+1) = max(uC(y0:y1, x0:x1+1), cU);
                vC(y0:y1+1, x0:x1) = max(vC(y0:y1+1, x0:x1), cV);
            end
            obj.uDragCoef = uC(:);
            obj.vDragCoef = vC(:);
        end

        function applyPorousDrag(obj)
            % v3.1.0：多孔区逐面二次阻尼（收缩映射，无条件稳定）。
            % 未激活面（贴固体）速度恒 0，1/(1+C·0)=1 无副作用。
            if isempty(obj.uDragCoef), return; end
            obj.uF = obj.uF ./ (1 + obj.uDragCoef .* abs(obj.uF));
            obj.vF = obj.vF ./ (1 + obj.vDragCoef .* abs(obj.vF));
        end

        function resetEnergyAccounting(obj)
            % 能量计账清零（v2.7.1）：热身后重置，使 accScale 平均窗口
            % 落在近稳态区间，守恒判据 A 不受升温瞬态污染；
            % 同时记录当前流体储能作为闭合判据的储能修正基准。
            obj.accResetOut = 0; obj.accClamp = 0; obj.accSteps = 0;
            obj.accAdvect = 0;  obj.accDiffuse = 0;
            obj.accClampSolve = 0; obj.accClampAdvect = 0;
            obj.accClampCap = 0;   obj.accClampFloor = 0;
            obj.accAdvectCase = 0; obj.accDiffuseCase = 0; obj.accClampCase = 0;  % v3.3.0
            obj.accBoundaryCase = 0; obj.accInjectCase = 0;                      % v3.3.0
            cell_m = obj.GRID.cell_size_mm / 1000;
            rhoCpCell = obj.AIR_DENSITY * obj.AIR_CP * cell_m^2 * obj.CHASSIS_DEPTH_M;
            obj.accE0 = sum(obj.T_fluid(obj.obstacle == 0) - 25) * rhoCpCell;
            % v3.0.1：机箱内部储能基准（判据 B 储能修正用；insideMask 由
            % computeInsideOutsideMasks 在初始化时建立，不含外围真实空气区）
            if ~isempty(obj.insideMask)
                obj.accE0_case = sum(obj.T_fluid(obj.insideMask) - 25) * rhoCpCell;
            else
                obj.accE0_case = 0;
            end
        end

        function computeInsideOutsideMasks(obj)
            % 机箱内部 = 矩形 [caseLeft, caseRight] × [caseTop, caseBottom] 内的自由流体
            W = obj.GRID.W; H = obj.GRID.H;
            ox = obj.caseOffsetX; oy = obj.caseOffsetY;
            cs = round(200*obj.gridScale);
            caseLeft = ox + 1; caseRight = ox + cs;
            caseTop = oy + 1;  caseBottom = oy + cs;
            insideRect = false(W, H);
            % 第一维为 y、第二维为 x（与 idx=(x-1)*W+y 约定一致）
            insideRect(caseTop:caseBottom, caseLeft:caseRight) = true;
            fluidMask = reshape(obj.obstacle == 0, W, H);
            obj.insideMask  = find(insideRect(:) & fluidMask(:));
            obj.outsideMask = find(~insideRect(:) & fluidMask(:));
            % v2.8 真开放域：最外圈 spongeWidth 格为远场海绵吸收层（阻尼+25°C
            % 钉扎+压力 Dirichlet p=0），其余外围格升格为真实空气
            % （浮力/平流/扩散全参与）。
            sw = max(1, round(obj.spongeWidth));
            ringMask = false(W, H);
            ringMask(1:sw, :) = true; ringMask(W-sw+1:W, :) = true;
            ringMask(:, 1:sw) = true; ringMask(:, H-sw+1:H) = true;
            obj.spongeRingIdx = find(ringMask(:) & fluidMask(:));
            spongeMask = false(W, H); spongeMask(obj.spongeRingIdx) = true;
            obj.liveOutsideMask = find(~insideRect(:) & fluidMask(:) & ~spongeMask(:));
            % 壁面距离场（用于 LVEL）：到最近障碍物的欧氏距离
            cell_m = obj.GRID.cell_size_mm / 1000;
            obsMask = reshape(obj.obstacle > 0, W, H);
            if any(obsMask(:))
                try
                    d_cells = bwdist(obsMask);  % Image Processing Toolbox
                catch
                    % 兜底：基于格子枚举的近似距离（慢但无依赖）
                    d_cells = obj.bwdistFallback(obsMask);
                end
            else
                d_cells = ones(W, H) * max(W, H);
            end
            obj.wallDistanceM = double(d_cells(:)) * cell_m;
            % v2.7：每个格子最近流体格的线性索引（温度平流插值替换用——
            % 防止回溯点落入钉扎热格/冷壁格插值带走不可计量的热量）
            if any(fluidMask(:))
                try
                    [~, nfIdx] = bwdist(fluidMask);  % Image Processing Toolbox
                catch
                    nfIdx = obj.nearestFluidFallback(fluidMask);
                end
                obj.nearestFluidIdx = nfIdx(:);
            else
                obj.nearestFluidIdx = [];
            end
        end

        function nIdx = nearestFluidFallback(~, fluidMask)
            % 无 Image Processing Toolbox 时的最近流体格索引（4 邻域迭代传播，
            % 不保证欧氏最近但保证取到邻近流体格——对本用途足够）
            [W, H] = size(fluidMask);
            cur = zeros(W, H);
            cur(fluidMask) = find(fluidMask);
            for it = 1:(W+H)
                if all(cur(:) > 0), break; end
                up    = [cur(2:W,:); zeros(1,H)];
                down  = [zeros(1,H); cur(1:W-1,:)];
                left  = [zeros(W,1) cur(:,1:H-1)];
                right = [cur(:,2:H) zeros(W,1)];
                cand = max(max(up, down), max(left, right));
                fill = cur == 0 & cand > 0;
                cur(fill) = cand(fill);
            end
            nIdx = cur;
        end

        function d = bwdistFallback(~, obsMask)
            % 简化 bwdist：扫描每个 fluid cell 找最近障碍物（O(N²) 慢）
            [Hgrid, Wgrid] = size(obsMask);
            d = zeros(Hgrid, Wgrid);
            [oj, oi] = find(obsMask);
            if isempty(oj), d = ones(size(obsMask)) * max(Hgrid, Wgrid); return; end
            for j = 1:Hgrid
                for i = 1:Wgrid
                    if obsMask(j, i)
                        d(j, i) = 0;
                    else
                        d(j, i) = sqrt(min((oj - j).^2 + (oi - i).^2));
                    end
                end
            end
        end

        function initHeatSources(obj, cpuPower, gpuPower, psuPower)
            obj.heatSources = struct('cpu',struct('power',cpuPower),...
                                     'gpu',struct('power',gpuPower),...
                                     'psu',struct('power',psuPower));
            obj.thermalNetworks.cpu = DetailedThermalNetwork('cpu', cpuPower, 100, 85, obj.CPU_HEATSINK);
            obj.thermalNetworks.gpu = DetailedThermalNetwork('gpu', gpuPower, 110, 100, obj.GPU_HEATSINK);
            obj.thermalNetworks.psu = DetailedThermalNetwork('psu', psuPower*(1-0.90), 85, 85, []);
        end
        
        function initBuiltInFans(obj)
            obj.builtInFans = {};
            ox = obj.caseOffsetX;
            oy = obj.caseOffsetY;
            s  = obj.gridScale;
            sc = @(v) round(v * s);
            % 顶部排气风扇 ×1（位于 CPU 上方，机箱顶壁）
            obj.builtInFans{end+1} = BuiltInFan(struct('id','top_fan_0',...
                'x',ox+sc(80),'y',oy+1,'type','exhaust','mount','top','size',120,...
                'rpm_min',600,'rpm_max',2200,'cfm_max',65,'noise_idle',18,'noise_max',32,...
                'gridScale',s));
            % CPU 塔式风冷风扇（从右向左吹过鳍片，朝向后置排气）
            cf = obj.CPU_HEATSINK.fin_area;
            cpuFanX = round(cf.x + cf.w/2);
            cpuFanY = round(cf.y + cf.h/2);
            obj.builtInFans{end+1} = BuiltInFan(struct('id','cpu_tower_fan',...
                'x',cpuFanX,'y',cpuFanY,'type','exhaust','mount','cpu_tower','size',120,...
                'rpm_min',800,'rpm_max',2200,'cfm_max',60,'noise_idle',17,'noise_max',31,...
                'gridScale',s));
            % GPU风扇 ×3（位于GPU散热器下方，机箱内部）
            gpuFans = [struct('x',ox+sc(98), 'y',oy+sc(154),'size',92,'rpm_min',800,'rpm_max',2600,'cfm_max',58,'noise_idle',16,'noise_max',34);...
                       struct('x',ox+sc(133),'y',oy+sc(154),'size',92,'rpm_min',800,'rpm_max',2600,'cfm_max',58,'noise_idle',16,'noise_max',34);...
                       struct('x',ox+sc(168),'y',oy+sc(154),'size',92,'rpm_min',800,'rpm_max',2600,'cfm_max',58,'noise_idle',16,'noise_max',34)];
            for i = 1:size(gpuFans,1)
                gf = gpuFans(i);
                obj.builtInFans{end+1} = BuiltInFan(struct('id',sprintf('gpu_fan_%d',i-1),...
                    'x',gf.x,'y',gf.y,'type','exhaust','mount','gpu_bottom','size',gf.size,...
                    'rpm_min',gf.rpm_min,'rpm_max',gf.rpm_max,'cfm_max',gf.cfm_max,...
                    'noise_idle',gf.noise_idle,'noise_max',gf.noise_max,'gridScale',s));
            end
        end
        
        function initFans(obj, layoutName)
            obj.fans = {};
            ox = obj.caseOffsetX;
            oy = obj.caseOffsetY;
            s  = obj.gridScale;
            sc = @(v) round(v * s);
            if strcmp(layoutName, 'atx_balanced')
                % 1个前面板进气（对准GPU高度）+ 1个后面板排气（CPU层，靠上）
                fanData = [struct('x',ox+sc(198),'y',oy+sc(125),'type','intake', 'model','P12','mount','front');...
                           struct('x',ox+sc(4),  'y',oy+sc(62), 'type','exhaust','model','P12','mount','rear')];
                for k = 1:size(fanData,1)
                    f = fanData(k);
                    obj.fans{end+1} = RealFan(struct('id',k,'x',f.x,'y',f.y,...
                        'type',f.type,'model',f.model,'mount',f.mount,'gridScale',s));
                end
            end
        end
        
        function [uC, vC] = getCellVelocity(obj)
            % v3.0：统一格心速度读取口（N×1 列向量，网格单位）。
            % MAC 交错网格：速度唯一真源为面场 uF/vF，格心值 = 两面臂平均。
            % 所有读速度的调用点一律走本接口，不直接访问 obj.u/obj.v。
            W = obj.GRID.W; H = obj.GRID.H;
            uM = reshape(obj.uF, W, H+1);
            vM = reshape(obj.vF, W+1, H);
            uC = reshape(0.5*(uM(:,1:H) + uM(:,2:H+1)), [], 1);
            vC = reshape(0.5*(vM(1:W,:) + vM(2:W+1,:)), [], 1);
        end

        function syncCellsToFaces(obj)
            % [v3.0 P5 起退役] 格心→面场过渡同步：面场已是唯一真源，
            % 所有力路径（风扇/浮力/海绵环）直接作用于面场，无回写需求。
            % 方法保留为空操作以防外部脚本误调；getCellVelocity 为唯一读取口。
        end

        function syncFacesToCells(obj)  %#ok<MANU>
            % [v3.0 P5 起退役] 面场→格心过渡同步：格心速度场已删除，
            % 读取一律走 getCellVelocity（面平均实时计算）。
        end

        function vn = getOpeningFaceVelocity(obj, mount, lo, hi)
            % 指定壁面开口段的 MAC 穿墙面法向速度（外向为正，网格单位，列向量）。
            % lo/hi：开口沿线方向格范围（top/bottom → x 范围；rear/front → y 范围），
            % 用于从该壁开口中筛出属于某台风扇的段。面索引约定与
            % computeOpeningFluxes 一致（top: yf=yy / bottom: yf=yy+1 /
            % rear: xf=xx / front: xf=xx+1）。
            % 用途（v3.0.1）：格栅 Δp = ζ·½ρv² 的 v 应取穿格栅平面的真实速度——
            % 盘区采样圈（r=30 格）覆盖风扇力施加区本身，读到射流核峰值，
            % 实测把 v 高估 2.7–3.4 倍（Δp 高估 3–12 倍，见 diag_grille_s1.m）。
            vn = [];
            if ~isfield(obj.openingIdx, mount), return; end
            idx = obj.openingIdx.(mount);
            if isempty(idx), return; end
            W = obj.GRID.W;
            yy = mod(idx-1, W) + 1;
            xx = ceil(idx / W);
            switch mount
                case {'top','bottom'}
                    sel = xx >= lo & xx <= hi;
                case {'rear','front'}
                    sel = yy >= lo & yy <= hi;
                otherwise
                    return;
            end
            xx = xx(sel); yy = yy(sel);
            if isempty(xx), return; end
            switch mount
                case 'top',    fLin = (xx-1)*(W+1) + yy;      sgn = -1; isV = true;
                case 'bottom', fLin = (xx-1)*(W+1) + yy + 1;  sgn = +1; isV = true;
                case 'rear',   fLin = (xx-1)*W + yy;          sgn = -1; isV = false;
                case 'front',  fLin = xx*W + yy;              sgn = +1; isV = false;
            end
            if isV
                vn = sgn * obj.vF(fLin);
            else
                vn = sgn * obj.uF(fLin);
            end
            vn = vn(:);
        end

        function [S_mag, V_local, y_wall] = computeStrainRateMag(obj)
            % 物理应变率张量模 |S| [1/s]、局部速度模 [m/s]、壁面距离 [m]（W×H）
            % v2.10 抽出共用：computeNuEff（LVEL/k-ω 两路径）与湍流输运的 P_k 共用，
            % 避免两处副本漂移。轴序约定：reshape(W,H) 后第 1 维=y、第 2 维=x。
            W = obj.GRID.W; H = obj.GRID.H;
            velScale = obj.VEL_SCALE;
            cellSizeM = obj.GRID.cell_size_mm / 1000;

            [uC, vC] = obj.getCellVelocity();
            umat = reshape(uC, W, H) * velScale;  % 直接转 m/s
            vmat = reshape(vC, W, H) * velScale;
            dudx = zeros(W,H); dudy = zeros(W,H); dvdx = zeros(W,H); dvdy = zeros(W,H);
            invDx = 1 / cellSizeM;
            % v3.0：法向梯度取面场精确差分（MAC 天然中心于格心）
            uMf = reshape(obj.uF, W, H+1) * velScale;
            vMf = reshape(obj.vF, W+1, H) * velScale;
            dudx = (uMf(:, 2:H+1) - uMf(:, 1:H)) * invDx;   % ∂u/∂x：u 面恰在格心两侧
            dvdy = (vMf(2:W+1, :) - vMf(1:W, :)) * invDx;   % ∂v/∂y：v 面同理
            % 切向梯度仍用格心中心差分（面场需两次平均，精度等价）
            dudy(2:W-1,2:H-1) = 0.5*(umat(3:W,2:H-1) - umat(1:W-2,2:H-1)) * invDx;  % ∂u/∂y：沿第1维
            dvdx(2:W-1,2:H-1) = 0.5*(vmat(2:W-1,3:H) - vmat(2:W-1,1:H-2)) * invDx;  % ∂v/∂x：沿第2维
            S_mag = sqrt(2*(dudx.^2 + dvdy.^2) + (dudy + dvdx).^2);  % [1/s]
            V_local = sqrt(umat.^2 + vmat.^2);  % [m/s]

            % 壁面距离（precomputed in computeInsideOutsideMasks）
            if isempty(obj.wallDistanceM) || numel(obj.wallDistanceM) ~= obj.GRID.TOTAL
                y_wall = ones(W, H) * cellSizeM;
            else
                y_wall = reshape(obj.wallDistanceM, W, H);
            end
        end

        function nuEff = computeNuEff(obj)
            % 有效粘性 ν_eff = ν + ν_t，空间场（v2.6 起），
            % 由 CFDSolverFEM.buildWeightedLaplacian 做面加权 FEM 装配。
            % v2.10：按 turbulenceModel 分派两条 ν_t 路径。

            nuMol = obj.AIR.nu;
            [S_mag, V_local, y_wall] = obj.computeStrainRateMag();

            if strcmp(obj.turbulenceModel, 'komega')
                % ===== k-ω 路径（v2.10, Wilcox 2006 + SST 式应力限制器）=====
                % ν_t = a₁·k / max(a₁·ω, S)，a₁=0.31：
                % 剪切主导区（S 大）限制器生效，防 stagnation 区 ν_t 过产；
                % 其余区域退化为标准 ν_t = k/ω。k/ω 场由 stepTurbulence 维护。
                if isempty(obj.turbK) || numel(obj.turbK) ~= obj.GRID.TOTAL
                    nuEff = nuMol * ones(obj.GRID.TOTAL, 1);
                    return;
                end
                a1 = 0.31;
                kMat = reshape(obj.turbK, obj.GRID.W, obj.GRID.H);
                wMat = reshape(obj.turbOmega, obj.GRID.W, obj.GRID.H);
                nu_t = a1 * kMat ./ max(a1 * wMat, S_mag);
                % 数值保险上限（LVEL 的 30× cap 不再适用本路径；k/ω 钳位
                % 已把 ν_t 约束在物理范围 O(10²-10³)×ν，此 cap 仅防瞬态爆值）
                nu_t = min(nu_t, 2000 * nuMol);
                nu_eff = nuMol + nu_t;
                nuEff = reshape(nu_eff, [], 1);
                nuEff(obj.obsIdx) = nuMol;
                return;
            end

            % ===== LVEL 零方程路径（Length-Velocity, Agonafer/Liao/Spalding 1996）=====
            % 电子设备散热行业标准（Ansys Icepak / 6SigmaET 默认），适合
            % 过渡/低 Re 内部流。比常数混合长度模型更物理：
            % - 用真实壁面距离 y（bwdist）替代"邻接障碍物"二元标记
            % - 用 van Driest 阻尼 D = 1 - exp(-y+/A+) 平滑近壁过渡
            % - ν_t = (κ·y·D)² · |S|，κ=0.4 (von Karman)
            % 仍是零方程代数模型，无额外 PDE，实时开销极小。

            % 壁面 Reynolds 数 y+ ≈ y·V/ν（LVEL 简化代理，省去隐式 u_τ）
            y_plus = max(y_wall .* V_local / nuMol, 0);
            % van Driest 阻尼：A+ = 26（Schlichting）
            D_vD = 1 - exp(-y_plus / 26);
            % 混合长度 l_m = κ·y·D（κ=0.4 von Karman）
            kappa = 0.4;
            l_m = kappa * y_wall .* D_vD;
            % 涡黏 ν_t = l_m² · |S|
            nu_t = (l_m.^2) .* S_mag;
            % 数值上限：默认 50× 分子粘度（近壁过渡区典型上限）。
            % 注意（v2.7.1 诊断）：该上限同时扼杀了自由剪切/射流核心区的
            % 湍流混合——真实风扇驱动箱内 ν_t/ν ~ O(10²-10³)，50× 时内部
            % 热只能靠慢扩散输运到主气流（实测系统等效换热仅 ~6 W/K，
            % 内部均温物理性偏高）。cap 可调供敏感性实验。
            % v2.10：k-ω 路径已解除此 cap，本上限仅作用于 LVEL 回退路径。
            nu_t = min(nu_t, obj.nuTCapFactor * nuMol);

            % v2.6：返回空间变化场 ν_eff(x) = ν_mol + ν_t(x)。
            % （v2.5 曾取机箱内中位数作均匀代表值——避免极端值触发重分解，
            %   但也抹平了 LVEL 壁面距离场的空间信息）
            nu_eff = nuMol + nu_t;
            nu_eff = min(nu_eff, 30 * nuMol);   % 数值上限（V2.5_PLAN 记录的妥协，仅 LVEL 路径）

            nuEff = reshape(nu_eff, [], 1);
            nuEff(obj.obsIdx) = nuMol;
        end

        function [kIn, wIn] = turbulenceInletValues(obj)
            % v2.10：来流/远场湍流边界值——低湍流度环境空气
            % k = 1.5·(I·V_ref)²，ω = k/(β*·ν_t,in)，ν_t,in = 10ν（常见入口假设）
            kIn = 1.5 * (obj.turbIntensity * obj.turbRefVel)^2;
            wIn = kIn / (0.09 * 10 * obj.AIR.nu);
        end

        function initOpenBoundaries(obj)
            % 在机箱壁风扇安装位置打洞，让气流穿过
            % 索引约定：idx = (x-1)*W + y（与 rectIdx / applyFanForces 一致）
            W = obj.GRID.W;
            ox = obj.caseOffsetX;
            oy = obj.caseOffsetY;
            cs = round(200*obj.gridScale);
            caseLeft = ox + 1;
            caseRight = ox + cs;
            caseTop = oy + 1;
            caseBottom = oy + cs;
            obj.openingIdx = struct('top',[],'rear',[],'front',[],'bottom',[]);  % 重置后重新记录
            allFans = [obj.fans, obj.builtInFans];
            for k = 1:length(allFans)
                fan = allFans{k};
                bnd = fan.getBounds();
                switch fan.mount
                    case 'top'
                        % 顶壁 y=caseTop，沿 x 方向开洞
                        xLo = max(caseLeft, floor(bnd.x));
                        xHi = min(caseRight, ceil(bnd.x + bnd.w));
                        if xLo > xHi, continue; end
                        wIdx = ((xLo:xHi)'-1)*W + caseTop;
                    case {'rear','left'}
                        % 后壁 x=caseLeft，沿 y 方向开洞
                        yLo = max(caseTop, floor(bnd.y));
                        yHi = min(caseBottom, ceil(bnd.y + bnd.h));
                        if yLo > yHi, continue; end
                        wIdx = (caseLeft-1)*W + (yLo:yHi)';
                    case {'front','right'}
                        % 前壁 x=caseRight，沿 y 方向开洞
                        yLo = max(caseTop, floor(bnd.y));
                        yHi = min(caseBottom, ceil(bnd.y + bnd.h));
                        if yLo > yHi, continue; end
                        wIdx = (caseRight-1)*W + (yLo:yHi)';
                    case 'bottom'
                        % 底壁 y=caseBottom，沿 x 方向开洞
                        xLo = max(caseLeft, floor(bnd.x));
                        xHi = min(caseRight, ceil(bnd.x + bnd.w));
                        if xLo > xHi, continue; end
                        wIdx = ((xLo:xHi)'-1)*W + caseBottom;
                    otherwise
                        continue;
                end
                % 在机箱壁上打洞（清除障碍物），并记录开口位置供通量/守恒计算
                obj.obstacle(wIdx) = 0;
                switch fan.mount
                    case 'top',                  obj.openingIdx.top    = [obj.openingIdx.top;    wIdx(:)];
                    case {'rear','left'},        obj.openingIdx.rear   = [obj.openingIdx.rear;   wIdx(:)];
                    case {'front','right'},      obj.openingIdx.front  = [obj.openingIdx.front;  wIdx(:)];
                    case 'bottom',               obj.openingIdx.bottom = [obj.openingIdx.bottom; wIdx(:)];
                end
            end
            obj.obsIdx = find(obj.obstacle > 0);
            heatTypes = [obj.OBSTACLE.CPU_BASE, obj.OBSTACLE.CPU_FINS, ...
                         obj.OBSTACLE.GPU_PCB, obj.OBSTACLE.GPU_HEATSINK, ...
                         obj.OBSTACLE.PSU_CASE, obj.OBSTACLE.PSU_FAN];
            obj.heatObsIdx = find(ismember(obj.obstacle, heatTypes));
            obj.wallObsIdx = find(obj.obstacle == obj.OBSTACLE.WALL);
            % v2.7.1：散热器也改为 Neumann 绝热——v2.7 全功率高斯注入已是唯一
            % 物理热源；若散热器仍 Dirichlet 钉扎 T_solid，钉扎格在近壁高 ν_t 区
            % 以不受功率约束的通量向流体二次注热（双重热源，实测系统级残差 +300%+）。
            obj.adiabaticObsIdx = find(obj.obstacle > 0 & obj.obstacle ~= obj.OBSTACLE.WALL);
            obj.computeInsideOutsideMasks();
            obj.computeFaceMasks();      % v3.0：MAC 面掩码随 obsIdx 重建
            obj.onOpeningsChanged();   % v2.7.1：通知子类重装压力矩阵（开口 p=0）
        end

        function computeFaceMasks(obj)
            % v3.0：MAC 面掩码。
            % u 面 (y,xf)：xf=2..H 为格间面（格 (y,xf-1) 与 (y,xf) 之间），
            %   激活 ⟺ 两侧皆流体（任一侧障碍 → 无穿透钉 0）；
            %   xf=1/H+1 为域边界面，单侧邻格流体即激活（远场开放，v2.8 语义）。
            % v 面 (yf,x) 同理。阻尼面 = 至少一侧邻接 spongeRingIdx 格的激活面。
            W = obj.GRID.W; H = obj.GRID.H;
            fM = reshape(obj.obstacle == 0, W, H);   % fM(y,x)
            % ---- u 面 (W, H+1) ----
            uAct = false(W, H+1);
            uAct(:, 2:H) = fM(:,1:H-1) & fM(:,2:H);
            uAct(:, 1)   = fM(:,1);
            uAct(:, H+1) = fM(:,H);
            % ---- v 面 (W+1, H) ----
            vAct = false(W+1, H);
            vAct(2:W, :) = fM(1:W-1,:) & fM(2:W,:);
            vAct(1, :)   = fM(1,:);
            vAct(W+1, :) = fM(W,:);
            obj.uFaceActive = uAct(:);
            obj.vFaceActive = vAct(:);
            % ---- 海绵环阻尼面 ----
            ringM = false(W, H); ringM(obj.spongeRingIdx) = true;
            uRing = false(W, H+1);
            uRing(:, 2:H) = ringM(:,1:H-1) | ringM(:,2:H);
            uRing(:, 1)   = ringM(:,1);
            uRing(:, H+1) = ringM(:,H);
            vRing = false(W+1, H);
            vRing(2:W, :) = ringM(1:W-1,:) | ringM(2:W,:);
            vRing(1, :)   = ringM(1,:);
            vRing(W+1, :) = ringM(W,:);
            obj.uFaceRing = uRing(:) & obj.uFaceActive;
            obj.vFaceRing = vRing(:) & obj.vFaceActive;
        end

        function onOpeningsChanged(~)
            % 开口重建钩子（v2.7.1）：FEM 子类覆写，重装压力矩阵。
            % 基类为空操作。
        end

        function applyOpenBoundaryBC(~)
            % 机箱开口边界不再需要强制速度/零梯度，
            % 流动由风扇动量源和压力场自然驱动。
            % v2.8：远场为海绵吸收层（最外圈 1 格阻尼+25°C+p=0），
            % 机箱外其余区域为真实空气，无任何强制边界。
        end

        function applyBuoyancy(obj)
            % v3.0：Boussinesq 浮力作用于 v 面场：dv/dt = -g·β·(T-T_ref)，
            % YDir reversed 故 -v 为向上。T 面取值 = y 向两邻格平均（边界面单侧）。
            % 作用域：激活面且至少一侧邻格属于机箱内部/机箱外真实空气区
            % （远场海绵环排除——环面另有阻尼吸收出流伪振荡，Gray & Giorgini 1976）
            W = obj.GRID.W; H = obj.GRID.H;
            Tm = reshape(obj.T_fluid, W, H);
            vTf = zeros(W+1, H);
            vTf(2:W, :) = 0.5*(Tm(1:W-1,:) + Tm(2:W,:));
            vTf(1, :)   = Tm(1,:);
            vTf(W+1, :) = Tm(W,:);
            buoyF = -obj.DT * obj.AIR.g * obj.AIR.beta * (vTf - 25);
            buoyM = false(W, H);
            buoyM([obj.insideMask; obj.liveOutsideMask]) = true;
            vB = false(W+1, H);
            vB(2:W, :) = buoyM(1:W-1,:) | buoyM(2:W,:);
            vB = vB & reshape(obj.vFaceActive, W+1, H);
            obj.vF = obj.vF + buoyF(:) .* double(vB(:));
        end

        function applyFanForces(obj)
            % v3.0：风扇动量源按面法向分解到 MAC 面场——fx 加到格两侧 u 面
            % （各 0.5 权重），fy 加到格两侧 v 面；共享面从两邻格各收一半，
            % 净效果与旧格心力一致，但力直接落在通量载体上（无格心↔面往返）。
            % 未激活面（贴障碍）不受力。进气 25°C 新风混合（T 场）不变。
            W = obj.GRID.W; H = obj.GRID.H;
            allFans = [obj.fans, obj.builtInFans];
            nUF = W*(H+1); nVF = (W+1)*H;
            uIdxAll = zeros(0,1); uValAll = zeros(0,1);
            vIdxAll = zeros(0,1); vValAll = zeros(0,1);
            for k = 1:length(allFans)
                fan = allFans{k};
                source = fan.getMomentumSource(obj);
                bounds = fan.getBounds();
                cx = bounds.x + bounds.w/2;
                cy = bounds.y + bounds.h/2;
                radius = max(bounds.w, bounds.h)/2;
                r = ceil(radius);
                iRange = max(2, floor(cx)-r) : min(W-1, floor(cx)+r);
                jRange = max(2, floor(cy)-r) : min(H-1, floor(cy)+r);
                [II, JJ] = ndgrid(iRange, jRange);
                dist = sqrt((II-cx).^2 + (JJ-cy).^2);
                inCircle = dist <= radius;
                II = II(inCircle); JJ = JJ(inCircle); dist = dist(inCircle);
                idx = (II-1)*W + JJ;
                free = obj.obstacle(idx) == 0;
                idx = idx(free); dist = dist(free);
                II = II(free); JJ = JJ(free);
                falloff = cos((dist/radius) * (pi/2));
                % v2.8：source.fx/fy 已是压升模型给出的每步网格速度增量
                % （物理导出），不再乘 flowGain 闭环增益与 ×2.0 经验系数
                fxC = source.fx * falloff;
                fyC = source.fy * falloff;
                % 格 (x=II, y=JJ) 的 u 面：xf=II 与 xf=II+1 → (xf-1)*W+y
                uIdxAll = [uIdxAll; (II-1)*W + JJ; II*W + JJ];        %#ok<AGROW>
                uValAll = [uValAll; 0.5*fxC; 0.5*fxC];                %#ok<AGROW>
                % v 面：yf=JJ 与 yf=JJ+1 → (x-1)*(W+1)+yf
                vIdxAll = [vIdxAll; (II-1)*(W+1) + JJ; (II-1)*(W+1) + JJ + 1]; %#ok<AGROW>
                vValAll = [vValAll; 0.5*fyC; 0.5*fyC];                %#ok<AGROW>
                if strcmp(fan.type, 'intake')
                    % 进气口吸入 25°C 外部空气（物理边界条件）；计入外缘重置
                    % 计账（这是边界通量，不属于数值能源）。
                    Tnew = 25*falloff + obj.T_fluid(idx).*(1-falloff);
                    obj.accResetOut = obj.accResetOut + sum(Tnew - obj.T_fluid(idx));
                    % v3.3.0：新风混合机箱内区 ΣΔT（算子级 B2；进气盘格在内区）
                    inCase = ismember(idx, obj.insideMask);
                    obj.accBoundaryCase = obj.accBoundaryCase + sum(Tnew(inCase) - obj.T_fluid(idx(inCase)));
                    obj.T_fluid(idx) = Tnew;
                end
            end
            if ~isempty(uIdxAll)
                dU = accumarray(uIdxAll, uValAll, [nUF,1]);
                dV = accumarray(vIdxAll, vValAll, [nVF,1]);
                obj.uF = obj.uF + dU .* double(obj.uFaceActive);
                obj.vF = obj.vF + dV .* double(obj.vFaceActive);
            end
        end

        function updateFlowGain(obj)
            % v2.7 通风闭环校准：风扇动量源强度是任意值（baseStrength·rpmRatio），
            % 实测换气流量系统性低于 datasheet 工作点。
            % v2.7.1：校准目标改为**全开口毛入流**——排气侧采样被穿透壁面的
            % 风扇射流污染（毛排气 91 CFM 但净换气仅 ~35 CFM，射流在同开口
            % 回流短路）；入流侧才是真实的新风补给。慢积分控制器把毛入流
            % 收敛到进气风扇名义值（getCFM·flowEfficiency·lastFlowFactor，
            % 含 P-Q 背压与格栅折减）。无进气风扇时退回排气口径。
            % 用上一完成步的场测量（fluidStep 开头调用）。
            caseWallMounts = {'top','rear','front','bottom','left','right'};
            targetIn = 0; targetOut = 0;
            for k = 1:length(obj.fans)
                f = obj.fans{k};
                cfm = f.getCFM(obj)*obj.flowEfficiency*f.lastFlowFactor;
                if strcmp(f.type, 'intake'),  targetIn  = targetIn  + cfm;
                else,                         targetOut = targetOut + cfm; end
            end
            for k = 1:length(obj.builtInFans)
                f = obj.builtInFans{k};
                if ~any(strcmp(f.mount, caseWallMounts)), continue; end  % 箱内循环不算
                cfm = f.getCFM(obj)*obj.flowEfficiency*f.lastFlowFactor;
                if strcmp(f.type, 'intake'),  targetIn  = targetIn  + cfm;
                else,                         targetOut = targetOut + cfm; end
            end
            flux = obj.computeOpeningFluxes();
            cfmIn  = flux.top.cfmIn  + flux.rear.cfmIn  + flux.front.cfmIn  + flux.bottom.cfmIn;
            cfmOut = flux.top.cfmOut + flux.rear.cfmOut + flux.front.cfmOut + flux.bottom.cfmOut;
            if targetIn >= 1
                target = targetIn; measured = cfmIn;
            elseif targetOut >= 1
                target = targetOut; measured = cfmOut;   % 无进气风扇的兜底口径
            else
                return;   % 无风扇（或仿真初始化前），不校准
            end
            if measured < 1
                return;   % 流场尚未建立，等下一步
            end
            step = 0.05 * (target/measured - 1);   % 慢积分（增益 0.05 防振荡）
            obj.flowGain = min(max(obj.flowGain * (1 + step), 0.5), obj.flowGainMax);
        end
        
        function temps = computeAirflowTemperatures(obj)
            ambient = 25;
            intakeCFM = 0; topExhaustCFM = 0; rearExhaustCFM = 0;
            otherExhaustCFM = 0;
            for k = 1:length(obj.fans)
                % v2.7：与动量轨同口径——lastFlowFactor 含 P-Q 背压与格栅折减
                f = obj.fans{k}; cfm = f.getCFM(obj)*obj.flowEfficiency*f.lastFlowFactor;
                if strcmp(f.type,'intake')
                    intakeCFM = intakeCFM + cfm;
                elseif strcmp(f.type,'exhaust')
                    if strcmp(f.mount,'top'),      topExhaustCFM  = topExhaustCFM  + cfm;
                    elseif strcmp(f.mount,'rear'), rearExhaustCFM = rearExhaustCFM + cfm;
                    else,                          otherExhaustCFM = otherExhaustCFM + cfm;
                    end
                end
            end
            % 内置风扇只有挂在机箱壁上的（如顶部排气扇）才参与全局换气；
            % cpu_tower / gpu_bottom 是箱内循环，不向箱外排热，不计入排气量
            caseWallMounts = {'top','rear','front','bottom','left','right'};
            for k = 1:length(obj.builtInFans)
                f = obj.builtInFans{k};
                if strcmp(f.type,'exhaust') && any(strcmp(f.mount, caseWallMounts))
                    cfm = f.getCFM(obj)*obj.flowEfficiency*f.lastFlowFactor;  % v2.7：同动量轨口径
                    if strcmp(f.mount,'top'),      topExhaustCFM  = topExhaustCFM  + cfm;
                    elseif strcmp(f.mount,'rear'), rearExhaustCFM = rearExhaustCFM + cfm;
                    else,                          otherExhaustCFM = otherExhaustCFM + cfm;
                    end
                end
            end
            cpuPower = obj.thermalNetworks.cpu.actual_power;  % 节流后实际发热
            gpuPower = obj.thermalNetworks.gpu.actual_power;
            psuHeat  = obj.thermalNetworks.psu.actual_power;
            heatCap  = obj.AIR_DENSITY * obj.AIR_CP * obj.CFM_TO_M3S;
            totalExhaust = topExhaustCFM + rearExhaustCFM + otherExhaustCFM;
            T_internal = ambient;
            if totalExhaust > 0.1
                T_internal = ambient + (cpuPower+gpuPower+psuHeat)/(totalExhaust*heatCap);
            end
            T_top = T_internal;
            if topExhaustCFM > 0.1
                T_top = T_internal + (cpuPower*0.4+gpuPower*0.3+psuHeat*0.3)/(topExhaustCFM*heatCap);
            end
            T_rear = T_internal;
            if rearExhaustCFM > 0.1
                T_rear = T_internal + (cpuPower*0.2+gpuPower*0.4+psuHeat*0.2)/(rearExhaustCFM*heatCap);
            end
            % v3.3.1（审计 P2）：代数轨排温物理上限——排气由元件加热，不可能
            % 超过最热结温；CFM 估计暖机期（lastFlowFactor 自 1 衰减中、
            % 冷流场背压大）上式发散，曾致后排气曲线启动/重置尖峰 82~119°C
            % （此时 Tj 仅 27-32°C，物理不可能）。稳态 T_top/T_rear 远低于
            % TjMax（~50/65 vs ~91°C），钳位只在瞬态生效。internalAmbient
            % 是 CHT 反馈量、不钳（分母为总排气，不发散）。
            TjMax = max([obj.thermalNetworks.cpu.T_junction, ...
                         obj.thermalNetworks.gpu.T_junction, ...
                         obj.thermalNetworks.psu.T_junction]);
            T_top  = min(T_top,  TjMax);
            T_rear = min(T_rear, TjMax);
            temps = struct('intake',ambient,'internalAmbient',T_internal,...
                           'topExhaust',T_top,'rearExhaust',T_rear,...
                           'totalCFM',intakeCFM+totalExhaust);

            % v2.6 CFD 交叉校验：从实际流场积分各开口的焓流/流量，
            % 与上面的代数热平衡对比。两轨差异大说明内部环境温度估计失真。
            flux = obj.computeOpeningFluxes();
            temps.topExhaustCFD  = flux.top.Tmean;
            temps.rearExhaustCFD = flux.rear.Tmean;
            outVol = max(0, flux.top.volM3s) + max(0, flux.rear.volM3s) + ...
                     max(0, flux.front.volM3s) + max(0, flux.bottom.volM3s);
            Qout   = flux.top.heatW + flux.rear.heatW + flux.front.heatW + flux.bottom.heatW;
            % v2.7：焓流/毛流量口径退为"排气平均温度"（报告项）——毛通量高估
            % 使其不代表内部均温；双轨对比改用与代数轨同定义的"机箱内部
            % 流体均温"（充分混合假设对应质量加权均值）。
            if outVol > 1e-6
                temps.exhaustMeanCFD = ambient + Qout/(obj.AIR_DENSITY*obj.AIR_CP*outVol);
            else
                temps.exhaustMeanCFD = ambient;
            end
            temps.interiorMeanCFD = mean(obj.T_fluid(obj.insideMask));
            temps.internalAmbientCFD = temps.interiorMeanCFD;
            temps.internalDiscrepancy = temps.internalAmbientCFD - T_internal;
        end

        function flux = computeOpeningFluxes(obj)
            % 各壁面开口的 CFD 实际通量（体积流量 / 焓流），外向为正
            % 供全局热平衡交叉校验与守恒校核使用（v2.6）
            cell_m = obj.GRID.cell_size_mm / 1000;
            dA    = cell_m * obj.CHASSIS_DEPTH_M;     % 每格开口面积（2D × Z 向深度）
            rhoCp = obj.AIR_DENSITY * obj.AIR_CP;
            mounts = {'top','rear','front','bottom'};
            flux = struct();
            for m = 1:numel(mounts)
                name = mounts{m};
                idx = obj.openingIdx.(name);
                if isempty(idx)
                    flux.(name) = struct('volM3s',0,'heatW',0,'cfm',0,'Tmean',25,...
                                         'cfmOut',0,'cfmIn',0);
                    continue;
                end
                % v3.0：直接读穿墙面（MAC 面场），v2.9 的 0.5·(开口+内侧) 面心
                % 补偿（D1）退役——面速度即穿越通量，无 cell-centered 采样偏置。
                % 外向法向：top=−v（YDir reversed，−v 向上），rear=−u，
                %           front=+u，bottom=+v。索引约定 idx=(x-1)*W+y。
                W2 = obj.GRID.W;
                yy = mod(idx-1, W2) + 1;
                xx = ceil(idx / W2);
                switch name
                    case 'top'   % 壁行 y=caseTop → v 面 yf=caseTop（格外侧 y−1）
                        fLin = (xx-1)*(W2+1) + yy;      sgn = -1; isV = true;  outIdx = idx - 1;
                    case 'rear'  % 壁列 x=caseLeft → u 面 xf=caseLeft（格外侧 x−1）
                        fLin = (xx-1)*W2 + yy;          sgn = -1; isV = false; outIdx = idx - W2;
                    case 'front' % 壁列 x=caseRight → u 面 xf=caseRight+1
                        fLin = xx*W2 + yy;              sgn = +1; isV = false; outIdx = idx + W2;
                    case 'bottom'% 壁行 y=caseBottom → v 面 yf=caseBottom+1
                        fLin = (xx-1)*(W2+1) + yy + 1;  sgn = +1; isV = true;  outIdx = idx + 1;
                end
                if isV
                    vn = sgn * obj.vF(fLin);
                else
                    vn = sgn * obj.uF(fLin);
                end
                vnPhys = vn * obj.VEL_SCALE;                       % m/s
                % v3.3.0：面温改迎风口径——出流面供体=内侧格、入流面供体=外侧格。
                % 旧中央平均 0.5·(内+外) 在双向流开口制造幻影热汇：入流面真实
                % 供体是外侧 25°C 新风（焓贡献应为 0），中央平均把面温抬到
                % ~(T内+25)/2，(Tf−25)·vn<0 形成不实出热项；v3.2.0 双向流
                % 翻倍后该项达 ~110W 级，是 B2 塞子项的主源（跨薄壁 SL 泄漏
                % 已由专项探针实测证伪 ~0W，见版本历史 v3.3.0）。
                Tf = obj.T_fluid(idx);
                inflowF = vnPhys < 0;
                Tf(inflowF) = obj.T_fluid(outIdx(inflowF));
                vol = sum(vnPhys) * dA;                            % m³/s（外向为正）
                volOut = sum(max(0, vnPhys)) * dA;                 % 出流毛量
                volIn  = sum(max(0, -vnPhys)) * dA;                % 入流毛量
                Q   = rhoCp * sum((Tf-25) .* vnPhys) * dA;  % W
                Tmean = 25;
                if vol > 1e-6   % 过小体积流量下 Q/vol 会爆表（v2.6.1 审计 S3）
                    Tmean = min(max(25 + Q/(rhoCp*vol), 25), 120);  % 截断到物理区间
                end
                flux.(name) = struct('volM3s',vol,'heatW',Q,'cfm',vol/obj.CFM_TO_M3S,'Tmean',Tmean,...
                                     'cfmOut',volOut/obj.CFM_TO_M3S,'cfmIn',volIn/obj.CFM_TO_M3S);
            end
        end

        function ff = computeFarFieldFlux(obj)
            % 远场海绵环的净/毛通量（v2.9 建立，v3.0 改面读数）：出域为正。
            % 直接读环界面（环格与内侧邻格之间的 MAC 面）：xf=2 / xf=H /
            % yf=2 / yf=W——面速度即跨界通量，D1 半格平均退役。
            % 外向法向：y 侧 −v/+v，x 侧 −u/+u。
            % 用途：全域质量账（开口净 + 远场净 ≈ 储能项≈0），区分开口采样
            % 偏差与远场环泄漏。
            W = obj.GRID.W; H = obj.GRID.H;
            cell_m = obj.GRID.cell_size_mm / 1000;
            dA = cell_m * obj.CHASSIS_DEPTH_M;
            rhoCp = obj.AIR_DENSITY * obj.AIR_CP;
            uM = reshape(obj.uF, W, H+1);
            vM = reshape(obj.vF, W+1, H);
            Tmat = reshape(obj.T_fluid, W, H);
            % 环界面法向速度（外向为正）
            vnTop    = -vM(2, :);          % yf=2（y=1 环格 / y=2 内侧之间）
            vnBottom =  vM(W, :);          % yf=W
            vnLeft   = -uM(:, 2).';        % xf=2
            vnRight  =  uM(:, H).';        % xf=H
            % v3.3.0：环面温同改迎风口径（出流供体=内侧格，入流供体=环格
            % 25°C）——中央平均在双向流下制造幻影出热项，与开口通量同型修复。
            TTop    = Tmat(2, :);      mT = vnTop < 0;    TTop(mT)    = Tmat(1, mT);
            TBottom = Tmat(W-1, :);    mB = vnBottom < 0; TBottom(mB) = Tmat(W, mB);
            TLeft   = Tmat(:, 2).';    mL = vnLeft < 0;   tmpL = Tmat(:, 1).';   TLeft(mL)  = tmpL(mL);
            TRight  = Tmat(:, H-1).';  mR = vnRight < 0;  tmpR = Tmat(:, H).';   TRight(mR) = tmpR(mR);
            vn = [vnTop, vnBottom, vnLeft, vnRight] * obj.VEL_SCALE;   % m/s
            Tf = [TTop, TBottom, TLeft, TRight];
            volNet   = sum(vn) * dA;
            volGross = sum(abs(vn)) * dA;
            heatW    = rhoCp * sum((Tf - 25) .* vn) * dA;
            ff = struct('volM3s',volNet,'grossM3s',volGross,...
                        'cfm',volNet/obj.CFM_TO_M3S,...
                        'grossCfm',volGross/obj.CFM_TO_M3S,...
                        'heatW',heatW);
        end

        function cons = computeConservationCheck(obj)
            % 系统级能量/质量守恒校核（v2.6 建立 / v2.7 升级）：把"看起来合理"
            % 变成可证伪的数值指标。
            %
            % 判据 A（流体域总账本，严格）：所有能源/能汇均逐步实测——
            %   Q_gaussian（全功率高斯注入，唯一物理热源）+ Q_R_advect（平流步
            %   能量增量实测）+ Q_R_diffuse（扩散求解步实测=−全壁面吸热）
            %   + Q_R_out（外缘重置实测）+ Q_R_clamp（温度钳位实测）≈ 0（稳态）
            %   稳态时储能不变、账本归零；残差 = 瞬态储能速率 + 未计量路径。
            %   v2.7 温度平流把障碍格值替换为最近流体格值，切断了
            %   "回溯落入钉扎热格带热"的不可计量伪路径。
            %   v2.7.1：散热器格改 Neumann 绝热，不再是 Dirichlet 热库，
            %   消除"高斯注入 + 钉扎格扩散"双重热源。
            %   注意：Q_R_advect 与 Q_R_out 单独看都被外缘缓冲区的射流搅动
            %   通胀（缓冲区内热羽流被半拉格朗日复制、再由重置倾泻），
            %   两者之和才是跨机箱边界的净物理排热。
            %
            % 判据 B（系统级闭合，gridScale=1 标定，独立采样路径）：
            %   Q_exhaust（开口焓流带符号积分）+ Q_openingDiff（开口平面
            %   扩散导热，v3.0.2）+ Q_wall_case（机箱壁导热，逐格 α 面加权）
            %   ≈ Q_injected
            %   与判据 A 的逐步计账互为独立测量；偏差主要来自质量不平衡
            %   与面 α 近似。v3.0.1：原残差只在真稳态成立（机箱热浸透
            %   储能会被误读为未排出），新增储能修正口径 residualCorrPct——
            %   Q_out + 机箱内储能速率 ≈ Q_injected，任意时刻成立的机箱级
            %   瞬时平衡。远场环焓流（farFieldHeatW）只作报告项：穿环热量中
            %   先过开口的部分（平流焓流 Q_exhaust + 开口扩散 Q_openingDiff）
            %   已入账，显式相加会双重计数；越环的其余部分是机箱外绕行气流
            %   与外部空气池的换热，超出机箱级平衡口径；全域口径由判据 A 覆盖。
            %
            % Q_wall 用与扩散矩阵一致的离散通量 q_face = ρcp_cell·α_face·gs·ΔT
            % （对 gridScale 不变：ρcp_cell·gs = ρcp·depth·0.31）；
            % α_face 取 (α_流体格+α_分子)/2 面加权近似（壁面格 α≈分子值），
            % 逐格使用 FEM 存储的 lastAlphaField（v2.7.1；标量路径退回中位数）。
            flux = obj.computeOpeningFluxes();
            Q_exhaust = flux.top.heatW + flux.rear.heatW + flux.front.heatW + flux.bottom.heatW;
            netVol    = flux.top.volM3s + flux.rear.volM3s + flux.front.volM3s + flux.bottom.volM3s;
            grossVol  = sum(abs([flux.top.volM3s flux.rear.volM3s flux.front.volM3s flux.bottom.volM3s]));
            % v2.9：远场环通量 + 全域质量账（开口净 + 远场净 ≈ 0；不可压稳态下
            % 储能体积项≈0）。分开口口径与全域口径，区分采样偏差与环泄漏。
            ff = obj.computeFarFieldFlux();
            domainNetVol = netVol + ff.volM3s;
            domainGross  = grossVol + ff.grossM3s;
            domainMassPct = 100 * domainNetVol / max(domainGross, eps);

            % 组件实际发热功率（热网络节流后值，三件口径一致）
            Q_injected = obj.thermalNetworks.cpu.actual_power + ...
                         obj.thermalNetworks.gpu.actual_power + ...
                         obj.thermalNetworks.psu.actual_power;
            Q_gaussian = Q_injected;   % v2.7：全功率高斯注入（原 /5 平滑系数已去除）

            % 逐格热扩散率场（FEM 子类在 diffuseTemperature 里存储 lastAlphaField；
            % 标量路径/首步前退回中位数近似）
            alphaMol = obj.AIR.nu / obj.AIR.Pr;
            alphaEff = alphaMol;
            if isprop(obj, 'lastAlphaEff') && obj.lastAlphaEff > 0
                alphaEff = obj.lastAlphaEff;
            end
            if isprop(obj, 'lastAlphaField') && ~isempty(obj.lastAlphaField)
                alphaFieldVec = obj.lastAlphaField(:);
            else
                alphaFieldVec = [];
            end
            cell_m = obj.GRID.cell_size_mm / 1000;
            gs = (obj.GRID.W-2) * (obj.GRID.H-2);
            rhoCpCell = obj.AIR_DENSITY * obj.AIR_CP * cell_m^2 * obj.CHASSIS_DEPTH_M;

            W = obj.GRID.W; H = obj.GRID.H;
            Tmat   = reshape(obj.T_fluid, W, H);
            fluidM = reshape(obj.obstacle == 0, W, H);

            % 邻接面计数（4 邻域）
            faceCount = @(obsMask2d) ...
                [zeros(1,H); obsMask2d(1:W-1,:)] + [obsMask2d(2:W,:); zeros(1,H)] + ...
                [zeros(W,1) obsMask2d(:,1:H-1)] + [obsMask2d(:,2:H) zeros(W,1)];

            % 逐格面系数 [W/K]：面 α 取 (α_格+α_分子)/2（壁面格 α≈分子值）
            if ~isempty(alphaFieldVec)
                kFaceCell = rhoCpCell * gs * 0.5*(alphaFieldVec + alphaMol);
            else
                kFaceCell = rhoCpCell * gs * alphaEff * ones(size(obj.T_fluid));
            end

            % Q_wall：流体 → 机箱壁（25°C Dirichlet），仅计正贡献——这是 v2.7 起
            % 唯一参与系统级闭合的壁面路径（热量真正离开机箱）。
            caseM = reshape(obj.obstacle == obj.OBSTACLE.WALL, W, H);
            dTpos = max(0, Tmat - 25) .* fluidM;
            fcCase = faceCount(caseM);
            Q_wall_case = sum((dTpos(:) .* fcCase(:)) .* kFaceCell);
            % 反事实参考项：内部钉扎件已 Neumann 绝热化（v2.7），实际通量≈0；
            % 此项估计"若仍钉 25°C 会吸走多少热"，仅用于展示邻近过热度，不计入闭合
            adiM = false(W, H); adiM(obj.adiabaticObsIdx) = true;
            fcAdi = faceCount(adiM);
            Q_wall_internal = sum((dTpos(:) .* fcAdi(:)) .* kFaceCell);
            Q_wall = Q_wall_case;

            % v3.0.2：开口平面扩散导热入账（v3.0.1 审计定位的缺口来源之一）。
            % 机箱内热空气经开口面向外围的导热是真实出箱热流，Q_exhaust 只计
            % 平流焓流、不含此项，二者不双计。口径与 Q_wall_case/扩散矩阵严格
            % 同态：q_face = ρcp_cell·gs·α_face·ΔT（α_face=0.5·(α内+α外)，
            % 开口两面皆流体、不替换 α_分子；outIdx 约定同 computeOpeningFluxes）。
            % 注意：审计诊断原稿用教科书物理通量 ρcp·α·ΔT·depth，是本口径的
            % 1/(cell_m²·gs)≈3.2 倍——求解器实际扩散输运速率由 PDE
            % dT/dt=gs·α·L_grid 决定，能量账本须按求解器实际口径入账。
            Q_openingDiffPer = struct('top',0,'rear',0,'front',0,'bottom',0);
            for m = {'top','rear','front','bottom'}
                nm = m{1};
                idx = obj.openingIdx.(nm);
                if isempty(idx), continue; end
                switch nm
                    case 'top',    outIdx = idx - 1;
                    case 'rear',   outIdx = idx - W;
                    case 'front',  outIdx = idx + W;
                    case 'bottom', outIdx = idx + 1;
                end
                if ~isempty(alphaFieldVec)
                    aFaceOp = 0.5*(alphaFieldVec(idx) + alphaFieldVec(outIdx));
                else
                    aFaceOp = alphaEff;
                end
                Q_openingDiffPer.(nm) = sum(rhoCpCell * gs .* aFaceOp .* ...
                    (obj.T_fluid(idx) - obj.T_fluid(outIdx)));
            end
            Q_openingDiff = Q_openingDiffPer.top + Q_openingDiffPer.rear + ...
                            Q_openingDiffPer.front + Q_openingDiffPer.bottom;

            % Q_pin（报告项，v2.7.1 起恒 0）：散热器格已 Neumann 绝热化，
            % 不再是 Dirichlet 热库——全功率高斯注入是唯一物理热源，
            % 散热器与流体间无扩散通量路径。
            Q_pin = 0;

            % 判据 A：流体域能源/能汇，全部逐步实测。外缘重置、钳位、平流步、
            % 扩散求解步均逐格计账（仅流体格）；稳态时账本残差→0。
            accN = max(obj.accSteps, 1);
            accScale = rhoCpCell / (accN * obj.DT);
            Q_R_heat   = Q_pin;                           % v2.7.1 起恒 0（散热器已绝热）
            Q_R_advect = obj.accAdvect   * accScale;      % 平流步（含边界通量+缓冲区搅动）
            Q_R_diffuse= obj.accDiffuse  * accScale;      % 扩散求解步（=−全壁面吸热，精确）
            Q_R_wall   = -Q_wall_case;                    % 机箱壁净吸热（逐格 α 面加权）
            Q_R_out    = obj.accResetOut * accScale;      % 外缘重置（排气倾泻+外部空气池）
            Q_R_clamp  = obj.accClamp    * accScale;      % 钳位（数值能源，应≈0）
            % v3.0.2：钳位分项（定位净吸热来源，v3.0.1 审计附带观察）
            Q_R_clampSolve  = obj.accClampSolve  * accScale;
            Q_R_clampAdvect = obj.accClampAdvect * accScale;
            Q_R_clampCap    = obj.accClampCap    * accScale;
            Q_R_clampFloor  = obj.accClampFloor  * accScale;
            % 流体域总账本：所有源汇均已计量，稳态应 ≈ 0（残差=瞬态储能速率）
            ledgerW   = Q_gaussian + Q_R_heat + Q_R_advect + Q_R_diffuse + ...
                        Q_R_out + Q_R_clamp;
            ledgerPct = 100 * ledgerW / max(Q_injected, eps);

            % 储能修正闭合（判据 A 主判据，v2.7.1）：账本残差减去计账窗口的
            % 实测储能速率（accE0 基准），剩余即"未计量路径"——所有路径均已
            % 逐步计账时任意时刻应≈0，无需等待稳态。该判据在开发中实测
            % 捕获了两个幽灵源（障碍格钳位污染、平流缓冲区搅动未计入）。
            E_now = sum((obj.T_fluid - 25) .* double(obj.obstacle == 0)) * rhoCpCell;
            dEdtW = (E_now - obj.accE0) / (accN * obj.DT);
            closureW   = ledgerW - dEdtW;
            closurePct = 100 * closureW / max(Q_injected, eps);

            % 系统级闭合残差（判据 B，独立采样路径）
            % Q_exhaust = 开口带符号焓流积分；Q_wall_case = 机箱壁逐格 α 面加权。
            % 与判据 A 互为独立测量；偏差主要来自质量不平衡与面 α 近似。
            Q_out    = Q_exhaust + Q_wall_case;
            residualW   = Q_out - Q_injected;
            residualPct = 100 * residualW / max(Q_injected, eps);
            % v3.0.1 判据 B 储能修正：原残差只在真稳态成立——有限窗口内机箱
            % 热浸透（储能速率 v2.8 实测 ~100W 级）会被误读为"未排出"。
            % 加上机箱内部储能速率后，判据变为任意时刻成立的机箱级瞬时平衡：
            %   Q_exhaust + Q_wall_case + dE_case/dt ≈ Q_injected
            % v3.0.2 再补开口平面扩散导热 Q_openingDiff（与 Q_wall_case 同态的
            % 面 α 口径；审计诊断原稿的教科书通量口径高估 3.2 倍，见上方注释）：
            %   Q_exhaust + Q_openingDiff + Q_wall_case + dE_case/dt ≈ Q_injected
            % 残余偏差来源：跨薄壁半拉格朗日泄漏、Q_wall_case 外表面份额
            % （机箱外射流格向 25°C 壁的吸热，已经 Q_exhaust 计过一次）与
            % 开口/壁面采样近似——v3.0.2 偏差预算已全分解（外表面虚高
            % +12.2W + 跨薄壁泄漏净流入 +46.8W，见 diag_residual_v302.m），
            % v3.0.3 起 residualCorrPct 升门禁（test_conservation 判据 B2，±25%）。
            % 远场环焓流（farFieldHeatW，报告项）不计入本判据：穿环热量中
            % 先过开口的部分（平流焓流 + 开口扩散）已入账，显式相加会双重
            % 计数；越环其余部分是机箱外绕行气流的换热，全域口径由判据 A 覆盖。
            E_case_now = sum(obj.T_fluid(obj.insideMask) - 25) * rhoCpCell;
            dEdtCaseW = (E_case_now - obj.accE0_case) / (accN * obj.DT);
            residualCorrW   = Q_out + Q_openingDiff + dEdtCaseW - Q_injected;
            residualCorrPct = 100 * residualCorrW / max(Q_injected, eps);
            % v3.3.0 算子级机箱平衡（B2 主口径，替代采样口径门禁）：机箱内区
            % 满足逐步恒等式 ΣΔT_inject（内区）+ ΣΔT_diffuse + ΣΔT_advect
            % + ΣΔT_clamp + ΣΔT_intake（进气风扇新风混合）= ΔE_case——内区全部
            % 改温算子逐一插桩（注入侧也插桩：高斯核尾可越过 1 格薄壁落到外围
            % 流体格，注入内区 ≠ Q_gaussian，实测差 ~35W），故 balanceOp 构造
            % 上 ≈0；作用是捕获未来新增/改动 T 算子忘插桩的回归（与判据 A
            % 全域口径同构）。采样口径 residualCorrPct 降级报告项（仪表质量
            % 指标）：其 −30% 缺口经本账本直测分解——高斯核尾越壁注入外围
            % 35.5W + 进气新风混合 −135.1W 不在采样口径内 + 开口面焓流采样
            % 高估 ~+50W 对冲（壁面 α 采样 30.7W 与算子扩散 −36.4W 实际接近，
            % 早期探针"壁面低估 ~−160W"归因系误并新风混合，已更正）；跨薄壁
            % 半拉格朗日泄漏证伪（~0W，上方"残余偏差来源"的泄漏归因以本条
            % 为准，probe_slxwall / probe_casemap 探针 + 本账本实测）。
            Q_injectCase  = obj.accInjectCase  * accScale;
            Q_advectCase  = obj.accAdvectCase  * accScale;
            Q_diffuseCase = obj.accDiffuseCase * accScale;
            Q_clampCase   = obj.accClampCase   * accScale;
            Q_boundaryCase= obj.accBoundaryCase* accScale;
            balanceOpW   = Q_injectCase + Q_advectCase + Q_diffuseCase + Q_clampCase + Q_boundaryCase - dEdtCaseW;
            balanceOpPct = 100 * balanceOpW / max(Q_injected, eps);
            massImbalancePct = 100 * netVol / max(grossVol, eps);

            cons = struct('Q_injected',Q_injected,'Q_gaussian',Q_gaussian,...
                          'Q_pin',Q_pin,'Q_exhaust',Q_exhaust,'Q_wall',Q_wall,...
                          'Q_wall_case',Q_wall_case,'Q_wall_internal',Q_wall_internal,...
                          'Q_out',Q_out,'Q_openingDiff',Q_openingDiff,...
                          'Q_openingDiffPer',Q_openingDiffPer,...
                          'residualW',residualW,...
                          'residualPct',residualPct,...
                          'storageRateCaseW',dEdtCaseW,...
                          'residualCorrW',residualCorrW,...
                          'residualCorrPct',residualCorrPct,...
                          'Q_advectCase',Q_advectCase,...
                          'Q_diffuseCase',Q_diffuseCase,...
                          'Q_clampCase',Q_clampCase,...
                          'Q_boundaryCase',Q_boundaryCase,...
                          'Q_injectCase',Q_injectCase,...
                          'balanceOpW',balanceOpW,...
                          'balanceOpPct',balanceOpPct,...
                          'Q_R_heat',Q_R_heat,'Q_R_wall',Q_R_wall,...
                          'Q_R_advect',Q_R_advect,'Q_R_diffuse',Q_R_diffuse,...
                          'Q_R_out',Q_R_out,'Q_R_clamp',Q_R_clamp,...
                          'Q_R_clampSolve',Q_R_clampSolve,...
                          'Q_R_clampAdvect',Q_R_clampAdvect,...
                          'Q_R_clampCap',Q_R_clampCap,...
                          'Q_R_clampFloor',Q_R_clampFloor,...
                          'ledgerW',ledgerW,'ledgerPct',ledgerPct,...
                          'closureW',closureW,'closurePct',closurePct,...
                          'storageRateW',dEdtW,...
                          'massImbalancePct',massImbalancePct,...
                          'farFieldCfm',ff.cfm,'farFieldGrossCfm',ff.grossCfm,...
                          'farFieldHeatW',ff.heatW,...
                          'domainNetVol',domainNetVol,'domainMassPct',domainMassPct,...
                          'flowGain',obj.flowGain,...
                          'flux',flux,'alphaEff',alphaEff);
        end
        
        function solveConjugateHeatTransfer(obj)
            temps = obj.computeAirflowTemperatures();
            W = obj.GRID.W; H = obj.GRID.H;
            s = obj.gridScale;
            sc = @(v) max(1, round(v * s));  % 区域尺寸随网格缩放
            fluidRectIdx = @(x,y,w,h) ...
                reshape(((max(2,x):min(W-1,x+w-1))'-1)*W + (max(2,y):min(H-1,y+h-1)), [], 1);
            [uC, vC] = obj.getCellVelocity();  % v3.0：统一读取口（MAC 下面平均回格心）

            % 物理归一化：空气对流热容 [J/(K·cell)]
            % cell_size=2mm，机箱 Z 向有效深度 CHASSIS_DEPTH_M=0.15m，rho*cp=1189 J/(m³·K)
            cell_m = obj.GRID.cell_size_mm / 1000;
            rho_cp_cell = obj.AIR.rho * obj.AIR.cp * cell_m^2 * obj.CHASSIS_DEPTH_M;  % ≈7.1e-4 J/K

            % ---- CPU ----
            % 风速采样：取CPU鳍片左侧出口（风扇下游）的自由流体速度
            % CPU塔式风扇从右向左吹，下游在鳍片左侧 x=[fin.x-20, fin.x-5]
            cf = obj.CPU_HEATSINK.fin_area;
            cpuSampleIdx = fluidRectIdx(cf.x-sc(20), cf.y+sc(10), sc(15), cf.h-sc(20));
            cpuSampleFree = cpuSampleIdx(obj.obstacle(cpuSampleIdx)==0);
            if ~isempty(cpuSampleFree)
                vel = sqrt(uC(cpuSampleFree).^2 + vC(cpuSampleFree).^2);
                avgVelCpu = max(0.3, mean(vel)) * obj.VEL_SCALE;
            else
                avgVelCpu = 0.5;
            end
            cpuNet = obj.thermalNetworks.cpu;
            cpuNet.solve(avgVelCpu, temps.internalAmbient, obj.DT);

            cb  = obj.CPU_HEATSINK.base;
            cx  = cb.x + cb.w/2; cy = cb.y + cb.h/2;
            cbIdx = fluidRectIdx(cb.x, cb.y, cb.w, cb.h);
            obj.T_solid(cbIdx) = cpuNet.T_junction;
            cf = obj.CPU_HEATSINK.fin_area;
            cfIdx = fluidRectIdx(cf.x, cf.y, cf.w, cf.h);
            [JJ,II] = ind2sub([W,H], cfIdx);
            dist = min(sqrt((II-cx).^2 + (JJ-cy).^2)/(40*s), 1);
            obj.T_solid(cfIdx) = cpuNet.T_junction - (cpuNet.T_junction-cpuNet.T_sink_base).*dist;

            % Gaussian热注入：中心置于散热器上方自由流体，避免全被障碍物过滤
            % 核半径/σ 按 gridScale 缩放（σ²=400 格² ↔ 物理 (40mm)²）
            kg = sc(35);
            [DI,DJ] = ndgrid(-kg:kg,-kg:kg);
            II = floor(cx+DI(:)); JJ = floor((cf.y-sc(15))+DJ(:));
            valid = II>=2 & II<=W-1 & JJ>=2 & JJ<=H-1;
            II=II(valid); JJ=JJ(valid); DI=DI(valid); DJ=DJ(valid);
            heatIdx = (II-1)*W + JJ;
            free = obj.obstacle(heatIdx)==0;
            heatIdx = heatIdx(free); DI=DI(free); DJ=DJ(free);
            w = exp(-(DI.^2+DJ.^2)/(400*s^2));
            % v2.7.1 对流拾取加权：热优先进入运动流体（模拟鳍片强制对流
            % 拾取 q∝h(v)·A·ΔT——真实散热器的流道强迫空气穿过热区）。
            % 静止/滞留格权重降至 0.25，避免热量注入滞留区后只能靠慢扩散
            % 释放（实测是升温慢模态与内部高温的主因之一）。总功率不变
            % （权重归一化），只改变注入的空间分布。
            vloc = sqrt(uC(heatIdx).^2 + vC(heatIdx).^2) * obj.VEL_SCALE;
            w = w .* (0.25 + 0.75 * min(1, vloc / 1.5));
            w_sum = sum(w);
            if w_sum > 0
                dT_cpu = cpuNet.actual_power * (w/w_sum) * obj.DT / rho_cp_cell;  % v2.7：全功率注入（原 /5 平滑系数的职责移交钉扎格架构时已冗余）
                obj.T_fluid(heatIdx) = obj.T_fluid(heatIdx) + dT_cpu;
                % v3.3.0：注入机箱内区 ΣΔT（算子级 B2；核尾可越壁落外围格）
                obj.accInjectCase = obj.accInjectCase + sum(dT_cpu(ismember(heatIdx, obj.insideMask)));
            end

            % ---- GPU ----
            % 风速采样：取GPU散热器上方出口（风扇上游）的自由流体速度
            % GPU底部风扇向上吹，气流穿过散热器后从上方排出
            gh = obj.GPU_HEATSINK.heatsink;
            gpuSampleIdx = fluidRectIdx(gh.x+sc(10), gh.y-sc(15), gh.w-sc(20), sc(10));
            gpuSampleFree = gpuSampleIdx(obj.obstacle(gpuSampleIdx)==0);
            if ~isempty(gpuSampleFree)
                vel = sqrt(uC(gpuSampleFree).^2 + vC(gpuSampleFree).^2);
                avgVelGpu = max(0.3, mean(vel)) * obj.VEL_SCALE;
            else
                avgVelGpu = 0.5;
            end
            gpuNet = obj.thermalNetworks.gpu;
            gpuNet.solve(avgVelGpu, temps.internalAmbient, obj.DT);

            gp  = obj.GPU_HEATSINK.pcb;
            gcx = gp.x + gp.w/2; gcy = gp.y + gp.h/2;
            gpIdx = fluidRectIdx(gp.x, gp.y, gp.w, gp.h);
            obj.T_solid(gpIdx) = gpuNet.T_junction;
            gh = obj.GPU_HEATSINK.heatsink;
            ghIdx = fluidRectIdx(gh.x, gh.y, gh.w, gh.h);
            [JJ,II] = ind2sub([W,H], ghIdx);
            % 横向温度梯度：沿散热片长度方向（x）变化慢，高度方向（y）变化快
            % 这样左右边缘温度高，上下边缘温度低，形成横向热源特征
            dist = min(sqrt(((II-gcx)/(100*s)).^2 + ((JJ-gcy)/(25*s)).^2), 1);
            obj.T_solid(ghIdx) = gpuNet.T_junction - (gpuNet.T_junction-gpuNet.T_sink_base).*dist;

            % GPU 热注入（v3.2.0：中心移入鳍片区内部——v3.1.0 起鳍片已多孔
            % 介质化、区格为流体，卡下风扇驱动气流穿鳍片直接拾取热量；
            % 旧注入点在卡与 PSU 隔板间窄缝（gh.y+gh.h+2），v3.2.0 几何改薄后
            % 该缝仅 ~4 格，注入其中只会重建钉帽滞留囊）
            kgX = sc(60); kgY = sc(30);
            [DI,DJ] = ndgrid(-kgX:kgX,-kgY:kgY);
            II = floor((gh.x+gh.w/2-sc(10))+DI(:)); JJ = floor((gh.y+round(gh.h*0.6))+DJ(:));
            valid = II>=2 & II<=W-1 & JJ>=2 & JJ<=H-1;
            II=II(valid); JJ=JJ(valid); DI=DI(valid); DJ=DJ(valid);
            heatIdx = (II-1)*W + JJ;
            free = obj.obstacle(heatIdx)==0;
            heatIdx = heatIdx(free); DI=DI(free); DJ=DJ(free);
            w = exp(-(DI.^2+DJ.^2)/(625*s^2));
            vloc = sqrt(uC(heatIdx).^2 + vC(heatIdx).^2) * obj.VEL_SCALE;
            w = w .* (0.25 + 0.75 * min(1, vloc / 1.5));  % v2.7.1 对流拾取加权（见 CPU 段注释）
            w_sum = sum(w);
            if w_sum > 0
                dT_gpu = gpuNet.actual_power * (w/w_sum) * obj.DT / rho_cp_cell;  % v2.7：全功率注入
                obj.T_fluid(heatIdx) = obj.T_fluid(heatIdx) + dT_gpu;
                % v3.3.0：注入机箱内区 ΣΔT（算子级 B2）
                obj.accInjectCase = obj.accInjectCase + sum(dT_gpu(ismember(heatIdx, obj.insideMask)));
            end

            % ---- PSU ----
            % 风速采样：取PSU风扇左侧出口的自由流体速度
            pf = obj.PSU2D.fan;
            psuSampleIdx = fluidRectIdx(pf.x-sc(20), pf.y+sc(5), sc(15), pf.h-sc(10));
            psuSampleFree = psuSampleIdx(obj.obstacle(psuSampleIdx)==0);
            if ~isempty(psuSampleFree)
                vel = sqrt(uC(psuSampleFree).^2 + vC(psuSampleFree).^2);
                avgVelPsu = max(0.3, mean(vel)) * obj.VEL_SCALE;
            else
                avgVelPsu = 0.5;
            end
            psuNet  = obj.thermalNetworks.psu;
            psuNet.solve(avgVelPsu, temps.internalAmbient, obj.DT);
            psuHeat = psuNet.actual_power;  % 节流后实际发热（v2.6.1 审计：与 CPU/GPU 注入口径一致）
            psuBody = obj.PSU2D.body;
            psuIdx  = fluidRectIdx(psuBody.x, psuBody.y, psuBody.w, psuBody.h);
            obj.T_solid(psuIdx) = psuNet.T_junction;

            % PSU 散热注入周围流体（中心置于PSU左侧自由流体）
            pf = obj.PSU2D.fan;
            pfcx = pf.x + pf.w/2; pfcy = pf.y + pf.h/2;
            kg = sc(25);
            [DI,DJ] = ndgrid(-kg:kg,-kg:kg);
            II = floor((pfcx-sc(20))+DI(:)); JJ = floor(pfcy+DJ(:));
            valid = II>=2 & II<=W-1 & JJ>=2 & JJ<=H-1;
            II=II(valid); JJ=JJ(valid); DI=DI(valid); DJ=DJ(valid);
            psuHeatIdx = (II-1)*W + JJ;
            free = obj.obstacle(psuHeatIdx)==0;
            psuHeatIdx = psuHeatIdx(free); II=II(free); JJ=JJ(free); DI=DI(free); DJ=DJ(free);
            w = exp(-(DI.^2+DJ.^2)/(225*s^2));
            % v3.0.5（v3.0.4 审计 f 项）：名义核中心若落入障碍（PSU 体），
            % 高斯峰值格被过滤、全功率挤进窄缝（实测 w_sum=9.5 vs CPU 930，
            % 峰值格钉 200°C 帽）。此时把中心重定位到自由格的权重质心后
            % 以新中心重算高斯权重；中心为自由格时行为不变。
            centerLin = max(1, min(W*H, (floor(pfcx-sc(20))-1)*W + floor(pfcy)));
            if ~isempty(psuHeatIdx) && obj.obstacle(centerLin) ~= 0
                wC = w / sum(w);
                cxR = sum(II .* wC); cyR = sum(JJ .* wC);
                w = exp(-((II-cxR).^2 + (JJ-cyR).^2)/(225*s^2));
            end
            vloc = sqrt(uC(psuHeatIdx).^2 + vC(psuHeatIdx).^2) * obj.VEL_SCALE;
            w = w .* (0.25 + 0.75 * min(1, vloc / 1.5));  % v2.7.1 对流拾取加权（见 CPU 段注释）
            w_sum = sum(w);
            if w_sum > 0
                dT_psu = psuHeat * (w/w_sum) * obj.DT / rho_cp_cell;  % v2.7：全功率注入
                obj.T_fluid(psuHeatIdx) = obj.T_fluid(psuHeatIdx) + dT_psu;
                % v3.3.0：注入机箱内区 ΣΔT（算子级 B2；PSU 核贴底壁，核尾越壁最明显）
                obj.accInjectCase = obj.accInjectCase + sum(dT_psu(ismember(psuHeatIdx, obj.insideMask)));
            end
        end
        
        function vort = computeVorticity(obj)
            W = obj.GRID.W; H = obj.GRID.H;
            [uC, vC] = obj.getCellVelocity();  % v3.0：统一读取口
            umat = reshape(uC, W, H);
            vmat = reshape(vC, W, H);
            vortMat = zeros(W, H);
            dvdx = 0.5*(vmat(2:W-1,3:H) - vmat(2:W-1,1:H-2));
            dudy = 0.5*(umat(3:W,2:H-1) - umat(1:W-2,2:H-1));
            vortMat(2:W-1,2:H-1) = dvdx - dudy;
            obs = reshape(obj.obstacle, W, H);
            vortMat(obs > 0) = 0;
            vort = vortMat(:);
        end
        
        function diag = calculateCFDDiagnostics(obj)
            L     = 0.40;
            [uC, vC] = obj.getCellVelocity();  % v3.0：统一读取口
            vel   = sqrt(uC.^2 + vC.^2);
            if ~isempty(obj.insideMask)
                fluidVel = vel(obj.insideMask);  % 仅采机箱内部流体
            else
                fluidVel = vel(obj.obstacle == 0);
            end
            if ~isempty(fluidVel), avgVel = mean(fluidVel); else, avgVel = 0.1; end
            V      = avgVel * obj.VEL_SCALE;
            deltaT = max(5, obj.thermalNetworks.cpu.T_junction - 25);
            Re = (obj.AIR.rho * V * L) / obj.AIR.mu;
            Gr = (obj.AIR.g * obj.AIR.beta * deltaT * L^3) / (obj.AIR.nu^2);
            Ra = Gr * obj.AIR.Pr;
            Nu_free   = 0.59 * max(Ra,1e-6)^0.25;
            Nu_forced = 0.023 * max(Re,1)^0.8 * obj.AIR.Pr^0.4;
            Nu        = (Nu_free^3 + Nu_forced^3)^(1/3);
            if Re < 2300,      flowRegime = '层流';
            elseif Re < 4000,  flowRegime = '过渡';
            else,              flowRegime = '湍流';
            end
            Ri = Gr / (Re^2 + 1);
            if Ri > 10,        flowRegime = [flowRegime ' | 自然对流主导'];
            elseif Ri > 0.1,   flowRegime = [flowRegime ' | 混合对流'];
            else,              flowRegime = [flowRegime ' | 强制对流主导'];
            end
            % Boussinesq 适用范围守卫（v2.6）：ΔT>30K 时密度误差 >10%，
            % 浮力项定量可信度下降（Gray & Giorgini 1976），结果应降置信
            if ~isempty(obj.insideMask)
                maxDeltaT = max(obj.T_fluid(obj.insideMask)) - 25;
            else
                maxDeltaT = max(obj.T_fluid) - 25;
            end
            if isempty(maxDeltaT), maxDeltaT = 0; end
            boussinesqValid = maxDeltaT <= 30;
            if ~boussinesqValid
                flowRegime = [flowRegime ' | ⚠ΔT>30K Boussinesq超限'];
            end
            diag = struct('Re',Re,'Gr',Gr,'Ra',Ra,'Nu',Nu,'flowRegime',flowRegime,...
                          'maxDeltaT',maxDeltaT,'boussinesqValid',boussinesqValid);
        end
        
        function result = stepMultiple(obj, steps)
            for s = 1:steps
                obj.fluidStep();
            end
            vort       = obj.computeVorticity();
            [uC, vC]   = obj.getCellVelocity();  % v3.0：统一读取口
            vel        = sqrt(uC.^2 + vC.^2);
            % 涡量阈值按物理量换算：grid 涡量 ∝ cell_m，故阈值随 gridScale 反比缩放
            vortThresh = 1.2 / obj.gridScale;
            if ~isempty(obj.insideMask)
                inside = obj.insideMask;
                deadCount  = sum(vel(inside) < 0.25 & abs(vort(inside)) > vortThresh);
                fluidCount = length(inside);
            else
                fluid = obj.obstacle == 0;
                fluidCount = sum(fluid);
                deadCount  = sum(fluid & vel < 0.25 & abs(vort) > vortThresh);
            end
            if fluidCount > 0
                obj.deadZoneRatio = deadCount / fluidCount;
            else
                obj.deadZoneRatio = 0;
            end
            obj.latestVorticity = vort;
            obj.lastDiag  = obj.calculateCFDDiagnostics();
            obj.lastTemps = obj.computeAirflowTemperatures();
            result = struct('deadRatio',obj.deadZoneRatio,'vort',vort,...
                            'diag',obj.lastDiag,'temps',obj.lastTemps);
        end
        
        function scores = calculateScores(obj)
            temps      = obj.computeAirflowTemperatures();
            cpuT       = obj.thermalNetworks.cpu.T_junction;
            gpuT       = obj.thermalNetworks.gpu.T_junction;
            psuT       = obj.thermalNetworks.psu.T_junction;
            totalNoise = 0; totalCFM = 0; totalPrice = 0;
            for k = 1:length(obj.fans)
                f = obj.fans{k};
                totalNoise = totalNoise + 10^(f.getNoise(obj)/10);
                totalCFM   = totalCFM   + f.getCFM(obj);
                totalPrice = totalPrice + f.price;
            end
            for k = 1:length(obj.builtInFans)
                f = obj.builtInFans{k};
                totalNoise = totalNoise + 10^(f.getNoise(obj)/10);
                totalCFM   = totalCFM   + f.getCFM(obj);
            end
            noiseDb     = 10*log10(max(totalNoise,1));
            % v3.0.6 评分重标定：v2.x 公式在假热沉压低温度（均温~49°C）时代
            % 标定，v3.0 结温回归真实（60–100°C）后散热分恒 0（实测 CPU 68/
            % GPU 98°C → 100−51.6−58.4=−10）。六维改锚定热网络节流阈/结温
            % 上限（CPU 85/100、GPU 100/110，见 initThermalNetworks）。
            tnC = obj.thermalNetworks.cpu; tnG = obj.thermalNetworks.gpu;
            tnP = obj.thermalNetworks.psu;
            % 散热：CPU ≤60°C 满分→节流阈零分；GPU ≤70°C 满分→节流阈零分
            cpuCool = max(0, min(100, (tnC.throttling_temp-cpuT)/(tnC.throttling_temp-60)*100));
            gpuCool = max(0, min(100, (tnG.throttling_temp-gpuT)/(tnG.throttling_temp-70)*100));
            cooling = 0.5*cpuCool + 0.5*gpuCool;
            % 性能：实际交付功率/额定功率（节流直接扣性能）；全件锁 35%
            % 节流（节流模型上限）→ 0 分。旧口径=结温余量，与"余量"维重复
            pNom = tnC.power + tnG.power + tnP.power;
            pAct = tnC.actual_power + tnG.actual_power + tnP.actual_power;
            performance = max(0, min(100, (pAct/max(pNom,eps) - 0.65)/0.35*100));
            % 均衡：组件间温差（口径不变）
            balance     = max(0, 100 - abs(cpuT-gpuT)*2);
            % 余量：距节流阈的归一化温差（25°C 环境→100，达节流阈→0）。
            % 旧口径锚 tjmax 100/110，真实工况下余量虚高
            cpuHead = max(0, (tnC.throttling_temp-cpuT)/(tnC.throttling_temp-25));
            gpuHead = max(0, (tnG.throttling_temp-gpuT)/(tnG.throttling_temp-25));
            margin      = 100*(0.5*cpuHead + 0.5*gpuHead);
            noise       = max(0, 100 - (noiseDb-20)*3);
            value       = max(0, 100 - totalPrice/15);
            totalScore  = round(cooling*0.25 + performance*0.20 + balance*0.10 + margin*0.15 + noise*0.20 + value*0.10);
            scores = struct('total',totalScore,'cooling',round(cooling),'performance',round(performance),...
                'balance',round(balance),'margin',round(margin),'noise',round(noise),'value',round(value),...
                'cpuTemp',round(cpuT),'gpuTemp',round(gpuT),'psuTemp',round(psuT),...
                'noiseDb',round(noiseDb),'totalPrice',totalPrice,'totalCFM',round(totalCFM),...
                'intake',temps.intake,'topExhaust',temps.topExhaust,'internalAmbient',temps.internalAmbient,...
                'rearExhaust',temps.rearExhaust);
        end
        
        function recs = getRecommendations(obj)
            scores = obj.calculateScores();
            recs = {};
            if scores.cpuTemp > 85
                recs{end+1} = struct('title','CPU温度过高','desc',sprintf('当前%d°C，建议增加顶部出风风扇或提高冷排转速',scores.cpuTemp),'level','warning');
            elseif scores.cpuTemp < 60
                recs{end+1} = struct('title','CPU散热余量充足','desc',sprintf('当前%d°C，可适当降低风扇转速以减少噪音',scores.cpuTemp),'level','good');
            end
            if scores.gpuTemp > 90
                recs{end+1} = struct('title','GPU温度过高','desc',sprintf('当前%d°C，建议改善显卡下方进风或增加机箱后部出风',scores.gpuTemp),'level','warning');
            elseif scores.gpuTemp < 65
                recs{end+1} = struct('title','GPU散热良好','desc',sprintf('当前%d°C，散热配置合理',scores.gpuTemp),'level','good');
            end
            if obj.deadZoneRatio > 0.15
                recs{end+1} = struct('title','风道存在涡量死区','desc',sprintf('死区占比%.1f%%，建议调整风扇位置避免气流短路',obj.deadZoneRatio*100),'level','warning');
            end
            if scores.noiseDb > 40
                recs{end+1} = struct('title','噪音水平偏高','desc',sprintf('当前约%ddB，建议启用自动温控或更换低噪风扇',scores.noiseDb),'level','warning');
            elseif scores.noiseDb < 25
                recs{end+1} = struct('title','运行安静','desc',sprintf('当前约%ddB，噪音控制优秀',scores.noiseDb),'level','good');
            end
            if scores.balance < 70
                recs{end+1} = struct('title','CPU/GPU温度不均衡','desc','温差较大，建议优化风道使热量均匀排出','level','warning');
            end
            if isempty(recs)
                recs{end+1} = struct('title','散热配置均衡','desc','当前风道设计合理，无明显瓶颈','level','good');
            end
        end
    end
    
    methods (Abstract)
        fluidStep(obj)
    end
end
