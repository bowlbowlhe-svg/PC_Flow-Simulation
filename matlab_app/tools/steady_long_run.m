function R = steady_long_run(L, P, gridScale, opts)
%STEADY_LONG_RUN 固定步数长时推进，取后段的统计量作为"稳态"结果。
%   R = steady_long_run(L, P, gridScale, opts)
%   L 布局（[] = 默认），P = [CPU GPU 电源负载] W，gridScale 网格倍数。
%   opts（可缺省）：steps 总步数（默认 3000 = 15 s）、avgFrom 统计起点步数（默认 1000）、
%                   turbUpdateEvery（默认 1）、progressFcn（每步调用 fcn(info)）。
%   runToSteady 只是"平台检测"：相邻窗口均值足够接近就停，可能停在暂时的平台上（例如 v4.1 的
%   过期算子使 280² 默认布局先停在 GPU 65 °C 的假平台）；对照与比较取长时统计，不受判稳时刻影响。
%   统计按**每步**的瞬时值计算（每 50 步采样会与周期整除 50 的伪振荡混叠，std 显示为 0）。
%   返回：steps、avgFrom、columns、history（每 10 步一行瞬时值，首列为步数）、
%         mean / std / min / max（avgFrom 之后每步值的统计）、solver（推进结束时的求解器）。
    if nargin < 4, opts = struct(); end
    def = struct('steps', 3000, 'avgFrom', 1000, 'turbUpdateEvery', 1, 'progressFcn', []);
    fn = fieldnames(def);
    for k = 1:numel(fn)
        if ~isfield(opts, fn{k}), opts.(fn{k}) = def.(fn{k}); end
    end
    s = CFDSolverFEM(P(1), P(2), P(3), L, gridScale);
    s.turbUpdateEvery = opts.turbUpdateEvery;
    info = s.runToSteady(struct('tolT', -1, 'tolFlow', -1, 'maxSteps', opts.steps, ...
        'chunk', 1, 'progressFcn', opts.progressFcn));
    stepCol = (1:size(info.history, 1))';
    sel = stepCol > opts.avgFrom;
    H = info.history(sel, :);
    keep = mod(stepCol, 10) == 0;
    R = struct('steps', info.steps, 'avgFrom', opts.avgFrom, 'columns', {info.columns}, ...
        'history', [stepCol(keep), info.history(keep, :)], ...
        'mean', mean(H, 1), 'std', std(H, 0, 1), 'min', min(H, [], 1), 'max', max(H, [], 1), ...
        'diverged', info.diverged, 'solver', s);
end
