function p = compare_protocol_default()
%COMPARE_PROTOCOL_DEFAULT 方案对比的默认计算口径（同网页版 web/src/compare/protocol.ts 的 DEFAULT_PROTOCOL）：
%   精确网格 280²、湍流逐步更新；自动温控从静止推进 1600 步，取第 800 步之后的均值；
%   再依次全局手动 40/70/100%，各接续推进 800 步，取第 400 步之后的均值。
    p = struct('gridScale', 1, 'turbUpdateEvery', 1, 'autoSteps', 1600, 'autoAvgFrom', 800, ...
               'sweepPct', [40 70 100], 'sweepSteps', 800, 'sweepAvgFrom', 400);
end
