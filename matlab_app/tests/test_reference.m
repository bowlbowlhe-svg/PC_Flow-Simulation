function pass = test_reference()
%TEST_REFERENCE 与标准答案数据集对照（tests/reference/fixed_default.json）：
%   默认布局、预览网格、从静止推进 200 步，逐场比较温度、速度、静压，并比较结温与风量。
%   生成环境与当前环境相同（同为 Octave 或同为 MATLAB）时要求近乎逐位一致；
%   跨平台时插值等实现有差异，只检查量级（并提示用 tools/make_reference_dataset 在本平台重新生成）。
    f = fullfile(fileparts(mfilename('fullpath')), 'reference', 'fixed_default.json');
    R = jsondecode(fileread(f));
    isOct = exist('OCTAVE_VERSION', 'builtin') ~= 0;
    same = strcmp(R.generator.platform, ternary(isOct, 'Octave', 'MATLAB'));
    L = layout_json_normalize(R.layout);
    s = CFDSolverFEM(R.powers(1), R.powers(2), R.powers(3), L, R.gridScale);
    s.turbUpdateEvery = 1;
    s.stepMultiple(R.steps);
    [uc, vc] = s.getCellVelocity();
    P = s.pressureFieldPa();
    fl = s.obstacle == 0;
    dT = max(abs(s.T_fluid(fl) - R.fields.T(fl)));
    dU = max(abs([uc(fl) * s.VEL_SCALE - R.fields.u(fl); vc(fl) * s.VEL_SCALE - R.fields.v(fl)]));
    Pr = R.fields.P(fl); Pc = P(fl);
    dP = max(abs(Pc - Pr));
    dTj = max(abs([s.thermalNetworks.cpu.T_junction - R.scalars.Tj_cpu, ...
                   s.thermalNetworks.gpu.T_junction - R.scalars.Tj_gpu, ...
                   s.thermalNetworks.psu.T_junction - R.scalars.Tj_psu]));
    if same
        tol = struct('T', 1e-3, 'U', 1e-4, 'P', 1e-3, 'Tj', 1e-3);   % 6 位有效数字存储的舍入
    else
        tol = struct('T', 2, 'U', 0.3, 'P', 2, 'Tj', 1);
        fprintf('  参考数据生成于 %s，当前为 %s：只检查量级；建议运行 tools/make_reference_dataset 在本平台重新生成\n', ...
            R.generator.platform, ternary(isOct, 'Octave', 'MATLAB'));
    end
    pass = dT <= tol.T && dU <= tol.U && dP <= tol.P && dTj <= tol.Tj;
    if pass, st = 'PASS'; else, st = 'FAIL'; end
    fprintf('[reference] 默认布局 140² 200 步：max|ΔT| %.2e°C、max|Δu| %.2e m/s、max|ΔP| %.2e Pa、max|ΔTj| %.2e°C（参考 v%s/%s）：%s\n', ...
        dT, dU, dP, dTj, R.generator.simulator, R.generator.platform, st);
end

function L = layout_json_normalize(L)
    % 与 layout_json('load') 相同的规整（数据集把布局嵌在 JSON 里）
    f = [tempname() '.json'];
    fid = fopen(f, 'w'); fwrite(fid, jsonencode(L)); fclose(fid);
    L = layout_json('load', f);
    delete(f);
end

function out = ternary(c, a, b)
    if c, out = a; else, out = b; end
end
