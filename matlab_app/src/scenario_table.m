function [rowNames, data] = scenario_table(snaps)
%SCENARIO_TABLE 方案对比表（界面 uitable 用）。
%   snaps：cell 数组，每项为方案快照 struct 或 []（空位显示 "—"）。快照字段：
%     summary（CFDSolverBase.scenarioSummary）、label（布局名）、layout（布局 struct）、
%     powers [cpu gpu psu]、gridScale、steady（是否已判定稳态）。
%   返回行名 cellstr 与 data（行 × 方案，均为字符串）。
    rows = { ...
        'CPU 结温 °C',   @(s) num1(s.summary.cpu); ...
        'GPU 结温 °C',   @(s) num1(s.summary.gpu); ...
        '电源 °C',       @(s) num1(s.summary.psu); ...
        '箱内均温 °C',   @(s) sprintf('%.1f', s.summary.interior); ...
        '机箱风量 CFM',  @(s) sprintf('%.1f', s.summary.cfm); ...
        '标称进/排 CFM', @(s) sprintf('%.0f / %.0f', s.summary.intakeCfm, s.summary.exhaustCfm); ...
        '压力',          @(s) s.summary.pressure; ...
        '噪音 dB(A)',    @(s) sprintf('%.1f', s.summary.noiseDb); ...
        '性能 %',        @(s) sprintf('%.1f', s.summary.perfPct); ...
        '评分（档）',    @(s) sprintf('%d（%s）', s.summary.score, s.summary.scoreCls); ...
        '死区 %',        @(s) sprintf('%.1f', s.summary.deadZonePct); ...
        '机箱风扇数',    @(s) sprintf('%d', s.summary.nCaseFans); ...
        '布局',          @(s) shortLabel(s.label); ...
        '电源仓挡板开孔', @(s) yesNo(hasGap(s.layout)); ...
        '显卡厚度',      @(s) slotsText(s.layout); ...
        'CPU 散热器',    @(s) towerText(s.layout); ...
        '风扇曲线',      @(s) curveText(s.layout); ...
        '功率 C/G/P W',  @(s) sprintf('%g/%g/%g', s.powers(1), s.powers(2), s.powers(3)); ...
        '网格 · 步数',   @(s) sprintf('%s · %d', gridName(s.gridScale), s.summary.steps); ...
        '稳态',          @(s) yesNo(s.steady)};
    rowNames = rows(:, 1);
    data = repmat({'—'}, size(rows, 1), numel(snaps));
    for j = 1:numel(snaps)
        s = snaps{j};
        if isempty(s), continue; end
        for i = 1:size(rows, 1)
            data{i, j} = rows{i, 2}(s);
        end
    end
end

function t = num1(x)
    if isnan(x), t = '—'; else, t = sprintf('%.1f', x); end
end

function t = shortLabel(label)
    % 表格列窄：预设用简称，配置文件取文件名前 8 个字符
    P = fan_presets();
    i = find(strcmp({P.label}, label), 1);
    if ~isempty(i)
        t = P(i).short;
    elseif strncmp(label, '配置 ', 3)
        [~, t] = fileparts(label(4:end));
        t = t(1:min(end, 8));
    else
        t = label;
    end
end

function g = gridName(scale)
    if scale >= 1, g = '精确'; else, g = '预览'; end
end

function t = slotsText(L)
    sl = layout_gpu_slots(L);
    if isnan(sl), t = '—'; else, t = sprintf('%g 槽', sl); end
end

function t = towerText(L)
    % 如"双塔·2 扇"
    if ~isfield(L, 'cpu') || isempty(L.cpu), t = '—'; return; end
    tw = layout_cpu_tower(L);
    if tw.stacks == 2, t = '双塔'; else, t = '单塔'; end
    if tw.fans == 0, t = [t '·无扇']; else, t = sprintf('%s·%d 扇', t, tw.fans); end
end

function t = curveText(L)
    C = layout_fan_curves(L);
    names = struct('quiet', '静音', 'standard', '标准', 'performance', '性能');
    if isfield(names, C.profile), t = names.(C.profile); else, t = '自定义'; end
end

function tf = hasGap(L)
    tf = isfield(L, 'shroud') && isfield(L.shroud, 'gaps') && ~isempty(L.shroud.gaps);
end

function t = yesNo(b)
    if b, t = '是'; else, t = '否'; end
end
