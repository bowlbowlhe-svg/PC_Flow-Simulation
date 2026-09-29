classdef BuiltInFan < handle
    %BUILTINFAN 内置风扇：机箱顶排（top）、CPU 塔扇（cpu_tower）、GPU 风扇（gpu_bottom）。
    %   推力模型与 RealFan 相同（P-Q 曲线工作点 + 风扇定律 + 格栅压损，仅顶排穿壁）。

    properties
        id
        x, y              % 挂载点（格坐标）
        type              % 'intake' | 'exhaust'
        mount             % 'top' | 'cpu_tower' | 'gpu_bottom' | 'cpu_down'
        size
        rpm_min
        rpm_max
        cfm_max
        noise_idle
        noise_max
        rpm
        thickness = 6
        gridScale = 1
        pmax_pa = 20      % 最大静压 [Pa]（通用 120mm 级近似）
        lastFlowFactor = 1
        pq_curve = [1.00 0.92 0.79 0.60 0.36 0.00]   % 通用轴流风扇 P-Q 曲线
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
            % 自动模式按 CPU/GPU 最高结温连续插值（曲线同 RealFan，但不含电源温度）；
            % 手动按全局百分比
            if solver.autoFanEnabled
                cpuT = 25; gpuT = 25;
                if isfield(solver.thermalNetworks, 'cpu'), cpuT = solver.thermalNetworks.cpu.T_junction; end
                if isfield(solver.thermalNetworks, 'gpu'), gpuT = solver.thermalNetworks.gpu.T_junction; end
                maxTemp = max(cpuT, gpuT);
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

            qRatio = 0; dpNet = obj.pmax_pa;
            if ~isempty(idx)
                switch obj.mount
                    case {'cpu_down','top'}, nd = [0; -1];
                    case 'gpu_bottom',       nd = [0.8; -0.4];
                    case 'cpu_tower',        nd = [-1; 0];
                    otherwise,               nd = [0; -1];
                end
                if strcmp(obj.type, 'intake'), nd = -nd; end
                [uCg, vCg] = solver.getCellVelocity();
                velNormal = mean(uCg(idx))*nd(1) + mean(vCg(idx))*nd(2);
                velMag = sqrt(sum(nd.^2));
                areaM2 = pi * (radius * solver.GRID.cell_size_mm / 1000)^2;
                velPhysical = max(0, velNormal) * solver.VEL_SCALE / max(velMag, eps);
                cfmEstimated = velPhysical * areaM2 * 2118.88;

                % 顶排穿壁：工作点流量取开口面净通量
                vnOp = [];
                if strcmp(obj.mount, 'top')
                    vnOp = solver.getOpeningFaceVelocity('top', floor(bounds.x), ceil(bounds.x+bounds.w));
                    if ~isempty(vnOp)
                        cellM = solver.GRID.cell_size_mm / 1000;
                        areaOpen = numel(vnOp) * cellM * solver.CHASSIS_DEPTH_M;
                        cfmEstimated = abs(mean(vnOp)) * solver.VEL_SCALE * areaOpen * 2118.88;
                    end
                end

                dpPQ = obj.pmax_pa;
                cfmMax = obj.getCFM(solver);
                if cfmMax > 0
                    qRatio = min(1, max(0, cfmEstimated / cfmMax));
                    rpmRatio = obj.getRPM(solver) / obj.rpm_max;
                    dpPQ = obj.pmax_pa * rpmRatio^2 * interp1(obj.PQ_QGRID, obj.pq_curve, qRatio, 'pchip');
                    dpPQ = max(0.0, min(obj.pmax_pa, dpPQ));
                end
                dpNet = dpPQ;

                if strcmp(obj.mount, 'top')
                    if ~isempty(vnOp)
                        vGrille = abs(mean(vnOp)) * solver.VEL_SCALE;
                    else
                        vGrille = velPhysical;
                    end
                    dpGrille = solver.GRILLE_ZETA_EXHAUST * 0.5 * solver.AIR_DENSITY * vGrille^2;
                    dpNet = max(0.0, dpPQ - dpGrille);
                end
            end

            rho = solver.AIR_DENSITY;
            tDisk = max(1, obj.thickness) * (solver.GRID.cell_size_mm/1000);
            duGrid = dpNet / (rho * tDisk) * solver.DT / solver.VEL_SCALE;
            ffNew = min(1.0, max(0.2, qRatio));
            aFF = min(1, solver.DT / 0.15);
            obj.lastFlowFactor = obj.lastFlowFactor + aFF * (ffNew - obj.lastFlowFactor);
            switch obj.mount
                case {'cpu_down','top'}
                    dx = 0; dy = -1;      % 顶排向上
                case 'gpu_bottom'
                    dx = 0.8; dy = -0.4;  % 向上吹入散热片、略偏向前
                case 'cpu_tower'
                    dx = -1; dy = 0;      % 从右向左（朝后排气）
                otherwise
                    dx = 0; dy = -1;
            end
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
                otherwise   % cpu_tower：覆盖鳍片区的方形
                    bounds = struct('x',obj.x - s/2,'y',obj.y - s/2,'w',s,'h',s);
            end
        end
    end
end
