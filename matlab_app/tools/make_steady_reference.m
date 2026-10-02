function ref = make_steady_reference()
%MAKE_STEADY_REFERENCE 生成 test_steady 的参考值（tests/steady_reference.json）：
%   默认场景精确档（280²）固定推进 3000 步，取 1000 步之后的均值与标准差（steady_long_run）。
%   若 tests/reference/steady_default.json 由当前版本生成（同一算例），直接取其统计量；
%   否则重新计算（Octave 约 20–30 分钟）。物理或数值改动后先重新生成标准答案或本参考值。
%   另存预览档自身的回归值 preview（与 test_steady 相同的设置跑 runToSteady，约 2–3 分钟），
%   test_steady 用它做严格回归（0.5°C、2%），弥补"预览档 vs 精确档"容差较宽的不足。
    root = fileparts(fileparts(mfilename('fullpath')));
    fd = fullfile(root, 'tests', 'reference', 'steady_default.json');
    src = '';
    if exist(fd, 'file')
        D = jsondecode(readUtf8(fd));
        if isfield(D, 'mean') && strcmp(D.generator.simulator, pcflow_version())
            m = D.mean; sd = D.std; steps = D.steps; avgFrom = D.avgFrom;
            src = 'tests/reference/steady_default.json';
        end
    end
    if isempty(src)
        t0 = tic;
        S = steady_long_run([], [125 250 450], 1);
        m = cell2struct(num2cell(S.mean), S.columns, 2);
        sd = cell2struct(num2cell(S.std), S.columns, 2);
        steps = S.steps; avgFrom = S.avgFrom;
        src = sprintf('steady_long_run (%.0f s)', toc(t0));
    end
    r2 = @(x) round(100 * x) / 100;
    ref = struct('version', pcflow_version(), 'source', src, 'steps', steps, 'avgFrom', avgFrom, ...
        'tj', r2([m.cpu m.gpu m.psu]), 'tjStd', r2([sd.cpu sd.gpu sd.psu]), ...
        'interior', r2(m.interior), 'cfm', r2(m.cfm), 'cfmStd', r2(sd.cfm));
    % 预览档回归值：同 test_steady 的设置
    s = CFDSolverFEM([], [], [], [], 0.5);
    s.turbUpdateEvery = 2;
    info = s.runToSteady();
    col = @(nm) info.final(strcmp(info.columns, nm));
    ref.preview = struct('steps', info.steps, 'tj', r2([col('cpu') col('gpu') col('psu')]), ...
        'interior', r2(col('interior')), 'cfm', r2(col('cfm')));
    fprintf('预览档 runToSteady %d 步：结温 %.2f/%.2f/%.2f°C，内温 %.2f°C，风量 %.2f CFM\n', ...
        ref.preview.steps, ref.preview.tj, ref.preview.interior, ref.preview.cfm);
    fprintf('精确档 %d 步（%d 步后均值，来源 %s）：结温 %.2f/%.2f/%.2f°C（σ %.2f/%.2f/%.2f），内温 %.2f°C，风量 %.2f CFM（σ %.2f）\n', ...
        steps, avgFrom, src, ref.tj, ref.tjStd, ref.interior, ref.cfm, ref.cfmStd);
    f = fullfile(root, 'tests', 'steady_reference.json');
    fid = fopen(f, 'w');
    fwrite(fid, unicode2native(jsonencode(ref), 'UTF-8'));
    fclose(fid);
    fprintf('已写入 %s\n', f);
end

function txt = readUtf8(f)
    fid = fopen(f, 'r');
    raw = fread(fid, inf, 'uint8=>uint8')';
    fclose(fid);
    txt = native2unicode(raw, 'UTF-8');
end
