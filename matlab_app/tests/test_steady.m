function pass = test_steady()
%TEST_STEADY 预览档（140² 网格、湍流隔步更新）跑到稳态，并与精确档参考值对照。
%   参考值：tests/steady_reference.json（tools/make_steady_reference 生成：默认场景 280² 固定推进
%   3000 步、取 1000 步之后的长时均值）。要求：runToSteady 判定收敛；CPU/电源结温偏差 ≤ 2°C、GPU ≤ 3°C；
%   风量偏差 ≤ 8%。GPU 放宽：v4.3 的紧凑机箱里显卡散热片后端到后壁的通道（26 mm）与显卡风扇下方的进风间隙
%   （21 mm）在预览网格上只有 5–6 格，预览档 GPU 偏高约 2.4°C（长时均值；runToSteady 约 2.2°C）。
%   另与参考文件里的预览档回归值 preview 比较（同样设置的 runToSteady）：结温 ≤ 0.5°C、风量 ≤ 2%。
%   实测见 README 的验证表。这是回归护栏：物理或数值改动若使预览档明显偏离精确档，会在这里暴露；
%   物理改动后需先重新生成参考值。
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
    pass = info.converged && all(abs(dTj) <= [2 3 2]) && abs(dQ) <= 0.08;
    reg = '';
    if isfield(ref, 'preview')
        pv = ref.preview; pv.tj = pv.tj(:)';
        dTp = tj - pv.tj; dQp = (cfm - pv.cfm) / pv.cfm;
        pass = pass && all(abs(dTp) <= 0.5) && abs(dQp) <= 0.02;
        reg = sprintf('；预览档回归差 %+.2f/%+.2f/%+.2f°C、风量 %+.1f%%', dTp, 100*dQp);
    end
    if pass, st = 'PASS'; else, st = 'FAIL'; end
    fprintf(['[steady] 预览档 %d 步收敛=%d（%.0f s）：结温 %.1f/%.1f/%.1f（参考差 %+.1f/%+.1f/%+.1f），' ...
             '风量 %.1f CFM（%+.0f%%）%s；参考 v%s：%s\n'], info.steps, info.converged, el, tj, dTj, ...
             cfm, 100*dQ, reg, ref.version, st);
end
