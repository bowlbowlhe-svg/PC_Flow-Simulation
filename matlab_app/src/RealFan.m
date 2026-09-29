classdef RealFan < handle
    %REALFAN 机箱风扇（挂在机箱壁上）：型号参数、转速控制、噪音与动量源。
    %   推力模型（actuator disk）：在工作点流量处按 P-Q 曲线取静压
    %   Δp = pmax·(n/n_max)²·f(Q/Q_max)，扣除格栅压损 ζ·½ρv²，
    %   经盘厚换算为体积加速度 a = Δp/(ρ·t_disk)，折算成每步网格速度增量。

    properties (Constant)
        % 型号库：基础参数 + 最大静压 + 归一化 P-Q 曲线
        % pq_curve = P/Pmax 在 Q/Qmax = {0, 0.2, 0.4, 0.6, 0.8, 1.0} 处的值
        % （Noctua/Phanteks/Arctic datasheet 读图近似）
        FAN_DATABASE = struct(...
            'NF_A14', struct('size',140,'rpm_min',300,'rpm_max',1500,'cfm_max',82.52,'noise_idle',12,'noise_max',24.6,'price',249,...
                'pmax_pa',20.4,'pq_curve',[1.00 0.91 0.78 0.59 0.34 0.00]),...
            'NF_A12', struct('size',120,'rpm_min',300,'rpm_max',2000,'cfm_max',102,'noise_idle',15,'noise_max',22.6,'price',229,...
                'pmax_pa',22.9,'pq_curve',[1.00 0.93 0.80 0.62 0.36 0.00]),...
            'NF_A9',  struct('size',92,'rpm_min',400,'rpm_max',2500,'cfm_max',46,'noise_idle',14,'noise_max',24,'price',129,...
                'pmax_pa',22.4,'pq_curve',[1.00 0.89 0.74 0.55 0.32 0.00]),...
            'RX140',  struct('size',140,'rpm_min',300,'rpm_max',1700,'cfm_max',95.7,'noise_idle',10,'noise_max',36,'price',219,...
                'pmax_pa',20.0,'pq_curve',[1.00 0.95 0.85 0.70 0.45 0.00]),...
            'RX120',  struct('size',120,'rpm_min',400,'rpm_max',2100,'cfm_max',74.2,'noise_idle',10,'noise_max',36,'price',189,...
                'pmax_pa',22.0,'pq_curve',[1.00 0.94 0.83 0.67 0.42 0.00]),...
            'P14',    struct('size',140,'rpm_min',200,'rpm_max',1700,'cfm_max',72.8,'noise_idle',12,'noise_max',22.5,'price',68,...
                'pmax_pa',23.5,'pq_curve',[1.00 0.92 0.77 0.57 0.32 0.00]),...
            'P12',    struct('size',120,'rpm_min',200,'rpm_max',1800,'cfm_max',56,'noise_idle',14,'noise_max',26,'price',55,...
                'pmax_pa',21.6,'pq_curve',[1.00 0.92 0.77 0.57 0.32 0.00])...
        )
        PQ_QGRID = [0 0.2 0.4 0.6 0.8 1.0]
    end

    properties
        id
        x, y              % 挂载点（格坐标）
        type              % 'intake' | 'exhaust'
        model
        mount             % 'front' | 'top' | 'rear' | 'bottom'
        size
        drawSize = 30
        thickness = 6     % 盘厚 [格]
        rpm_min
        rpm_max
        cfm_max
        noise_idle
        noise_max
        price
        rpm
        pq_curve
        pmax_pa
        gridScale = 1
        lastFlowFactor = 1  % 实测流量/标称流量（低通滤波），代数热平衡轨折减用
    end

    methods
        function obj = RealFan(config)
            obj.id = config.id;
            obj.x = config.x;
            obj.y = config.y;
            obj.type = config.type;
            obj.model = config.model;
            obj.mount = config.mount;
            spec = obj.FAN_DATABASE.(obj.model);
            obj.size = spec.size;
            obj.rpm_min = spec.rpm_min;
            obj.rpm_max = spec.rpm_max;
            obj.cfm_max = spec.cfm_max;
            obj.noise_idle = spec.noise_idle;
            obj.noise_max = spec.noise_max;
            obj.price = spec.price;
            obj.pq_curve = spec.pq_curve;
            obj.pmax_pa = spec.pmax_pa;
            if isfield(config, 'gridScale') && ~isempty(config.gridScale)
                obj.gridScale = config.gridScale;
                obj.thickness = 6 * config.gridScale;
            end
            if isfield(config, 'rpm') && ~isempty(config.rpm)
                obj.rpm = config.rpm;
            else
                obj.rpm = obj.rpm_min + (obj.rpm_max - obj.rpm_min)*0.4;
            end
        end

        function rpm = getRPM(obj, solver)
            % 自动模式：按最高结温连续插值（55/70/80°C → 20/50/80%，85°C 满速）；
            % 手动模式：按全局百分比。
            if solver.autoFanEnabled
                cpuT = 25; gpuT = 25; psuT = 25;
                if isfield(solver.thermalNetworks, 'cpu'), cpuT = solver.thermalNetworks.cpu.T_junction; end
                if isfield(solver.thermalNetworks, 'gpu'), gpuT = solver.thermalNetworks.gpu.T_junction; end
                if isfield(solver.thermalNetworks, 'psu'), psuT = solver.thermalNetworks.psu.T_junction; end
                maxTemp = max([cpuT, gpuT, psuT]);
                r = interp1([25 55 70 80 85], [0.2 0.2 0.5 0.8 1.0], maxTemp, 'linear', 'extrap');
                rpm = obj.rpm_min + (obj.rpm_max - obj.rpm_min)*min(1.0, max(0.2, r));
            else
                rpm = obj.rpm_min + (obj.rpm_max - obj.rpm_min)*(solver.fanSpeedRatio/100);
            end
        end

        function cfm = getCFM(obj, solver)
            % 自由送风量（风扇定律 Q ∝ n）
            cfm = obj.cfm_max * (obj.getRPM(solver)/obj.rpm_max);
        end

        function noise = getNoise(obj, solver)
            % 噪音：怠速/满速两端点间按转速比三次方插值 [dB(A)]
            rpmVal = obj.getRPM(solver);
            rpmRatio = (rpmVal - obj.rpm_min) / max(obj.rpm_max - obj.rpm_min, eps);
            noise = obj.noise_idle + (obj.noise_max - obj.noise_idle)*rpmRatio^3;
        end

        function source = getMomentumSource(obj, solver)
            % 返回每步网格速度增量 (fx, fy)，方向为风扇送风方向。
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
                % 盘区法向平均速度 → 流量估计（开口面数据缺失时的后备口径）
                switch obj.mount
                    case {'front','right','left'},  nd = [1; 0];
                    case 'rear',                    nd = [-1; 0];
                    case 'top',                     nd = [0; -1];
                    case 'bottom',                  nd = [0; 1];
                    otherwise,                      nd = [1; 0];
                end
                if strcmp(obj.type, 'intake'), nd = -nd; end
                [uCg, vCg] = solver.getCellVelocity();
                velNormal = mean(uCg(idx))*nd(1) + mean(vCg(idx))*nd(2);
                areaM2 = pi * (radius * solver.GRID.cell_size_mm / 1000)^2;
                velPhysical = max(0, velNormal) * solver.VEL_SCALE;
                cfmEstimated = velPhysical * areaM2 * 2118.88;

                % 工作点流量优先取开口面净通量（盘区采样会读到射流核峰值）
                isWallMount = any(strcmp(obj.mount, {'front','rear','top','bottom','left','right'}));
                vnOp = [];
                if isWallMount
                    grilleMount = obj.mount;
                    if strcmp(grilleMount,'left'),  grilleMount = 'rear';  end
                    if strcmp(grilleMount,'right'), grilleMount = 'front'; end
                    if any(strcmp(grilleMount, {'top','bottom'}))
                        vnOp = solver.getOpeningFaceVelocity(grilleMount, floor(bounds.x), ceil(bounds.x+bounds.w));
                    else
                        vnOp = solver.getOpeningFaceVelocity(grilleMount, floor(bounds.y), ceil(bounds.y+bounds.h));
                    end
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

                % 格栅/滤网压损（穿壁风扇）：v 取开口面穿格栅速度。
                % 进气侧开口常有双向流，压损逐面耗散、与方向无关，取毛速率 mean(|v|)；
                % 排气侧出流主导，取净速率 |mean(v)|。
                if isWallMount
                    if strcmp(obj.type, 'intake')
                        zeta = solver.GRILLE_ZETA_INTAKE;
                    else
                        zeta = solver.GRILLE_ZETA_EXHAUST;
                    end
                    if ~isempty(vnOp)
                        if strcmp(obj.type, 'intake')
                            vGrille = mean(abs(vnOp)) * solver.VEL_SCALE;
                        else
                            vGrille = abs(mean(vnOp)) * solver.VEL_SCALE;
                        end
                    else
                        vGrille = velPhysical;
                    end
                    dpGrille = zeta * 0.5 * solver.AIR_DENSITY * vGrille^2;
                    dpNet = max(0.0, dpPQ - dpGrille);
                end
            end

            % Δp → 每步网格速度增量：Δu = Δp/(ρ·t_disk)·DT / VEL_SCALE
            rho = solver.AIR_DENSITY;
            tDisk = max(1, obj.thickness) * (solver.GRID.cell_size_mm/1000);
            duGrid = dpNet / (rho * tDisk) * solver.DT / solver.VEL_SCALE;
            % 代数轨流量折减：Q 比低通滤波（τ≈0.15s），下限 0.2 防启动暂态
            ffNew = min(1.0, max(0.2, qRatio));
            aFF = min(1, solver.DT / 0.15);
            obj.lastFlowFactor = obj.lastFlowFactor + aFF * (ffNew - obj.lastFlowFactor);
            % 方向：壁面外法线（排气方向）；进气翻转
            switch obj.mount
                case {'front','right','left'}
                    dx = 1; dy = 0;
                case 'rear'
                    dx = -1; dy = 0;
                case 'top'
                    dx = 0; dy = -1;
                case 'bottom'
                    dx = 0; dy = 1;
                otherwise
                    dx = 1; dy = 0;
            end
            if strcmp(obj.type, 'intake')
                dx = -dx; dy = -dy;
            end
            source = struct('fx',duGrid*dx,'fy',duGrid*dy);
        end

        function bounds = getBounds(obj)
            % 风扇盘外接矩形（格坐标）：沿壁方向为风扇直径，法向为盘厚
            s = obj.gridScale;
            sz = round(60*s);
            if obj.size == 140, sz = round(70*s); end
            if obj.size == 92, sz = round(46*s); end
            switch obj.mount
                case 'top'
                    bounds = struct('x',obj.x - sz/2,'y',obj.y - obj.thickness,'w',sz,'h',obj.thickness);
                case {'right','front'}
                    bounds = struct('x',obj.x - obj.thickness,'y',obj.y - sz/2,'w',obj.thickness,'h',sz);
                case {'rear','left'}
                    bounds = struct('x',obj.x,'y',obj.y - sz/2,'w',obj.thickness,'h',sz);
                case 'bottom'
                    bounds = struct('x',obj.x - sz/2,'y',obj.y,'w',sz,'h',obj.thickness);
                otherwise
                    bounds = struct('x',obj.x - sz/2,'y',obj.y - sz/2,'w',sz,'h',sz);
            end
        end
    end
end
