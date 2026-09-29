classdef CFDSolverBase < handle
    %CFDSOLVERBASE PC 风道 CFD 求解器公共基类。
    %   负责几何（由布局配置构建）、场与掩码、风扇与热网络、共轭传热、
    %   诊断、守恒计账与评分；时间推进 fluidStep 由子类 CFDSolverFEM 实现。
    %
    %   网格与索引约定：
    %     - 计算域 W×H 格（W=H），格心线性索引 idx = (x-1)*W + y，
    %       reshape(field, W, H) 后第 1 维为 y（向下）、第 2 维为 x（向右）。
    %     - 速度存于 MAC 交错网格面上：uF(y,xf) 为 W×(H+1)，vF(yf,x) 为 (W+1)×H，
    %       均为"网格单位"，物理速度 = 网格速度 × VEL_SCALE [m/s]。
    %     - 显示时 YDir 反向：y=1 在顶，-v 为向上。

    properties (Constant)
        OBSTACLE = struct('WALL',1,'MOTHERBOARD',2,'CPU_BASE',3,'CPU_FINS',4,...
                          'GPU_PCB',5,'GPU_HEATSINK',6,'PSU_CASE',7,'PSU_FAN',8,...
                          'RAM_SLOT',9,'VRM',10,'CHIPSET',11,'PSU_SHROUD',12,'CABLE_BAR',13)
        AIR_DENSITY = 1.184
        AIR_CP = 1005
        CFM_TO_M3S = 0.0004719
        FLOW_EFFICIENCY = 0.75   % 代数轨流量效率缺省值
        % 格栅/滤网阻力系数 ζ（Δp = ζ·½ρv²，Idelchik 手册近似）
        GRILLE_ZETA_INTAKE = 2.0   % 前面板开孔 + 防尘网
        GRILLE_ZETA_EXHAUST = 0.8  % 排气格栅
    end

    properties
        % ===== 配置与网格 =====
        layout            % 布局配置（见 layout_default）
        powerW            % 名义功率输入 struct(cpu, gpu, psu) [W]（psu 为电源负载）
        DT = 0.005        % 时间步长 [s]
        flowEfficiency    % 代数轨流量效率（构造时取 FLOW_EFFICIENCY，标定时可覆盖）
        VEL_SCALE = 0.554 % 网格速度 → m/s：(W-2)·格距（构造时按网格重算）
        gridScale = 1     % 网格细化倍数：1=280²×2mm，2=560²×1mm，0.5=140²×4mm
        GRID = struct('W',280,'H',280,'cell_size_mm',2,'TOTAL',78400)
        caseOffsetX = 40
        caseOffsetY = 40
        CHASSIS_DEPTH_M = 0.15   % 机箱 Z 向有效深度 [m]（2D 换算用，取自布局）
        AIR

        % ===== 场 =====
        p, T_fluid, T_solid
        uF = []           % u 面速度 W×(H+1)，向量化 (xf-1)*W+y；xf=1/H+1 为域边界面
        vF = []           % v 面速度 (W+1)×H，向量化 (x-1)*(W+1)+yf
        turbK = []        % 湍动能 k [m²/s²]
        turbOmega = []    % 比耗散率 ω [1/s]
        latestVorticity
        obstacle
        iteration = 0

        % ===== 面掩码 =====
        uFaceActive = []  % u 面激活（两侧皆流体；域边界面取单侧）
        vFaceActive = []
        uFaceRing = []    % 邻接远场海绵环的激活 u 面（阻尼用）
        vFaceRing = []

        % ===== 几何（格坐标，由 layout 换算）=====
        CASE2D
        CPU_HEATSINK
        GPU_HEATSINK
        PSU2D
        RAM_SLOTS
        VRM
        CHIPSET
        SHROUD

        % ===== 障碍与区域索引 =====
        obsIdx = []           % 全部障碍格
        heatObsIdx = []       % 发热元件固体格（CPU 底座/GPU PCB/PSU；仅显示 T_solid）
        wallObsIdx = []       % 机箱壁格（温度 Dirichlet 25°C）
        adiabaticObsIdx = []  % 其余内部障碍格（温度 Neumann 绝热）
        porousZones = []      % 多孔区 struct 数组：rect / zetaThru / zetaCross / thru
        uDragCoef = []        % u 面多孔阻力系数（u ← u/(1+C|u|)），非多孔面为 0
        vDragCoef = []
        nearestFluidIdx = []  % 每格最近流体格（温度/湍流平流时替换障碍格值）
        insideMask = []       % 机箱内部流体格
        outsideMask = []      % 机箱外部流体格
        spongeRingIdx = []    % 域最外圈流体格（远场吸收层：阻尼 + 25°C + p=0）
        liveOutsideMask = []  % 机箱外真实空气区 = outsideMask \ 海绵环
        wallDistanceM = []    % 到最近障碍的距离 [m]（湍流模型用）
        openingIdx = struct('top',[],'rear',[],'front',[],'bottom',[])  % 壁面开口格

        % ===== 风扇与热网络 =====
        fans = {}             % 机箱风扇（RealFan）
        builtInFans = {}      % 内置风扇（BuiltInFan：顶排/CPU 塔扇/GPU 风扇）
        thermalNetworks       % struct(cpu, gpu, psu) of DetailedThermalNetwork
        autoFanEnabled = true
        fanSpeedRatio = 40    % 手动模式全局转速 [%]

        % ===== 模型开关与参数 =====
        spongeDamping = 0.8   % 远场海绵环速度保留比例（每步）
        spongeWidth = 1       % 海绵环厚度 [格]
        nuTCapFactor = 50     % LVEL 路径 ν_t 上限（×分子粘度）
        turbulenceModel = 'komega'  % 'komega'（默认）| 'lvel'
        turbIntensity = 0.05  % 来流/初始湍流度 I
        turbRefVel = 2.0      % k₀ 参考速度 [m/s]
        turbUpdateEvery = 1   % 湍流场每 N 步更新一次
        nuTFloor = 1e-10      % k 下限

        % ===== 诊断 =====
        deadZoneRatio = 0
        lastDiag
        lastTemps

        % ===== 能量计账（逐步累计 ΣΔT [K·cell]，computeConservationCheck 换算成功率）=====
        accResetOut  = 0   % 远场海绵环重置 + 进气新风混合
        accClamp     = 0   % 全部温度钳位合计
        accClampSolve  = 0 % 扩散求解后 max(T,25)
        accClampAdvect = 0 % 温度平流后 max(T,25)
        accClampCap    = 0 % 共轭传热后 min(T,200)（削顶，汇）
        accClampFloor  = 0 % 共轭传热后 max(T,25)（抬底，源）
        accAdvect    = 0   % 温度平流步
        accDiffuse   = 0   % 温度扩散求解步
        accSteps     = 0
        accE0        = 0   % 计账清零时的流体储能 [J]
        accE0_case   = 0   % 计账清零时的机箱内部流体储能 [J]
        % 机箱内区算子级计账（判据 B2：内区全部改温算子逐一插桩）
        accAdvectCase  = 0
        accDiffuseCase = 0
        accClampCase   = 0
        accBoundaryCase= 0 % 进气风扇新风混合
        accInjectCase  = 0 % 高斯热注入（核尾可越过薄壁落到机箱外）
    end

    methods
        function obj = CFDSolverBase(cpuPower, gpuPower, psuPower, layout, gridScale, dtVal)
            %CFDSOLVERBASE 构造求解器。
            %   layout 可为布局名（char）或布局配置 struct；功率参数为空时取布局默认值。
            if nargin < 4 || isempty(layout), layout = 'atx_balanced'; end
            if isstring(layout), layout = char(layout); end
            if ischar(layout), layout = layout_default(layout); end
            if nargin < 1 || isempty(cpuPower), cpuPower = layout.power.cpu; end
            if nargin < 2 || isempty(gpuPower), gpuPower = layout.power.gpu; end
            if nargin < 3 || isempty(psuPower), psuPower = layout.power.psu; end
            if nargin < 5 || isempty(gridScale), gridScale = 1; end
            if nargin < 6 || isempty(dtVal), dtVal = 0.005; end

            obj.layout = layout;
            obj.powerW = struct('cpu', cpuPower, 'gpu', gpuPower, 'psu', psuPower);
            obj.flowEfficiency = obj.FLOW_EFFICIENCY;
            obj.gridScale = gridScale;
            obj.DT = dtVal;
            cellMm = layout.domain.baseCellMm / gridScale;
            Wg = round(layout.domain.sizeMm / cellMm);
            obj.GRID = struct('W',Wg,'H',Wg,'cell_size_mm',cellMm,'TOTAL',Wg*Wg);
            obj.caseOffsetX = round(layout.chassis.originMm / cellMm);
            obj.caseOffsetY = round(layout.chassis.originMm / cellMm);
            obj.CHASSIS_DEPTH_M = layout.chassis.depthM;
            obj.VEL_SCALE = (obj.GRID.W-2) * (obj.GRID.cell_size_mm/1000);
            obj.AIR = struct('rho',1.184,'mu',1.81e-5,'nu',1.56e-5,...
                             'k',0.026,'cp',1005,'alpha',2.2e-5,'Pr',0.71,...
                             'beta',3.4e-3,'g',9.81);
            obj.buildModel();
        end

        function reset(obj)
            %RESET 回到初始状态（场、几何、风扇、热网络、能量计账）。
            %   保留当前功率、风扇控制设置与各可调参数（DT、湍流模型、flowEfficiency 等），
            %   之后的推进与用相同参数新建的求解器一致。
            obj.buildModel();
            obj.lastDiag = [];
            obj.lastTemps = [];
            obj.deadZoneRatio = 0;
        end

        function setComponentPower(obj, name, watts)
            %SETCOMPONENTPOWER 修改元件名义功率（'cpu' | 'gpu' | 'psu'，psu 为电源负载）。
            %   立即生效，节流比清零，由下一步热网络重新计算。
            obj.powerW.(name) = watts;
            net = obj.thermalNetworks.(name);
            if strcmp(name, 'psu')
                net.power = watts * (1 - obj.layout.psu.efficiency);
            else
                net.power = watts;
            end
            net.actual_power = net.power;
            net.throttling_ratio = 0;
        end

        function buildModel(obj)
            % 构建几何、场与风扇（构造与 reset 共用）
            obj.initGeometry();
            obj.initFields();
            obj.initObstacles();
            obj.initHeatSources(obj.powerW.cpu, obj.powerW.gpu, obj.powerW.psu);
            obj.initBuiltInFans();
            obj.initFans();
            obj.initOpenBoundaries();   % 在风扇壁面位置开洞（需在风扇初始化之后）
        end

        % ================================================================
        % 几何
        % ================================================================
        function initGeometry(obj)
            % 布局（mm，相对机箱原点）→ 格坐标
            L = obj.layout;
            ox = obj.caseOffsetX;
            oy = obj.caseOffsetY;
            cellMm = obj.GRID.cell_size_mm;
            toCell = @(mm) round(mm / cellMm);
            rg = @(r) struct('x', ox + toCell(r.x), 'y', oy + toCell(r.y), ...
                             'w', max(1, toCell(r.w)), 'h', max(1, toCell(r.h)));
            cs = toCell(L.chassis.sizeMm);
            % 机箱方位：后面板在左、前面板在右、顶在上、底在下
            obj.CASE2D = struct('outer', struct('x',ox+1,'y',oy+1,'w',cs,'h',cs), ...
                                'motherboard_tray', rg(L.motherboardTray));
            obj.CPU_HEATSINK = struct('base', rg(L.cpu.base), 'fin_area', rg(L.cpu.fins), ...
                                      'thermal', L.cpu.thermal);
            obj.GPU_HEATSINK = struct('pcb', rg(L.gpu.pcb), 'heatsink', rg(L.gpu.heatsink), ...
                                      'thermal', L.gpu.thermal);
            obj.PSU2D = struct('body', rg(L.psu.body), 'fan', rg(L.psu.fan));
            ram = rg(L.ram(1));
            for r = 2:numel(L.ram)
                ram(r,1) = rg(L.ram(r));
            end
            obj.RAM_SLOTS = ram;
            obj.VRM = struct('heatsink', rg(L.vrm));
            obj.CHIPSET = struct('heatsink', rg(L.chipset));
            obj.SHROUD = struct('y', oy + toCell(L.shroud.yMm), 'h', toCell(L.shroud.hMm));
        end

        function initFields(obj)
            N = obj.GRID.TOTAL;
            W = obj.GRID.W; H = obj.GRID.H;
            obj.p = zeros(N,1);
            obj.T_fluid = ones(N,1)*25;
            obj.T_solid = ones(N,1)*25;
            obj.obstacle = zeros(N,1,'uint8');
            obj.latestVorticity = zeros(N,1);
            obj.uF = zeros(W*(H+1),1);
            obj.vF = zeros((W+1)*H,1);
            obj.iteration = 0;
            obj.resetAccumulators();
            % k-ω 初值：k₀ = 1.5·(I·V_ref)²，ω₀ = k₀/(β*·ν)（即 ν_t0 = ν）
            betaStar = 0.09;
            k0 = 1.5 * (obj.turbIntensity * obj.turbRefVel)^2;
            w0 = k0 / (betaStar * obj.AIR.nu);
            obj.turbK = ones(N,1) * k0;
            obj.turbOmega = ones(N,1) * w0;
        end

        function initObstacles(obj)
            obj.obstacle(:) = 0;
            W = obj.GRID.W; H = obj.GRID.H;
            rectIdx = @(x,y,w,h) reshape(((x:min(W,x+w-1))'-1)*W + (y:min(H,y+h-1)), [], 1);
            ox = obj.caseOffsetX;
            oy = obj.caseOffsetY;
            cs = obj.CASE2D.outer.w;   % 机箱边长 [格]
            caseLeft = ox + 1;
            caseRight = ox + cs;
            caseTop = oy + 1;
            caseBottom = oy + cs;

            % 计算域最外 1 格是远场海绵吸收层（不设固壁），见 fluidStep / 压力装配。
            % 机箱壁是内部障碍环（风扇位置之后由 initOpenBoundaries 开洞）。
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

            % CPU 底座（固体）
            cb = obj.CPU_HEATSINK.base;
            idx = rectIdx(cb.x,cb.y,cb.w,cb.h);
            obj.obstacle(idx(obj.obstacle(idx)==0)) = obj.OBSTACLE.CPU_BASE;
            % CPU 鳍片与 GPU 散热片是多孔介质（流体可穿流），不进障碍，见 buildPorousDrag
            obj.porousZones = struct('rect',{},'zetaThru',{},'zetaCross',{},'thru',{});
            pz = obj.layout.cpu.porous;
            obj.porousZones = [obj.porousZones, struct('rect', obj.CPU_HEATSINK.fin_area, ...
                'zetaThru', pz.zetaThru, 'zetaCross', pz.zetaCross, 'thru', pz.thru)];
            % GPU PCB（固体薄条）
            gp = obj.GPU_HEATSINK.pcb;
            obj.obstacle(rectIdx(gp.x,gp.y,gp.w,gp.h)) = obj.OBSTACLE.GPU_PCB;
            pz = obj.layout.gpu.porous;
            obj.porousZones = [obj.porousZones, struct('rect', obj.GPU_HEATSINK.heatsink, ...
                'zetaThru', pz.zetaThru, 'zetaCross', pz.zetaCross, 'thru', pz.thru)];
            % 电源机身与风扇口
            psu = obj.PSU2D.body;
            obj.obstacle(rectIdx(psu.x,psu.y,psu.w,psu.h)) = obj.OBSTACLE.PSU_CASE;
            pf = obj.PSU2D.fan;
            idx = rectIdx(pf.x,pf.y,pf.w,pf.h);
            obj.obstacle(idx(obj.obstacle(idx)==obj.OBSTACLE.PSU_CASE)) = obj.OBSTACLE.PSU_FAN;
            % 电源仓挡板（全宽水平隔板）
            idx = rectIdx(ox+1, obj.SHROUD.y, cs, obj.SHROUD.h);
            obj.obstacle(idx(obj.obstacle(idx)==0)) = obj.OBSTACLE.PSU_SHROUD;
            % 内存
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
            % 芯片组
            chip = obj.CHIPSET.heatsink;
            idx = rectIdx(chip.x,chip.y,chip.w,chip.h);
            mask = obj.obstacle(idx)==0 | obj.obstacle(idx)==obj.OBSTACLE.MOTHERBOARD;
            obj.obstacle(idx(mask)) = obj.OBSTACLE.CHIPSET;

            obj.updateObstacleSets();
            obj.buildPorousDrag();
        end

        function updateObstacleSets(obj)
            % 由 obstacle 重建各障碍索引集与内外掩码
            obj.obsIdx = find(obj.obstacle > 0);
            heatTypes = [obj.OBSTACLE.CPU_BASE, obj.OBSTACLE.CPU_FINS, ...
                         obj.OBSTACLE.GPU_PCB, obj.OBSTACLE.GPU_HEATSINK, ...
                         obj.OBSTACLE.PSU_CASE, obj.OBSTACLE.PSU_FAN];
            obj.heatObsIdx = find(ismember(obj.obstacle, heatTypes));
            % 温度边界：机箱壁 = 25°C Dirichlet（真实排热路径）；其余内部件 = 绝热。
            % 发热元件的热量全部经高斯注入进入流体，固体格不参与温度求解。
            obj.wallObsIdx = find(obj.obstacle == obj.OBSTACLE.WALL);
            obj.adiabaticObsIdx = find(obj.obstacle > 0 & obj.obstacle ~= obj.OBSTACLE.WALL);
            obj.computeInsideOutsideMasks();
        end

        function buildPorousDrag(obj)
            % 多孔区 Darcy-Forchheimer 二次阻力：Δp = ζ·½ρ|v|² 摊到区厚 L，
            % 每步逐面点阻尼 u ← u/(1+C·|u|)，C = ζ·VEL_SCALE·DT/(2L)（网格速度）。
            % 穿流方向低阻 ζThru、横向高阻 ζCross，表达鳍片通道的方向性。
            % 点阻尼是收缩映射，无条件稳定。面归属：u 面覆盖区内 x0..x1 及进出面。
            W = obj.GRID.W; H = obj.GRID.H;
            cellM = obj.GRID.cell_size_mm / 1000;
            uC = zeros(W, H+1);
            vC = zeros(W+1, H);
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
            if isempty(obj.uDragCoef), return; end
            obj.uF = obj.uF ./ (1 + obj.uDragCoef .* abs(obj.uF));
            obj.vF = obj.vF ./ (1 + obj.vDragCoef .* abs(obj.vF));
        end

        function computeInsideOutsideMasks(obj)
            % 机箱内部 = 机箱矩形（含壁）内的流体格；最外 spongeWidth 圈为远场海绵环
            W = obj.GRID.W; H = obj.GRID.H;
            ox = obj.caseOffsetX; oy = obj.caseOffsetY;
            cs = obj.CASE2D.outer.w;
            caseLeft = ox + 1; caseRight = ox + cs;
            caseTop = oy + 1;  caseBottom = oy + cs;
            insideRect = false(W, H);
            insideRect(caseTop:caseBottom, caseLeft:caseRight) = true;
            fluidMask = reshape(obj.obstacle == 0, W, H);
            obj.insideMask  = find(insideRect(:) & fluidMask(:));
            obj.outsideMask = find(~insideRect(:) & fluidMask(:));
            sw = max(1, round(obj.spongeWidth));
            ringMask = false(W, H);
            ringMask(1:sw, :) = true; ringMask(W-sw+1:W, :) = true;
            ringMask(:, 1:sw) = true; ringMask(:, H-sw+1:H) = true;
            obj.spongeRingIdx = find(ringMask(:) & fluidMask(:));
            spongeMask = false(W, H); spongeMask(obj.spongeRingIdx) = true;
            obj.liveOutsideMask = find(~insideRect(:) & fluidMask(:) & ~spongeMask(:));
            % 壁面距离（湍流模型用）与最近流体格索引（平流时替换障碍格值）
            cell_m = obj.GRID.cell_size_mm / 1000;
            obsMask = reshape(obj.obstacle > 0, W, H);
            if any(obsMask(:))
                try
                    d_cells = bwdist(obsMask);   % Image Processing Toolbox
                catch
                    d_cells = obj.bwdistFallback(obsMask);
                end
            else
                d_cells = ones(W, H) * max(W, H);
            end
            obj.wallDistanceM = double(d_cells(:)) * cell_m;
            if any(fluidMask(:))
                try
                    [~, nfIdx] = bwdist(fluidMask);
                catch
                    nfIdx = obj.nearestFluidFallback(fluidMask);
                end
                obj.nearestFluidIdx = nfIdx(:);
            else
                obj.nearestFluidIdx = [];
            end
        end

        function nIdx = nearestFluidFallback(~, fluidMask)
            % 无 bwdist 时的最近流体格（4 邻域传播，非严格欧氏最近）
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
            % 无 bwdist 时的壁面距离（逐格枚举，慢）
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

        % ================================================================
        % 热网络与风扇
        % ================================================================
        function initHeatSources(obj, cpuPower, gpuPower, psuPower)
            L = obj.layout;
            obj.thermalNetworks = struct();
            obj.thermalNetworks.cpu = DetailedThermalNetwork('cpu', cpuPower, L.cpu.tjmax, L.cpu.throttleTemp, obj.CPU_HEATSINK);
            obj.thermalNetworks.gpu = DetailedThermalNetwork('gpu', gpuPower, L.gpu.tjmax, L.gpu.throttleTemp, obj.GPU_HEATSINK);
            % 电源发热 = 负载 × (1 − 效率)
            obj.thermalNetworks.psu = DetailedThermalNetwork('psu', psuPower*(1-L.psu.efficiency), L.psu.tjmax, L.psu.throttleTemp, []);
        end

        function initBuiltInFans(obj)
            L = obj.layout;
            obj.builtInFans = {};
            ox = obj.caseOffsetX;
            oy = obj.caseOffsetY;
            s  = obj.gridScale;
            toCell = @(mm) round(mm / obj.GRID.cell_size_mm);
            % 顶部排气风扇（挂在顶壁所在格）
            sp = L.topFan.spec;
            obj.builtInFans{end+1} = BuiltInFan(struct('id',L.topFan.id,...
                'x',ox+toCell(L.topFan.x),'y',oy+1,'type','exhaust','mount','top','size',sp.size,...
                'rpm_min',sp.rpm_min,'rpm_max',sp.rpm_max,'cfm_max',sp.cfm_max,...
                'noise_idle',sp.noise_idle,'noise_max',sp.noise_max,'gridScale',s));
            % CPU 塔扇：挂载点取鳍片中心，气流从右向左（朝后排气）
            cf = obj.CPU_HEATSINK.fin_area;
            sp = L.cpuFan.spec;
            obj.builtInFans{end+1} = BuiltInFan(struct('id',L.cpuFan.id,...
                'x',round(cf.x + cf.w/2),'y',round(cf.y + cf.h/2),'type','exhaust','mount','cpu_tower',...
                'size',sp.size,'rpm_min',sp.rpm_min,'rpm_max',sp.rpm_max,'cfm_max',sp.cfm_max,...
                'noise_idle',sp.noise_idle,'noise_max',sp.noise_max,'gridScale',s));
            % GPU 风扇（显卡散热器下方）
            sp = L.gpuFans.spec;
            for i = 1:numel(L.gpuFans.xs)
                obj.builtInFans{end+1} = BuiltInFan(struct('id',sprintf('gpu_fan_%d',i-1),...
                    'x',ox+toCell(L.gpuFans.xs(i)),'y',oy+toCell(L.gpuFans.y),'type','exhaust',...
                    'mount','gpu_bottom','size',sp.size,...
                    'rpm_min',sp.rpm_min,'rpm_max',sp.rpm_max,'cfm_max',sp.cfm_max,...
                    'noise_idle',sp.noise_idle,'noise_max',sp.noise_max,'gridScale',s));
            end
        end

        function initFans(obj)
            obj.fans = {};
            ox = obj.caseOffsetX;
            oy = obj.caseOffsetY;
            toCell = @(mm) round(mm / obj.GRID.cell_size_mm);
            cfg = obj.layout.caseFans;
            for k = 1:numel(cfg)
                f = cfg(k);
                obj.fans{end+1} = RealFan(struct('id',k,'x',ox+toCell(f.x),'y',oy+toCell(f.y),...
                    'type',f.type,'model',f.model,'mount',f.mount,'gridScale',obj.gridScale));
            end
        end

        function initOpenBoundaries(obj)
            % 在壁面风扇位置开洞（清除机箱壁障碍），记录开口格供通量/计账用
            W = obj.GRID.W;
            ox = obj.caseOffsetX;
            oy = obj.caseOffsetY;
            cs = obj.CASE2D.outer.w;
            caseLeft = ox + 1;
            caseRight = ox + cs;
            caseTop = oy + 1;
            caseBottom = oy + cs;
            obj.openingIdx = struct('top',[],'rear',[],'front',[],'bottom',[]);
            allFans = [obj.fans, obj.builtInFans];
            for k = 1:length(allFans)
                fan = allFans{k};
                bnd = fan.getBounds();
                switch fan.mount
                    case 'top'
                        xLo = max(caseLeft, floor(bnd.x));
                        xHi = min(caseRight, ceil(bnd.x + bnd.w));
                        if xLo > xHi, continue; end
                        wIdx = ((xLo:xHi)'-1)*W + caseTop;
                    case {'rear','left'}
                        yLo = max(caseTop, floor(bnd.y));
                        yHi = min(caseBottom, ceil(bnd.y + bnd.h));
                        if yLo > yHi, continue; end
                        wIdx = (caseLeft-1)*W + (yLo:yHi)';
                    case {'front','right'}
                        yLo = max(caseTop, floor(bnd.y));
                        yHi = min(caseBottom, ceil(bnd.y + bnd.h));
                        if yLo > yHi, continue; end
                        wIdx = (caseRight-1)*W + (yLo:yHi)';
                    case 'bottom'
                        xLo = max(caseLeft, floor(bnd.x));
                        xHi = min(caseRight, ceil(bnd.x + bnd.w));
                        if xLo > xHi, continue; end
                        wIdx = ((xLo:xHi)'-1)*W + caseBottom;
                    otherwise
                        continue;
                end
                obj.obstacle(wIdx) = 0;
                switch fan.mount
                    case 'top',                  obj.openingIdx.top    = [obj.openingIdx.top;    wIdx(:)];
                    case {'rear','left'},        obj.openingIdx.rear   = [obj.openingIdx.rear;   wIdx(:)];
                    case {'front','right'},      obj.openingIdx.front  = [obj.openingIdx.front;  wIdx(:)];
                    case 'bottom',               obj.openingIdx.bottom = [obj.openingIdx.bottom; wIdx(:)];
                end
            end
            obj.updateObstacleSets();
            obj.computeFaceMasks();
            obj.onOpeningsChanged();
        end

        function computeFaceMasks(obj)
            % MAC 面掩码：格间面两侧皆流体才激活（贴障碍面无穿透，速度钉 0）；
            % 域边界面单侧邻格为流体即激活（远场开放）。阻尼面 = 邻接海绵环的激活面。
            W = obj.GRID.W; H = obj.GRID.H;
            fM = reshape(obj.obstacle == 0, W, H);
            uAct = false(W, H+1);
            uAct(:, 2:H) = fM(:,1:H-1) & fM(:,2:H);
            uAct(:, 1)   = fM(:,1);
            uAct(:, H+1) = fM(:,H);
            vAct = false(W+1, H);
            vAct(2:W, :) = fM(1:W-1,:) & fM(2:W,:);
            vAct(1, :)   = fM(1,:);
            vAct(W+1, :) = fM(W,:);
            obj.uFaceActive = uAct(:);
            obj.vFaceActive = vAct(:);
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
            % 开口变化钩子：FEM 子类重装压力矩阵
        end

        % ================================================================
        % 速度读取
        % ================================================================
        function [uC, vC] = getCellVelocity(obj)
            % 格心速度（网格单位，N×1）= 两侧面速度平均。所有读速度处统一走此接口。
            W = obj.GRID.W; H = obj.GRID.H;
            uM = reshape(obj.uF, W, H+1);
            vM = reshape(obj.vF, W+1, H);
            uC = reshape(0.5*(uM(:,1:H) + uM(:,2:H+1)), [], 1);
            vC = reshape(0.5*(vM(1:W,:) + vM(2:W+1,:)), [], 1);
        end

        function vn = getOpeningFaceVelocity(obj, mount, lo, hi)
            % 壁面开口段的穿墙面法向速度（外向为正，网格单位，列向量）。
            % lo/hi：沿壁方向的格范围（top/bottom 为 x，rear/front 为 y），
            % 用于筛出某台风扇对应的开口段。面索引约定同 computeOpeningFluxes。
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

        % ================================================================
        % 湍流
        % ================================================================
        function [S_mag, V_local, y_wall] = computeStrainRateMag(obj)
            % 应变率模 |S| [1/s]、局部速度 [m/s]、壁面距离 [m]（均为 W×H）
            W = obj.GRID.W; H = obj.GRID.H;
            velScale = obj.VEL_SCALE;
            cellSizeM = obj.GRID.cell_size_mm / 1000;

            [uC, vC] = obj.getCellVelocity();
            umat = reshape(uC, W, H) * velScale;
            vmat = reshape(vC, W, H) * velScale;
            dudy = zeros(W,H); dvdx = zeros(W,H);
            invDx = 1 / cellSizeM;
            % 法向梯度取面场差分（MAC 面恰在格心两侧）；切向梯度用格心中心差分
            uMf = reshape(obj.uF, W, H+1) * velScale;
            vMf = reshape(obj.vF, W+1, H) * velScale;
            dudx = (uMf(:, 2:H+1) - uMf(:, 1:H)) * invDx;
            dvdy = (vMf(2:W+1, :) - vMf(1:W, :)) * invDx;
            dudy(2:W-1,2:H-1) = 0.5*(umat(3:W,2:H-1) - umat(1:W-2,2:H-1)) * invDx;
            dvdx(2:W-1,2:H-1) = 0.5*(vmat(2:W-1,3:H) - vmat(2:W-1,1:H-2)) * invDx;
            S_mag = sqrt(2*(dudx.^2 + dvdy.^2) + (dudy + dvdx).^2);
            V_local = sqrt(umat.^2 + vmat.^2);

            if isempty(obj.wallDistanceM) || numel(obj.wallDistanceM) ~= obj.GRID.TOTAL
                y_wall = ones(W, H) * cellSizeM;
            else
                y_wall = reshape(obj.wallDistanceM, W, H);
            end
        end

        function nuEff = computeNuEff(obj)
            % 有效粘性场 ν_eff = ν + ν_t（N×1）。
            nuMol = obj.AIR.nu;
            [S_mag, V_local, y_wall] = obj.computeStrainRateMag();

            if strcmp(obj.turbulenceModel, 'komega')
                % k-ω（Wilcox 2006 + SST 式应力限制器）：ν_t = a₁·k / max(a₁·ω, |S|)
                if isempty(obj.turbK) || numel(obj.turbK) ~= obj.GRID.TOTAL
                    nuEff = nuMol * ones(obj.GRID.TOTAL, 1);
                    return;
                end
                a1 = 0.31;
                kMat = reshape(obj.turbK, obj.GRID.W, obj.GRID.H);
                wMat = reshape(obj.turbOmega, obj.GRID.W, obj.GRID.H);
                nu_t = a1 * kMat ./ max(a1 * wMat, S_mag);
                nu_t = min(nu_t, 2000 * nuMol);   % 数值保险帽
                nu_eff = nuMol + nu_t;
                nuEff = reshape(nu_eff, [], 1);
                nuEff(obj.obsIdx) = nuMol;
                return;
            end

            % LVEL 零方程（Agonafer/Liao/Spalding 1996）：
            % y⁺ ≈ y·V/ν，van Driest 阻尼 D = 1−exp(−y⁺/26)，l_m = κ·y·D，ν_t = l_m²·|S|
            y_plus = max(y_wall .* V_local / nuMol, 0);
            D_vD = 1 - exp(-y_plus / 26);
            kappa = 0.4;
            l_m = kappa * y_wall .* D_vD;
            nu_t = (l_m.^2) .* S_mag;
            nu_t = min(nu_t, obj.nuTCapFactor * nuMol);
            nu_eff = nuMol + nu_t;
            nu_eff = min(nu_eff, 30 * nuMol);
            nuEff = reshape(nu_eff, [], 1);
            nuEff(obj.obsIdx) = nuMol;
        end

        function [kIn, wIn] = turbulenceInletValues(obj)
            % 来流/远场湍流值：k = 1.5·(I·V_ref)²，ω = k/(β*·10ν)
            kIn = 1.5 * (obj.turbIntensity * obj.turbRefVel)^2;
            wIn = kIn / (0.09 * 10 * obj.AIR.nu);
        end

        % ================================================================
        % 体积力
        % ================================================================
        function applyBuoyancy(obj)
            % Boussinesq 浮力作用于 v 面：dv/dt = -g·β·(T-T_ref)（-v 向上）。
            % 面温 = y 向两邻格平均；作用于机箱内部与机箱外真实空气区（海绵环除外）。
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
            % 风扇动量源：每台风扇给出每步网格速度增量 (fx, fy)（压升模型，见
            % RealFan.getMomentumSource），在风扇圆盘内按 cos 衰减分配到格，
            % 再按面法向分解（格两侧 u 面各收 0.5·fx，v 面同理）。贴障碍面不受力。
            % 进气风扇同时把盘内流体温度向 25°C 新风混合。
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
                fxC = source.fx * falloff;
                fyC = source.fy * falloff;
                uIdxAll = [uIdxAll; (II-1)*W + JJ; II*W + JJ];                 %#ok<AGROW>
                uValAll = [uValAll; 0.5*fxC; 0.5*fxC];                         %#ok<AGROW>
                vIdxAll = [vIdxAll; (II-1)*(W+1) + JJ; (II-1)*(W+1) + JJ + 1]; %#ok<AGROW>
                vValAll = [vValAll; 0.5*fyC; 0.5*fyC];                         %#ok<AGROW>
                if strcmp(fan.type, 'intake')
                    Tnew = 25*falloff + obj.T_fluid(idx).*(1-falloff);
                    obj.accResetOut = obj.accResetOut + sum(Tnew - obj.T_fluid(idx));
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

        % ================================================================
        % 代数热平衡轨与开口通量
        % ================================================================
        function temps = computeAirflowTemperatures(obj)
            % 代数热平衡轨：按风扇标称风量 × 流量效率 × P-Q 折减估计换气量，
            % 充分混合假设下 T_internal = 25 + ΣP/(CFM·ρcp)。同时给出 CFD 交叉校验量。
            ambient = 25;
            intakeCFM = 0; topExhaustCFM = 0; rearExhaustCFM = 0;
            otherExhaustCFM = 0;
            for k = 1:length(obj.fans)
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
            % 内置风扇只有挂在机箱壁上的（顶排）参与整机换气；塔扇/GPU 风扇是箱内循环
            caseWallMounts = {'top','rear','front','bottom','left','right'};
            for k = 1:length(obj.builtInFans)
                f = obj.builtInFans{k};
                if strcmp(f.type,'exhaust') && any(strcmp(f.mount, caseWallMounts))
                    cfm = f.getCFM(obj)*obj.flowEfficiency*f.lastFlowFactor;
                    if strcmp(f.mount,'top'),      topExhaustCFM  = topExhaustCFM  + cfm;
                    elseif strcmp(f.mount,'rear'), rearExhaustCFM = rearExhaustCFM + cfm;
                    else,                          otherExhaustCFM = otherExhaustCFM + cfm;
                    end
                end
            end
            cpuPower = obj.thermalNetworks.cpu.actual_power;
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
            % 排气温度物理上限：不超过最热结温（风量估计暖机期上式会发散）
            TjMax = max([obj.thermalNetworks.cpu.T_junction, ...
                         obj.thermalNetworks.gpu.T_junction, ...
                         obj.thermalNetworks.psu.T_junction]);
            T_top  = min(T_top,  TjMax);
            T_rear = min(T_rear, TjMax);
            temps = struct('intake',ambient,'internalAmbient',T_internal,...
                           'topExhaust',T_top,'rearExhaust',T_rear,...
                           'totalCFM',intakeCFM+totalExhaust);

            % CFD 交叉校验：开口焓流与机箱内部流体均温
            flux = obj.computeOpeningFluxes();
            temps.topExhaustCFD  = flux.top.Tmean;
            temps.rearExhaustCFD = flux.rear.Tmean;
            outVol = max(0, flux.top.volM3s) + max(0, flux.rear.volM3s) + ...
                     max(0, flux.front.volM3s) + max(0, flux.bottom.volM3s);
            Qout   = flux.top.heatW + flux.rear.heatW + flux.front.heatW + flux.bottom.heatW;
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
            % 各壁面开口的体积流量与焓流（外向为正），直接读穿墙 MAC 面速度。
            % 面温取迎风值：出流取内侧格、入流取外侧格。
            cell_m = obj.GRID.cell_size_mm / 1000;
            dA    = cell_m * obj.CHASSIS_DEPTH_M;
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
                % 外向法向：top=−v，rear=−u，front=+u，bottom=+v
                W2 = obj.GRID.W;
                yy = mod(idx-1, W2) + 1;
                xx = ceil(idx / W2);
                switch name
                    case 'top'
                        fLin = (xx-1)*(W2+1) + yy;      sgn = -1; isV = true;  outIdx = idx - 1;
                    case 'rear'
                        fLin = (xx-1)*W2 + yy;          sgn = -1; isV = false; outIdx = idx - W2;
                    case 'front'
                        fLin = xx*W2 + yy;              sgn = +1; isV = false; outIdx = idx + W2;
                    case 'bottom'
                        fLin = (xx-1)*(W2+1) + yy + 1;  sgn = +1; isV = true;  outIdx = idx + 1;
                end
                if isV
                    vn = sgn * obj.vF(fLin);
                else
                    vn = sgn * obj.uF(fLin);
                end
                vnPhys = vn * obj.VEL_SCALE;
                Tf = obj.T_fluid(idx);
                inflowF = vnPhys < 0;
                Tf(inflowF) = obj.T_fluid(outIdx(inflowF));
                vol = sum(vnPhys) * dA;
                volOut = sum(max(0, vnPhys)) * dA;
                volIn  = sum(max(0, -vnPhys)) * dA;
                Q   = rhoCp * sum((Tf-25) .* vnPhys) * dA;
                Tmean = 25;
                if vol > 1e-6
                    Tmean = min(max(25 + Q/(rhoCp*vol), 25), 120);
                end
                flux.(name) = struct('volM3s',vol,'heatW',Q,'cfm',vol/obj.CFM_TO_M3S,'Tmean',Tmean,...
                                     'cfmOut',volOut/obj.CFM_TO_M3S,'cfmIn',volIn/obj.CFM_TO_M3S);
            end
        end

        function ff = computeFarFieldFlux(obj)
            % 远场海绵环界面的净/毛通量与焓流（出域为正，面温取迎风值）
            W = obj.GRID.W; H = obj.GRID.H;
            cell_m = obj.GRID.cell_size_mm / 1000;
            dA = cell_m * obj.CHASSIS_DEPTH_M;
            rhoCp = obj.AIR_DENSITY * obj.AIR_CP;
            uM = reshape(obj.uF, W, H+1);
            vM = reshape(obj.vF, W+1, H);
            Tmat = reshape(obj.T_fluid, W, H);
            vnTop    = -vM(2, :);
            vnBottom =  vM(W, :);
            vnLeft   = -uM(:, 2).';
            vnRight  =  uM(:, H).';
            TTop    = Tmat(2, :);      mT = vnTop < 0;    TTop(mT)    = Tmat(1, mT);
            TBottom = Tmat(W-1, :);    mB = vnBottom < 0; TBottom(mB) = Tmat(W, mB);
            TLeft   = Tmat(:, 2).';    mL = vnLeft < 0;   tmpL = Tmat(:, 1).';   TLeft(mL)  = tmpL(mL);
            TRight  = Tmat(:, H-1).';  mR = vnRight < 0;  tmpR = Tmat(:, H).';   TRight(mR) = tmpR(mR);
            vn = [vnTop, vnBottom, vnLeft, vnRight] * obj.VEL_SCALE;
            Tf = [TTop, TBottom, TLeft, TRight];
            volNet   = sum(vn) * dA;
            volGross = sum(abs(vn)) * dA;
            heatW    = rhoCp * sum((Tf - 25) .* vn) * dA;
            ff = struct('volM3s',volNet,'grossM3s',volGross,...
                        'cfm',volNet/obj.CFM_TO_M3S,...
                        'grossCfm',volGross/obj.CFM_TO_M3S,...
                        'heatW',heatW);
        end

        % ================================================================
        % 能量守恒校核
        % ================================================================
        function resetAccumulators(obj)
            obj.accResetOut = 0; obj.accClamp = 0; obj.accSteps = 0;
            obj.accAdvect = 0;  obj.accDiffuse = 0;
            obj.accClampSolve = 0; obj.accClampAdvect = 0;
            obj.accClampCap = 0;   obj.accClampFloor = 0;
            obj.accAdvectCase = 0; obj.accDiffuseCase = 0; obj.accClampCase = 0;
            obj.accBoundaryCase = 0; obj.accInjectCase = 0;
            obj.accE0 = 0; obj.accE0_case = 0;
        end

        function resetEnergyAccounting(obj)
            % 计账清零（热身后调用，使计量窗口落在近稳态区间），并记录储能基准
            obj.resetAccumulators();
            cell_m = obj.GRID.cell_size_mm / 1000;
            rhoCpCell = obj.AIR_DENSITY * obj.AIR_CP * cell_m^2 * obj.CHASSIS_DEPTH_M;
            obj.accE0 = sum(obj.T_fluid(obj.obstacle == 0) - 25) * rhoCpCell;
            if ~isempty(obj.insideMask)
                obj.accE0_case = sum(obj.T_fluid(obj.insideMask) - 25) * rhoCpCell;
            else
                obj.accE0_case = 0;
            end
        end

        function cons = computeConservationCheck(obj)
            % 能量/质量守恒校核（计量窗口 = 上次 resetEnergyAccounting 以来）。
            %
            % 判据 A（全域逐步计账，严格）：高斯注入 + 平流步 + 扩散步 + 海绵环重置
            %   + 钳位 − 储能速率 ≈ 0。所有源汇逐步实测，任意时刻成立。
            % 判据 B2（机箱内区算子级平衡）：内区注入 + 平流 + 扩散 + 钳位 + 新风混合
            %   − 内区储能速率 ≈ 0，捕获新增改温算子漏计账的回归。
            % 报告项：开口焓流 Q_exhaust、机箱壁导热 Q_wall_case、开口平面扩散
            %   Q_openingDiff（三者构成采样口径的机箱级平衡 residualCorrPct）、
            %   远场环通量与全域质量账。
            % 壁面/开口导热通量按求解器扩散算子的同一离散口径 q = ρcp_cell·gs·α_face·ΔT。
            flux = obj.computeOpeningFluxes();
            Q_exhaust = flux.top.heatW + flux.rear.heatW + flux.front.heatW + flux.bottom.heatW;
            netVol    = flux.top.volM3s + flux.rear.volM3s + flux.front.volM3s + flux.bottom.volM3s;
            grossVol  = sum(abs([flux.top.volM3s flux.rear.volM3s flux.front.volM3s flux.bottom.volM3s]));
            ff = obj.computeFarFieldFlux();
            domainNetVol = netVol + ff.volM3s;
            domainGross  = grossVol + ff.grossM3s;
            domainMassPct = 100 * domainNetVol / max(domainGross, eps);

            Q_injected = obj.thermalNetworks.cpu.actual_power + ...
                         obj.thermalNetworks.gpu.actual_power + ...
                         obj.thermalNetworks.psu.actual_power;
            Q_gaussian = Q_injected;

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

            faceCount = @(obsMask2d) ...
                [zeros(1,H); obsMask2d(1:W-1,:)] + [obsMask2d(2:W,:); zeros(1,H)] + ...
                [zeros(W,1) obsMask2d(:,1:H-1)] + [obsMask2d(:,2:H) zeros(W,1)];

            % 逐格面系数 [W/K]：面 α 取 (α_格 + α_分子)/2（壁面格 α≈分子值）
            if ~isempty(alphaFieldVec)
                kFaceCell = rhoCpCell * gs * 0.5*(alphaFieldVec + alphaMol);
            else
                kFaceCell = rhoCpCell * gs * alphaEff * ones(size(obj.T_fluid));
            end

            % 机箱壁导热（流体 → 25°C 壁，仅正贡献）
            caseM = reshape(obj.obstacle == obj.OBSTACLE.WALL, W, H);
            dTpos = max(0, Tmat - 25) .* fluidM;
            fcCase = faceCount(caseM);
            Q_wall_case = sum((dTpos(:) .* fcCase(:)) .* kFaceCell);
            % 反事实参考：若内部件仍是 25°C 热沉会吸走多少（不计入闭合）
            adiM = false(W, H); adiM(obj.adiabaticObsIdx) = true;
            fcAdi = faceCount(adiM);
            Q_wall_internal = sum((dTpos(:) .* fcAdi(:)) .* kFaceCell);
            Q_wall = Q_wall_case;

            % 开口平面扩散导热（开口两侧皆流体）
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

            % ---- 判据 A：全域逐步计账 ----
            accN = max(obj.accSteps, 1);
            accScale = rhoCpCell / (accN * obj.DT);
            Q_R_advect = obj.accAdvect   * accScale;
            Q_R_diffuse= obj.accDiffuse  * accScale;
            Q_R_wall   = -Q_wall_case;
            Q_R_out    = obj.accResetOut * accScale;
            Q_R_clamp  = obj.accClamp    * accScale;
            Q_R_clampSolve  = obj.accClampSolve  * accScale;
            Q_R_clampAdvect = obj.accClampAdvect * accScale;
            Q_R_clampCap    = obj.accClampCap    * accScale;
            Q_R_clampFloor  = obj.accClampFloor  * accScale;
            ledgerW   = Q_gaussian + Q_R_advect + Q_R_diffuse + Q_R_out + Q_R_clamp;
            ledgerPct = 100 * ledgerW / max(Q_injected, eps);
            E_now = sum((obj.T_fluid - 25) .* double(obj.obstacle == 0)) * rhoCpCell;
            dEdtW = (E_now - obj.accE0) / (accN * obj.DT);
            closureW   = ledgerW - dEdtW;
            closurePct = 100 * closureW / max(Q_injected, eps);

            % ---- 采样口径机箱级平衡（报告项）----
            Q_out    = Q_exhaust + Q_wall_case;
            residualW   = Q_out - Q_injected;
            residualPct = 100 * residualW / max(Q_injected, eps);
            E_case_now = sum(obj.T_fluid(obj.insideMask) - 25) * rhoCpCell;
            dEdtCaseW = (E_case_now - obj.accE0_case) / (accN * obj.DT);
            residualCorrW   = Q_out + Q_openingDiff + dEdtCaseW - Q_injected;
            residualCorrPct = 100 * residualCorrW / max(Q_injected, eps);

            % ---- 判据 B2：机箱内区算子级平衡 ----
            Q_injectCase  = obj.accInjectCase  * accScale;
            Q_advectCase  = obj.accAdvectCase  * accScale;
            Q_diffuseCase = obj.accDiffuseCase * accScale;
            Q_clampCase   = obj.accClampCase   * accScale;
            Q_boundaryCase= obj.accBoundaryCase* accScale;
            balanceOpW   = Q_injectCase + Q_advectCase + Q_diffuseCase + Q_clampCase + Q_boundaryCase - dEdtCaseW;
            balanceOpPct = 100 * balanceOpW / max(Q_injected, eps);
            massImbalancePct = 100 * netVol / max(grossVol, eps);

            cons = struct('Q_injected',Q_injected,'Q_gaussian',Q_gaussian,...
                          'Q_exhaust',Q_exhaust,'Q_wall',Q_wall,...
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
                          'Q_R_wall',Q_R_wall,...
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
                          'flux',flux,'alphaEff',alphaEff);
        end

        % ================================================================
        % 共轭传热：热网络求结温，元件热量以高斯核注入邻近流体
        % ================================================================
        function solveConjugateHeatTransfer(obj)
            temps = obj.computeAirflowTemperatures();
            W = obj.GRID.W; H = obj.GRID.H;
            s = obj.gridScale;
            sc = @(v) max(1, round(v * s));   % 基准格尺寸 → 当前网格
            fluidRectIdx = @(x,y,w,h) ...
                reshape(((max(2,x):min(W-1,x+w-1))'-1)*W + (max(2,y):min(H-1,y+h-1)), [], 1);
            [uC, vC] = obj.getCellVelocity();
            cell_m = obj.GRID.cell_size_mm / 1000;
            rho_cp_cell = obj.AIR.rho * obj.AIR.cp * cell_m^2 * obj.CHASSIS_DEPTH_M;  % [J/(K·cell)]

            % ---- CPU：风速取鳍片左侧出口（塔扇下游）----
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
            cfIdx = fluidRectIdx(cf.x, cf.y, cf.w, cf.h);
            [JJ,II] = ind2sub([W,H], cfIdx);
            dist = min(sqrt((II-cx).^2 + (JJ-cy).^2)/(40*s), 1);
            obj.T_solid(cfIdx) = cpuNet.T_junction - (cpuNet.T_junction-cpuNet.T_sink_base).*dist;

            % 高斯热注入（中心在鳍片上方），权重叠加对流拾取系数
            % 0.25 + 0.75·min(1, V/1.5)：热优先进入运动流体（模拟鳍片强制对流拾取）
            kg = sc(35);
            [DI,DJ] = ndgrid(-kg:kg,-kg:kg);
            II = floor(cx+DI(:)); JJ = floor((cf.y-sc(15))+DJ(:));
            valid = II>=2 & II<=W-1 & JJ>=2 & JJ<=H-1;
            II=II(valid); JJ=JJ(valid); DI=DI(valid); DJ=DJ(valid);
            heatIdx = (II-1)*W + JJ;
            free = obj.obstacle(heatIdx)==0;
            heatIdx = heatIdx(free); DI=DI(free); DJ=DJ(free);
            w = exp(-(DI.^2+DJ.^2)/(400*s^2));
            vloc = sqrt(uC(heatIdx).^2 + vC(heatIdx).^2) * obj.VEL_SCALE;
            w = w .* (0.25 + 0.75 * min(1, vloc / 1.5));
            w_sum = sum(w);
            if w_sum > 0
                dT_cpu = cpuNet.actual_power * (w/w_sum) * obj.DT / rho_cp_cell;
                obj.T_fluid(heatIdx) = obj.T_fluid(heatIdx) + dT_cpu;
                obj.accInjectCase = obj.accInjectCase + sum(dT_cpu(ismember(heatIdx, obj.insideMask)));
            end

            % ---- GPU：风速取散热器上方出口 ----
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
            ghIdx = fluidRectIdx(gh.x, gh.y, gh.w, gh.h);
            [JJ,II] = ind2sub([W,H], ghIdx);
            dist = min(sqrt(((II-gcx)/(100*s)).^2 + ((JJ-gcy)/(25*s)).^2), 1);
            obj.T_solid(ghIdx) = gpuNet.T_junction - (gpuNet.T_junction-gpuNet.T_sink_base).*dist;

            % 高斯热注入（中心在鳍片区内部，风扇上吹的气流穿鳍拾热）
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
            w = w .* (0.25 + 0.75 * min(1, vloc / 1.5));
            w_sum = sum(w);
            if w_sum > 0
                dT_gpu = gpuNet.actual_power * (w/w_sum) * obj.DT / rho_cp_cell;
                obj.T_fluid(heatIdx) = obj.T_fluid(heatIdx) + dT_gpu;
                obj.accInjectCase = obj.accInjectCase + sum(dT_gpu(ismember(heatIdx, obj.insideMask)));
            end

            % ---- PSU：风速取电源风扇左侧出口 ----
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
            psuHeat = psuNet.actual_power;
            psuBody = obj.PSU2D.body;
            psuIdx  = fluidRectIdx(psuBody.x, psuBody.y, psuBody.w, psuBody.h);
            obj.T_solid(psuIdx) = psuNet.T_junction;

            % 高斯热注入（名义中心在电源风扇左侧；若落入电源机身则重定位到
            % 自由格权重质心后重算权重，避免全功率挤进窄缝）
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
            centerLin = max(1, min(W*H, (floor(pfcx-sc(20))-1)*W + floor(pfcy)));
            if ~isempty(psuHeatIdx) && obj.obstacle(centerLin) ~= 0
                wC = w / sum(w);
                cxR = sum(II .* wC); cyR = sum(JJ .* wC);
                w = exp(-((II-cxR).^2 + (JJ-cyR).^2)/(225*s^2));
            end
            vloc = sqrt(uC(psuHeatIdx).^2 + vC(psuHeatIdx).^2) * obj.VEL_SCALE;
            w = w .* (0.25 + 0.75 * min(1, vloc / 1.5));
            w_sum = sum(w);
            if w_sum > 0
                dT_psu = psuHeat * (w/w_sum) * obj.DT / rho_cp_cell;
                obj.T_fluid(psuHeatIdx) = obj.T_fluid(psuHeatIdx) + dT_psu;
                obj.accInjectCase = obj.accInjectCase + sum(dT_psu(ismember(psuHeatIdx, obj.insideMask)));
            end
        end

        % ================================================================
        % 诊断、推进、评分
        % ================================================================
        function vort = computeVorticity(obj)
            % 涡量（网格单位，格心中心差分）
            W = obj.GRID.W; H = obj.GRID.H;
            [uC, vC] = obj.getCellVelocity();
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
            % 无量纲数诊断（特征长度 0.4 m，特征温差取 CPU 结温 − 25°C）
            L     = 0.40;
            [uC, vC] = obj.getCellVelocity();
            vel   = sqrt(uC.^2 + vC.^2);
            if ~isempty(obj.insideMask)
                fluidVel = vel(obj.insideMask);
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
            % Boussinesq 适用范围：ΔT > 30K 时密度误差 > 10%（Gray & Giorgini 1976）
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
            % 推进 steps 步并更新诊断（死区、涡量、无量纲数、代数轨温度）
            for s = 1:steps
                obj.fluidStep();
            end
            vort       = obj.computeVorticity();
            [uC, vC]   = obj.getCellVelocity();
            vel        = sqrt(uC.^2 + vC.^2);
            vortThresh = 1.2 / obj.gridScale;   % 网格涡量 ∝ 格距，阈值随网格缩放
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
            % 六维评分（锚定热网络节流阈）：
            %   散热 25%：CPU ≤60°C / GPU ≤70°C 满分 → 节流阈零分，各占一半
            %   性能 20%：实际交付功率/额定，全件锁 35% 节流时为 0
            %   均衡 10%：CPU/GPU 温差；余量 15%：距节流阈归一化温差
            %   噪音 20%：100 − 3·(dB − 20)；性价比 10%：100 − 风扇总价/15
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
            tnC = obj.thermalNetworks.cpu; tnG = obj.thermalNetworks.gpu;
            tnP = obj.thermalNetworks.psu;
            cpuCool = max(0, min(100, (tnC.throttling_temp-cpuT)/(tnC.throttling_temp-60)*100));
            gpuCool = max(0, min(100, (tnG.throttling_temp-gpuT)/(tnG.throttling_temp-70)*100));
            cooling = 0.5*cpuCool + 0.5*gpuCool;
            pNom = tnC.power + tnG.power + tnP.power;
            pAct = tnC.actual_power + tnG.actual_power + tnP.actual_power;
            performance = max(0, min(100, (pAct/max(pNom,eps) - 0.65)/0.35*100));
            balance     = max(0, 100 - abs(cpuT-gpuT)*2);
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

        function fluidStep(obj) %#ok<MANU>
            % 单步时间推进，由子类实现（Octave 不支持无实现的抽象方法声明）
            error('CFDSolverBase:abstract', 'fluidStep 由子类 CFDSolverFEM 实现');
        end
    end
end
