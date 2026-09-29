classdef RealFan < handle
    %REALFAN 用户可配置的真实风扇模型
    
    properties (Constant)
        % FAN_DATABASE: 每个型号包含基础参数 + 归一化 P-Q 曲线
        % pq_curve = [P/Pmax at Q/Qmax ∈ {0, 0.2, 0.4, 0.6, 0.8, 1.0}]
        % 数据来源：Noctua、Phanteks、Arctic 官方 datasheet 静压-流量曲线
        % 用于风扇背压修正 thrust_factor = interp1([0..1], pq_curve, Q/Qmax)
        FAN_DATABASE = struct(...
            'NF_A14', struct('size',140,'rpm_min',300,'rpm_max',1500,'cfm_max',82.52,'noise_idle',12,'noise_max',24.6,'price',249,...
                'pmax_pa',20.4,...  % 2.08 mmH2O
                'pq_curve',[1.00 0.91 0.78 0.59 0.34 0.00]),...
            'NF_A12', struct('size',120,'rpm_min',300,'rpm_max',2000,'cfm_max',102,'noise_idle',15,'noise_max',22.6,'price',229,...
                'pmax_pa',22.9,...  % 2.34 mmH2O
                'pq_curve',[1.00 0.93 0.80 0.62 0.36 0.00]),...
            'NF_A9',  struct('size',92,'rpm_min',400,'rpm_max',2500,'cfm_max',46,'noise_idle',14,'noise_max',24,'price',129,...
                'pmax_pa',22.4,...  % 2.28 mmH2O
                'pq_curve',[1.00 0.89 0.74 0.55 0.32 0.00]),...
            'RX140',  struct('size',140,'rpm_min',300,'rpm_max',1700,'cfm_max',95.7,'noise_idle',10,'noise_max',36,'price',219,...
                'pmax_pa',20.0,...  % 近似值，可按 datasheet 更新
                'pq_curve',[1.00 0.95 0.85 0.70 0.45 0.00]),...
            'RX120',  struct('size',120,'rpm_min',400,'rpm_max',2100,'cfm_max',74.2,'noise_idle',10,'noise_max',36,'price',189,...
                'pmax_pa',22.0,...  % 近似值，可按 datasheet 更新
                'pq_curve',[1.00 0.94 0.83 0.67 0.42 0.00]),...
            'P14',    struct('size',140,'rpm_min',200,'rpm_max',1700,'cfm_max',72.8,'noise_idle',12,'noise_max',22.5,'price',68,...
                'pmax_pa',23.5,...  % 2.4 mmH2O
                'pq_curve',[1.00 0.92 0.77 0.57 0.32 0.00]),...
            'P12',    struct('size',120,'rpm_min',200,'rpm_max',1800,'cfm_max',56,'noise_idle',14,'noise_max',26,'price',55,...
                'pmax_pa',21.6,...  % 2.2 mmH2O
                'pq_curve',[1.00 0.92 0.77 0.57 0.32 0.00])...
        )
        PQ_QGRID = [0 0.2 0.4 0.6 0.8 1.0]
    end
    
    properties
        id
        x, y
        type       % 'intake' or 'exhaust'
        model
        mount      % 'front','top','rear','bottom','left','right'
        size
        drawSize
        thickness = 6
        rpm_min
        rpm_max
        cfm_max
        noise_idle
        noise_max
        price
        rpm
        auto = true
        pq_curve   % 6 点归一化 P-Q 曲线
        pmax_pa    % 最大静压 [Pa]（datasheet 近似值）
        gridScale = 1  % 网格细化倍数（getBounds 尺寸缩放用）
        lastFlowFactor = 1  % 上一步 P-Q 背压×格栅折减系数（v2.7：供代数热平衡轨同口径使用）
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
            obj.drawSize = 30; % obj.size==120 ? 30 : 35;
            obj.rpm_min = spec.rpm_min;
            obj.rpm_max = spec.rpm_max;
            obj.cfm_max = spec.cfm_max;
            obj.noise_idle = spec.noise_idle;
            obj.noise_max = spec.noise_max;
            obj.price = spec.price;
            if isfield(spec, 'pq_curve'), obj.pq_curve = spec.pq_curve;
            else, obj.pq_curve = [1.00 0.92 0.77 0.57 0.32 0.00]; end
            if isfield(spec, 'pmax_pa'), obj.pmax_pa = spec.pmax_pa;
            else, obj.pmax_pa = 22; end  % 缺省：120mm 级风扇典型最大静压
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
            if solver.autoFanEnabled
                cpuT = 25; gpuT = 25; psuT = 25;
                if isfield(solver.thermalNetworks, 'cpu'), cpuT = solver.thermalNetworks.cpu.T_junction; end
                if isfield(solver.thermalNetworks, 'gpu'), gpuT = solver.thermalNetworks.gpu.T_junction; end
                if isfield(solver.thermalNetworks, 'psu'), psuT = solver.thermalNetworks.psu.T_junction; end
                maxTemp = max([cpuT, gpuT, psuT]);
                % v3.2.0：连续风扇曲线（锚点同旧 4 档：55/70/80°C→0.2/0.5/0.8，
                % 85°C 起满速）。旧阶梯在阈值处 RPM 跳档 → 代数轨 CFM 跳变 →
                % 后排气温度曲线阶梯式下跌；真实风扇曲线连续，档间线性插值。
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
            % v2.8 风机压升模型（actuator disk）：风扇不再是任意强度的体积力源，
            % 推力由 P-Q 曲线在实测盘流量处取 Δp，扣除格栅系统阻力后，经盘厚
            % 换算为体积加速度 a = Δp_net/(ρ·t_disk)，再按 DT 与 VEL_SCALE
            % 折算成每步网格速度增量。消除 v2.7 及之前的三个任意系数
            % （baseStrength / applyFanForces ×2.0 / flowGain 闭环）。
            
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
                    case {'front','right','left'},  nd = [1; 0];
                    case 'rear',                    nd = [-1; 0];
                    case 'top',                     nd = [0; -1];
                    case 'bottom',                  nd = [0; 1];
                    otherwise,                      nd = [1; 0];
                end
                if strcmp(obj.type, 'intake'), nd = -nd; end
                [uCg, vCg] = solver.getCellVelocity();  % v3.0: 统一读取口
                velNormal = mean(uCg(idx))*nd(1) + mean(vCg(idx))*nd(2);
                % 估算CFM：网格速度→m/s 用统一 VEL_SCALE × 面积 × CFM换算
                areaM2 = pi * (radius * solver.GRID.cell_size_mm / 1000)^2;
                velPhysical = max(0, velNormal) * solver.VEL_SCALE;
                cfmEstimated = velPhysical * areaM2 * 2118.88;

                % v3.0.4：穿壁风扇的 P-Q 工作点流量改读开口面 MAC 净通量
                % （abs(mean)·A_segment）。盘区采样圈覆盖风扇力施加区本身、
                % 读到射流核峰值（实测盘速高估 1.3–3.4×，diag_grille_s1），
                % 开口面采样无此偏置；净流量即不可压连续下的穿越流量。
                % 曾试风扇方向毛流量（max(±vn,0) 口径，与格栅 mean(|v|) 对称）
                % ——实测 P-Q 负反馈过弱、后排开口换向（net −5.6 CFM）、削顶
                % 钳位翻倍（−175.6W）、判据 B2 −40.6% FAIL，退回净流量口径。
                % vnOp 同时供下方格栅 Δp 使用；开口缺失时退回盘区采样。
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
                        areaOpen = numel(vnOp) * cellM * solver.CHASSIS_DEPTH_M;  % 开口段面积 = 面数×格宽×Z深
                        cfmEstimated = abs(mean(vnOp)) * solver.VEL_SCALE * areaOpen * 2118.88;
                    end
                end

                cfmMax = obj.getCFM(solver);
                if cfmMax > 0
                    qRatio = min(1, max(0, cfmEstimated / cfmMax));
                    % P-Q 工作点静压（厂家 datasheet 拟合 + pchip 插值）
                    % v3.2.0：风扇相似定律补齐——Q∝n 已在 getCFM（qRatio 分母），
                    % Δp∝n² 此前缺失：低转速下零流量静压仍取满速 pmax，推力
                    % 系统性虚高。rpmRatio² 缩放后 40% 转速静压降至 ~16%。
                    rpmRatio = obj.getRPM(solver) / obj.rpm_max;
                    dpPQ = obj.pmax_pa * rpmRatio^2 * interp1(obj.PQ_QGRID, obj.pq_curve, qRatio, 'pchip');
                    dpPQ = max(0.0, min(obj.pmax_pa, dpPQ));
                end
                dpNet = dpPQ;

                % 格栅/滤网系统阻力（v2.6）：Δp = ζ·½ρv²，从可用静压中扣除；
                % 仅作用于穿壁风扇
                if isWallMount
                    if strcmp(obj.type, 'intake')
                        zeta = solver.GRILLE_ZETA_INTAKE;   % 前面板+防尘网
                    else
                        zeta = solver.GRILLE_ZETA_EXHAUST;  % 排气格栅
                    end
                    % v3.0.1（S1 复核）：v 改读穿墙开口的 MAC 面速度（真实穿格栅
                    % 速度），替代盘区采样——采样圈 r=30 格覆盖风扇力施加区本身，
                    % 读到射流核峰值（实测 v 高估 1.3–2.7×）。left/right 别名
                    % 映射到 rear/front 开口记录。v3.0.4 起 vnOp 在上方 P-Q 流量
                    % 段统一取好，此处直接复用。
                    if ~isempty(vnOp)
                        % v3.0.2：进气侧改 mean(|vn|)——双向流开口（front 实测
                        % 出16/入57 CFM）下净均值 abs(mean) 把穿格栅速率低估
                        % 约 3 倍（Δp ~1.2 vs ~3.5 Pa）；格栅压损 ζ·½ρv² 逐面
                        % 耗散、方向无关，毛速率才是正确口径。排气侧出流主导，
                        % 维持 abs(mean)（v3.0.2 审计未建议改动）。
                        if strcmp(obj.type, 'intake')
                            vGrille = mean(abs(vnOp)) * solver.VEL_SCALE;  % m/s
                        else
                            vGrille = abs(mean(vnOp)) * solver.VEL_SCALE;  % m/s
                        end
                    else
                        vGrille = velPhysical;  % 开口缺失时退回盘区采样
                    end
                    dpGrille = zeta * 0.5 * solver.AIR_DENSITY * vGrille^2;
                    dpNet = max(0.0, dpPQ - dpGrille);
                end
            end
            
            % Δp_net → 每步网格速度增量：a = Δp/(ρ·t_disk)，Δv = a·DT，
            % Δu_grid = Δv / VEL_SCALE。t_disk = thickness（格）× cell_m。
            rho = solver.AIR_DENSITY;
            tDisk = max(1, obj.thickness) * (solver.GRID.cell_size_mm/1000);
            duGrid = dpNet / (rho * tDisk) * solver.DT / solver.VEL_SCALE;
            % 代数热平衡轨折减口径（v2.8）：实测盘流量相对自由流量的比值，
            % 下限 0.2 防启动暂态把代数轨 CFM 打到 0（稳态值不受影响）
            % v3.0.7：低通滤波（τ≈0.15s，~30 步）——开口净通量逐步噪声大，
            % 未滤波时经 CFM→T_internal/T_rear 代数链放大为排气温曲线
            % ±50°C/步的锯齿（probe_q1q2 实测）。只影响代数轨报告量，
            % 动量轨 P-Q 工作点（dpPQ）仍用瞬时 qRatio，不受影响。
            ffNew = min(1.0, max(0.2, qRatio));
            aFF = min(1, solver.DT / 0.15);
            obj.lastFlowFactor = obj.lastFlowFactor + aFF * (ffNew - obj.lastFlowFactor);
            % dx/dy = 壁面向外法线（排气风扇气流方向）
            % 进气风扇翻转（向内推）；排气风扇不翻转（向外拉）
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
            s = obj.gridScale;
            sz = round(60*s); % default for 120mm
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
