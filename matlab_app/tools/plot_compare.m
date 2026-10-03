function fig = plot_compare(R, scenario, visible)
%PLOT_COMPARE 画 compare_scenarios 的结果（同网页版"方案对比展示"页的主要图）：
%   左上  评分总览：方案 × 场景（色块 + 数字）
%   右上  所选场景各方案的最高结温与噪音（双柱）
%   下    所选场景的"噪音—最高结温"权衡曲线（全局手动转速扫描；空心圆为自动温控），越靠左下越好
%   fig = plot_compare(R)               场景默认 'gaming'（R 里没有时取第一个）
%   fig = plot_compare(R, 'heavy')
%   fig = plot_compare(R, 'heavy', 'off')   不显示窗口（导出或测试用）
    if nargin < 3 || isempty(visible), visible = 'on'; end
    keys = unique({R.scenario}, 'stable');
    if nargin < 2 || isempty(scenario) || ~any(strcmp(keys, scenario))
        if any(strcmp(keys, 'gaming')), scenario = 'gaming'; else, scenario = keys{1}; end
    end
    S = compare_scenario_list();
    P = fan_presets();
    names = unique({R.preset}, 'stable');
    labels = cell(size(names));
    for i = 1:numel(names)
        k = find(strcmp({P.name}, names{i}), 1);
        if isempty(k), labels{i} = names{i}; else, labels{i} = P(k).short; end
    end
    sk = {S.key};
    sk = sk(ismember(sk, keys));
    M = nan(numel(names), numel(sk));
    for i = 1:numel(names)
        for j = 1:numel(sk)
            r = R(strcmp({R.preset}, names{i}) & strcmp({R.scenario}, sk{j}));
            if ~isempty(r), M(i, j) = r(1).auto.score; end
        end
    end
    fig = figure('Name', '方案对比', 'Color', [0.05 0.05 0.08], 'Visible', visible, 'Position', [80 80 1100 760]);
    fg = [0.85 0.85 0.9];

    % 评分总览
    ax1 = subplot(2, 2, 1, 'Parent', fig);
    imagesc(ax1, M, [0 100]);
    colormap(ax1, [linspace(0.55, 0.15, 64)' linspace(0.15, 0.5, 64)' 0.12 * ones(64, 1)]);
    for i = 1:numel(names)
        for j = 1:numel(sk)
            if isfinite(M(i, j)), text(ax1, j, i, sprintf('%d', round(M(i, j))), 'Color', [1 1 1], 'HorizontalAlignment', 'center'); end
        end
    end
    lab = arrayfun(@(s) s.label, S(ismember({S.key}, sk)), 'UniformOutput', false);
    set(ax1, 'XTick', 1:numel(sk), 'XTickLabel', lab, 'YTick', 1:numel(names), 'YTickLabel', labels, ...
        'Color', [0.07 0.07 0.12], 'XColor', fg, 'YColor', fg);
    title(ax1, '评分（各场景按功率分档）', 'Color', fg);

    % 所选场景：最高结温与噪音
    rs = R(strcmp({R.scenario}, scenario));
    tmax = arrayfun(@(r) max([r.auto.cpu r.auto.gpu]), rs);
    db = arrayfun(@(r) r.auto.noiseDb, rs);
    lb = cellfun(@(nm) labels{strcmp(names, nm)}, {rs.preset}, 'UniformOutput', false);
    ax2 = subplot(2, 2, 2, 'Parent', fig);
    Y = [tmax(:) db(:)];
    if size(Y, 1) == 1, Y = [Y; NaN NaN]; end           % 只有一个方案时仍按组画两根柱
    bar(ax2, Y);
    if numel(rs) == 1, set(ax2, 'XLim', [0.5 1.5]); end
    set(ax2, 'XTick', 1:numel(rs), 'XTickLabel', lb, 'Color', [0.07 0.07 0.12], 'XColor', fg, 'YColor', fg);
    legend(ax2, {'最高结温 °C', '噪音 dB(A)'}, 'TextColor', fg, 'Color', [0.1 0.1 0.15], 'Location', 'northoutside', 'Orientation', 'horizontal');
    sl = S(strcmp({S.key}, scenario)).label;
    title(ax2, sprintf('%s场景（自动温控）', sl), 'Color', fg);

    % 权衡曲线
    ax3 = subplot(2, 1, 2, 'Parent', fig);
    hold(ax3, 'on');
    cols = lines(max(numel(rs), 1));
    leg = {};
    if exist('OCTAVE_VERSION', 'builtin'), hs = []; else, hs = gobjects(0); end
    for i = 1:numel(rs)
        sw = rs(i).sweep;
        if isempty(sw), continue; end
        x = cellfun(@(q) q.noiseDb, sw);
        y = cellfun(@(q) max([q.cpu q.gpu]), sw);
        h = plot(ax3, x, y, '-o', 'Color', cols(i, :), 'MarkerFaceColor', cols(i, :), 'LineWidth', 1.5);
        plot(ax3, rs(i).auto.noiseDb, tmax(i), 'o', 'Color', cols(i, :), 'MarkerSize', 9, 'LineWidth', 1.5);
        hs(end+1) = h; %#ok<AGROW>
        leg{end+1} = lb{i}; %#ok<AGROW>
    end
    hold(ax3, 'off');
    set(ax3, 'Color', [0.07 0.07 0.12], 'XColor', fg, 'YColor', fg);
    xlabel(ax3, '噪音 dB(A)', 'Color', fg);
    ylabel(ax3, '最高结温 °C', 'Color', fg);
    if ~isempty(hs), legend(ax3, hs, leg, 'TextColor', fg, 'Color', [0.1 0.1 0.15], 'Location', 'eastoutside'); end
    title(ax3, '同噪音 / 同温度比较：全局手动转速扫描（实心），自动温控（空心）；越靠左下越好', 'Color', fg);
end
