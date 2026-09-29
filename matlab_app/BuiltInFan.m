classdef BuiltInFan < handle
    %BUILTINFAN 内置风扇模型 (CPU AIO / GPU风扇)
    
    properties
        id
        x, y
        type       % 'intake' or 'exhaust'
        mount      % 'top','gpu_bottom','cpu_down'
        size
        rpm_min
        rpm_max
        cfm_max
        noise_idle
        noise_max
        rpm
        thickness = 6
        gridScale = 1   % 网格细化倍数（getBounds 尺寸缩放用）
        pmax_pa = 20    % 最大静压 [Pa]（通用 120mm 级内置风扇近似值）
        lastFlowFactor = 1  % 上一步 P-Q 背压×格栅折减系数（v2.7：供代数热平衡轨同口径使用）
        % 通用 PC 轴流风扇 P-Q 曲线（在 Noctua/Arctic/Phanteks 之间取平均）
        pq_curve = [1.00 0.92 0.79 0.60 0.36 0.00]
    end
    properties (Constant)
        PQ_QGRID = [0 0.2 0.4 0.6 0.8 1.0]
    end
    
    methods
        function obj = BuiltInFan(config)
            obj.id = config.id;
            obj.x = config.x;
            obj.y = config.y;
            obj.type = config.type;
            obj.mount = config.mount;
            obj.size = config.size;
            obj.rpm_min = config.rpm_min;
            obj.rpm_max = config.rpm_max;
            obj.cfm_max = config.cfm_max;
            obj.noise_idle = config.noise_idle;
            obj.noise_max = config.noise_max;
            obj.rpm = obj.rpm_min + (obj.rpm_max - obj.rpm_min)*0.5;
            if isfield(config, 'gridScale') && ~isempty(config.gridScale)
                obj.gridScale = config.gridScale;
                obj.thickness = 6 * config.gridScale;
            end
        end
        
        function rpm = getRPM(obj, solver)
            if solver.autoFanEnabled
                cpuT = 25; gpuT = 25;
                if isfield(solver.thermalNetworks, 'cpu'), cpuT = solver.thermalNetworks.cpu.T_junction; end
                if isfield(solver.thermalNetworks, 'gpu'), gpuT = solver.thermalNetworks.gpu.T_junction; end
                maxTemp = max(cpuT, gpuT);
                % v3.2.0：连续风扇曲线（同 RealFan，锚点不变、档间线性）——
                % 旧 4 档阶梯在阈值处 RPM 跳变，后排气温度曲线呈阶梯式下跌。
                r = interp1([25 55 70 80 85], [0.2 0.2 0.5 0.8 1.0], maxTemp, 'linear', 'extrap');
                rpm = obj.rpm_min + (obj.rpm_max - obj.rpm_min)*min(1.0, max(0.2, r));
            else
                rpm = obj.rpm_min + (obj.rpm_max - obj.rpm_min)*(solver.fanSpeedRatio/100);
            end
        end
        
        function cfm = getCFM(obj, solver)
            cfm = obj.cfm_max * (obj.getRPM(solver)/obj.rpm_max);
        end
        
        function noise = getNoise(obj, solver)
            rpmVal = obj.getRPM(solver);
            rpmRatio = (rpmVal - obj.rpm_min) / max(obj.rpm_max - obj.rpm_min, eps);
            noise = obj.noise_idle + (obj.noise_max - obj.noise_idle)*rpmRatio^3;
        end
        
        function source = getMomentumSource(obj, solver)
            % v2.8 风机压升模型（actuator disk，同 RealFan）：P-Q 曲线在实测
            % 盘流量处取 Δp，扣除格栅阻力后经盘厚换算为每步网格速度增量。
            
            % 盘区法向速度采样（cell-centered 均值）→ 实测盘流量
            bounds = obj.getBounds();
            W = solver.GRID.W; H = solver.GRID.H;
            cx = bounds.x + bounds.w/2;
            cy = bounds.y + bounds.h/2;
            radius = max(bounds.w, bounds.h)/2;
            r = ceil(radius);
            iRange = max(2, floor(cx)-r) : min(W-1, floor(cx)+r);
            jRange = max(2, floor(cy)-r) : min(H-1, floor(cy)+r);
            [II, JJ] = ndgrid(iRange, jRange);
            dist = sqrt((II-cx).^2 + (JJ-cy).^2);
            inCircle = dist <= radius;
            II = II(inCircle); JJ = JJ(inCircle);
            idx = (II-1)*W + JJ;
            free = solver.obstacle(idx) == 0;
            idx = idx(free);
            
            qRatio = 0; dpPQ = obj.pmax_pa; dpNet = obj.pmax_pa;
            if ~isempty(idx)
                switch obj.mount
                    case {'cpu_down','top'}, nd = [0; -1];
                    case 'gpu_bottom',       nd = [0.8; -0.4];
                    case 'cpu_tower',        nd = [-1; 0];
                    otherwise,               nd = [0; -1];
                end
                if strcmp(obj.type, 'intake'), nd = -nd; end
                [uCg, vCg] = solver.getCellVelocity();  % v3.0: 统一读取口
                velNormal = mean(uCg(idx))*nd(1) + mean(vCg(idx))*nd(2);
                velMag = sqrt(sum(nd.^2));
                areaM2 = pi * (radius * solver.GRID.cell_size_mm / 1000)^2;
                velPhysical = max(0, velNormal) * solver.VEL_SCALE / max(velMag, eps);
                cfmEstimated = velPhysical * areaM2 * 2118.88;

                % v3.0.4：穿壁的顶排风扇 P-Q 工作点流量改读开口面 MAC 净通量
                % （无偏；盘区采样覆盖力施加区、读射流核峰值，实测高估 ~3.4×）。
                % 净流量口径（曾试风扇方向毛流量，B2 FAIL 退回，理由见
                % RealFan 同段注释）。cpu_tower/gpu_bottom/cpu_down 不直接
                % 穿壁、无对应开口记录，保持盘区采样。vnOp 同时供下方格栅
                % Δp 复用。
                vnOp = [];
                if strcmp(obj.mount, 'top')
                    vnOp = solver.getOpeningFaceVelocity('top', floor(bounds.x), ceil(bounds.x+bounds.w));
                    if ~isempty(vnOp)
                        cellM = solver.GRID.cell_size_mm / 1000;
                        areaOpen = numel(vnOp) * cellM * solver.CHASSIS_DEPTH_M;
                        cfmEstimated = abs(mean(vnOp)) * solver.VEL_SCALE * areaOpen * 2118.88;
                    end
                end

                cfmMax = obj.getCFM(solver);
                if cfmMax > 0
                    qRatio = min(1, max(0, cfmEstimated / cfmMax));
                    % v3.2.0：风扇相似定律 Δp∝n²（同 RealFan，Q∝n 已在 getCFM）
                    rpmRatio = obj.getRPM(solver) / obj.rpm_max;
                    dpPQ = obj.pmax_pa * rpmRatio^2 * interp1(obj.PQ_QGRID, obj.pq_curve, qRatio, 'pchip');
                    dpPQ = max(0.0, min(obj.pmax_pa, dpPQ));
                end
                dpNet = dpPQ;

                % 格栅阻力（v2.6）：Δp = ζ·½ρv² 从可用静压扣除；仅穿壁的内置顶排风扇
                if strcmp(obj.mount, 'top')
                    % v3.0.1（S1 复核）：v 改读穿墙开口的 MAC 面速度——即真实
                    % 穿格栅速度。盘区采样圈（r=30 格）覆盖风扇力施加区本身，
                    % 读到射流核峰值（实测 v 高估 ~3.4×）；v2.6.1 曾用格心开口
                    % 采样、v2.8 因外围真实化删除特例，MAC 面场给出无偏穿越
                    % 通量后特例以更严格形式回归。v3.0.4 起 vnOp 在上方 P-Q
                    % 流量段统一取好，此处直接复用。
                    if ~isempty(vnOp)
                        vGrille = abs(mean(vnOp)) * solver.VEL_SCALE;  % m/s
                    else
                        vGrille = velPhysical;  % 开口缺失时退回盘区采样
                    end
                    dpGrille = solver.GRILLE_ZETA_EXHAUST * 0.5 * solver.AIR_DENSITY * vGrille^2;
                    dpNet = max(0.0, dpPQ - dpGrille);
                end
            end
            
            % Δp_net → 每步网格速度增量（同 RealFan：a = Δp/(ρ·t_disk)·DT/VEL_SCALE）
            rho = solver.AIR_DENSITY;
            tDisk = max(1, obj.thickness) * (solver.GRID.cell_size_mm/1000);
            duGrid = dpNet / (rho * tDisk) * solver.DT / solver.VEL_SCALE;
            % v3.0.7：低通滤波（τ≈0.15s），同 RealFan——开口/盘区通量逐步
            % 噪声经代数热平衡链放大为排气温锯齿；仅影响代数轨报告量。
            ffNew = min(1.0, max(0.2, qRatio));
            aFF = min(1, solver.DT / 0.15);
            obj.lastFlowFactor = obj.lastFlowFactor + aFF * (ffNew - obj.lastFlowFactor);
            % dx/dy = 排气方向（向外法线）；进气风扇翻转
            switch obj.mount
                case {'cpu_down','top'}
                    dx = 0; dy = -1;      % 顶排向外 = 向上（负 v）
                case 'gpu_bottom'
                    dx = 0.8; dy = -0.4;  % GPU：向上穿散热片为主，略向右（下方统一归一化）
                case 'cpu_tower'
                    dx = -1; dy = 0;      % 塔式风冷：从右向左（朝向后置排气）
                otherwise
                    dx = 0; dy = -1;
            end
            % 方向向量归一化（修正 gpu_bottom (0.8,-0.4) 模长 0.894 导致的推力缩水）
            ndNorm = hypot(dx, dy);
            if ndNorm > 0
                dx = dx / ndNorm; dy = dy / ndNorm;
            end
            if strcmp(obj.type, 'intake')
                dx = -dx; dy = -dy;
            end
            source = struct('fx',duGrid*dx,'fy',duGrid*dy);
        end
        
        function bounds = getBounds(obj)
            gs = obj.gridScale;
            if strcmp(obj.mount, 'gpu_bottom')
                s = round(46*gs);
            elseif strcmp(obj.mount, 'cpu_down')
                s = round(46*gs);
            elseif strcmp(obj.mount, 'cpu_tower')
                s = round(60*gs);  % 覆盖CPU鳍片区域（120mm风扇 → 60格 = 120mm）
            else
                s = round(60*gs);
            end
            switch obj.mount
                case 'cpu_down'
                    bounds = struct('x',obj.x - s/2,'y',obj.y - s/2,'w',s,'h',s);
                case 'top'
                    bounds = struct('x',obj.x - s/2,'y',max(1, obj.y - obj.thickness),'w',s,'h',obj.thickness);
                case 'gpu_bottom'
                    bounds = struct('x',obj.x - s/2,'y',obj.y - round(8*gs),'w',s,'h',round(16*gs));
                case 'cpu_tower'
                    % 覆盖整个CPU鳍片区域（方形），中心为风扇挂载点
                    bounds = struct('x',obj.x - s/2,'y',obj.y - s/2,'w',s,'h',s);
                otherwise
                    bounds = struct('x',obj.x - s/2,'y',obj.y - s/2,'w',s,'h',s);
            end
        end
    end
end
