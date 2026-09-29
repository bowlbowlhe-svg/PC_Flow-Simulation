function T = profile_step(nSteps, gridScale, warmup)
%PROFILE_STEP 单步耗时剖析：先热身 warmup 步，再在 profiler 下推进 nSteps 步，
%   打印耗时最多的函数（自身时间）。MATLAB 与 Octave 通用。
%   用法：profile_step(50, 1, 100)
    if nargin < 1 || isempty(nSteps), nSteps = 50; end
    if nargin < 2 || isempty(gridScale), gridScale = 1; end
    if nargin < 3 || isempty(warmup), warmup = 100; end
    s = CFDSolverFEM([], [], [], [], gridScale);
    for k = 1:warmup, s.fluidStep(); end
    profile clear; profile on;
    t0 = tic;
    for k = 1:nSteps, s.fluidStep(); end
    el = toc(t0);
    profile off;
    info = profile('info');
    ft = info.FunctionTable;
    names = {ft.FunctionName};
    tot = [ft.TotalTime];
    if isfield(ft, 'SelfTime')
        self = [ft.SelfTime];
    else
        self = tot;   % MATLAB 旧版无 SelfTime 时退回总时间
    end
    [~, ord] = sort(self, 'descend');
    fprintf('推进 %d 步（网格 %d²）：%.1f s，%.1f ms/步\n', nSteps, s.GRID.W, el, 1000*el/nSteps);
    fprintf('%-60s %10s %10s\n', '函数', '自身(s)', '总计(s)');
    for k = 1:min(25, numel(ord))
        i = ord(k);
        fprintf('%-60s %10.2f %10.2f\n', names{i}, self(i), tot(i));
    end
    T = struct('msPerStep', 1000*el/nSteps, 'names', {names(ord)}, 'self', self(ord));
end
