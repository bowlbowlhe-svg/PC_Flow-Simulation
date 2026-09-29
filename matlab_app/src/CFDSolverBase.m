classdef CFDSolverBase < handle
    %CFDSOLVERBASE PC 风道 CFD 求解器公共基类。
    %   负责几何（由布局配置构建）、场与掩码、风扇、开口、共轭传热、诊断、
    %   守恒计账与评分；时间推进 fluidStep 由子类 CFDSolverFEM 实现。
    %
    %   网格与索引约定：
    %     - 计算域 W×H 格（W=H），格心线性索引 idx = (x-1)*W + y，
    %       reshape(field, W, H) 后第 1 维为 y（向下）、第 2 维为 x（向右）。
    %     - 速度存于 MAC 交错网格面上：uF(y,xf) 为 W×(H+1)（面 xf 位于格 xf-1 与 xf 之间），
    %       vF(yf,x) 为 (W+1)×H（面 yf 位于格 yf-1 与 yf 之间），均为"网格单位"，
    %       物理速度 = 网格速度 × VEL_SCALE [m/s]，VEL_SCALE = (W-2)·格距。
    %     - 显示时 YDir 反向：y=1 在顶，-v 为向上。
    %   物理量：ν、α 为 m²/s，扩散算子系数为 1/格距²（diffScale）。

    properties (Constant)
        OBSTACLE = struct('WALL',1,'MOTHERBOARD',2,'CPU_BASE',3,'CPU_FINS',4,...
                          'GPU_PCB',5,'GPU_HEATSINK',6,'PSU_CASE',7,'PSU_FAN',8,...
                          'RAM_SLOT',9,'VRM',10,'CHIPSET',11,'PSU_SHROUD',12,'BLOCK',13)
        AIR_DENSITY = 1.184
        AIR_CP = 1005
        CFM_TO_M3S = 0.0004719
        FLOW_EFFICIENCY = 0.75   % 代数轨流量效率缺省值
    end

    properties
        % ===== 配置与网格 =====
        layout            % 布局配置（见 layout_default）
        powerW            % 名义功率输入 struct(cpu, gpu, psu) [W]（psu 为电源输出负载）
        DT = 0.005        % 时间步长 [s]
        flowEfficiency    % 代数轨流量效率
        VEL_SCALE = 0.556 % 网格速度 → m/s
        diffScale         % 扩散算子系数 1/格距² [1/m²]
        gridScale = 1     % 网格细化倍数：1=280²×2mm，2=560²×1mm，0.5=140²×4mm
        GRID = struct('W',280,'H',280,'cell_size_mm',2,'TOTAL',78400)
        caseOffsetX = 40
        caseOffsetY = 40
        CHASSIS_DEPTH_M = 0.15
        T_amb = 25        % 环境温度 [°C]
        AIR

        % ===== 场 =====
        p, T_fluid, T_solid
        uF = []
        vF = []
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
        hasCpu = false
        hasGpu = false
        hasPsu = false

        % ===== 障碍与区域索引 =====
        obsIdx = []           % 全部障碍格
        heatObsIdx = []       % 发热元件固体格（CPU 底座/GPU PCB/电源外壳；仅显示 T_solid）
        caseWallIdx = []      % 机箱壁格（全部）
        dirichletIdx = []     % 定温壁格
        dirichletT = []       % 定温壁温度（与 dirichletIdx 对齐）[°C]
        adiabaticObsIdx = []  % 其余障碍格（温度绝热）
        porousZones = []      % 多孔区 struct 数组：rect / zetaThru / zetaCross / thru
        uDragCoef = []        % u 面二次阻力系数（u ← u/(1+C|u|)），无阻力面为 0
        vDragCoef = []
        uGrilleFace = []      % 开口格栅所在的 u / v 面（逻辑列向量）
        vGrilleFace = []
        nearestFluidIdx = []  % 每格最近流体格（平流时替换障碍格值）
        insideMask = []       % 机箱内部流体格
        outsideMask = []      % 机箱外部流体格
        spongeRingIdx = []    % 域最外圈流体格（远场吸收层：阻尼 + 环境温度 + p=0）
        liveOutsideMask = []  % 机箱外真实空气区 = outsideMask \ 海绵环
        wallDistanceM = []    % 到最近障碍的距离 [m]
        openings = []         % 开口 struct 数组：mount / idx / kind / fan / zeta
        openingIdx = struct('top',[],'rear',[],'front',[],'bottom',[])  % 各壁开口格
        % 共轭传热区域：进风采样、散热体（注热 + 风速）
        cpuInletIdx = []
        cpuFinIdx = []
        gpuInletIdx = []
        gpuFinIdx = []
        psuInletIdx = []
        psuInteriorIdx = []

        % ===== 风扇与热网络 =====
        fans = {}             % 机箱风扇（Fan，role='case'）
        builtInFans = {}      % 内置风扇（Fan，role='cpu'/'gpu'/'psu'）
        thermalNetworks = struct()  % 存在的元件：cpu / gpu / psu（DetailedThermalNetwork）
        autoFanEnabled = true
        fanSpeedRatio = 40    % 全局手动转速 [%]
        fanDiskCells = 6      % 执行盘厚 [格]（由 layout.fanDiskMm 换算）
        acoustics             % 噪音模型参数（layout.acoustics 覆盖 acoustics_default）

        % ===== 模型开关与参数 =====
        spongeDamping = 0.8   % 远场海绵环速度保留比例（每步）
        spongeWidth = 1       % 海绵环厚度 [格]
        nuTCapFactor = 50     % LVEL 路径 ν_t 上限（×分子粘度）
        turbulenceModel = 'komega'  % 'komega' | 'lvel' | 'laminar'
        turbIntensity = 0.05
        turbRefVel = 2.0
        turbUpdateEvery = 1
        nuTFloor = 1e-10

        % ===== 诊断 =====
        deadZoneRatio = 0
        lastDiag
        lastTemps

        % ===== 能量计账（逐步累计 ΣΔT [K·cell]）=====
        accResetOut  = 0   % 远场海绵环重置
        accClamp     = 0
        accClampSolve  = 0
        accClampAdvect = 0
        accClampCap    = 0
        accClampFloor  = 0
        accAdvect    = 0
        accDiffuse   = 0
        accSteps     = 0
        accE0        = 0
        accE0_case   = 0
        accAdvectCase  = 0
        accDiffuseCase = 0
        accClampCase   = 0
        accInjectCase  = 0
    end

    methods
        function obj = CFDSolverBase(cpuPower, gpuPower, psuPower, layout, gridScale, dtVal)
            %CFDSOLVERBASE 构造求解器。
            %   layout 可为布局名（char）或布局配置 struct；功率参数为空时取布局默认值。
            if nargin < 4 || isempty(layout), layout = 'atx_balanced'; end
            if isstring(layout), layout = char(layout); end
            if ischar(layout), layout = layout_default(layout); end
            pw = struct('cpu', 0, 'gpu', 0, 'psu', 0);
            if isfield(layout, 'power'), pw = layout.power; end
            if nargin < 1 || isempty(cpuPower), cpuPower = pw.cpu; end
            if nargin < 2 || isempty(gpuPower), gpuPower = pw.gpu; end
            if nargin < 3 || isempty(psuPower), psuPower = pw.psu; end
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
            obj.diffScale = 1 / (obj.GRID.cell_size_mm/1000)^2;
            if isfield(layout, 'ambientC'), obj.T_amb = layout.ambientC; end
            if isfield(layout, 'turbulenceModel'), obj.turbulenceModel = layout.turbulenceModel; end
            obj.AIR = struct('rho',1.184,'mu',1.81e-5,'nu',1.56e-5,...
                             'k',0.026,'cp',1005,'Pr',0.71,...
                             'beta',3.4e-3,'g',9.81);
            if isfield(layout, 'air')
                fn = fieldnames(layout.air);
                for k = 1:numel(fn)
                    obj.AIR.(fn{k}) = layout.air.(fn{k});
                end
            end
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
            %SETCOMPONENTPOWER 修改元件功率（'cpu' | 'gpu' | 'psu'，psu 为电源输出负载）。
            obj.powerW.(name) = watts;
            if ~isfield(obj.thermalNetworks, name), return; end
            net = obj.thermalNetworks.(name);
            if strcmp(name, 'psu')
                net.power = obj.psuLossW(watts);
            else
                net.power = watts;
            end
            net.actual_power = net.power;
            net.throttling_ratio = 0;
        end

        function loss = psuLossW(obj, loadW)
            % 电源损耗 = 负载 · (1/η − 1)，η 按负载率在效率曲线上线性插值（两端取端点）
            P = obj.layout.psu;
            frac = loadW / P.ratedW;
            f = min(max(frac, P.effCurve.load(1)), P.effCurve.load(end));
            eta = interp1(P.effCurve.load, P.effCurve.eff, f, 'linear');
            loss = loadW * (1/eta - 1);
        end

        function buildModel(obj)
            % 构建几何、场、风扇与开口（构造与 reset 共用）
            obj.acoustics = acoustics_default();
            if isfield(obj.layout, 'acoustics')
                obj.acoustics = struct_merge(obj.acoustics, obj.layout.acoustics);
                acoustics_validate(obj.acoustics);
            end
            obj.initGeometry();
            obj.initFields();
            obj.initObstacles();
            obj.initHeatSources();
            obj.initFans();
            obj.initOpenings();
            obj.updateObstacleSets();
            obj.initCHTRegions();
            obj.computeFaceMasks();
            obj.buildPorousDrag();
            obj.onOpeningsChanged();
        end

        function f = allFans(obj)
            f = [obj.fans, obj.builtInFans];
        end

        function fan = findFan(obj, role)
            % 第一个指定角色的内置风扇（无则返回 []）
            fan = [];
            for k = 1:numel(obj.builtInFans)
                if strcmp(obj.builtInFans{k}.role, role), fan = obj.builtInFans{k}; return; end
            end
        end

        % ================================================================
        % 几何
        % ================================================================
        function c = toCell(obj, mm)
            c = round(mm / obj.GRID.cell_size_mm);
        end

        function r = rectToGrid(obj, rm)
            % 布局矩形（mm，相对机箱原点）→ 格坐标矩形
            r = struct('x', obj.caseOffsetX + obj.toCell(rm.x), 'y', obj.caseOffsetY + obj.toCell(rm.y), ...
                       'w', max(1, obj.toCell(rm.w)), 'h', max(1, obj.toCell(rm.h)));
        end

        function idx = rectCells(obj, r)
            % 格坐标矩形内的全部格（裁剪到计算域）
            W = obj.GRID.W; H = obj.GRID.H;
            xs = max(1, r.x) : min(H, r.x + r.w - 1);
            ys = max(1, r.y) : min(W, r.y + r.h - 1);
            [YY, XX] = ndgrid(ys, xs);
            idx = (XX(:) - 1) * W + YY(:);
        end

        function initGeometry(obj)
            L = obj.layout;
            ox = obj.caseOffsetX;
            oy = obj.caseOffsetY;
            cs = obj.toCell(L.chassis.sizeMm);
            obj.CASE2D = struct('outer', struct('x',ox+1,'y',oy+1,'w',cs,'h',cs), ...
                                'enabled', L.chassis.enabled);
            if isfield(L, 'motherboardTray')
                obj.CASE2D.motherboard_tray = obj.rectToGrid(L.motherboardTray);
            end
            obj.hasCpu = isfield(L, 'cpu') && ~isempty(L.cpu);
            obj.hasGpu = isfield(L, 'gpu') && ~isempty(L.gpu);
            obj.hasPsu = isfield(L, 'psu') && ~isempty(L.psu);
            obj.CPU_HEATSINK = []; obj.GPU_HEATSINK = []; obj.PSU2D = [];
            if obj.hasCpu
                obj.CPU_HEATSINK = struct('base', obj.rectToGrid(L.cpu.base), ...
                    'fin_area', obj.rectToGrid(L.cpu.fins), 'thermal', L.cpu.thermal);
            end
            if obj.hasGpu
                obj.GPU_HEATSINK = struct('pcb', obj.rectToGrid(L.gpu.pcb), ...
                    'heatsink', obj.rectToGrid(L.gpu.heatsink), 'thermal', L.gpu.thermal);
            end
            if obj.hasPsu
                % 电源贴后壁/底壁安装：与壁内侧的间隙 ≤ 6 mm 时对齐到壁内侧
                % （按 mm 判断，各档网格一致；粗网格取整可能压到壁上，也一并对齐）
                b = obj.rectToGrid(L.psu.body);
                cL = ox + 1; cB = oy + cs;
                snapCells = 6 / obj.GRID.cell_size_mm;
                if b.x - (cL + 1) <= snapCells
                    b.w = b.w + (b.x - (cL + 1)); b.x = cL + 1;
                end
                if (cB - 1) - (b.y + b.h - 1) <= snapCells
                    b.h = (cB - 1) - b.y + 1;
                end
                obj.PSU2D = struct('body', b);
            end
            obj.RAM_SLOTS = [];
            if isfield(L, 'ram')
                for r = 1:numel(L.ram)
                    g = obj.rectToGrid(L.ram(r));
                    if r == 1, obj.RAM_SLOTS = g; else, obj.RAM_SLOTS(r,1) = g; end
                end
            end
            obj.VRM = []; obj.CHIPSET = []; obj.SHROUD = [];
            if isfield(L, 'vrm'), obj.VRM = struct('heatsink', obj.rectToGrid(L.vrm)); end
            if isfield(L, 'chipset'), obj.CHIPSET = struct('heatsink', obj.rectToGrid(L.chipset)); end
            if isfield(L, 'shroud')
                obj.SHROUD = struct('y', oy + obj.toCell(L.shroud.yMm), 'h', obj.toCell(L.shroud.hMm));
            end
        end

        function initFields(obj)
            N = obj.GRID.TOTAL;
            W = obj.GRID.W; H = obj.GRID.H;
            obj.p = zeros(N,1);
            obj.T_fluid = ones(N,1)*obj.T_amb;
            obj.T_solid = ones(N,1)*obj.T_amb;
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
            % 障碍布置：机箱壁 → 元件固体 → 电源仓挡板 → 其它；多孔区登记
            L = obj.layout;
            obj.obstacle(:) = 0;
            W = obj.GRID.W;
            OB = obj.OBSTACLE;
            obj.porousZones = struct('rect',{},'zetaThru',{},'zetaCross',{},'thru',{});
            co = obj.CASE2D.outer;
            if obj.CASE2D.enabled
                cL = co.x; cR = co.x + co.w - 1; cT = co.y; cB = co.y + co.h - 1;
                obj.obstacle((cL-1)*W + (cT:cB)) = OB.WALL;
                obj.obstacle((cR-1)*W + (cT:cB)) = OB.WALL;
                obj.obstacle(((cL:cR)-1)*W + cT) = OB.WALL;
                obj.obstacle(((cL:cR)-1)*W + cB) = OB.WALL;
            end
            setIfFree = @(idx, type) obj.setObstacle(idx(obj.obstacle(idx) == 0), type);

            if obj.hasCpu
                setIfFree(obj.rectCells(obj.CPU_HEATSINK.base), OB.CPU_BASE);
                pz = L.cpu.porous;
                obj.porousZones(end+1) = struct('rect', obj.CPU_HEATSINK.fin_area, ...
                    'zetaThru', pz.zetaThru, 'zetaCross', pz.zetaCross, 'thru', pz.thru);
            end
            if obj.hasGpu
                setIfFree(obj.rectCells(obj.GPU_HEATSINK.pcb), OB.GPU_PCB);
                pz = L.gpu.porous;
                obj.porousZones(end+1) = struct('rect', obj.GPU_HEATSINK.heatsink, ...
                    'zetaThru', pz.zetaThru, 'zetaCross', pz.zetaCross, 'thru', pz.thru);
            end
            if obj.hasPsu
                % 电源：1 格外壳（固体）+ 内部多孔区
                b = obj.PSU2D.body;
                inner = struct('x', b.x+1, 'y', b.y+1, 'w', b.w-2, 'h', b.h-2);
                shell = setdiff(obj.rectCells(b), obj.rectCells(inner));
                setIfFree(shell, OB.PSU_CASE);
                obj.PSU2D.interior = inner;
                pz = L.psu.porous;
                obj.porousZones(end+1) = struct('rect', inner, ...
                    'zetaThru', pz.zetaThru, 'zetaCross', pz.zetaCross, 'thru', pz.thru);
            end
            if ~isempty(obj.SHROUD)
                sh = struct('x', co.x, 'y', obj.SHROUD.y, 'w', co.w, 'h', obj.SHROUD.h);
                idx = obj.rectCells(sh);
                if isfield(L.shroud, 'gaps')
                    for g = 1:numel(L.shroud.gaps)
                        gp = L.shroud.gaps(g);
                        x0 = obj.caseOffsetX + obj.toCell(gp.x0Mm);
                        x1 = obj.caseOffsetX + obj.toCell(gp.x1Mm);
                        xx = ceil(idx / W);
                        idx = idx(xx < x0 | xx > x1);
                    end
                end
                setIfFree(idx, OB.PSU_SHROUD);
            end
            for r = 1:numel(obj.RAM_SLOTS)
                setIfFree(obj.rectCells(obj.RAM_SLOTS(r)), OB.RAM_SLOT);
            end
            if ~isempty(obj.VRM)
                setIfFree(obj.rectCells(obj.VRM.heatsink), OB.VRM);
            end
            if isfield(L, 'solidBlocks')
                for k = 1:numel(L.solidBlocks)
                    setIfFree(obj.rectCells(obj.rectToGrid(L.solidBlocks(k))), OB.BLOCK);
                end
            end
            if isfield(L, 'porousBlocks')
                for k = 1:numel(L.porousBlocks)
                    pb = L.porousBlocks(k);
                    obj.porousZones(end+1) = struct('rect', obj.rectToGrid(pb.rect), ...
                        'zetaThru', pb.zetaThru, 'zetaCross', pb.zetaCross, 'thru', pb.thru);
                end
            end
        end

        function setObstacle(obj, idx, type)
            obj.obstacle(idx) = type;
        end

        function updateObstacleSets(obj)
            % 由 obstacle 重建各障碍索引集与内外掩码
            OB = obj.OBSTACLE;
            obj.obsIdx = find(obj.obstacle > 0);
            obj.heatObsIdx = find(ismember(obj.obstacle, [OB.CPU_BASE, OB.GPU_PCB, OB.PSU_CASE]));
            obj.caseWallIdx = find(obj.obstacle == OB.WALL);
            % 温度边界：定温壁 = Dirichlet，其余障碍 = 绝热。元件热量全部经注热进入流体。
            [obj.dirichletIdx, obj.dirichletT] = obj.wallTemperatureCells();
            obj.adiabaticObsIdx = setdiff(obj.obsIdx, obj.dirichletIdx);
            obj.computeInsideOutsideMasks();
        end

        function [idx, T] = wallTemperatureCells(obj)
            % 各机箱壁的 Dirichlet 温度（NaN 壁为绝热，不计入）
            idx = []; T = [];
            if ~obj.CASE2D.enabled, return; end
            W = obj.GRID.W;
            co = obj.CASE2D.outer;
            cL = co.x; cR = co.x + co.w - 1; cT = co.y; cB = co.y + co.h - 1;
            wt = obj.layout.chassis.wallTempC;
            % 角格归属：顶/底壁优先
            sides = {'top',    ((cL:cR)'-1)*W + cT; ...
                     'bottom', ((cL:cR)'-1)*W + cB; ...
                     'rear',   (cL-1)*W + (cT+1:cB-1)'; ...
                     'front',  (cR-1)*W + (cT+1:cB-1)'};
            for k = 1:size(sides,1)
                Tw = wt.(sides{k,1});
                if isempty(Tw) || isnan(Tw), continue; end    % NaN（JSON 读回为 []）= 绝热
                cells = sides{k,2};
                cells = cells(obj.obstacle(cells) == obj.OBSTACLE.WALL);
                idx = [idx; cells];                       %#ok<AGROW>
                T = [T; Tw * ones(numel(cells),1)];      %#ok<AGROW>
            end
        end

        function buildPorousDrag(obj)
            % 二次阻力（Darcy-Forchheimer）系数：每面每步阻力 C·|u|u（网格单位），
            % 在阻力耦合投影（CFDSolverFEM.projectWithDrag）中以 β = 1/(1+C|u_ref|) 隐式施加，
            % u_ref 为施加风扇力之前的速度。
            %   多孔区：总压降 ζ·½ρv² 分摊到区内各面，C = ζ·VEL_SCALE·DT/(2·L)，
            %          L 为区厚；区边界面半权（控制体一半在区外）。
            %   开口格栅：总压降 ζ·½ρv² 施加在穿壁的内侧面上（L = 1 格）。
            W = obj.GRID.W; H = obj.GRID.H;
            cellM = obj.GRID.cell_size_mm / 1000;
            uC = zeros(W, H+1);
            vC = zeros(W+1, H);
            gU = false(W, H+1);          % 开口格栅面（阻力重装判据分组用）
            gV = false(W+1, H);
            for z = 1:numel(obj.porousZones)
                zn = obj.porousZones(z); r = zn.rect;
                x0 = max(2, r.x);         x1 = min(H-1, r.x + r.w - 1);
                y0 = max(2, r.y);         y1 = min(W-1, r.y + r.h - 1);
                if x1 < x0 || y1 < y0, continue; end
                nx = x1 - x0 + 1; ny = y1 - y0 + 1;
                if strcmp(zn.thru, 'x')
                    zU = zn.zetaThru; zV = zn.zetaCross;
                else
                    zU = zn.zetaCross; zV = zn.zetaThru;
                end
                cU = zU * obj.VEL_SCALE * obj.DT / (2 * nx * cellM);
                cV = zV * obj.VEL_SCALE * obj.DT / (2 * ny * cellM);
                wU = ones(1, nx+1); wU([1 end]) = 0.5;     % u 面 x0..x1+1
                wV = ones(ny+1, 1); wV([1 end]) = 0.5;     % v 面 y0..y1+1
                uC(y0:y1, x0:x1+1) = max(uC(y0:y1, x0:x1+1), cU * repmat(wU, ny, 1));
                vC(y0:y1+1, x0:x1) = max(vC(y0:y1+1, x0:x1), cV * repmat(wV, 1, nx));
            end
            for k = 1:numel(obj.openings)
                op = obj.openings(k);
                if op.zeta <= 0 || isempty(op.idx), continue; end
                c = op.zeta * obj.VEL_SCALE * obj.DT / (2 * cellM);
                yy = mod(op.idx-1, W) + 1;
                xx = ceil(op.idx / W);
                switch op.mount
                    case 'rear',   f = sub2ind([W H+1], yy, xx+1); uC(f) = c; gU(f) = true;
                    case 'front',  f = sub2ind([W H+1], yy, xx);   uC(f) = c; gU(f) = true;
                    case 'top',    f = sub2ind([W+1 H], yy+1, xx); vC(f) = c; gV(f) = true;
                    case 'bottom', f = sub2ind([W+1 H], yy, xx);   vC(f) = c; gV(f) = true;
                end
            end
            obj.uDragCoef = uC(:);
            obj.vDragCoef = vC(:);
            obj.uGrilleFace = gU(:);
            obj.vGrilleFace = gV(:);
        end

        function computeInsideOutsideMasks(obj)
            % 机箱内部 = 机箱矩形（含壁）内的流体格；最外 spongeWidth 圈为远场海绵环
            W = obj.GRID.W; H = obj.GRID.H;
            co = obj.CASE2D.outer;
            insideRect = false(W, H);
            insideRect(co.y:co.y+co.h-1, co.x:co.x+co.w-1) = true;
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
        % 热网络、风扇与开口
        % ================================================================
        function initHeatSources(obj)
            L = obj.layout;
            obj.thermalNetworks = struct();
            if obj.hasCpu
                obj.thermalNetworks.cpu = DetailedThermalNetwork('cpu', obj.powerW.cpu, ...
                    L.cpu.tjmax, L.cpu.throttleTemp, obj.CPU_HEATSINK);
            end
            if obj.hasGpu
                obj.thermalNetworks.gpu = DetailedThermalNetwork('gpu', obj.powerW.gpu, ...
                    L.gpu.tjmax, L.gpu.throttleTemp, obj.GPU_HEATSINK);
            end
            if obj.hasPsu
                net = DetailedThermalNetwork('psu', obj.psuLossW(obj.powerW.psu), ...
                    L.psu.warnTemp + 15, L.psu.warnTemp, []);
                net.canThrottle = false;          % 电源不降频：超温只告警
                net.R_internal = L.psu.R_internal;
                obj.thermalNetworks.psu = net;
            end
            for f = fieldnames(obj.thermalNetworks)'
                obj.thermalNetworks.(f{1}).T_junction = obj.T_amb;
                obj.thermalNetworks.(f{1}).T_theory_f = obj.T_amb;
            end
        end

        function T = sensorTemp(obj, sensor)
            % 风扇温控传感器温度 [°C]；缺失的元件按环境温度
            tj = @(n) obj.junctionOr(n);
            switch sensor
                case 'cpu', T = tj('cpu');
                case 'gpu', T = tj('gpu');
                case 'psu', T = tj('psu');
                otherwise,  T = max(tj('cpu'), tj('gpu'));
            end
        end

        function T = junctionOr(obj, name)
            if isfield(obj.thermalNetworks, name)
                T = obj.thermalNetworks.(name).T_junction;
            else
                T = obj.T_amb;
            end
        end

        function initFans(obj)
            % 由布局创建风扇并确定执行盘几何（格坐标）
            L = obj.layout;
            obj.fans = {};
            obj.builtInFans = {};
            t = max(1, obj.toCell(L.fanDiskMm));
            obj.fanDiskCells = t;
            cat = fan_catalog();
            if isfield(L, 'caseFans')
                for k = 1:numel(L.caseFans)
                    cf = L.caseFans(k);
                    cfg = struct('id', sprintf('case_%s_%d', cf.mount, k), 'role', 'case', ...
                        'mount', cf.mount, 'type', cf.type, 'model', cf.model, 'sensor', 'max');
                    if isfield(cf, 'speedMode'), cfg.speedMode = cf.speedMode; end
                    if isfield(cf, 'manualPct'), cfg.manualPct = cf.manualPct; end
                    fan = Fan(cfg);
                    obj.placeWallFan(fan, cf.alongMm, t);
                    fan.positionDb = obj.acoustics.positionDb.(cf.mount);
                    obj.fans{end+1} = fan;
                end
            end
            if obj.hasCpu && isfield(L.cpu, 'fan')
                fin = obj.CPU_HEATSINK.fin_area;
                fan = Fan(struct('id', 'cpu_tower_fan', 'role', 'cpu', 'model', L.cpu.fan.model, 'sensor', 'cpu'));
                n = obj.toCell(cat.(fan.model).size);
                cy = round(fin.y + (fin.h-1)/2);
                r0 = cy - floor(n/2);
                fan.rows = [r0, r0 + n - 1];
                fan.cols = [fin.x + fin.w, fin.x + fin.w + t - 1];   % 鳍片前侧
                fan.normal = [-1 0];                                 % 从前向后吹
                fan.thickM = t * obj.GRID.cell_size_mm / 1000;
                fan.positionDb = obj.acoustics.positionDb.cpu;
                obj.builtInFans{end+1} = fan;
            end
            if obj.hasGpu && isfield(L.gpu, 'fans')
                hs = obj.GPU_HEATSINK.heatsink;
                prevC1 = -Inf;
                for i = 1:numel(L.gpu.fans.xs)
                    fan = Fan(struct('id', sprintf('gpu_fan_%d', i-1), 'role', 'gpu', ...
                        'model', L.gpu.fans.model, 'sensor', 'gpu'));
                    n = obj.toCell(cat.(fan.model).size);
                    c = obj.caseOffsetX + obj.toCell(L.gpu.fans.xs(i));
                    c0 = max([c - floor(n/2), prevC1 + 1, hs.x]);     % 不重叠、不伸出散热片左端
                    c1 = min(c0 + n - 1, hs.x + hs.w - 1);            % 不伸出散热片右端
                    if c1 < c0
                        error('CFDSolverBase:gpuFans', '显卡风扇 %d 在散热片上放不下（散热片宽 %d 格）', i, hs.w);
                    end
                    fan.cols = [c0, c1];
                    prevC1 = fan.cols(2);
                    fan.rows = [hs.y + hs.h, hs.y + hs.h + t - 1];      % 散热片下方
                    fan.normal = [0 -1];                                 % 向上吹入鳍片
                    fan.thickM = t * obj.GRID.cell_size_mm / 1000;
                    fan.positionDb = obj.acoustics.positionDb.gpu;
                    obj.builtInFans{end+1} = fan;
                end
            end
            if obj.hasPsu && isfield(L.psu, 'fan')
                in = obj.PSU2D.interior;
                fan = Fan(struct('id', 'psu_fan', 'role', 'psu', 'model', L.psu.fan.model, 'sensor', 'psu'));
                n = obj.toCell(cat.(fan.model).size);
                c = obj.caseOffsetX + obj.toCell(L.psu.fan.xMm);
                c0 = max(in.x, c - floor(n/2));
                c1 = min(in.x + in.w - 1, c0 + n - 1);
                fan.cols = [c0, c1];
                fan.rows = [in.y + in.h - t, in.y + in.h - 1];           % 电源内部底部
                fan.normal = [0 -1];                                     % 自底部向上吸入
                fan.thickM = t * obj.GRID.cell_size_mm / 1000;
                fan.positionDb = obj.acoustics.positionDb.psu;
                obj.builtInFans{end+1} = fan;
            end
        end

        function placeWallFan(obj, fan, alongMm, t)
            % 机箱风扇：盘紧贴壁面内侧，宽 = 风扇直径，厚 t 格；进气吹向箱内、排气吹向箱外
            [fan.cols, fan.rows] = obj.wallFanSpan(fan.mount, alongMm, fan.size, t);
            sgn = 1; if strcmp(fan.type, 'intake'), sgn = -1; end
            switch fan.mount
                case 'front',  fan.normal = [ sgn 0];
                case 'rear',   fan.normal = [-sgn 0];
                case 'top',    fan.normal = [0 -sgn];
                case 'bottom', fan.normal = [0  sgn];
            end
            fan.thickM = t * obj.GRID.cell_size_mm / 1000;
        end

        function [cols, rows] = wallFanSpan(obj, mount, alongMm, sizeMm, t)
            % 壁装风扇执行盘占据的格列/格行（placeWallFan 与界面安装位标记共用）
            if nargin < 5, t = obj.fanDiskCells; end
            co = obj.CASE2D.outer;
            cL = co.x; cR = co.x + co.w - 1; cT = co.y; cB = co.y + co.h - 1;
            n = obj.toCell(sizeMm);
            c = obj.toCell(alongMm);
            a0 = c - floor(n/2);
            a0 = max(2, min(co.w - n, a0));              % 夹在壁内侧范围
            a1 = a0 + n - 1;
            switch mount
                case 'front',  cols = [cR - t, cR - 1];  rows = co.y - 1 + [a0 a1];
                case 'rear',   cols = [cL + 1, cL + t];  rows = co.y - 1 + [a0 a1];
                case 'top',    rows = [cT + 1, cT + t];  cols = co.x - 1 + [a0 a1];
                case 'bottom', rows = [cB - t, cB - 1];  cols = co.x - 1 + [a0 a1];
                otherwise
                    error('CFDSolverBase:mount', '未知风扇安装位：%s', mount);
            end
        end

        function initOpenings(obj)
            % 开口：机箱风扇位、电源进/出风口、被动通风口。开口处清除壁/外壳障碍，
            % 并记录格栅阻力 ζ（buildPorousDrag 施加在穿壁面上）。
            L = obj.layout;
            W = obj.GRID.W;
            co = obj.CASE2D.outer;
            cL = co.x; cR = co.x + co.w - 1; cT = co.y; cB = co.y + co.h - 1;
            ops = struct('mount',{},'idx',{},'kind',{},'fan',{},'zeta',{});
            wallCells = @(mount, a0, a1) obj.wallSpanCells(mount, a0, a1, cL, cR, cT, cB);
            % 机箱风扇
            for k = 1:numel(obj.fans)
                f = obj.fans{k};
                switch f.mount
                    case {'front','rear'}, span = f.rows;
                    otherwise,             span = f.cols;
                end
                if strcmp(f.type, 'intake'), z = L.grille.intakeZeta; else, z = L.grille.exhaustZeta; end
                f.grilleZeta = z;
                ops(end+1) = struct('mount', f.mount, 'idx', wallCells(f.mount, span(1), span(2)), ...
                    'kind', 'fan', 'fan', k, 'zeta', z); %#ok<AGROW>
            end
            % 被动通风口
            if isfield(L, 'vents')
                for k = 1:numel(L.vents)
                    v = L.vents(k);
                    n = obj.toCell(v.lengthMm);
                    c = obj.toCell(v.alongMm);
                    a0 = max(2, c - floor(n/2)); a1 = min(co.w - 1, a0 + n - 1);
                    switch v.mount
                        case {'front','rear'}, span = co.y - 1 + [a0 a1];
                        otherwise,             span = co.x - 1 + [a0 a1];
                    end
                    ops(end+1) = struct('mount', v.mount, 'idx', wallCells(v.mount, span(1), span(2)), ...
                        'kind', 'vent', 'fan', 0, 'zeta', v.zeta); %#ok<AGROW>
                end
            end
            % 电源：底部进风（风扇下方）、后部出风
            if obj.hasPsu
                b = obj.PSU2D.body; in = obj.PSU2D.interior;
                pf = obj.findFan('psu');
                if isempty(pf)   % 无风扇时进风口取机身中段 120 mm
                    n = obj.toCell(120); c0 = in.x + floor((in.w - n)/2);
                    pf = struct('cols', [max(in.x, c0), min(in.x + in.w - 1, c0 + n - 1)]);
                end
                % 外壳开孔：底部进风、后部出风
                obj.obstacle(((pf.cols(1):pf.cols(2))' - 1)*W + (b.y + b.h - 1)) = 0;
                obj.obstacle((b.x - 1)*W + (in.y:in.y+in.h-1)') = 0;
                obj.psuInletIdx = ((pf.cols(1):pf.cols(2))' - 1)*W + (b.y + b.h - 1);
                if b.y + b.h == cB
                    ops(end+1) = struct('mount', 'bottom', 'idx', wallCells('bottom', pf.cols(1), pf.cols(2)), ...
                        'kind', 'psu_intake', 'fan', 0, 'zeta', L.psu.intakeZeta); %#ok<AGROW>
                end
                if b.x == cL + 1
                    ops(end+1) = struct('mount', 'rear', 'idx', wallCells('rear', in.y, in.y + in.h - 1), ...
                        'kind', 'psu_exhaust', 'fan', 0, 'zeta', L.psu.exhaustZeta); %#ok<AGROW>
                end
            end
            obj.openings = ops;
            obj.openingIdx = struct('top',[],'rear',[],'front',[],'bottom',[]);
            for k = 1:numel(ops)
                obj.obstacle(ops(k).idx) = 0;
                obj.openingIdx.(ops(k).mount) = [obj.openingIdx.(ops(k).mount); ops(k).idx(:)];
            end
        end

        function idx = wallSpanCells(obj, mount, a0, a1, cL, cR, cT, cB)
            % 指定壁面上 a0..a1（行或列）的壁格
            W = obj.GRID.W;
            switch mount
                case 'front',  idx = (cR - 1)*W + (a0:a1)';
                case 'rear',   idx = (cL - 1)*W + (a0:a1)';
                case 'top',    idx = ((a0:a1)' - 1)*W + cT;
                case 'bottom', idx = ((a0:a1)' - 1)*W + cB;
            end
        end

        function initCHTRegions(obj)
            % 共轭传热区域：散热体（注热、风速）与进风采样（环境温度）
            fluid = obj.obstacle == 0;
            keepFluid = @(idx) idx(fluid(idx));
            nIn = max(2, obj.toCell(10));   % 进风采样带厚 10 mm
            if obj.hasCpu
                obj.cpuFinIdx = keepFluid(obj.rectCells(obj.CPU_HEATSINK.fin_area));
                cf = obj.findFan('cpu');
                if isempty(cf)
                    fin = obj.CPU_HEATSINK.fin_area;
                    obj.cpuInletIdx = keepFluid(obj.rectCells(struct('x', fin.x + fin.w, 'y', fin.y, 'w', nIn, 'h', fin.h)));
                else
                    obj.cpuInletIdx = keepFluid(obj.rectCells(struct('x', cf.cols(2) + 1, 'y', cf.rows(1), ...
                        'w', nIn, 'h', cf.rows(2) - cf.rows(1) + 1)));
                end
            end
            if obj.hasGpu
                hs = obj.GPU_HEATSINK.heatsink;
                obj.gpuFinIdx = keepFluid(obj.rectCells(hs));
                gf = obj.findFan('gpu');
                r0 = hs.y + hs.h;
                if ~isempty(gf), r0 = gf.rows(2) + 1; end
                obj.gpuInletIdx = keepFluid(obj.rectCells(struct('x', hs.x, 'y', r0, 'w', hs.w, 'h', nIn)));
            end
            if obj.hasPsu
                obj.psuInteriorIdx = keepFluid(obj.rectCells(obj.PSU2D.interior));
                obj.psuInletIdx = keepFluid(obj.psuInletIdx);
            end
            if obj.hasCpu && isempty(obj.cpuInletIdx), obj.cpuInletIdx = obj.cpuFinIdx; end
            if obj.hasGpu && isempty(obj.gpuInletIdx), obj.gpuInletIdx = obj.gpuFinIdx; end
            if obj.hasPsu && isempty(obj.psuInletIdx), obj.psuInletIdx = obj.psuInteriorIdx; end
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
            % 几何变化钩子：FEM 子类重装压力矩阵
        end

        % ================================================================
        % 速度读取
        % ================================================================
        function [uC, vC] = getCellVelocity(obj)
            % 格心速度（网格单位，N×1）= 两侧面速度平均
            W = obj.GRID.W; H = obj.GRID.H;
            uM = reshape(obj.uF, W, H+1);
            vM = reshape(obj.vF, W+1, H);
            uC = reshape(0.5*(uM(:,1:H) + uM(:,2:H+1)), [], 1);
            vC = reshape(0.5*(vM(1:W,:) + vM(2:W+1,:)), [], 1);
        end

        function Q = diskFlow(obj, fan)
            % 穿过风扇盘中面的体积流量 [m³/s]（送风方向为正）
            W = obj.GRID.W;
            dA = obj.GRID.cell_size_mm / 1000 * obj.CHASSIS_DEPTH_M;
            if fan.normal(1) ~= 0
                t = fan.cols(2) - fan.cols(1) + 1;
                xf = fan.cols(1) + floor(t/2);
                rows = (fan.rows(1):fan.rows(2))';
                vn = sign(fan.normal(1)) * obj.uF((xf-1)*W + rows);
            else
                t = fan.rows(2) - fan.rows(1) + 1;
                yf = fan.rows(1) + floor(t/2);
                cols = (fan.cols(1):fan.cols(2))';
                vn = sign(fan.normal(2)) * obj.vF((cols-1)*(W+1) + yf);
            end
            Q = sum(vn) * obj.VEL_SCALE * dA;
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

        function nuEff = computeNuEff(obj, S_mag, V_local, y_wall)
            % 有效粘性场 ν_eff = ν + ν_t（N×1）。可传入本步已算好的应变率场以免重算。
            nuMol = obj.AIR.nu;
            if strcmp(obj.turbulenceModel, 'laminar')
                nuEff = nuMol * ones(obj.GRID.TOTAL, 1);
                return;
            end
            if nargin < 4
                [S_mag, V_local, y_wall] = obj.computeStrainRateMag();
            end
            if strcmp(obj.turbulenceModel, 'komega')
                % k-ω（Wilcox 2006 + SST 式应力限制器）：ν_t = a₁·k / max(a₁·ω, |S|)
                a1 = 0.31;
                kMat = reshape(obj.turbK, obj.GRID.W, obj.GRID.H);
                wMat = reshape(obj.turbOmega, obj.GRID.W, obj.GRID.H);
                nu_t = a1 * kMat ./ max(a1 * wMat, S_mag);
                nu_t = min(nu_t, 2000 * nuMol);   % 数值保险帽
                nuEff = reshape(nuMol + nu_t, [], 1);
                nuEff(obj.obsIdx) = nuMol;
                return;
            end
            % LVEL 零方程：y⁺ ≈ y·V/ν，D = 1−exp(−y⁺/26)，l_m = κ·y·D，ν_t = l_m²·|S|
            y_plus = max(y_wall .* V_local / nuMol, 0);
            D_vD = 1 - exp(-y_plus / 26);
            l_m = 0.4 * y_wall .* D_vD;
            nu_t = min((l_m.^2) .* S_mag, obj.nuTCapFactor * nuMol);
            nu_eff = min(nuMol + nu_t, 30 * nuMol);
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
            % Boussinesq 浮力：dv/dt = −g·β·(T − T_amb)（物理量），换算为网格速度增量
            % ÷ VEL_SCALE。面温 = y 向两邻格平均；作用于机箱内与机箱外真实空气（海绵环除外）。
            W = obj.GRID.W; H = obj.GRID.H;
            Tm = reshape(obj.T_fluid, W, H);
            vTf = zeros(W+1, H);
            vTf(2:W, :) = 0.5*(Tm(1:W-1,:) + Tm(2:W,:));
            vTf(1, :)   = Tm(1,:);
            vTf(W+1, :) = Tm(W,:);
            buoyF = -obj.DT * obj.AIR.g * obj.AIR.beta * (vTf - obj.T_amb) / obj.VEL_SCALE;
            buoyM = false(W, H);
            buoyM([obj.insideMask; obj.liveOutsideMask]) = true;
            vB = false(W+1, H);
            vB(2:W, :) = buoyM(1:W-1,:) | buoyM(2:W,:);
            vB = vB & reshape(obj.vFaceActive, W+1, H);
            obj.vF = obj.vF + buoyF(:) .* double(vB(:));
        end

        function applyFanForces(obj)
            % 执行盘：盘内每格体积力 a = Δp/(ρ·t)，每步网格速度增量 Δu = a·DT/VEL_SCALE，
            % 沿送风方向分到格两侧面（各 0.5），盘内相邻格共享面合计 1 份，
            % 穿盘的积分静压升恰为 Δp。贴障碍面不受力。
            W = obj.GRID.W; H = obj.GRID.H;
            allF = obj.allFans();
            uIdx = zeros(0,1); uVal = zeros(0,1);
            vIdx = zeros(0,1); vVal = zeros(0,1);
            for k = 1:numel(allF)
                fan = allF{k};
                dp = fan.updateOperatingPoint(obj);
                du = dp / (obj.AIR_DENSITY * fan.thickM) * obj.DT / obj.VEL_SCALE;
                [RR, CC] = ndgrid(fan.rows(1):fan.rows(2), fan.cols(1):fan.cols(2));
                RR = RR(:); CC = CC(:);
                ok = RR >= 1 & RR <= W & CC >= 1 & CC <= H;
                RR = RR(ok); CC = CC(ok);
                free = obj.obstacle((CC-1)*W + RR) == 0;
                RR = RR(free); CC = CC(free);
                if fan.normal(1) ~= 0
                    val = 0.5 * du * fan.normal(1) * ones(numel(RR), 1);
                    uIdx = [uIdx; (CC-1)*W + RR; CC*W + RR];      %#ok<AGROW>
                    uVal = [uVal; val; val];                      %#ok<AGROW>
                end
                if fan.normal(2) ~= 0
                    val = 0.5 * du * fan.normal(2) * ones(numel(RR), 1);
                    vIdx = [vIdx; (CC-1)*(W+1) + RR; (CC-1)*(W+1) + RR + 1]; %#ok<AGROW>
                    vVal = [vVal; val; val];                                 %#ok<AGROW>
                end
            end
            if ~isempty(uIdx)
                dU = accumarray(uIdx, uVal, [W*(H+1), 1]);
                obj.uF = obj.uF + dU .* double(obj.uFaceActive);
            end
            if ~isempty(vIdx)
                dV = accumarray(vIdx, vVal, [(W+1)*H, 1]);
                obj.vF = obj.vF + dV .* double(obj.vFaceActive);
            end
        end

        % ================================================================
        % 开口通量与温度汇总
        % ================================================================
        function st = openingFlux(obj, idx, mount)
            % 一组开口格的体积流量与焓流（外向为正），读穿墙外侧 MAC 面；
            % 面温取迎风值：出流取内侧格、入流取外侧格。
            W = obj.GRID.W;
            cell_m = obj.GRID.cell_size_mm / 1000;
            dA    = cell_m * obj.CHASSIS_DEPTH_M;
            rhoCp = obj.AIR_DENSITY * obj.AIR_CP;
            if isempty(idx)
                st = struct('volM3s',0,'heatW',0,'cfm',0,'Tmean',obj.T_amb,'cfmOut',0,'cfmIn',0);
                return;
            end
            yy = mod(idx-1, W) + 1;
            xx = ceil(idx / W);
            switch mount
                case 'top',    fLin = (xx-1)*(W+1) + yy;      sgn = -1; isV = true;  outIdx = idx - 1;
                case 'rear',   fLin = (xx-1)*W + yy;          sgn = -1; isV = false; outIdx = idx - W;
                case 'front',  fLin = xx*W + yy;              sgn = +1; isV = false; outIdx = idx + W;
                case 'bottom', fLin = (xx-1)*(W+1) + yy + 1;  sgn = +1; isV = true;  outIdx = idx + 1;
            end
            if isV, vn = sgn * obj.vF(fLin); else, vn = sgn * obj.uF(fLin); end
            vnPhys = vn * obj.VEL_SCALE;
            Tf = obj.T_fluid(idx);
            inflowF = vnPhys < 0;
            Tf(inflowF) = obj.T_fluid(outIdx(inflowF));
            vol = sum(vnPhys) * dA;
            volOut = sum(max(0, vnPhys)) * dA;
            volIn  = sum(max(0, -vnPhys)) * dA;
            Q = rhoCp * sum((Tf - obj.T_amb) .* vnPhys) * dA;
            Tmean = obj.T_amb;
            if vol > 1e-6
                Tmean = min(max(obj.T_amb + Q/(rhoCp*vol), obj.T_amb), 150);
            end
            st = struct('volM3s',vol,'heatW',Q,'cfm',vol/obj.CFM_TO_M3S,'Tmean',Tmean,...
                        'cfmOut',volOut/obj.CFM_TO_M3S,'cfmIn',volIn/obj.CFM_TO_M3S);
        end

        function flux = computeOpeningFluxes(obj)
            % 各壁面全部开口合计（外向为正）
            mounts = {'top','rear','front','bottom'};
            flux = struct();
            for m = 1:numel(mounts)
                flux.(mounts{m}) = obj.openingFlux(obj.openingIdx.(mounts{m}), mounts{m});
            end
        end

        function list = openingFluxList(obj)
            % 每个开口的通量（与 obj.openings 对齐）
            list = cell(1, numel(obj.openings));
            for k = 1:numel(obj.openings)
                op = obj.openings(k);
                list{k} = obj.openingFlux(op.idx, op.mount);
            end
        end

        function temps = computeAirflowTemperatures(obj)
            % 温度汇总：CFD 口径（界面显示）+ 代数热平衡口径（交叉校验）。
            %   internalAmbient：机箱内部流体均温；topExhaust/rearExhaust：顶/后部机箱风扇
            %   开口的出风混合温度；totalCFM：机箱开口（不含电源风道）的总出风量。
            amb = obj.T_amb;
            fl = obj.openingFluxList();
            outTop = [0 0]; outRear = [0 0]; totalOut = 0;   % [焓流 W, 体积 m³/s]
            for k = 1:numel(obj.openings)
                op = obj.openings(k); st = fl{k};
                if any(strcmp(op.kind, {'psu_intake','psu_exhaust'})), continue; end
                if st.volM3s > 0
                    totalOut = totalOut + st.volM3s;
                    if strcmp(op.mount, 'top'),  outTop  = outTop  + [st.heatW st.volM3s]; end
                    if strcmp(op.mount, 'rear'), outRear = outRear + [st.heatW st.volM3s]; end
                end
            end
            rhoCp = obj.AIR_DENSITY * obj.AIR_CP;
            mixT = @(hv) amb + hv(1) / max(rhoCp * hv(2), eps) * (hv(2) > 1e-6);
            if isempty(obj.insideMask), Tin = amb; else, Tin = mean(obj.T_fluid(obj.insideMask)); end
            temps = struct('intake', amb, 'internalAmbient', Tin, ...
                           'topExhaust', mixT(outTop), 'rearExhaust', mixT(outRear), ...
                           'totalCFM', totalOut / obj.CFM_TO_M3S);
            temps.interiorMeanCFD = Tin;
            temps.internalAmbientCFD = Tin;

            % 代数热平衡：充分混合假设 T = amb + (P_cpu+P_gpu)/(CFM_排·ρcp)，
            % 排风量 = 机箱排气风扇标称风量 × 流量效率 × 实测/自由流量比；电源自带风道不计。
            exhaustCFM = 0;
            for k = 1:numel(obj.fans)
                f = obj.fans{k};
                if strcmp(f.type, 'exhaust')
                    exhaustCFM = exhaustCFM + f.getCFM(obj) * obj.flowEfficiency * f.lastFlowFactor;
                end
            end
            P = 0;
            if obj.hasCpu, P = P + obj.thermalNetworks.cpu.actual_power; end
            if obj.hasGpu, P = P + obj.thermalNetworks.gpu.actual_power; end
            Talg = amb;
            if exhaustCFM > 0.1
                Talg = amb + P / (exhaustCFM * obj.AIR_DENSITY * obj.AIR_CP * obj.CFM_TO_M3S);
            end
            temps.internalAmbientAlg = Talg;
            temps.internalDiscrepancy = Tin - Talg;
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
            obj.accInjectCase = 0;
            obj.accE0 = 0; obj.accE0_case = 0;
        end

        function resetEnergyAccounting(obj)
            % 计账清零（热身后调用），并记录储能基准
            obj.resetAccumulators();
            rhoCpCell = obj.rhoCpCell();
            obj.accE0 = sum(obj.T_fluid(obj.obstacle == 0) - obj.T_amb) * rhoCpCell;
            if ~isempty(obj.insideMask)
                obj.accE0_case = sum(obj.T_fluid(obj.insideMask) - obj.T_amb) * rhoCpCell;
            else
                obj.accE0_case = 0;
            end
        end

        function c = rhoCpCell(obj)
            % 每格空气热容 [J/K]
            cell_m = obj.GRID.cell_size_mm / 1000;
            c = obj.AIR_DENSITY * obj.AIR_CP * cell_m^2 * obj.CHASSIS_DEPTH_M;
        end

        function cons = computeConservationCheck(obj)
            % 能量/质量守恒校核（计量窗口 = 上次 resetEnergyAccounting 以来）。
            % 判据 A（全域逐步计账）：注入 + 平流 + 扩散 + 海绵环重置 + 钳位 − 储能速率 ≈ 0。
            % 判据 B2（机箱内区算子级平衡）：内区注入 + 平流 + 扩散 + 钳位 − 内区储能 ≈ 0。
            % 报告项：开口焓流、定温壁导热、开口平面扩散（采样口径机箱平衡）、远场环与质量账。
            % 壁面/开口导热按求解器扩散算子同一离散：q = ρcp_cell·diffScale·α_face·ΔT。
            flux = obj.computeOpeningFluxes();
            Q_exhaust = flux.top.heatW + flux.rear.heatW + flux.front.heatW + flux.bottom.heatW;
            netVol    = flux.top.volM3s + flux.rear.volM3s + flux.front.volM3s + flux.bottom.volM3s;
            grossVol  = (flux.top.cfmOut + flux.top.cfmIn + flux.rear.cfmOut + flux.rear.cfmIn + ...
                         flux.front.cfmOut + flux.front.cfmIn + flux.bottom.cfmOut + flux.bottom.cfmIn) * obj.CFM_TO_M3S;
            ff = obj.computeFarFieldFlux();
            domainNetVol = netVol + ff.volM3s;
            domainGross  = grossVol + ff.grossM3s;
            domainMassPct = 100 * domainNetVol / max(domainGross, eps);

            Q_injected = 0;
            for f = fieldnames(obj.thermalNetworks)'
                Q_injected = Q_injected + obj.thermalNetworks.(f{1}).actual_power;
            end
            Q_gaussian = Q_injected;

            alphaMol = obj.AIR.nu / obj.AIR.Pr;
            if isprop(obj, 'lastAlphaField') && ~isempty(obj.lastAlphaField)
                alphaFieldVec = obj.lastAlphaField(:);
            else
                alphaFieldVec = alphaMol * ones(obj.GRID.TOTAL, 1);
            end
            rhoCpCell = obj.rhoCpCell();
            W = obj.GRID.W; H = obj.GRID.H;
            Tmat   = reshape(obj.T_fluid, W, H);
            fluidM = reshape(obj.obstacle == 0, W, H);
            kFace = reshape(rhoCpCell * obj.diffScale * 0.5*(alphaFieldVec + alphaMol), W, H);

            % 定温壁导热（流体 → 壁，逐面 ΔT）
            DM = false(W, H); DM(obj.dirichletIdx) = true;
            TwM = zeros(W, H); TwM(obj.dirichletIdx) = obj.dirichletT;
            Qw = zeros(W, H);
            Qw(2:W,:)   = Qw(2:W,:)   + DM(1:W-1,:) .* (Tmat(2:W,:)   - TwM(1:W-1,:));
            Qw(1:W-1,:) = Qw(1:W-1,:) + DM(2:W,:)   .* (Tmat(1:W-1,:) - TwM(2:W,:));
            Qw(:,2:H)   = Qw(:,2:H)   + DM(:,1:H-1) .* (Tmat(:,2:H)   - TwM(:,1:H-1));
            Qw(:,1:H-1) = Qw(:,1:H-1) + DM(:,2:H)   .* (Tmat(:,1:H-1) - TwM(:,2:H));
            Q_wall = sum(sum(Qw .* fluidM .* kFace));

            % 开口平面扩散导热（开口两侧皆流体）
            Q_openingDiff = 0;
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
                aFace = 0.5*(alphaFieldVec(idx) + alphaFieldVec(outIdx));
                Q_openingDiff = Q_openingDiff + sum(rhoCpCell * obj.diffScale .* aFace .* ...
                    (obj.T_fluid(idx) - obj.T_fluid(outIdx)));
            end

            % ---- 判据 A ----
            accN = max(obj.accSteps, 1);
            accScale = rhoCpCell / (accN * obj.DT);
            Q_R_advect = obj.accAdvect   * accScale;
            Q_R_diffuse= obj.accDiffuse  * accScale;
            Q_R_out    = obj.accResetOut * accScale;
            Q_R_clamp  = obj.accClamp    * accScale;
            ledgerW   = Q_gaussian + Q_R_advect + Q_R_diffuse + Q_R_out + Q_R_clamp;
            E_now = sum((obj.T_fluid - obj.T_amb) .* double(obj.obstacle == 0)) * rhoCpCell;
            dEdtW = (E_now - obj.accE0) / (accN * obj.DT);
            closureW   = ledgerW - dEdtW;
            closurePct = 100 * closureW / max(Q_injected, eps);

            % ---- 采样口径机箱平衡（报告项）----
            E_case_now = sum(obj.T_fluid(obj.insideMask) - obj.T_amb) * rhoCpCell;
            dEdtCaseW = (E_case_now - obj.accE0_case) / (accN * obj.DT);
            residualCorrW   = Q_exhaust + Q_wall + Q_openingDiff + dEdtCaseW - Q_injected;
            residualCorrPct = 100 * residualCorrW / max(Q_injected, eps);

            % ---- 判据 B2 ----
            Q_injectCase  = obj.accInjectCase  * accScale;
            Q_advectCase  = obj.accAdvectCase  * accScale;
            Q_diffuseCase = obj.accDiffuseCase * accScale;
            Q_clampCase   = obj.accClampCase   * accScale;
            balanceOpW   = Q_injectCase + Q_advectCase + Q_diffuseCase + Q_clampCase - dEdtCaseW;
            balanceOpPct = 100 * balanceOpW / max(Q_injected, eps);

            cons = struct('Q_injected',Q_injected,'Q_gaussian',Q_gaussian,...
                'Q_exhaust',Q_exhaust,'Q_wall',Q_wall,'Q_openingDiff',Q_openingDiff,...
                'storageRateCaseW',dEdtCaseW,'residualCorrW',residualCorrW,'residualCorrPct',residualCorrPct,...
                'Q_injectCase',Q_injectCase,'Q_advectCase',Q_advectCase,'Q_diffuseCase',Q_diffuseCase,...
                'Q_clampCase',Q_clampCase,'balanceOpW',balanceOpW,'balanceOpPct',balanceOpPct,...
                'Q_R_advect',Q_R_advect,'Q_R_diffuse',Q_R_diffuse,'Q_R_out',Q_R_out,'Q_R_clamp',Q_R_clamp,...
                'Q_R_clampSolve',obj.accClampSolve*accScale,'Q_R_clampAdvect',obj.accClampAdvect*accScale,...
                'Q_R_clampCap',obj.accClampCap*accScale,'Q_R_clampFloor',obj.accClampFloor*accScale,...
                'ledgerW',ledgerW,'ledgerPct',100*ledgerW/max(Q_injected,eps),...
                'closureW',closureW,'closurePct',closurePct,'storageRateW',dEdtW,...
                'massImbalancePct',100 * netVol / max(grossVol, eps),...
                'farFieldCfm',ff.cfm,'farFieldGrossCfm',ff.grossCfm,'farFieldHeatW',ff.heatW,...
                'domainNetVol',domainNetVol,'domainMassPct',domainMassPct,'flux',flux);
        end

        function ff = computeFarFieldFlux(obj)
            % 远场海绵环界面的净/毛通量与焓流（出域为正，面温取迎风值）
            W = obj.GRID.W; H = obj.GRID.H;
            dA = obj.GRID.cell_size_mm / 1000 * obj.CHASSIS_DEPTH_M;
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
            ff = struct('volM3s', sum(vn) * dA, 'grossM3s', sum(abs(vn)) * dA, ...
                        'cfm', sum(vn) * dA / obj.CFM_TO_M3S, 'grossCfm', sum(abs(vn)) * dA / obj.CFM_TO_M3S, ...
                        'heatW', rhoCp * sum((Tf - obj.T_amb) .* vn) * dA);
        end

        % ================================================================
        % 共轭传热：热网络求结温（环境 = CFD 进风温度，风速 = 散热体内风速），
        % 元件热量注入散热体内的流体
        % ================================================================
        function solveConjugateHeatTransfer(obj)
            [uC, vC] = obj.getCellVelocity();
            speed = sqrt(uC.^2 + vC.^2) * obj.VEL_SCALE;       % m/s
            rhoCpCell = obj.rhoCpCell();
            if obj.hasCpu
                net = obj.thermalNetworks.cpu;
                obj.solveComponent(net, obj.cpuInletIdx, obj.cpuFinIdx, speed, rhoCpCell);
                obj.T_solid(obj.rectCells(obj.CPU_HEATSINK.base)) = net.T_junction;
                obj.T_solid(obj.cpuFinIdx) = net.T_sink_base;
            end
            if obj.hasGpu
                net = obj.thermalNetworks.gpu;
                obj.solveComponent(net, obj.gpuInletIdx, obj.gpuFinIdx, speed, rhoCpCell);
                obj.T_solid(obj.rectCells(obj.GPU_HEATSINK.pcb)) = net.T_junction;
                obj.T_solid(obj.gpuFinIdx) = net.T_sink_base;
            end
            if obj.hasPsu
                net = obj.thermalNetworks.psu;
                obj.solveComponent(net, obj.psuInletIdx, obj.psuInteriorIdx, speed, rhoCpCell);
                obj.T_solid(obj.rectCells(obj.PSU2D.body)) = net.T_junction;
            end
        end

        function solveComponent(obj, net, inletIdx, bodyIdx, speed, rhoCpCell)
            % 单元件：进风均温为环境，散热体内平均风速定 h；按对流拾取权重注热
            %   w = 0.25 + 0.75·min(1, V/1.5)：热优先进入运动流体（鳍片强制对流）
            Tamb = mean(obj.T_fluid(inletIdx));
            V = mean(speed(bodyIdx));
            net.solve(V, Tamb, obj.DT);
            w = 0.25 + 0.75 * min(1, speed(bodyIdx) / 1.5);
            dT = net.actual_power * (w / sum(w)) * obj.DT / rhoCpCell;
            obj.T_fluid(bodyIdx) = obj.T_fluid(bodyIdx) + dT;
            inCase = ismember(bodyIdx, obj.insideMask);
            obj.accInjectCase = obj.accInjectCase + sum(dT(inCase));
        end

        % ================================================================
        % 诊断、推进、评分
        % ================================================================
        function vort = computeVorticity(obj)
            % 涡量 [1/s]（格心中心差分）
            W = obj.GRID.W; H = obj.GRID.H;
            [uC, vC] = obj.getCellVelocity();
            umat = reshape(uC, W, H) * obj.VEL_SCALE;
            vmat = reshape(vC, W, H) * obj.VEL_SCALE;
            invDx = 1 / (obj.GRID.cell_size_mm / 1000);
            vortMat = zeros(W, H);
            dvdx = 0.5*(vmat(2:W-1,3:H) - vmat(2:W-1,1:H-2)) * invDx;
            dudy = 0.5*(umat(3:W,2:H-1) - umat(1:W-2,2:H-1)) * invDx;
            vortMat(2:W-1,2:H-1) = dvdx - dudy;
            vortMat(reshape(obj.obstacle, W, H) > 0) = 0;
            vort = vortMat(:);
        end

        function diag = calculateCFDDiagnostics(obj)
            % 无量纲数诊断（特征长度 = 机箱边长，特征温差 = 最热元件 − 环境）
            L = obj.layout.chassis.sizeMm / 1000;
            [uC, vC] = obj.getCellVelocity();
            vel = sqrt(uC.^2 + vC.^2);
            if ~isempty(obj.insideMask), fluidVel = vel(obj.insideMask); else, fluidVel = vel(obj.obstacle == 0); end
            V = mean(fluidVel) * obj.VEL_SCALE;
            deltaT = max(5, obj.sensorTemp('max') - obj.T_amb);
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
                maxDeltaT = max(obj.T_fluid(obj.insideMask)) - obj.T_amb;
            else
                maxDeltaT = max(obj.T_fluid) - obj.T_amb;
            end
            boussinesqValid = maxDeltaT <= 30;
            if ~boussinesqValid
                flowRegime = [flowRegime ' | ⚠ΔT>30K Boussinesq超限'];
            end
            diag = struct('Re',Re,'Gr',Gr,'Ra',Ra,'Nu',Nu,'flowRegime',flowRegime,...
                          'maxDeltaT',maxDeltaT,'boussinesqValid',boussinesqValid);
        end

        function result = stepMultiple(obj, steps)
            % 推进 steps 步并更新诊断（死区、涡量、无量纲数、温度汇总）
            for s = 1:steps
                obj.fluidStep();
            end
            vort = obj.computeVorticity();
            [uC, vC] = obj.getCellVelocity();
            vel = sqrt(uC.^2 + vC.^2) * obj.VEL_SCALE;
            % 死区：机箱内风速 < 0.1 m/s 的滞流区占比
            if ~isempty(obj.insideMask)
                obj.deadZoneRatio = mean(vel(obj.insideMask) < 0.1);
            else
                obj.deadZoneRatio = 0;
            end
            obj.latestVorticity = vort;
            obj.lastDiag  = obj.calculateCFDDiagnostics();
            obj.lastTemps = obj.computeAirflowTemperatures();
            result = struct('deadRatio',obj.deadZoneRatio,'vort',vort,...
                            'diag',obj.lastDiag,'temps',obj.lastTemps);
        end

        function info = runToSteady(obj, opts)
            %RUNTOSTEADY 推进到稳态。每 chunk 步记录一行：各元件结温、机箱内均温、机箱风量。
            %   判据：比较最近两个相邻窗口（各约 window 步）的均值，结温与内温均值变化
            %   < tolT、风量均值相对变化 < tolFlow 即判稳态。窗口均值能滤掉准周期波动
            %   （GPU 结温约 ±0.5°C），也能发现缓慢漂移。
            %   opts 字段（均可缺省）：
            %     minSteps  最少步数，默认 2 s 物理时间（DT = 0.005 s 时 400 步）
            %     maxSteps  最多步数，默认 15 s（3000 步），严格不超过
            %     chunk 50（每块步数）、window 默认 1 s（200 步；实际取 chunk 的整数倍）
            %     tolT 0.3 [°C]、tolFlow 0.03、progressFcn（每块调用 fcn(info)，返回 true 则中止）
            %   返回 info：
            %     steps、converged、aborted、diverged（出现 NaN/Inf 时提前停止）
            %     history  每块一行，列名见 columns（{元件名..., 'interior', 'cfm'}）
            %     final    最近一个窗口的均值（列同 history），稳态结果应取它而不是瞬时值
            %     names    元件名（history 前几列）
            if nargin < 2, opts = struct(); end
            def = struct('minSteps', round(2 / obj.DT), 'maxSteps', round(15 / obj.DT), 'chunk', 50, ...
                         'window', round(1 / obj.DT), 'tolT', 0.3, 'tolFlow', 0.03, 'progressFcn', []);
            fn = fieldnames(def);
            for k = 1:numel(fn)
                if ~isfield(opts, fn{k}), opts.(fn{k}) = def.(fn{k}); end
            end
            nWin = max(1, round(opts.window / opts.chunk));
            names = fieldnames(obj.thermalNetworks)';
            hist = zeros(0, numel(names) + 2);
            info = struct('steps', 0, 'converged', false, 'aborted', false, 'diverged', false, ...
                          'history', hist, 'columns', {[names, {'interior', 'cfm'}]}, ...
                          'final', nan(1, numel(names) + 2), 'names', {names});
            startIter = obj.iteration;
            while obj.iteration - startIter < opts.maxSteps
                n = min(opts.chunk, opts.maxSteps - (obj.iteration - startIter));
                r = obj.stepMultiple(n);
                tj = cellfun(@(nm) obj.thermalNetworks.(nm).T_junction, names);
                row = [tj, r.temps.internalAmbient, r.temps.totalCFM];
                hist(end+1, :) = row; %#ok<AGROW>
                info.steps = obj.iteration - startIter;
                info.history = hist;
                info.final = mean(hist(max(1, end - nWin + 1):end, :), 1);
                if ~all(isfinite(row)) || ~all(isfinite(obj.T_fluid))
                    info.diverged = true;
                    break;
                end
                if size(hist, 1) >= 2 * nWin && info.steps >= opts.minSteps
                    a = mean(hist(end - 2*nWin + 1:end - nWin, :), 1);
                    b = info.final;
                    dT = max(abs(b(1:end-1) - a(1:end-1)));
                    dQ = abs(b(end) - a(end)) / max(b(end), 1);
                    info.converged = dT < opts.tolT && dQ < opts.tolFlow;
                end
                if ~isempty(opts.progressFcn)
                    if opts.progressFcn(info), info.aborted = true; break; end
                end
                if info.converged, break; end
            end
        end

        function tn = netOrIdle(obj, name)
            % 元件热网络；布局中缺该元件时返回环境温度、零功率的占位（评分/诊断用）
            if isfield(obj.thermalNetworks, name)
                tn = obj.thermalNetworks.(name);
            else
                tn = struct('T_junction', obj.T_amb, 'throttling_temp', 95, ...
                            'power', 0, 'actual_power', 0);
            end
        end

        function scores = calculateScores(obj)
            % 六维评分（锚定节流阈）：
            %   散热 25%：CPU ≤60°C / GPU ≤70°C 满分 → 节流阈零分，各占一半
            %   性能 20%：CPU+GPU 实际交付功率/额定，锁 35% 节流时为 0
            %   均衡 10%：CPU/GPU 温差；余量 15%：距节流阈归一化温差
            %   噪音 20%：100 − 3·(dB − 20)；性价比 10%：100 − 机箱风扇总价/15
            temps = obj.computeAirflowTemperatures();
            tnC = obj.netOrIdle('cpu'); tnG = obj.netOrIdle('gpu');
            cpuT = tnC.T_junction; gpuT = tnG.T_junction;
            psuT = obj.junctionOr('psu');
            [noiseDb, ~] = obj.totalNoise();
            totalCFM = 0; totalPrice = 0;
            for k = 1:numel(obj.fans)
                totalCFM = totalCFM + obj.fans{k}.getCFM(obj);
                totalPrice = totalPrice + obj.fans{k}.price;
            end
            cpuCool = max(0, min(100, (tnC.throttling_temp-cpuT)/(tnC.throttling_temp-60)*100));
            gpuCool = max(0, min(100, (tnG.throttling_temp-gpuT)/(tnG.throttling_temp-70)*100));
            cooling = 0.5*cpuCool + 0.5*gpuCool;
            pNom = tnC.power + tnG.power;
            pAct = tnC.actual_power + tnG.actual_power;
            performance = max(0, min(100, (pAct/max(pNom,eps) - 0.65)/0.35*100));
            balance = max(0, 100 - abs(cpuT-gpuT)*2);
            cpuHead = max(0, (tnC.throttling_temp-cpuT)/(tnC.throttling_temp-obj.T_amb));
            gpuHead = max(0, (tnG.throttling_temp-gpuT)/(tnG.throttling_temp-obj.T_amb));
            margin = 100*(0.5*cpuHead + 0.5*gpuHead);
            noise = max(0, min(100, 100 - (noiseDb-20)*3));
            value = max(0, 100 - totalPrice/15);
            totalScore = round(cooling*0.25 + performance*0.20 + balance*0.10 + margin*0.15 + noise*0.20 + value*0.10);
            scores = struct('total',totalScore,'cooling',round(cooling),'performance',round(performance),...
                'balance',round(balance),'margin',round(margin),'noise',round(noise),'value',round(value),...
                'cpuTemp',round(cpuT),'gpuTemp',round(gpuT),'psuTemp',round(psuT),...
                'noiseDb',round(noiseDb),'totalPrice',totalPrice,'totalCFM',round(temps.totalCFM),...
                'intake',temps.intake,'topExhaust',temps.topExhaust,'internalAmbient',temps.internalAmbient,...
                'rearExhaust',temps.rearExhaust);
        end

        function S = scenarioSummary(obj)
            % 方案对比用的汇总指标（当前时刻）。压力状态按机箱风扇当前转速下的
            % 标称自由风量判断：进 > 排 ×1.1 为正压，< ×0.9 为负压，其余为平衡。
            sc = obj.calculateScores();
            t = obj.lastTemps;
            if isempty(t), t = obj.computeAirflowTemperatures(); end
            [db, ~] = obj.totalNoise();
            qin = 0; qout = 0;
            for k = 1:numel(obj.fans)
                f = obj.fans{k};
                if strcmp(f.type, 'intake'), qin = qin + f.getCFM(obj); else, qout = qout + f.getCFM(obj); end
            end
            tj = nan(1, 3); nm = {'cpu', 'gpu', 'psu'};       % 布局中缺的元件为 NaN
            for k = 1:3
                if isfield(obj.thermalNetworks, nm{k}), tj(k) = obj.thermalNetworks.(nm{k}).T_junction; end
            end
            S = struct('cpu', tj(1), 'gpu', tj(2), ...
                'psu', tj(3), 'interior', t.internalAmbient, 'cfm', t.totalCFM, ...
                'noiseDb', db, 'score', sc.total, 'intakeCfm', qin, 'exhaustCfm', qout, ...
                'pressure', fan_pressure_label(qin, qout), 'deadZonePct', 100*obj.deadZoneRatio, ...
                'nCaseFans', numel(obj.fans), 'steps', obj.iteration);
        end

        function P = pressureFieldPa(obj)
            % 相对远场的静压 [Pa]（列向量，障碍格为 NaN）。
            %   投影的速度修正 Δu_grid = −Δp（每格），物理上 Δu = −(DT/ρ)·ΔP/Δx，
            %   故 P = ρ·VEL_SCALE·Δx·p / DT。一步内两次投影的压力相加为总压力
            %   （稳态时第一次投影的压力接近 0）。远场海绵环 p = 0。
            p = obj.p;
            if isprop(obj, 'pProj1') && numel(obj.pProj1) == numel(p)
                p = p + obj.pProj1;
            end
            if isempty(p), p = zeros(obj.GRID.TOTAL, 1); end
            dx = obj.GRID.cell_size_mm / 1000;
            P = p * obj.AIR.rho * obj.VEL_SCALE * dx / obj.DT;
            P(obj.obstacle > 0) = NaN;
        end

        function M = openingMarkers(obj)
            % 各开口的标注位置与净风量（界面用）：x/y 为壁外侧的格坐标，
            % cfm > 0 为流出机箱，mount 为所在壁，kind 为 fan / vent / psu_intake / psu_exhaust
            W = obj.GRID.W;
            fl = obj.openingFluxList();
            M = struct('x', {}, 'y', {}, 'mount', {}, 'kind', {}, 'fan', {}, 'cfm', {});
            off = 3 + obj.fanDiskCells;
            for k = 1:numel(obj.openings)
                op = obj.openings(k);
                if isempty(op.idx), continue; end
                yy = mod(op.idx - 1, W) + 1; xx = ceil(op.idx / W);
                x = mean(xx); y = mean(yy);
                switch op.mount
                    case 'front',  x = max(xx) + off;
                    case 'rear',   x = min(xx) - off;
                    case 'top',    y = min(yy) - off;
                    case 'bottom', y = max(yy) + off;
                end
                M(end+1) = struct('x', x, 'y', y, 'mount', op.mount, 'kind', op.kind, ...
                    'fan', op.fan, 'cfm', fl{k}.cfm); %#ok<AGROW>
            end
        end

        function r = cellReadout(obj, idx)
            % 单格读数（悬停用，只算这一格）：风速 [m/s]、温度 [°C]、静压 [Pa]、是否固体
            W = obj.GRID.W;
            y = mod(idx - 1, W) + 1; x = ceil(idx / W);
            u = 0.5 * (obj.uF((x-1)*W + y) + obj.uF(x*W + y));
            v = 0.5 * (obj.vF((x-1)*(W+1) + y) + obj.vF((x-1)*(W+1) + y + 1));
            p = obj.p(idx);
            if isprop(obj, 'pProj1') && numel(obj.pProj1) == numel(obj.p), p = p + obj.pProj1(idx); end
            r = struct('solid', obj.obstacle(idx) > 0, 'speed', hypot(u, v) * obj.VEL_SCALE, ...
                'T', obj.T_fluid(idx), 'Tsolid', obj.T_solid(idx), ...
                'P', p * obj.AIR.rho * obj.VEL_SCALE * obj.GRID.cell_size_mm / 1000 / obj.DT);
        end

        function list = fanStatusList(obj)
            % 全部风扇的实时状态（界面风扇表用）：名称、转速、实测/自由风量、静压、噪音。
            % 实测风量取当前（投影后）流场穿盘中面的流量；工作点静压 lastDp 由本步施力前
            % 的中间流场求得，后者流量约低 4%，因此工作点图上的点略偏离曲线。
            allF = obj.allFans();
            list = struct('name', {}, 'role', {}, 'rpm', {}, 'cfm', {}, 'freeCfm', {}, 'dp', {}, ...
                          'qRatio', {}, 'noiseDb', {}, 'noise', {}, 'sharePct', {});
            [~, perFan, parts] = obj.totalNoise();
            share = 100 * 10.^(perFan/10) / max(sum(10.^(perFan/10)), eps);
            nGpu = 0;
            mountCN = struct('front', '前', 'rear', '后', 'top', '顶', 'bottom', '底', 'internal', '');
            for k = 1:numel(allF)
                f = allF{k};
                switch f.role
                    case 'case'
                        if strcmp(f.type, 'intake'), ty = '进气'; else, ty = '排气'; end
                        name = sprintf('%s%s %s', mountCN.(f.mount), ty, f.model);
                    case 'cpu', name = 'CPU 塔扇';
                    case 'gpu', nGpu = nGpu + 1; name = sprintf('显卡风扇 %d', nGpu);
                    otherwise,  name = '电源风扇';
                end
                list(end+1) = struct('name', name, 'role', f.role, 'rpm', f.getRPM(obj), ...
                    'cfm', abs(obj.diskFlow(f)) * Fan.CFM_PER_M3S, 'freeCfm', f.getCFM(obj), ...
                    'dp', f.lastDp, 'qRatio', f.noiseQRatio, 'noiseDb', perFan(k), ...
                    'noise', parts(k), 'sharePct', share(k)); %#ok<AGROW>
            end
        end

        function [dbTotal, perFan, parts] = totalNoise(obj)
            % 听音位置总声压级：各风扇（含工作点/格栅/位置修正）能量叠加
            %   L = 10·log10(Σ 10^(Li/10))。parts 为各扇分项（fan_noise_terms）。
            allF = obj.allFans();
            perFan = zeros(1, numel(allF));
            parts = struct('base', {}, 'op', {}, 'grille', {}, 'pos', {}, 'total', {});
            for k = 1:numel(allF)
                [perFan(k), parts(k)] = allF{k}.getNoise(obj); %#ok<AGROW>
            end
            if any(~isfinite(perFan))
                error('CFDSolverBase:noise', '风扇噪音出现非有限值，检查布局 acoustics 参数');
            end
            dbTotal = 10*log10(max(sum(10.^(perFan/10)), 1));
        end

        function recs = getRecommendations(obj)
            scores = obj.calculateScores();
            recs = {};
            tnC = obj.netOrIdle('cpu'); tnG = obj.netOrIdle('gpu');
            if ~obj.hasCpu
                % 布局中无 CPU：不给 CPU 建议
            elseif scores.cpuTemp > tnC.throttling_temp - 5
                recs{end+1} = struct('title','CPU温度过高','desc',sprintf('当前%d°C，接近降频阈值，建议提高 CPU 风扇/机箱排风',scores.cpuTemp),'level','warning');
            elseif scores.cpuTemp < 60
                recs{end+1} = struct('title','CPU散热余量充足','desc',sprintf('当前%d°C，可适当降低风扇转速以减少噪音',scores.cpuTemp),'level','good');
            end
            if ~obj.hasGpu
                % 布局中无显卡：不给 GPU 建议
            elseif scores.gpuTemp > tnG.throttling_temp - 5
                recs{end+1} = struct('title','GPU温度过高','desc',sprintf('当前%d°C，建议改善显卡下方进风或增加机箱排风',scores.gpuTemp),'level','warning');
            elseif scores.gpuTemp < 65
                recs{end+1} = struct('title','GPU散热良好','desc',sprintf('当前%d°C，散热配置合理',scores.gpuTemp),'level','good');
            end
            if isfield(obj.thermalNetworks, 'psu') && obj.thermalNetworks.psu.overTemp
                recs{end+1} = struct('title','电源温度过高','desc',sprintf('当前%d°C，超过告警阈值，检查电源进风',scores.psuTemp),'level','warning');
            end
            if obj.deadZoneRatio > 0.30
                recs{end+1} = struct('title','风道存在滞流死区','desc',sprintf('风速<0.1m/s 区域占比%.1f%%，建议调整风扇位置避免气流短路',obj.deadZoneRatio*100),'level','warning');
            end
            if scores.noiseDb > 40
                recs{end+1} = struct('title','噪音水平偏高','desc',sprintf('当前约%ddB，建议启用自动温控或更换低噪风扇',scores.noiseDb),'level','warning');
            elseif scores.noiseDb < 25
                recs{end+1} = struct('title','运行安静','desc',sprintf('当前约%ddB，噪音控制优秀',scores.noiseDb),'level','good');
            end
            if scores.balance < 70 && obj.hasCpu && obj.hasGpu
                recs{end+1} = struct('title','CPU/GPU温度不均衡','desc','温差较大，建议优化风道使热量均匀排出','level','warning');
            end
            % 主要噪音来源（能量占比超过 40% 的风扇）
            fl = obj.fanStatusList();
            if ~isempty(fl)
                [mx, i] = max([fl.sharePct]);
                if mx > 40
                    p = fl(i).noise;
                    recs{end+1} = struct('title','主要噪音来源','desc',sprintf( ...
                        '%s 占总噪音能量 %.0f%%（%.1f dB：转速 %.1f、工作点 %+.1f、格栅 %+.1f、位置 %+.1f）', ...
                        fl(i).name, mx, p.total, p.base, p.op, p.grille, p.pos),'level','info');
                end
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
