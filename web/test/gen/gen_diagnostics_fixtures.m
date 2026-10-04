function gen_diagnostics_fixtures(outFile)
%GEN_DIAGNOSTICS_FIXTURES 生成网页版诊断量的对照数据（web/test/fixtures/diagnostics.json）。
%   用法（在 matlab_app 目录下）：
%     OMP_NUM_THREADS=1 octave-cli --no-gui --eval "setup_paths(); addpath('../web/test/gen'); gen_diagnostics_fixtures"
%   算例（均为 140²、湍流逐步更新）：
%     default200  默认布局 125/250/450 W 推进 200 步（同 fixed_default）
%     duct13      直风道基准（无元件）推进 13 步：评分与建议的"缺元件"分支
%     hot120      默认布局 300/500/1200 W 推进 120 步：节流、电源超温告警
%     manual40    默认布局、关闭自动温控、全局 70%、前 1 号机箱风扇手动 30%，推进 40 步
%     steady      默认布局 runToSteady（maxSteps 300、minSteps 100、chunk 25、window 50、tolT 1、tolFlow 0.05）
%     legacy48    v4.8.0 的默认几何（4 槽、PCB 从 38 mm 起、无 ioBlock、全宽电源仓挡板 + 280–318 mm 开孔）推进 100 步
%     cycling40   默认布局办公功率 40/35/200 W 推进 40 步（显卡、电源风扇停转），再把第 1 台显卡风扇与电源风扇设为
%                 窗口内启停 2 次（toggleIter）、最近转动转速 1200 / 900 rpm：时转时停的感知噪音、状态表与建议
%   每个算例记录：温度汇总、无量纲数诊断、死区比、评分、方案汇总、建议、风扇状态表、开口标注、
%   涡量统计与抽样、单格读数、结温。
    if nargin < 1
        here = fileparts(mfilename('fullpath'));
        outFile = fullfile(here, '..', 'fixtures', 'diagnostics.json');
    end
    R = struct();
    R.generator = struct('tool', 'octave', 'version', version(), 'script', 'web/test/gen/gen_diagnostics_fixtures.m');

    s = mk(layout_default(), [125 250 450]);
    s.stepMultiple(200);
    R.default200 = dump(s);

    s = mk(layout_benchmark('duct', 20), [0 0 0]);
    s.stepMultiple(13);
    R.duct13 = dump(s);

    s = mk(layout_default(), [300 500 1200]);
    s.stepMultiple(120);
    R.hot120 = dump(s);

    L = layout_default();
    L.caseFans(1).speedMode = 'manual';
    L.caseFans(1).manualPct = 30;
    s = mk(L, [125 250 450]);
    s.autoFanEnabled = false;
    s.fanSpeedRatio = 70;
    s.stepMultiple(40);
    R.manual40 = dump(s);
    R.manual40.layout = listify(L);

    s = mk(layout_default(), [125 250 450]);
    info = s.runToSteady(struct('maxSteps', 300, 'minSteps', 100, 'chunk', 25, 'window', 50, ...
        'tolT', 1.0, 'tolFlow', 0.05));
    R.steady = struct('steps', info.steps, 'converged', info.converged, 'aborted', info.aborted, ...
        'diverged', info.diverged, 'history', info.history, 'columns', {info.columns}, 'final', info.final);

    L = layout_set_gpu_slots(layout_default(), 4);
    L.gpu = rmfield(L.gpu, 'ioBlock');
    L.gpu.pcb = struct('x', 38, 'y', 212, 'w', 216, 'h', 12);
    L.shroud = rmfield(L.shroud, 'lengthMm');
    L.shroud.gaps = struct('x0Mm', 280, 'x1Mm', 318);
    s = mk(L, [125 250 450]);
    s.stepMultiple(100);
    R.legacy48 = dump(s);

    s = mk(layout_default(), [40 35 200]);
    s.stepMultiple(40);
    gf = s.findFan('gpu'); gf.toggleIter = [s.iteration - 50, s.iteration - 10]; gf.lastRunRpm = 1200;
    pf = s.findFan('psu'); pf.toggleIter = [s.iteration - 30, s.iteration - 5]; pf.lastRunRpm = 900;
    R.cycling40 = dump(s);

    fid = fopen(outFile, 'w');
    fwrite(fid, unicode2native(jsonencode(R), 'UTF-8'));
    fclose(fid);
    fprintf('已写入 %s\n', outFile);
end

function s = mk(L, P)
    s = CFDSolverFEM(P(1), P(2), P(3), L, 0.5);
    s.turbUpdateEvery = 1;
end

function L = listify(L)
    % 列表字段写成 cell，jsonencode 后单元素也是数组
    for f = {'caseFans', 'vents', 'solidBlocks', 'porousBlocks'}
        if isfield(L, f{1}) && isstruct(L.(f{1})), L.(f{1}) = num2cell(L.(f{1})); end
    end
end

function D = dump(s)
    D = struct('iteration', s.iteration);
    nm = fieldnames(s.thermalNetworks);
    for k = 1:numel(nm)
        n = s.thermalNetworks.(nm{k});
        D.(['Tj_' nm{k}]) = n.T_junction;
        D.(['freq_' nm{k}]) = n.freq_ratio;
        D.(['throttled_' nm{k}]) = n.throttled;
        D.(['overTemp_' nm{k}]) = n.overTemp;
    end
    D.temps = s.lastTemps;
    D.diag = s.lastDiag;
    D.deadZoneRatio = s.deadZoneRatio;
    D.scores = s.calculateScores();
    D.summary = s.scenarioSummary();
    recs = s.getRecommendations();
    D.recs = recs;
    fl = s.fanStatusList();
    D.fans = num2cell(fl);
    D.markers = num2cell(s.openingMarkers());
    v = s.latestVorticity;
    D.vortAbsSum = sum(abs(v));
    D.vortMaxAbs = max(abs(v));
    W = s.GRID.W;
    samp = unique(round(linspace(1, numel(v), 97)));
    samp = [samp, (70-1)*W + 70, (40-1)*W + 90];
    D.vortIdx = samp;
    D.vortSamples = v(samp).';
    cells = [(70-1)*W + 70, (40-1)*W + 90, (100-1)*W + 30, 1, s.obsIdx(1)];
    rd = cell(1, numel(cells));
    for k = 1:numel(cells)
        r = s.cellReadout(cells(k));
        r.idx = cells(k);
        rd{k} = r;
    end
    D.readout = rd;
    P = s.pressureFieldPa();
    D.pressureSumFinite = sum(P(isfinite(P)));
end
