function test_advection()
%TEST_ADVECTION 平流方向性回归测试（v3.0 引入）
%   背景：v2.x 格心平流存在查询轴转置 bug——gridInterpF(Xq,Yq) 把 x 回溯
%   坐标传入插值器 y 维（dim1=y），每步把场转置一次、位移两轴交替。
%   本测试为 blob 对照试验：均匀 +x 流下 blob 应沿 +x（dim2/列）移动。
%   1) 格心标量路径（advect fieldId 0，makima）
%   2) MAC 面场路径（advectFaces，cubic）
    nFail = 0;
    s = CFDSolverFEM(125,250,450,'atx_balanced',1);
    W = s.GRID.W; H = s.GRID.H;
    dt0 = s.DT * (W-2);
    nSteps = 10;
    uMag = 0.5;
    expectDx = dt0 * uMag * nSteps;   % 理论 x 位移（格）

    % ---- 1) 格心标量路径 ----
    u0 = zeros(W*H,1) + uMag; v0 = zeros(W*H,1);
    T = ones(W*H,1)*25;
    y0 = round(W/2); x0 = 20;   % 机箱外左侧纯流体区
    T((x0-1)*W + y0) = 50;
    for i = 1:nSteps
        T = s.advect(0, T, T, u0, v0);
    end
    TM = reshape(T, W, H);
    w = max(TM - 25, 0);
    [yy, xx] = ndgrid(1:W, 1:H);
    cy = sum(yy(:).*w(:))/sum(w(:)); cx = sum(xx(:).*w(:))/sum(w(:));
    dx = cx - x0; dy = cy - y0;
    ok = dx > 0.7*expectDx && dx < 1.3*expectDx && abs(dy) < 0.5;
    fprintf('[1] 格心标量平流：dx=%.2f（理论 %.2f），dy=%.2f：%s\n', ...
        dx, expectDx, dy, tern(ok,'PASS','FAIL'));
    if ~ok, nFail = nFail + 1; end

    % ---- 2) MAC 面场路径（小振幅高斯 blob，自平流可忽略）----
    s.uF(:) = 0; s.vF(:) = 0;
    s.uF(s.uFaceActive) = uMag;
    [yyB, xxB] = ndgrid(1:W+1, 1:H);
    vM = 0.05 * exp(-((yyB-y0).^2 + (xxB-x0).^2) / 8);
    assert(s.vFaceActive((x0-1)*(W+1)+y0), 'blob 面未激活');
    s.vF = vM(:);
    for i = 1:nSteps
        s.advectFaces();
    end
    vM2 = reshape(s.vF, W+1, H);
    cy = sum(yyB(:).*vM2(:))/sum(vM2(:)); cx = sum(xxB(:).*vM2(:))/sum(vM2(:));
    dx = cx - x0; dy = cy - y0;
    ok = dx > 0.7*expectDx && dx < 1.3*expectDx && abs(dy) < 0.5;
    fprintf('[2] MAC 面场平流：dx=%.2f（理论 %.2f），dy=%.2f：%s\n', ...
        dx, expectDx, dy, tern(ok,'PASS','FAIL'));
    if ~ok, nFail = nFail + 1; end

    if nFail == 0
        fprintf('=== 平流方向性测试全部通过 ===\n');
    else
        fprintf('=== 平流方向性测试 %d 项失败 ===\n', nFail);
    end
end

function s = tern(c, a, b)
    if c, s = a; else, s = b; end
end
