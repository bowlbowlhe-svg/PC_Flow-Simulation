function pass = test_reset(steps, gridScale)
%TEST_RESET reset() 后与新建求解器逐位一致。
%   路径 A：新建 → 跑 steps 步 → 改功率 → reset → 跑 steps 步
%   路径 B：用改后的功率新建 → 跑 steps 步
%   两条路径的全部场与结温应逐位相同。
    if nargin < 1, steps = 20; end
    if nargin < 2, gridScale = 0.5; end

    a = CFDSolverFEM(125, 250, 450, 'atx_balanced', gridScale);
    a.stepMultiple(steps);
    a.setComponentPower('cpu', 100);
    a.setComponentPower('gpu', 200);
    a.setComponentPower('psu', 500);
    a.reset();
    a.stepMultiple(steps);

    b = CFDSolverFEM(100, 200, 500, 'atx_balanced', gridScale);
    b.stepMultiple(steps);

    names = {'T_fluid','T_solid','uF','vF','p','turbK','turbOmega'};
    pass = true;
    for k = 1:numel(names)
        d = max(abs(a.(names{k})(:) - b.(names{k})(:)));
        if d ~= 0
            fprintf('[reset] %s 最大差 %.3g：FAIL\n', names{k}, d);
            pass = false;
        end
    end
    tjA = [a.thermalNetworks.cpu.T_junction a.thermalNetworks.gpu.T_junction a.thermalNetworks.psu.T_junction];
    tjB = [b.thermalNetworks.cpu.T_junction b.thermalNetworks.gpu.T_junction b.thermalNetworks.psu.T_junction];
    if any(tjA ~= tjB)
        fprintf('[reset] 结温不一致：FAIL\n');
        pass = false;
    end
    if pass
        fprintf('[reset] reset 后 %d 步与新建求解器逐位一致：PASS\n', steps);
    end
end
