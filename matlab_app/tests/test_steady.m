function pass = test_steady()
%TEST_STEADY 预览档（140² 网格、湍流隔步更新）跑到稳态，并与精确档参考值对照。
%   参考值：tests/steady_reference.json（tools/make_steady_reference 生成：默认场景
%   280² 网格跑到稳态的窗口均值）。要求：runToSteady 判定收敛；结温偏差 ≤ 2°C；
%   风量偏差 ≤ 8%（v3.8.1 实测：CPU/GPU +0.2/−0.1°C、电源 +1.4°C（电源内部格数少）、风量 +5.5%）。这是回归护栏：物理或数值改动若使预览档明显偏离精确档，
%   会在这里暴露；物理改动后需先重新生成参考值。
    f = fullfile(fileparts(mfilename('fullpath')), 'steady_reference.json');
    ref = jsondecode(fileread(f));
    ref.tj = ref.tj(:)';
    s = CFDSolverFEM([], [], [], [], 0.5);
    s.turbUpdateEvery = 2;
    t0 = tic;
    info = s.runToSteady();
    el = toc(t0);
    col = @(nm) info.final(strcmp(info.columns, nm));
    tj = [col('cpu') col('gpu') col('psu')];
    cfm = col('cfm');
    dTj = tj - ref.tj;
    dQ = (cfm - ref.cfm) / ref.cfm;
    pass = info.converged && all(abs(dTj) <= 2) && abs(dQ) <= 0.08;
    if pass, st = 'PASS'; else, st = 'FAIL'; end
    fprintf(['[steady] 预览档 %d 步收敛=%d（%.0f s）：结温 %.1f/%.1f/%.1f（参考差 %+.1f/%+.1f/%+.1f），' ...
             '风量 %.1f CFM（%+.0f%%）；参考 v%s：%s\n'], info.steps, info.converged, el, tj, dTj, ...
             cfm, 100*dQ, ref.version, st);
end
