function ref = make_steady_reference()
%MAKE_STEADY_REFERENCE 生成 test_steady 的参考值：默认场景精确档（280²）跑到稳态，
%   取最近一个窗口的均值，写入 tests/steady_reference.json。
%   物理或数值改动后重新运行（Octave 约 5–10 分钟）。
    s = CFDSolverFEM([], [], [], [], 1);
    t0 = tic;
    info = s.runToSteady();
    col = @(nm) info.final(strcmp(info.columns, nm));
    r2 = @(x) round(100 * x) / 100;
    ref = struct('version', pcflow_version(), 'steps', info.steps, 'converged', info.converged, ...
        'tj', r2([col('cpu') col('gpu') col('psu')]), 'interior', r2(col('interior')), 'cfm', r2(col('cfm')));
    fprintf('精确档 %d 步（收敛=%d，%.0f s）：结温 %.2f/%.2f/%.2f°C，内温 %.2f°C，风量 %.2f CFM\n', ...
        info.steps, info.converged, toc(t0), ref.tj, ref.interior, ref.cfm);
    f = fullfile(fileparts(fileparts(mfilename('fullpath'))), 'tests', 'steady_reference.json');
    fid = fopen(f, 'w');
    fwrite(fid, jsonencode(ref));
    fclose(fid);
    fprintf('已写入 %s\n', f);
end
