function pass = test_quasi3d()
%TEST_QUASI3D 准三维修正、机箱壁散热与鳍片换热（v4.8.0；规格 §2.4、§3.9、§4）。
%   1) 部分遮挡：默认布局的显卡 PCB、内存、VRM 是多孔区（ζ = zeta_partial(z)），不是障碍；z = 1 时为障碍（旧模型）；
%   2) 壁面散热：散热格与衰减因子（侧板 + 贴壁边），电源外壳内不散热，缺 panelU 时没有；
%   3) 鳍片换热：h = h_free + h_forced·V^h_exp，风速取穿流分量（横穿 GPU 鳍片的气流不算）；三个 h 参数都不给时为旧模型
%      （30 + 130·V，风速取风速模）；显卡风扇都停转时换热风速乘 passiveFlowShare，有风扇在转或没有风扇时不乘；
%   4) 取值检查与旧配置迁移（热参数都是 v4.7 默认值时整体升级，改过的整个文件保持 v4.7 模型）。
    errs = {};
    L0 = layout_default();
    OB = CFDSolverBase.OBSTACLE;

    % 1) 部分遮挡
    errs = check(errs, abs(zeta_partial(0.8) - 26) < 1e-12 && abs(zeta_partial(0.2) - 0.21875) < 1e-12, 'zeta_partial(0.8) = 26、(0.2) = 0.21875');
    s = CFDSolverFEM([], [], [], L0, 0.5);
    pcb = s.rectCells(s.GPU_HEATSINK.pcb);
    ram = s.rectCells(s.RAM_SLOTS(1));
    vrm = s.rectCells(s.VRM.heatsink);
    errs = check(errs, all(s.obstacle(pcb) == 0) && all(s.obstacle(ram) == 0) && all(s.obstacle(vrm) == 0), ...
        '默认布局的显卡 PCB、内存、VRM 应为流体格（多孔区）');
    zt = [s.porousZones.zetaThru];
    errs = check(errs, sum(abs(zt - zeta_partial(0.8)) < 1e-12) == 1 && sum(abs(zt - zeta_partial(0.2)) < 1e-12) == 5, ...
        '多孔区里应有 1 个显卡（ζ 26）与 5 个内存/VRM（ζ 0.22）');
    errs = check(errs, isempty(s.heatObsIdx) || all(s.obstacle(s.heatObsIdx) == OB.PSU_CASE), '发热固体只剩电源外壳');
    L1 = L0; L1.zShare = struct('gpu', 1, 'ram', 1, 'vrm', 1);
    s1 = CFDSolverFEM([], [], [], L1, 0.5);
    errs = check(errs, all(s1.obstacle(pcb) == OB.GPU_PCB) && all(s1.obstacle(ram) == OB.RAM_SLOT) && all(s1.obstacle(vrm) == OB.VRM), ...
        'zShare = 1 时应为固体障碍（旧模型）');
    errs = check(errs, numel(s1.porousZones) == numel(s.porousZones) - 6, 'zShare = 1 时不登记部分遮挡的多孔区');

    % 2) 壁面散热
    co = s.CASE2D.outer; W = s.GRID.W;
    rc = s.AIR_DENSITY * s.AIR_CP;
    kSide = 2 * L0.chassis.panelU.side / (rc * L0.chassis.depthM);
    kEdge = L0.chassis.panelU.edge / (rc * s.GRID.cell_size_mm / 1000);
    iMid = (co.x + 40 - 1) * W + co.y + 20;                      % 机箱中部（顶壁下 19 格）
    iTop = (co.x + 40 - 1) * W + co.y + 1;                       % 贴顶壁
    dOf = @(i) pick(s.wallLossDecay, s.wallLossIdx == i);
    errs = check(errs, abs(dOf(iMid) - exp(-kSide * s.DT)) < 1e-15, '机箱中部只有侧板散热');
    errs = check(errs, abs(dOf(iTop) - exp(-(kEdge + kSide) * s.DT)) < 1e-15, '贴顶壁的格另加一条边的壁面散热');
    errs = check(errs, ~any(ismember(s.wallLossIdx, s.psuInteriorIdx)), '电源外壳内不散热');
    errs = check(errs, all(ismember(s.wallLossIdx, s.insideMask)), '散热格都在机箱内');
    Lb = layout_benchmark('cavity', 1e4);
    sb = CFDSolverFEM(0, 0, 0, Lb, 0.5);
    errs = check(errs, isempty(sb.wallLossIdx), '缺 chassis.panelU 时没有壁面散热');
    Ld = L0; Ld.chassis.wallTempC.top = 25;                       % 定温壁的边不再另计壁面散热
    sd = CFDSolverFEM([], [], [], Ld, 0.5);
    errs = check(errs, abs(pick(sd.wallLossDecay, sd.wallLossIdx == iTop) - exp(-kSide * s.DT)) < 1e-15, '定温壁旁只有侧板散热');

    % 3) 鳍片换热
    net = DetailedThermalNetwork('gpu', 100, 95, 87, struct('thermal', L0.gpu.thermal, 'dvfs', layout_dvfs(L0, 'gpu')));
    net.solve(1, 30, 0.005);
    th = L0.gpu.thermal;
    errs = check(errs, abs(net.h_conv - (th.h_free + th.h_forced)) < 1e-12, 'V = 1 m/s 时 h = h_free + h_forced');
    old = rmfield(th, {'h_free', 'h_forced', 'h_exp'});
    net0 = DetailedThermalNetwork('gpu', 100, 95, 87, struct('thermal', old, 'dvfs', layout_dvfs(L0, 'gpu')));
    net0.solve(0.5, 30, 0.005);
    errs = check(errs, abs(net0.h_conv - (30 + 130 * 0.5)) < 1e-12 && net0.heat.legacy, '缺 h_free 等字段时为旧式 h = 30 + 130·V');
    errs = check(errs, throws(@() layout_heat_coef(rmfield(th, 'h_exp'), 'gpu')), 'h 参数只给一部分应报错');
    % 停转时的换热风速比例：构建时显卡风扇停转（结温 = 环境温度）
    sp = CFDSolverFEM([], [], [], L0, 0.5);
    k1 = sp.passiveScale(sp.thermalNetworks.gpu, 'gpu');
    sp.autoFanEnabled = false;                                    % 全局手动：风扇都转
    k2 = sp.passiveScale(sp.thermalNetworks.gpu, 'gpu');
    Ln = L0; Ln.gpu = rmfield(Ln.gpu, 'fans');                     % 没有显卡风扇（被动散热卡）
    sn = CFDSolverFEM([], [], [], Ln, 0.5);
    k3 = sn.passiveScale(sn.thermalNetworks.gpu, 'gpu');
    errs = check(errs, k1 == th.passiveFlowShare && k2 == 1 && k3 == 1 && sp.passiveScale(sp.thermalNetworks.cpu, 'cpu') == 1, ...
        sprintf('停转时换热风速比例：停转 %g、转动 %g、没有风扇 %g', k1, k2, k3));
    s.uF(:) = 0.5 / s.VEL_SCALE; s.vF(:) = 0;                     % 纯横向流：GPU 鳍片（穿流 y）的换热风速为 0
    s.uF(~s.uFaceActive) = 0;
    s.solveConjugateHeatTransfer();
    errs = check(errs, abs(s.thermalNetworks.gpu.h_conv - th.h_free) < 1e-12 && s.thermalNetworks.cpu.h_conv > L0.cpu.thermal.h_free + 1, ...
        sprintf('横向流不计入 GPU 鳍片换热（h %.2f），CPU 鳍片（穿流 x）照计（h %.2f）', ...
        s.thermalNetworks.gpu.h_conv, s.thermalNetworks.cpu.h_conv));
    Lg = L0; Lg.gpu.thermal = rmfield(Lg.gpu.thermal, {'h_free', 'h_forced', 'h_exp', 'passiveFlowShare'});
    sg = CFDSolverFEM([], [], [], Lg, 0.5);                       % 旧模型：风速取风速模
    sg.uF(:) = 0.5 / sg.VEL_SCALE; sg.vF(:) = 0; sg.uF(~sg.uFaceActive) = 0;
    sg.solveConjugateHeatTransfer();
    errs = check(errs, abs(sg.thermalNetworks.gpu.h_conv - (30 + 130 * 0.5)) < 1e-9, ...
        sprintf('旧模型的换热风速取风速模（h %.4f）', sg.thermalNetworks.gpu.h_conv));

    % 4) 取值检查与旧配置迁移
    bad = {{'zShare', struct('gpu', 0)}, {'zShare', struct('gpu', 0.5, 'cpu', 0.5)}, {'zShare', struct('gpu', 0.97)}, {'zShare', 0.8}};
    for k = 1:numel(bad)
        Lx = L0; Lx.(bad{k}{1}) = bad{k}{2};
        errs = check(errs, throws(@() CFDSolverFEM([], [], [], Lx, 0.5)), sprintf('不合法的 zShare 应报错（%d）', k));
    end
    Lx = L0; Lx.chassis.panelU.side = -1;
    errs = check(errs, throws(@() CFDSolverFEM([], [], [], Lx, 0.5)), '不合法的 panelU 应报错');
    Lx = L0; Lx.gpu.thermal.h_exp = 3;
    errs = check(errs, throws(@() CFDSolverFEM([], [], [], Lx, 0.5)), '不合法的 h_exp 应报错');
    Lo = L0;                                                      % v4.7 默认布局的样子
    Lo.chassis = rmfield(Lo.chassis, 'panelU');
    Lo.chassis.wallTempC = struct('rear', 25, 'front', 25, 'top', 25, 'bottom', 25);
    Lo = rmfield(Lo, 'zShare');
    Lo.cpu.thermal = struct('R_junction_to_case', 0.15, 'R_tim', 0.04, 'R_base', 0.05, 'fin_thickness_mm', 0.4, 'A_fin_total_m2', 0.15);
    Lo.gpu.thermal = struct('R_junction_to_case', 0.08, 'R_tim', 0.02, 'R_base', 0.02, 'fin_thickness_mm', 0.35, 'A_fin_total_m2', 0.5 * 57 / 47);
    Lo.gpu.porous = struct('zetaThru', 4, 'zetaCross', 10, 'thru', 'x');
    f = [tempname() '.json'];
    layout_json('save', Lo, f);
    [Lm, info] = layout_json('load', f);
    errs = check(errs, strcmp(info.migration, 'v48') && isnan(Lm.chassis.wallTempC.top) && isequal(Lm.chassis.panelU, L0.chassis.panelU) && ...
        isequal(Lm.zShare, L0.zShare) && isequal(Lm.cpu.thermal, L0.cpu.thermal) && ...
        isequal(Lm.gpu.thermal, L0.gpu.thermal) && isequal(Lm.gpu.porous, L0.gpu.porous), 'v4.7 的默认值应整体升级为 v4.8');
    L35 = layout_set_gpu_slots(Lo, 3.5);                          % 旧模型布局改槽数：仍按旧标定 0.5·h/47
    errs = check(errs, abs(L35.gpu.thermal.A_fin_total_m2 - 0.5 * 47 / 47) < 1e-15 && ...
        abs(getfield(layout_set_gpu_slots(L0, 3.5), 'gpu').thermal.A_fin_total_m2 - gpu_fin_area(47)) < 1e-15, ...
        '改槽数：旧模型布局按 0.5·h/47、新布局按 gpu_fin_area(h)');
    layout_json('save', L35, f);
    [Lm, info] = layout_json('load', f);
    errs = check(errs, strcmp(info.migration, 'v48') && abs(Lm.gpu.thermal.A_fin_total_m2 - gpu_fin_area(47)) < 1e-15, ...
        '3.5 槽显卡的旧默认面积应换成 gpu_fin_area(47)');
    variants = {@(L) setfield(L, 'cpu', setfield(L.cpu, 'thermal', setfield(L.cpu.thermal, 'R_tim', 0.05))), ...
                @(L) setfield(L, 'gpu', setfield(L.gpu, 'porous', setfield(L.gpu.porous, 'zetaCross', 12)))};
    for k = 1:numel(variants)
        Lk = variants{k}(Lo);                                     % 改过热参数或 GPU 鳍片阻力：整个文件按 v4.7 模型
        Lk.chassis.wallTempC.rear = 30;
        layout_json('save', Lk, f);
        [Lm, info] = layout_json('load', f);
        errs = check(errs, strcmp(info.migration, 'legacy') && ~isfield(Lm.chassis, 'panelU') && ~isfield(Lm, 'zShare') && ...
            Lm.chassis.wallTempC.top == 25 && Lm.chassis.wallTempC.rear == 30 && isequal(Lm.cpu.thermal, Lk.cpu.thermal) && ...
            isequal(Lm.gpu.porous, Lk.gpu.porous), sprintf('改过参数的 v4.7 配置应保持原样（%d）', k));
    end
    layout_json('save', layout_benchmark('cavity', 1e4), f);       % 基准布局没有元件，不迁移
    [~, info] = layout_json('load', f);
    errs = check(errs, strcmp(info.migration, 'none'), '基准布局不应迁移');
    delete(f);

    pass = isempty(errs);
    for k = 1:numel(errs), fprintf('  - %s\n', errs{k}); end
    if pass, st = 'PASS'; else, st = 'FAIL'; end
    fprintf('[quasi3d] 部分遮挡 / 壁面散热（%d 格）/ 鳍片换热 / 取值检查与迁移：%s\n', numel(s.wallLossIdx), st);
end

function v = pick(a, sel)
    % 恰好一个匹配时取值，否则 NaN（比较必然失败）
    if nnz(sel) == 1, v = a(sel); else, v = NaN; end
end

function tf = throws(f)
    tf = false;
    try
        f();
    catch
        tf = true;
    end
end

function errs = check(errs, cond, msg)
    if ~cond, errs{end+1} = msg; end
end
