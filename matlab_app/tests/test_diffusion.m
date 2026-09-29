function pass = test_diffusion(nSteps)
%TEST_DIFFUSION 扩散算子物理尺度：高斯包二阶矩增长 vs 解析解。
%   隐式欧拉 + 5 点 Laplacian 下，每步每个方向的方差严格增长 2·α·DT/Δx²（格²），
%   因此 n 步后 σ² − σ0² = 2·α·t/Δx²（t = n·DT），与物理热方程一致。
%   分别检验温度（格心，标量 α 与空间场 α 两条装配路径）与速度（MAC u 面）。
    if nargin < 1, nSteps = 100; end
    s = CFDSolverFEM(0, 0, 0, layout_benchmark('empty'), 1, 0.005);
    W = s.GRID.W; H = s.GRID.H;
    dx = s.GRID.cell_size_mm / 1000;
    t = nSteps * s.DT;
    alpha = s.AIR.nu / s.AIR.Pr;
    expect = 2 * alpha * t / dx^2;           % 每方向方差增量 [格²]
    sigma0 = 4;
    [YY, XX] = ndgrid(1:W, 1:H);
    yc = (W+1)/2; xc = (H+1)/2;
    blob = 10 * exp(-((YY-yc).^2 + (XX-xc).^2) / (2*sigma0^2));
    pass = true;

    % 1) 温度，标量 α（L_temp 路径）
    s.T_fluid = s.T_amb + blob(:);
    for k = 1:nSteps, s.diffuseTemperature(alpha); end
    pass = checkMoments('温度（标量 α）', reshape(s.T_fluid - s.T_amb, W, H), YY, XX, sigma0, expect) && pass;

    % 2) 温度，空间场 α（面加权装配路径）
    s.reset();
    s.T_fluid = s.T_amb + blob(:);
    for k = 1:nSteps, s.diffuseTemperature(alpha * ones(W*H, 1)); end
    pass = checkMoments('温度（空间场 α）', reshape(s.T_fluid - s.T_amb, W, H), YY, XX, sigma0, expect) && pass;

    % 3) 速度（u 面点阵，ν）
    s.reset();
    nu = s.AIR.nu;
    expectU = 2 * nu * t / dx^2;
    [YU, XU] = ndgrid(1:W, 0.5:H+0.5);
    ub = 0.01 * exp(-((YU-yc).^2 + (XU-xc).^2) / (2*sigma0^2));
    s.uF = ub(:);
    s.vF(:) = 0;
    for k = 1:nSteps, s.diffuseVelocity(nu); end
    pass = checkMoments('速度（u 面，ν）', reshape(s.uF, W, H+1), YU, XU, sigma0, expectU) && pass;
end

function ok = checkMoments(name, f, YY, XX, sigma0, expect)
    m0 = sum(f(:));
    yc = sum(YY(:).*f(:)) / m0; xc = sum(XX(:).*f(:)) / m0;
    vy = sum((YY(:)-yc).^2 .* f(:)) / m0 - sigma0^2;
    vx = sum((XX(:)-xc).^2 .* f(:)) / m0 - sigma0^2;
    ry = vy / expect; rx = vx / expect;
    ok = abs(ry - 1) < 0.02 && abs(rx - 1) < 0.02;
    if ok, st = 'PASS'; else, st = 'FAIL'; end
    fprintf('[diffusion] %s：方差增量 y %.3f / x %.3f 格²，解析 %.3f（比值 %.3f / %.3f）：%s\n', ...
        name, vy, vx, expect, ry, rx, st);
end
