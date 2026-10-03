function pass = test_steady()
%TEST_STEADY 预览档（140² 网格、湍流隔步更新）跑到稳态，并与精确档参考值对照。
%   参考值：tests/steady_reference.json（tools/make_steady_reference 生成：默认场景 280² 固定推进
%   3000 步、取 1000 步之后的长时均值）。两项检查：
%   1) 回归（严格）：与参考文件里的预览档回归值 preview（同样设置的 runToSteady）比较，结温 ≤ 0.5°C、风量 ≤ 2%；
%   2) 两档网格的差距不明显变大：与精确档比较，CPU ≤ 3.5°C、GPU ≤ 7°C、电源 ≤ 2°C、风量 ≤ 12%，且 runToSteady 判定收敛。
%   第 2 项是模型在粗网格上的保真度，不是代码正确性：紧凑机箱（v4.3 起）里显卡周围 20–30 mm 的间隙在预览网格上只有
%   5–6 格，v4.4.0（CPU 底座不挡风）默认布局预览档（runToSteady 判稳值）CPU −2.5°C、GPU +3.9°C、风量 −9%，
%   超出原来 2°C/3°C/8% 的容差，因此放宽；v4.5.0（双塔散热器）为 0.0/+1.2/+1.3°C、−1%；v4.6.0（风扇转速按厂家数据，
%   显卡风扇在低转速）为 −1.5/+5.0/+0.7°C、−8%：显卡风扇风量小，进风间隙的分辨率影响更大，GPU 容差放宽到 7°C
%   （其它布局的两档差别本来就到 ±7°C，见 README）。
%   实测见 README 的验证表。
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
    pass = info.converged && all(abs(dTj) <= [3.5 7 2]) && abs(dQ) <= 0.12;
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
