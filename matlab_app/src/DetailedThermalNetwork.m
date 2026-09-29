classdef DetailedThermalNetwork < handle
    %DETAILEDTHERMALNETWORK 元件热网络（CPU/GPU/PSU）：串联热阻 + 一阶热惯性 + 节流。
    %   CPU/GPU：R_total = R_jc + R_TIM + R_base + R_conv，
    %            R_conv = 1/(h·A·η_overall)，h = 30 + 130·V [W/m²K]，
    %            鳍片效率 η_f = tanh(mL)/(mL)，m = √(2h/(k·t_fin))，k = 200 W/mK。
    %   PSU：    R_total = R_internal + 1/(h·A)，h = 15 + 80·V，A = 0.08 m²。
    %   V 为散热体（鳍片/电源内部）平均风速，T_amb 为进风温度。
    %   结温一阶惯性：C·dTj/dt = P_actual − (Tj − T_amb)/R_total（τ = tau，
    %   为数值平滑取短时间常数，不代表真实热容）。
    %   节流（canThrottle）：无节流理论稳态温度（同 τ 低通滤波）超过节流阈后，
    %         在 5°C 窗口内线性降功率，最多降 35%；不可节流的元件（电源）只置 overTemp。

    properties
        name
        power                 % 名义发热功率 [W]
        actual_power          % 节流后发热功率 [W]
        throttling_ratio = 0
        tjmax
        throttling_temp
        spec                  % 散热器规格（含 .thermal），PSU 为空
        T_junction = 25
        T_case = 25
        T_sink_base = 25
        h_conv = 50           % 最近一次使用的对流系数 [W/m²K]
        tau = 0.25            % 结温惯性时间常数 [s]
        dt = 0.005
        T_theory_f = 25       % 无节流理论稳态温度的滤波值（节流判据）
        canThrottle = true    % false：超温不降功率，只置 overTemp
        overTemp = false
        R_internal = 0.8      % 无散热器规格时（电源）的内部固定热阻 [K/W]
        R_total = 0           % 最近一次的总热阻 [K/W]
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
            % 推进一步：velocity_ambient 为散热器处风速 [m/s]，T_ambient 为环境温度 [°C]
            if nargin < 4 || isempty(dt), dt = obj.dt; end
            effective_velocity = max(0.8, velocity_ambient);
            if ~isempty(obj.spec)
                h = 30 + 130 * min(effective_velocity, 6);
                fin_t_m = max(obj.spec.thermal.fin_thickness_mm, 0.1) / 1000;
                m = sqrt(2 * h / (200 * fin_t_m));
                L_fin = 0.025;
                eta_f = tanh(m * L_fin) / (m * L_fin + 1e-10);
                eta_overall = 1 - (1 - eta_f) * 0.8;
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
                R_total = obj.R_internal + R_conv;
            end
            T_theory = T_ambient + obj.power * R_total;
            alpha = min(1, dt / obj.tau);
            obj.T_theory_f = obj.T_theory_f + alpha * (T_theory - obj.T_theory_f);
            excess = obj.T_theory_f - obj.throttling_temp;
            obj.R_total = R_total;
            obj.overTemp = excess > 0;
            if excess > 0 && obj.canThrottle
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
            obj.h_conv = h;
            result = struct('T_junction',obj.T_junction,'actual_power',obj.actual_power,'throttling_ratio',obj.throttling_ratio);
        end
    end
end
