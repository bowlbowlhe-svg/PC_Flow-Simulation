function d = layout_dvfs(L, name)
%LAYOUT_DVFS CPU/GPU 的频率与功率参数（布局 cpu.dvfs / gpu.dvfs 与默认值合并，缺省字段取默认）。
%   d = layout_dvfs(L, 'cpu' | 'gpu')，字段（见 DetailedThermalNetwork）：
%     softStartC   加速频率开始随温度下降的结温 [°C]（CPU 60、GPU 50）
%     softSlope    此后每 °C 频率下降的比例（0.001 = 0.1%/°C；公开资料里显卡约每 5°C 降一档 ≈ 0.1%/°C）
%     minFreq      温度墙最多压到的频率比（0.5）
%     powerExp     动态功耗 ∝ 频率^powerExp（电压随频率升，3）
%     leakShare    漏电功耗在 leakRefC 时占总功耗的比例（CPU 0.15、GPU 0.10）
%     leakRefC     界面上设定的功率对应的结温 [°C]（70）
%     leakDoubleC  漏电功耗每升高多少 °C 翻倍（25）
%   v4.5 及以前的布局没有 dvfs 字段，按默认值。取值不合法时报错。
    def = struct('softStartC', 60, 'softSlope', 0.001, 'minFreq', 0.5, 'powerExp', 3, ...
                 'leakShare', 0.15, 'leakRefC', 70, 'leakDoubleC', 25);
    if strcmp(name, 'gpu')
        def.softStartC = 50; def.leakShare = 0.10;
    end
    d = def;
    if isfield(L, name) && isfield(L.(name), 'dvfs') && ~isempty(L.(name).dvfs)
        if ~isstruct(L.(name).dvfs) || ~isscalar(L.(name).dvfs)
            error('layout_dvfs:field', '%s.dvfs 应为结构体（字段见 layout_dvfs）', name);
        end
        d = struct_merge(def, L.(name).dvfs);
        extra = setdiff(fieldnames(d), fieldnames(def));
        if ~isempty(extra)
            error('layout_dvfs:field', '%s.dvfs 中有未知字段：%s', name, strjoin(extra', ', '));
        end
    end
    num = @(x) isnumeric(x) && isscalar(x) && isfinite(x);
    ok = num(d.softStartC) && num(d.softSlope) && d.softSlope >= 0 && num(d.minFreq) && d.minFreq > 0 && ...
         d.minFreq <= 1 && num(d.powerExp) && d.powerExp >= 1 && num(d.leakShare) && d.leakShare >= 0 && ...
         d.leakShare < 1 && num(d.leakRefC) && num(d.leakDoubleC) && d.leakDoubleC > 0;
    if ~ok
        error('layout_dvfs:value', ['%s.dvfs 取值不合法（softSlope ≥ 0，0 < minFreq ≤ 1，powerExp ≥ 1，' ...
            '0 ≤ leakShare < 1，leakDoubleC > 0，均为有限的数）'], name);
    end
end
