classdef Fan < handle
    %FAN 风扇（机箱风扇与内置风扇统一模型）。
    %   执行盘（actuator disk）模型：风扇是一块厚 t、宽为风扇直径的薄盘，
    %   盘内流体受均匀体积力 a = Δp/(ρ·t)，穿过盘的静压升恰为 Δp。
    %   Δp 取 P-Q 曲线在实测盘流量处的值，并按风扇定律随转速缩放：
    %     Δp = pmax·(n/n_max)²·f(Q/Q_free)，Q_free = cfm_max·(n/n_max)。
    %   格栅/滤网压损不在此扣除，而是作为开口面上的流动阻力（见 CFDSolverBase），
    %   工作点由风扇曲线与系统阻力自然平衡得到。
    %   2D 口径：盘流量 = 盘中面法向速度 × 盘宽 × 机箱 Z 向深度（体积流量守恒）。

    properties (Constant)
        PQ_QGRID = [0 0.2 0.4 0.6 0.8 1.0]
        CFM_PER_M3S = 2118.88
    end

    properties
        id                 % 标识
        role = 'case'      % 'case' | 'cpu' | 'gpu' | 'psu'
        mount = 'internal' % 机箱风扇：'front' | 'rear' | 'top' | 'bottom'；内置：'internal'
        type = 'exhaust'   % 机箱风扇：'intake' | 'exhaust'
        model
        label
        size
        rpm_min
        rpm_max
        cfm_max
        noise_idle
        noise_max
        pmax_pa
        pq_curve
        price
        speedMode = 'auto' % 'auto'（跟随全局：自动曲线或全局手动）| 'manual'（本扇固定转速）
        manualPct = 60     % speedMode='manual' 时的转速百分比
        sensor = 'max'     % 自动曲线的温度来源：'max'(CPU/GPU 最高) | 'cpu' | 'gpu' | 'psu'
        % ---- 执行盘几何（格坐标，由求解器设置）----
        cols = [1 1]       % 盘占据的格列 [c0 c1]
        rows = [1 1]       % 盘占据的格行 [r0 r1]
        normal = [1 0]     % 送风方向单位向量（x 向右、y 向下）
        thickM = 0.012     % 盘厚 [m]
        % ---- 运行状态 ----
        lastQ = 0          % 实测盘流量 [m³/s]
        lastDp = 0         % 当前静压升 [Pa]
        lastQRatio = 0
        lastFlowFactor = 1 % 实测/自由流量比（低通），代数轨交叉校验用
    end

    methods
        function obj = Fan(cfg)
            cat = fan_catalog();
            sp = cat.(cfg.model);
            obj.model = cfg.model;
            obj.label = sp.label;
            obj.size = sp.size;
            obj.rpm_min = sp.rpm_min;
            obj.rpm_max = sp.rpm_max;
            obj.cfm_max = sp.cfm_max;
            obj.noise_idle = sp.noise_idle;
            obj.noise_max = sp.noise_max;
            obj.pmax_pa = sp.pmax_pa;
            obj.pq_curve = sp.pq_curve;
            obj.price = sp.price;
            flds = {'id','role','mount','type','speedMode','manualPct','sensor'};
            for k = 1:numel(flds)
                if isfield(cfg, flds{k}) && ~isempty(cfg.(flds{k}))
                    obj.(flds{k}) = cfg.(flds{k});
                end
            end
        end

        function f = speedFraction(obj, solver)
            % 转速比例 ∈ [0,1]（相对 rpm_min→rpm_max 区间）
            if strcmp(obj.speedMode, 'manual')
                f = obj.manualPct / 100;
            elseif solver.autoFanEnabled
                % 连续温控曲线：55/70/80°C → 20/50/80%，85°C 满速，最低 20%
                T = solver.sensorTemp(obj.sensor);
                r = interp1([25 55 70 80 85], [0.2 0.2 0.5 0.8 1.0], T, 'linear', 'extrap');
                f = min(1.0, max(0.2, r));
            else
                f = solver.fanSpeedRatio / 100;
            end
            f = min(1, max(0, f));
        end

        function rpm = getRPM(obj, solver)
            rpm = obj.rpm_min + (obj.rpm_max - obj.rpm_min) * obj.speedFraction(solver);
        end

        function cfm = getCFM(obj, solver)
            % 当前转速下的自由送风量（风扇定律 Q ∝ n）
            cfm = obj.cfm_max * (obj.getRPM(solver) / obj.rpm_max);
        end

        function noise = getNoise(obj, solver)
            % 怠速/满速两端点间按转速比三次方插值 [dB(A)]
            f = (obj.getRPM(solver) - obj.rpm_min) / max(obj.rpm_max - obj.rpm_min, eps);
            noise = obj.noise_idle + (obj.noise_max - obj.noise_idle) * f^3;
        end

        function dp = updateOperatingPoint(obj, solver)
            % 实测盘流量 → P-Q 工作点静压 [Pa]；同时更新运行状态。
            % 流量超过自由风量（被其它风扇带动）时按曲线末段斜率外推为负压，
            % 风扇此时是流动阻力而不是"透明"的；倒流时取零流量静压。
            Q = solver.diskFlow(obj);                      % m³/s，送风方向为正
            rpm = obj.getRPM(solver);
            qFree = obj.cfm_max * (rpm / obj.rpm_max) / obj.CFM_PER_M3S;
            qRatio = 0;
            if qFree > 0
                qRatio = min(2, max(0, Q / qFree));
            end
            pq = obj.pq_curve;
            if qRatio <= 1
                f = interp1(obj.PQ_QGRID, pq, qRatio, 'pchip');
            else
                f = pq(end) + (pq(end) - pq(end-1)) / (obj.PQ_QGRID(end) - obj.PQ_QGRID(end-1)) * (qRatio - 1);
            end
            dp = obj.pmax_pa * (rpm / obj.rpm_max)^2 * f;
            dp = max(-obj.pmax_pa, min(obj.pmax_pa, dp));
            obj.lastQ = Q;
            obj.lastDp = dp;
            obj.lastQRatio = qRatio;
            aFF = min(1, solver.DT / 0.15);
            obj.lastFlowFactor = obj.lastFlowFactor + aFF * (min(1, max(0.2, qRatio)) - obj.lastFlowFactor);
        end

        function b = getBounds(obj)
            % 盘的外接矩形（格坐标，绘图用）
            b = struct('x', obj.cols(1), 'y', obj.rows(1), ...
                       'w', obj.cols(2) - obj.cols(1) + 1, 'h', obj.rows(2) - obj.rows(1) + 1);
        end
    end
end
