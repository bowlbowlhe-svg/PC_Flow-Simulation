function R = layout_fan_report(L)
%LAYOUT_FAN_REPORT 机箱风扇布局的静态检查与标称风量（不需要求解器）。
%   R.warnings    cellstr：同壁风扇重叠、超出壁面、与电源重叠
%   R.intakeCfm   进气风扇标称自由风量之和 [CFM]（自动转速的风扇按满速计）
%   R.exhaustCfm  排气风扇标称自由风量之和 [CFM]
%   R.pressure    '正压' | '负压' | '平衡' | '无机箱风扇'（见 fan_pressure_label）
%   R.intakeCfmIdle / R.exhaustCfmIdle / R.pressureIdle：自动转速的风扇按温控下限
%                 （20%）计。各型号转速下限不同，低速与满速时的进/排比例可能不同。
%   R.nIntake / R.nExhaust
%   手动转速的风扇两种口径都按其设定转速。
%   同壁两扇框架重叠 ≤ 15 mm 视为贴装（2D 简化），不报警。
    cat = fan_catalog();
    R = struct('warnings', {{}}, 'intakeCfm', 0, 'exhaustCfm', 0, 'pressure', '', ...
               'intakeCfmIdle', 0, 'exhaustCfmIdle', 0, 'pressureIdle', '', 'nIntake', 0, 'nExhaust', 0);
    if ~isfield(L, 'caseFans') || isempty(L.caseFans)
        R.pressure = fan_pressure_label(0, 0);
        R.pressureIdle = R.pressure;
        return;
    end
    F = L.caseFans;
    size_ = L.chassis.sizeMm;
    wallMm = L.domain.baseCellMm;           % 机箱壁厚约 1 格
    lo = zeros(numel(F), 1); hi = lo;
    mountCN = struct('front', '前', 'rear', '后', 'top', '顶', 'bottom', '底');
    for k = 1:numel(F)
        f = F(k);
        sp = cat.(f.model);
        lo(k) = f.alongMm - sp.size/2; hi(k) = f.alongMm + sp.size/2;
        if lo(k) < wallMm - 0.5 || hi(k) > size_ - wallMm + 0.5
            R.warnings{end+1} = sprintf('%s壁 %s（中心 %g mm）超出壁面，求解时会被夹到壁内', ...
                mountCN.(f.mount), f.model, f.alongMm);
        end
        if isfield(f, 'speedMode') && strcmp(f.speedMode, 'manual')
            frac = f.manualPct / 100 * [1 1];
        else
            frac = [1 0.2];                    % 满速 / 温控下限
        end
        q = sp.cfm_max * (sp.rpm_min + (sp.rpm_max - sp.rpm_min) * frac) / sp.rpm_max;
        if strcmp(f.type, 'intake')
            R.intakeCfm = R.intakeCfm + q(1); R.intakeCfmIdle = R.intakeCfmIdle + q(2);
            R.nIntake = R.nIntake + 1;
        else
            R.exhaustCfm = R.exhaustCfm + q(1); R.exhaustCfmIdle = R.exhaustCfmIdle + q(2);
            R.nExhaust = R.nExhaust + 1;
        end
    end
    % 同壁重叠
    for i = 1:numel(F)
        for j = i+1:numel(F)
            if ~strcmp(F(i).mount, F(j).mount), continue; end
            ov = min(hi(i), hi(j)) - max(lo(i), lo(j));
            if ov > 15
                R.warnings{end+1} = sprintf('%s壁两台风扇重叠 %.0f mm（中心 %g / %g mm）', ...
                    mountCN.(F(i).mount), ov, F(i).alongMm, F(j).alongMm);
            end
        end
    end
    % 与电源重叠（电源贴后壁/底壁）
    if isfield(L, 'psu') && isfield(L.psu, 'body')
        b = L.psu.body;
        for k = 1:numel(F)
            switch F(k).mount
                case 'bottom', ov = min(hi(k), b.x + b.w) - max(lo(k), b.x);
                case 'rear',   ov = min(hi(k), b.y + b.h) - max(lo(k), b.y);
                otherwise,     ov = 0;
            end
            if ov > 0
                R.warnings{end+1} = sprintf('%s壁风扇（中心 %g mm）与电源重叠 %.0f mm', ...
                    mountCN.(F(k).mount), F(k).alongMm, ov);
            end
        end
    end
    R.pressure = fan_pressure_label(R.intakeCfm, R.exhaustCfm);
    R.pressureIdle = fan_pressure_label(R.intakeCfmIdle, R.exhaustCfmIdle);
end
