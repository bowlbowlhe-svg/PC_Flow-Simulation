function out = grid_interp2(V, q1, q2, method, o1, o2)
%GRID_INTERP2 均匀单位格距网格上的二维插值（平流用；MATLAB 与 Octave 共用同一实现）。
%   out = grid_interp2(V, q1, q2, method, o1, o2)
%   V 为 n1×n2 节点值，节点坐标：第 1 维 o1 + (0:n1−1)，第 2 维 o2 + (0:n2−1)。
%   q1/q2 为同尺寸的查询坐标（先钳入网格范围，即外插取最近）。method：
%     'linear'  双线性；
%     'cubic'   三次卷积（Catmull-Rom，Keys a = −0.5：节点斜率 = 中心差分）；
%     'makima'  修正 Akima：斜率 s_i = (w_hi·δ_{i−1} + w_lo·δ_i)/(w_lo + w_hi)，
%               w_lo = |δ_{i−1} − δ_{i−2}| + |δ_{i−1} + δ_{i−2}|/2，
%               w_hi = |δ_{i+1} − δ_i| + |δ_{i+1} + δ_i|/2，分母为 0 时 s_i = 0。
%   cubic/makima 为逐维张量积，计算顺序固定（makima 对数据非线性，顺序影响结果）：
%     1) 每维两端各按二次外插延拓 2 个节点（f_0 = 3f_1 − 3f_2 + f_3，f_{−1} = 3f_0 − 3f_1 + f_2）；
%     2) 先沿第 2 维：在延拓后的阵上求第 2 维节点斜率，对查询点所在的第 1 维 6 个节点行
%        （i−2..i+3，含延拓行）分别做第 2 维三次 Hermite，得到 6 个中间值；
%     3) 再沿第 1 维：由这 6 个中间值求第 1 维斜率（节点 i、i+1），做三次 Hermite。
%   单元定位：u = q − o + 1 钳入 [1, n]，i = min(floor(u), n − 1)，t = u − i。
%   参考数据（tests/reference）即由本实现生成；MATLAB 内置 griddedInterpolant 的
%   二维 makima 计算顺序与此不同，不能替换。
    [n1, n2] = size(V);
    sz = size(q1);
    u1 = min(max(q1(:) - o1 + 1, 1), n1);
    u2 = min(max(q2(:) - o2 + 1, 1), n2);
    i1 = min(floor(u1), n1 - 1); t1 = u1 - i1;
    i2 = min(floor(u2), n2 - 1); t2 = u2 - i2;
    if strcmp(method, 'linear')
        a = V(i1 + (i2 - 1) * n1);      b = V(i1 + i2 * n1);
        c = V(i1 + 1 + (i2 - 1) * n1);  d = V(i1 + 1 + i2 * n1);
        out = reshape((a .* (1 - t2) + b .* t2) .* (1 - t1) + (c .* (1 - t2) + d .* t2) .* t1, sz);
        return;
    end
    isMakima = strcmp(method, 'makima');
    % 第 1 维两端各延拓 2 行，再求第 2 维节点斜率
    Vp = [pad2(V(1,:), V(2,:), V(3,:)); V; flipud(pad2(V(end,:), V(end-1,:), V(end-2,:)))];
    S2 = slopesDim2(Vp, isMakima);
    m = n1 + 4;
    f = zeros(numel(u1), 6);
    for k = -2:3
        r = i1 + k + 2;                            % 延拓后的行号
        la = r + (i2 - 1) * m;  lb = r + i2 * m;
        f(:, k + 3) = hermite(Vp(la), Vp(lb), S2(la), S2(lb), t2);
    end
    dl = diff(f, 1, 2);                            % δ1..δ5（节点 i−2..i+3 之间）
    if isMakima
        d3 = makimaSlope(dl(:,1), dl(:,2), dl(:,3), dl(:,4));
        d4 = makimaSlope(dl(:,2), dl(:,3), dl(:,4), dl(:,5));
    else
        d3 = 0.5 * (f(:,4) - f(:,2));
        d4 = 0.5 * (f(:,5) - f(:,3));
    end
    out = reshape(hermite(f(:, 3), f(:, 4), d3, d4, t1), sz);
end

function P = pad2(a1, a2, a3)
    % 由端点起的 3 个节点二次外插 2 个节点，返回 [远端; 近端]
    f0 = 3*a1 - 3*a2 + a3;
    fm = 3*f0 - 3*a1 + a2;
    P = [fm; f0];
end

function S = slopesDim2(A, isMakima)
    % 沿第 2 维的节点斜率（单位格距），与 A 同尺寸
    f0 = 3*A(:,1) - 3*A(:,2) + A(:,3);
    fm = 3*f0 - 3*A(:,1) + A(:,2);
    g0 = 3*A(:,end) - 3*A(:,end-1) + A(:,end-2);
    gm = 3*g0 - 3*A(:,end) + A(:,end-1);
    Ap = [fm, f0, A, g0, gm];
    n = size(A, 2);
    if isMakima
        dl = diff(Ap, 1, 2);                       % 列 j..j+3 对应 δ_{j−2}..δ_{j+1}
        S = makimaSlope(dl(:, 1:n), dl(:, 2:n+1), dl(:, 3:n+2), dl(:, 4:n+3));
    else
        S = 0.5 * (Ap(:, 4:n+3) - Ap(:, 2:n+1));   % 中心差分
    end
end

function s = makimaSlope(dm2, dm1, d0, dp1)
    wLo = abs(dm1 - dm2) + abs(dm1 + dm2) / 2;
    wHi = abs(dp1 - d0)  + abs(dp1 + d0)  / 2;
    wSum = wLo + wHi;
    s = (wHi .* dm1 + wLo .* d0) ./ wSum;
    s(wSum == 0) = 0;
end

function y = hermite(a, b, da, db, t)
    t2 = t .* t; t3 = t2 .* t;
    y = (2*t3 - 3*t2 + 1) .* a + (t3 - 2*t2 + t) .* da + ...
        (-2*t3 + 3*t2) .* b + (t3 - t2) .* db;
end
