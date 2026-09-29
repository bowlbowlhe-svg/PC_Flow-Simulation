function pass = test_reference()
%TEST_REFERENCE 与标准答案数据集对照（tests/reference/fixed_default.json、fixed_duct.json）：
%   预览网格从静止推进 200 步，逐场比较温度、格心速度、静压，并比较结温。
%   插值、最近流体格、pchip 都是项目自带实现，MATLAB 与 Octave 走同一套代码，差异只来自
%   线性求解与求和的舍入，因此两级判据：
%     差异 ≤ 存储舍入（6 位有效数字：ΔT 1e−3°C、Δu 1e−4 m/s、ΔP 1e−3 Pa）→ 通过；
%     跨平台（数据由另一平台生成）时差异超出舍入但 ≤ 0.05°C / 0.005 m/s / 0.05 Pa → 通过并提示反馈；
%     其余 → 失败（实现口径与参考数据不一致）。
    cases = {'fixed_default', 'fixed_duct'};
    pass = true;
    isOct = exist('OCTAVE_VERSION', 'builtin') ~= 0;
    here = ternary(isOct, 'Octave', 'MATLAB');
    for c = 1:numel(cases)
        f = fullfile(fileparts(mfilename('fullpath')), 'reference', [cases{c} '.json']);
        R = jsondecode(readUtf8(f));
        same = strcmp(R.generator.platform, here);
        L = layout_json_normalize(R.layout);
        s = CFDSolverFEM(R.powers(1), R.powers(2), R.powers(3), L, R.gridScale);
        s.turbUpdateEvery = R.turbUpdateEvery;
        s.stepMultiple(R.steps);
        [uc, vc] = s.getCellVelocity();
        P = s.pressureFieldPa();
        fl = s.obstacle == 0;
        d = struct();
        d.T = max(abs(s.T_fluid(fl) - R.fields.T(fl)));
        d.U = max(abs([uc(fl) * s.VEL_SCALE - R.fields.u(fl); vc(fl) * s.VEL_SCALE - R.fields.v(fl)]));
        d.P = max(abs(P(fl) - R.fields.P(fl)));
        nm = fieldnames(s.thermalNetworks);
        d.Tj = 0;
        for k = 1:numel(nm)
            d.Tj = max(d.Tj, abs(s.thermalNetworks.(nm{k}).T_junction - R.scalars.(['Tj_' nm{k}])));
        end
        strict = struct('T', 1e-3, 'U', 1e-4, 'P', 1e-3, 'Tj', 1e-3);
        loose  = struct('T', 0.05, 'U', 0.005, 'P', 0.05, 'Tj', 0.05);
        okStrict = within(d, strict);
        ok = okStrict || (~same && within(d, loose));
        if ok && okStrict, st = 'PASS';
        elseif ok, st = 'PASS（跨平台差异超出存储舍入，请反馈）';
        else, st = 'FAIL';
        end
        fprintf(['[reference] %s（%d² %d 步）：max|ΔT| %.2e°C、max|Δu| %.2e m/s、max|ΔP| %.2e Pa、' ...
                 'max|ΔTj| %.2e°C（参考 v%s/%s，当前 %s）：%s\n'], cases{c}, R.W, R.steps, ...
                 d.T, d.U, d.P, d.Tj, R.generator.simulator, R.generator.platform, here, st);
        pass = pass && ok;
    end
end

function ok = within(d, tol)
    ok = d.T <= tol.T && d.U <= tol.U && d.P <= tol.P && d.Tj <= tol.Tj;
end

function txt = readUtf8(f)
    fid = fopen(f, 'r');
    raw = fread(fid, inf, 'uint8=>uint8')';
    fclose(fid);
    txt = native2unicode(raw, 'UTF-8');
end

function L = layout_json_normalize(L)
    % 与 layout_json('load') 相同的规整（数据集把布局嵌在 JSON 里）
    f = [tempname() '.json'];
    layout_json('save', L, f);
    L = layout_json('load', f);
    delete(f);
end

function out = ternary(c, a, b)
    if c, out = a; else, out = b; end
end
