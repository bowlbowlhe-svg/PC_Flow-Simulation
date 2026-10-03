classdef DetailedThermalNetwork < handle
    %DETAILEDTHERMALNETWORK 元件热网络（CPU/GPU/PSU）：串联热阻 + 一阶热惯性 + 频率与功率控制。
    %   CPU/GPU：R_total = R_jc + R_TIM + R_base + R_conv，
    %            R_conv = 1/(h·A·η_overall)，h = 30 + 130·V [W/m²K]，
    %            鳍片效率 η_f = tanh(mL)/(mL)，m = √(2h/(k·t_fin))，k = 200 W/mK。
    %   PSU：    R_total = R_internal + 1/(h·A)，h = 15 + 80·V，A = 0.08 m²。
    %   V 为散热体（鳍片/电源内部）平均风速（2D 流场按机箱深度折算的体积流量口径），
    %   T_amb 为进风温度。V 不设下限：风扇提速 → V 增大 → h 增大 → 结温下降。
    %   结温一阶惯性：Tj += a·(T_amb + P_actual·R_total − Tj)，a = min(1, dt/τ)（τ 为数值平滑，不代表真实热容）。
    %
    %   频率与功率（CPU/GPU，参数见布局 cpu.dvfs / gpu.dvfs）：频率比 φ（相对最高加速频率）。
    %     功率   P = P_nom·[(1 − λ)·φ^k + λ·2^((min(Tj, tjmax) − T_ref)/T_dbl)]：动态功耗 ∝ φ^k（电压随频率升，k = 3），
    %            漏电功耗占 λ（结温 T_ref 时），结温每升 T_dbl 翻倍；超过 tjmax 后不再增加（真实芯片在此过热保护，
    %            否则无风时漏电与结温正反馈会发散）。P_nom 为界面上设的功率（最高加速、T_ref 时）。
    %     加速   φ_soft = 1 − s·max(0, Tj − T_soft)：结温超过 T_soft 后加速频率逐步下降（每 °C 降 s）。
    %     温度墙 φ_wall：稳态结温恰为降频阈 T_limit 时的频率，
    %            (1 − λ)·φ_wall^k = (T_limit − T_amb)/(P_nom·R_total) − λ·leak(Tj)；右边 ≤ 0 时 φ_wall = 0
    %            （漏电按当前结温计，形成负反馈；稳态时 Tj = T_limit，与按 T_limit 计相同）。
    %     目标   φ_t = clamp(min(φ_soft, φ_wall), φ_min, 1)；φ += a·(φ_t − φ)。throttled = φ_wall < φ_soft（温度墙在起作用）。
    %     过热   overTemp = Tj > tjmax（降到最低频率仍压不住）。
    %   电源不降频：P_actual = 损耗，overTemp = Tj > 告警温度。

    properties
        name
        power                 % 名义发热功率 P_nom [W]（电源为损耗）
        actual_power          % 实际发热功率 [W]
        freq_ratio = 1        % 频率比 φ（CPU/GPU；电源恒为 1）
        throttled = false     % 温度墙在起作用（φ 被压到加速频率以下）
        tjmax
        throttling_temp       % 降频阈（CPU/GPU 的温度墙）；电源为告警温度
        spec                  % 散热器规格（含 .thermal、.dvfs），PSU 为空
        T_junction = 25
        T_case = 25
        T_sink_base = 25
        h_conv = 50           % 最近一次使用的对流系数 [W/m²K]
        tau = 0.25            % 结温惯性时间常数 [s]
        dt = 0.005
        canThrottle = true    % false（电源）：不降频，超温只置 overTemp
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
            % 推进一步：velocity_ambient 为散热器处风速 [m/s]，T_ambient 为进风温度 [°C]
            if nargin < 4 || isempty(dt), dt = obj.dt; end
            effective_velocity = max(0, velocity_ambient);
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
            alpha = min(1, dt / obj.tau);
            obj.R_total = R_total;
            d = [];
            if obj.canThrottle && ~isempty(obj.spec) && isfield(obj.spec, 'dvfs'), d = obj.spec.dvfs; end
            if isempty(d)
                obj.freq_ratio = 1;
                obj.throttled = false;
                obj.actual_power = obj.power;
            else
                lam = d.leakShare; k = d.powerExp;
                leak = @(T) 2^((min(T, obj.tjmax) - d.leakRefC) / d.leakDoubleC);
                phiSoft = 1 - d.softSlope * max(0, obj.T_junction - d.softStartC);
                if obj.power > 0
                    % 漏电按当前结温计：结温越高温度墙把频率压得越低（负反馈）。若按 T_limit 处的漏电计，漏电大、散热差时
                    % （R·P_nom 约 > 120 K）平衡点不稳定，结温会越过降频阈、停在频率高于最低频率的过热状态
                    rhs = (obj.throttling_temp - T_ambient) / (obj.power * R_total) - lam * leak(obj.T_junction);
                    if rhs > 0
                        phiWall = (rhs / (1 - lam))^(1 / k);
                    else
                        phiWall = 0;
                    end
                else
                    phiWall = Inf;
                end
                phiT = min(1, max(d.minFreq, min(phiSoft, phiWall)));
                obj.freq_ratio = obj.freq_ratio + alpha * (phiT - obj.freq_ratio);
                obj.throttled = phiWall < phiSoft;
                obj.actual_power = obj.power * ((1 - lam) * obj.freq_ratio^k + lam * leak(obj.T_junction));
            end
            T_ss = T_ambient + obj.actual_power * R_total;
            obj.T_junction = obj.T_junction + alpha * (T_ss - obj.T_junction);
            if obj.canThrottle
                obj.overTemp = obj.T_junction > obj.tjmax;
            else
                obj.overTemp = obj.T_junction > obj.throttling_temp;
            end
            if ~isempty(obj.spec)
                obj.T_sink_base = obj.T_junction - obj.actual_power * (obj.spec.thermal.R_junction_to_case + obj.spec.thermal.R_tim);
            else
                obj.T_sink_base = obj.T_junction - obj.actual_power * 0.5;
            end
            obj.h_conv = h;
            result = struct('T_junction',obj.T_junction,'actual_power',obj.actual_power,'freq_ratio',obj.freq_ratio);
        end
    end
end
