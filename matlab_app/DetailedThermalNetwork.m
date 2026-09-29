classdef DetailedThermalNetwork < handle
    %DETAILEDTHERMALNETWORK 详细热网络模型 (CPU/GPU/PSU)
    
    properties
        name
        power
        actual_power
        throttling_ratio = 0
        tjmax
        throttling_temp
        spec
        T_junction = 25
        T_case = 25
        T_sink_base = 25
        h_conv = 50
        tau = 0.25        % v3.0.7 结温惯性时间常数 [s]（~50 步 @DT=0.005）
        dt = 0.005        % 求解步长 [s]，由 solver 调用时传入覆盖
        T_theory_f = 25   % v3.0.7 无节流理论稳态的滤波值（节流判据用）
    end
    
    methods
        function obj = DetailedThermalNetwork(name, power, tjmax, throttling, spec)
            obj.name = name;
            obj.power = power;
            obj.actual_power = power;
            obj.tjmax = tjmax;
            if nargin < 4 || isempty(throttling)
                obj.throttling_temp = tjmax - 15;
            else
                obj.throttling_temp = throttling;
            end
            obj.spec = spec;
        end
        
        function result = solve(obj, velocity_ambient, T_ambient, dt)
            if nargin < 4 || isempty(dt), dt = obj.dt; end
            effective_velocity = max(0.8, velocity_ambient);
            if ~isempty(obj.spec)
                h = 30 + 130 * min(effective_velocity, 6);
                fin_t_m = max(obj.spec.thermal.fin_thickness_mm, 0.1) / 1000;
                m = sqrt(2 * h / (200 * fin_t_m));
                L_fin = 0.025;
                eta_f = tanh(m * L_fin) / (m * L_fin + 1e-10);
                eta_overall = 1 - (1 - eta_f) * 0.8;
                % 散热片有效面积（鳍片总展开面积 + 底座）
                % CPU 塔式风冷：典型 0.10–0.15 m²（Noctua NH-U12S ~ 0.13）
                % GPU 三风扇散热器：典型 0.45–0.80 m²（参考 RTX 4070/4080 拆解）
                % v2.5 校正：GPU 由 0.25 → 0.50 m² 反映现代 GPU 散热器规模
                % 优先取 spec.A_fin_total_m2（几何派生）；缺省回退到旧硬编码值
                if isfield(obj.spec.thermal, 'A_fin_total_m2') && ~isempty(obj.spec.thermal.A_fin_total_m2)
                    A_total = obj.spec.thermal.A_fin_total_m2;
                elseif strcmp(obj.name, 'cpu')
                    A_total = 0.12;
                else
                    A_total = 0.50;
                end
                R_conv = 1 / max(h * A_total * eta_overall, eps);
                R_total = obj.spec.thermal.R_junction_to_case + obj.spec.thermal.R_tim + ...
                          obj.spec.thermal.R_base + R_conv;
            else
                h = 15 + 80 * min(effective_velocity, 4);
                A_total = 0.08;
                R_conv = 1 / max(h * A_total, eps);
                R_total = 0.8 + R_conv; % PSU internal R (45W×0.96≈68°C < 85°C throttle)
            end
            % v3.0.7 结温热容惯性：Tj 不再代数直达稳态，改一阶积分
            %     C·dTj/dt = P_actual − (Tj−T_ambient)/R_total
            % 物理：封装+散热器有热容，真实结温对功率/风速扰动按分钟级响应。
            % 数值：根治零惯性代数轨的逐步 flip-flop（v3.0.7 探针 probe_q1q2
            % 实测 GPU ±11°C/步交替、PSU 节流比 0↔0.30 逐步扑动，反馈环为
            % 注入热→浮力→采样风速→h→Tj→节流→注入热）。
            % 口径设计：节流判据沿用旧语义（无节流理论温度越阈），但对理论
            % 温度做同时间常数低通滤波打断瞬时反馈环——稳态不动点与
            % v3.0.6 及之前完全一致（不移动稳态基线），仅瞬态曲线变平滑。
            T_theory = T_ambient + obj.power * R_total;   % 无节流理论稳态（瞬时）
            alpha = min(1, dt / obj.tau);
            obj.T_theory_f = obj.T_theory_f + alpha * (T_theory - obj.T_theory_f);
            excess = obj.T_theory_f - obj.throttling_temp;
            if excess > 0
                % 物理节流模型：匹配 Intel TVB / AMD PB2 实测的"陡降悬崖"
                % - 在 throttle_temp 上方 5°C 窗口内，线性降至最大 35% 功率衰减
                % - 超过窗口锁死在 35% 衰减（避免完全停机的非物理行为）
                % 参考：Gamers Nexus 9900X 测量，Tom's Hardware Raptor Lake Fast Throttle
                obj.throttling_ratio = min(0.35, excess / 5 * 0.35);
            else
                obj.throttling_ratio = 0;
            end
            obj.actual_power = obj.power * (1 - obj.throttling_ratio);
            T_ss = T_ambient + obj.actual_power * R_total;
            obj.T_junction = obj.T_junction + alpha * (T_ss - obj.T_junction);
            if ~isempty(obj.spec)
                obj.T_sink_base = obj.T_junction - obj.actual_power * (obj.spec.thermal.R_junction_to_case + obj.spec.thermal.R_tim);
            else
                obj.T_sink_base = obj.T_junction - obj.actual_power * 0.5;
            end
            obj.h_conv = h;  % 报告本分支实际使用的 h（PSU 为 15+80v 公式）
            result = struct('T_junction',obj.T_junction,'actual_power',obj.actual_power,'throttling_ratio',obj.throttling_ratio);
        end
    end
end
