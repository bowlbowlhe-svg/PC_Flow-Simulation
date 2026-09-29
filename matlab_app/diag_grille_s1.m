function diag_grille_s1(nSteps)
%DIAG_GRILLE_S1 S1 复核诊断：盘区采样 vs 开口 MAC 面采样（格栅 Δp 口径）
%   默认场景跑 nSteps 步后，对每台穿壁风扇比较：
%     v_disk = 盘区采样圈格心法向速度（旧口径，采样圈覆盖风扇力施加区、读射流核峰值）
%     v_open = 开口段穿墙面速度（新口径，getOpeningFaceVelocity）
%   以及两种 v 下的格栅压降 dpGrille = zeta*0.5*rho*v^2。
%   用法： diag_grille_s1        % 400 步
%          diag_grille_s1(200)

    if nargin < 1, nSteps = 400; end
    s = CFDSolverFEM();
    tic;
    s.stepMultiple(nSteps);
    fprintf('推进 %d 步完成（%.1fs）\n', nSteps, toc);

    W = s.GRID.W; H = s.GRID.H;
    [uC, vC] = s.getCellVelocity();
    allFans = [s.fans, s.builtInFans];
    fprintf('\n%-14s %-6s %8s %8s %9s %9s\n', 'fan', 'mount', 'v_disk', 'v_open', 'dpG_old', 'dpG_new');
    fprintf('%s\n', repmat('-', 1, 62));
    for k = 1:numel(allFans)
        f = allFans{k};
        m = f.mount;
        gm = m;
        if strcmp(gm,'left'),  gm = 'rear';  end
        if strcmp(gm,'right'), gm = 'front'; end
        if ~any(strcmp(gm, {'top','bottom','rear','front'})), continue; end
        bnd = f.getBounds();
        % --- 旧口径：盘区采样圈 ---
        cx = bnd.x + bnd.w/2; cy = bnd.y + bnd.h/2;
        radius = max(bnd.w, bnd.h)/2; r = ceil(radius);
        iR = max(2, floor(cx)-r) : min(W-1, floor(cx)+r);
        jR = max(2, floor(cy)-r) : min(H-1, floor(cy)+r);
        [II, JJ] = ndgrid(iR, jR);
        dd = sqrt((II-cx).^2 + (JJ-cy).^2);
        II = II(dd<=radius); JJ = JJ(dd<=radius);
        idx = (II-1)*W + JJ;
        idx = idx(s.obstacle(idx) == 0);
        switch m
            case {'front','right','left'}, nd = [1; 0];
            case 'rear',                   nd = [-1; 0];
            case 'top',                    nd = [0; -1];
            case 'bottom',                 nd = [0; 1];
            otherwise,                     nd = [1; 0];
        end
        if strcmp(f.type, 'intake'), nd = -nd; end
        vN = mean(uC(idx))*nd(1) + mean(vC(idx))*nd(2);
        vDisk = max(0, vN) * s.VEL_SCALE / max(norm(nd), eps);
        % --- 新口径：开口 MAC 面 ---
        if any(strcmp(gm, {'top','bottom'}))
            lo = floor(bnd.x); hi = ceil(bnd.x + bnd.w);
        else
            lo = floor(bnd.y); hi = ceil(bnd.y + bnd.h);
        end
        vnOp = s.getOpeningFaceVelocity(gm, lo, hi);
        if isempty(vnOp)
            vOpen = NaN;
        else
            vOpen = abs(mean(vnOp)) * s.VEL_SCALE;
        end
        % --- 两种口径下的格栅压降 ---
        if strcmp(f.type, 'intake'), z = s.GRILLE_ZETA_INTAKE;
        else,                        z = s.GRILLE_ZETA_EXHAUST; end
        dpO = z * 0.5 * s.AIR_DENSITY * vDisk^2;
        dpN = z * 0.5 * s.AIR_DENSITY * vOpen^2;
        if isnumeric(f.id), idStr = sprintf('realfan_%d', f.id);
        else,               idStr = f.id; end
        fprintf('%-14s %-6s %8.3f %8.3f %9.3f %9.3f\n', idStr, m, vDisk, vOpen, dpO, dpN);
    end

    fl = s.computeOpeningFluxes();
    fprintf('\n开口 CFM（外向为正）：top=%+.1f  rear=%+.1f  front=%+.1f  bottom=%+.1f\n', ...
        fl.top.cfm, fl.rear.cfm, fl.front.cfm, fl.bottom.cfm);
    fprintf('Tj：cpu=%.1f  gpu=%.1f  psu=%.1f °C\n', ...
        s.thermalNetworks.cpu.T_junction, s.thermalNetworks.gpu.T_junction, ...
        s.thermalNetworks.psu.T_junction);
end
