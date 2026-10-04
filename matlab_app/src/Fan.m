classdef Fan < handle
    %FAN 风扇（机箱风扇与内置风扇统一模型）。
    %   执行盘（actuator disk）模型：风扇是一块厚 t、宽为风扇直径的薄盘，
    %   盘内流体受均匀体积力 a = Δp/(ρ·t)，穿过盘的静压升恰为 Δp。
    %   Δp 取 P-Q 曲线在实测盘流量处的值，并按风扇定律随转速缩放：
    %     Δp = pmax·(n/n_max)²·f(Q/Q_free)，Q_free = cfm_max·(n/n_max)。
    %   转速 n = max(rpm_min, duty·rpm_max)，duty 取自按角色区分的温控曲线（fan_curve_profiles）、
    %   本扇固定转速或全局手动转速；显卡风扇低温停转、电源风扇半被动时 n = 0（不施力、不计噪音）。
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
        pos = ''           % CPU 塔扇位置：'front' | 'mid' | 'rear'（其它风扇为空）
        mount = 'internal' % 机箱风扇：'front' | 'rear' | 'top' | 'bottom'；内置：'internal'
        type = 'exhaust'   % 机箱风扇：'intake' | 'exhaust'
        model
        label
        size
        rpm_min
        rpm_max
        cfm_max
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
        noiseQRatio = 1    % 实测/自由流量比（低通 τ = 0.5 s），噪音工作点修正用
        % ---- 噪音修正（由求解器按布局 acoustics 设置）----
        grilleZeta = 0     % 机箱风扇开口的格栅/滤网阻力 ζ（内置风扇为 0）
        positionDb = 0     % 听音位置修正 [dB]（按安装壁或内置位置）
        % ---- 控制状态 ----
        stopped = false    % 低温停转（显卡）/ 半被动停转（电源）中；每步由 updateControl 按回差更新
        toggleIter = zeros(1, 0) % 自动温控下启停切换发生的步号（最近 4 次；时转时停判定用）
        lastRunRpm = 0     % 最近一次转动时的转速（停转期间算"时转时停"的感知噪音用）
        autoResumed = false % 刚从手动 / 关闭自动温控回到自动温控：这一次判定不记切换
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
            obj.noise_max = sp.noise_max;
            obj.pmax_pa = sp.pmax_pa;
            obj.pq_curve = sp.pq_curve;
            obj.price = sp.price;
            flds = {'id','role','pos','mount','type','speedMode','manualPct','sensor'};
            for k = 1:numel(flds)
                if isfield(cfg, flds{k}) && ~isempty(cfg.(flds{k}))
                    obj.(flds{k}) = cfg.(flds{k});
                end
            end
        end

        function d = duty(obj, solver)
            % 转速占空比 ∈ [0,1]（占满速转速的比例）：本扇固定转速 > 自动温控曲线 > 全局手动转速
            if strcmp(obj.speedMode, 'manual')
                d = obj.manualPct / 100;
            elseif solver.autoFanEnabled
                c = solver.fanCurves.(obj.curveKey());
                T = solver.sensorTemp(obj.sensor);
                d = Fan.curveDuty(c, T);
            else
                d = solver.fanSpeedRatio / 100;
            end
            d = min(1, max(0, d));
        end

        function tf = isStopped(obj, solver)
            % 当前是否停转：只在自动温控下、按曲线停转的风扇（显卡低温停转、电源半被动）
            tf = obj.stopped && strcmp(obj.speedMode, 'auto') && solver.autoFanEnabled;
        end

        function updateControl(obj, solver, record)
            % 每步施力前调用一次：按回差更新停转状态
            %   显卡：停转中结温 ≥ startAboveC 才重新转；转动中结温 < stopBelowC 才停
            %   电源：负载率 ≥ passiveLoad 时一直转；否则停转中温度 ≥ passiveRestartC 才转，转动中温度 < passiveMaxC 才停
            %   record（缺省 true）：自动温控下状态改变时记下步号（初始化时的首次判定不记）
            if nargin < 3, record = true; end
            if ~(strcmp(obj.speedMode, 'auto') && solver.autoFanEnabled)
                % 手动时风扇一直转，不算启停；切换记录清空，回到自动温控后的首次判定也不记（那是模式切换，不是时转时停）
                obj.stopped = false;
                obj.toggleIter = zeros(1, 0);
                obj.autoResumed = true;
                return;
            end
            if obj.autoResumed
                record = false;
                obj.autoResumed = false;
            end
            was = obj.stopped;
            c = solver.fanCurves.(obj.curveKey());
            T = solver.sensorTemp(obj.sensor);
            if strcmp(obj.role, 'gpu') && isfield(c, 'stopBelowC') && ~isempty(c.stopBelowC)
                if obj.stopped
                    obj.stopped = T < c.startAboveC;
                else
                    obj.stopped = T < c.stopBelowC;
                end
            elseif strcmp(obj.role, 'psu') && isfield(c, 'passiveLoad') && ~isempty(c.passiveLoad)
                if solver.psuLoadRatio() >= c.passiveLoad
                    obj.stopped = false;
                elseif obj.stopped
                    obj.stopped = T < c.passiveRestartC;
                else
                    obj.stopped = T < c.passiveMaxC;
                end
            else
                obj.stopped = false;
            end
            if record && obj.stopped ~= was
                obj.toggleIter = [obj.toggleIter(max(1, end-2):end), solver.iteration];
            end
        end

        function tf = isCycling(obj, solver)
            % 时转时停：自动温控下、最近 cycleWindowS 秒（仿真时间）内启停切换 ≥ 2 次
            %   （手动转速或关闭自动温控时风扇不会停，不算）
            tf = false;
            if ~(strcmp(obj.speedMode, 'auto') && solver.autoFanEnabled), return; end
            w = round(solver.acoustics.cycleWindowS / solver.DT);
            tf = sum(obj.toggleIter > solver.iteration - w) >= 2;
        end

        function L = ratingNoise(obj, solver)
            % 评分用的感知噪音 [dB(A)]：时转时停的风扇按转动时的声级（停转中取最近一次转动的转速）
            % 加间歇性修正 acoustics.intermittentDb（BS 4142）；其它风扇同 getNoise
            [L, ~] = obj.getNoise(solver);
            if ~obj.isCycling(solver), return; end
            rpm = obj.getRPM(solver);
            if rpm <= 0, rpm = obj.lastRunRpm; end
            if rpm <= 0, return; end
            fin = 0;
            if any(strcmp(obj.role, {'cpu', 'gpu'})), fin = solver.acoustics.finDb; end
            p = fan_noise_terms(obj.noise_max + 50 * log10(rpm / obj.rpm_max), obj.noiseQRatio, obj.grilleZeta, fin, ...
                                obj.positionDb, solver.acoustics);
            L = p.total + solver.acoustics.intermittentDb;
        end

        function k = curveKey(obj)
            % 温控曲线：机箱风扇 'caseFan'，内置风扇按角色 'cpu' / 'gpu' / 'psu'
            if strcmp(obj.role, 'case'), k = 'caseFan'; else, k = obj.role; end
        end

        function rpm = getRPM(obj, solver)
            if obj.isStopped(solver)
                rpm = 0;
            else
                rpm = max(obj.rpm_min, obj.duty(solver) * obj.rpm_max);
            end
        end

        function cfm = getCFM(obj, solver)
            % 当前转速下的自由送风量（风扇定律 Q ∝ n）
            cfm = obj.cfm_max * (obj.getRPM(solver) / obj.rpm_max);
        end

        function noise = baseNoise(obj, solver)
            % 转速主项：风扇定律 L = noise_max + 50·log10(n/n_max) [dB(A)]；停转为 −Inf
            rpm = obj.getRPM(solver);
            if rpm <= 0
                noise = -Inf;
            else
                noise = obj.noise_max + 50 * log10(rpm / obj.rpm_max);
            end
        end

        function [noise, parts] = getNoise(obj, solver)
            % 听音位置的单扇声压级 [dB(A)] = 转速主项 + 工作点 + 格栅 + 鳍片 + 位置（见 fan_noise_terms）；
            % 停转的风扇为 −Inf（不计入总噪音）
            fin = 0;
            if any(strcmp(obj.role, {'cpu', 'gpu'})), fin = solver.acoustics.finDb; end
            parts = fan_noise_terms(obj.baseNoise(solver), obj.noiseQRatio, obj.grilleZeta, fin, ...
                                    obj.positionDb, solver.acoustics);
            noise = parts.total;
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
                f = pchip_eval(obj.PQ_QGRID, pq, qRatio);
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
            if ~obj.isStopped(solver)          % 停转期间保持（重新起转时不出现虚假的"近失速"噪音）
                aN = min(1, solver.DT / 0.5);
                obj.noiseQRatio = obj.noiseQRatio + aN * (qRatio - obj.noiseQRatio);
            end
            if rpm > 0, obj.lastRunRpm = rpm; end
        end

        function b = getBounds(obj)
            % 盘的外接矩形（格坐标，绘图用）
            b = struct('x', obj.cols(1), 'y', obj.rows(1), ...
                       'w', obj.cols(2) - obj.cols(1) + 1, 'h', obj.rows(2) - obj.rows(1) + 1);
        end
    end

    methods (Static)
        function d = curveDuty(c, T)
            % 温控曲线 T → duty：点间线性插值（T 落在 (T_i, T_i+1] 段，t = (T − T_i)/(T_i+1 − T_i)，
            % d = d_i + t·(d_i+1 − d_i)），两端取端点值；温度为 NaN（散热体与进风带都被固体盖住）时取最低占空比
            if ~(T > c.T(1))
                d = c.duty(1);
            elseif T >= c.T(end)
                d = c.duty(end);
            else
                i = find(T <= c.T(2:end), 1);
                t = (T - c.T(i)) / (c.T(i+1) - c.T(i));
                d = c.duty(i) + t * (c.duty(i+1) - c.duty(i));
            end
        end
    end
end
