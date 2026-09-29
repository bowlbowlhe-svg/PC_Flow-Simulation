function [D, idx] = edt_nearest(mask)
%EDT_NEAREST 精确欧氏距离变换：每格到最近 true 格的格心距离（格）及该格的线性索引。
%   [D, idx] = edt_nearest(mask)，mask 为 W×H 逻辑阵（行 y、列 x，线性索引 (x−1)·W + y）。
%   与 bwdist 的距离相同，但最近格的平局规则固定为"线性索引最小"（先取 x 最小的列，
%   再取该列 y 最小的格），不依赖 Image Processing Toolbox，MATLAB 与 Octave 结果一致。
%   mask 全为 false 时 D = Inf、idx = 0。
%   算法（可分离，逐维精确）：
%     1) 沿第 1 维（每列内）：到本列最近 true 格的距离 g 与行号 r，上下等距取上（y 小）；
%     2) 沿第 2 维（每行内）：D²(y, x) = min_x' [(x − x')² + g(y, x')²]，等值取 x' 最小。
    [W, H] = size(mask);
    mask = logical(mask);
    if ~any(mask(:))
        D = inf(W, H); idx = zeros(W, H);
        return;
    end
    % 1) 列内最近：向下扫描记录上方最近行，向上扫描记录下方最近行
    upRow = nan(W, H);
    last = nan(1, H);
    for y = 1:W
        last(mask(y, :)) = y;
        upRow(y, :) = last;
    end
    dnRow = nan(W, H);
    nxt = nan(1, H);
    for y = W:-1:1
        nxt(mask(y, :)) = y;
        dnRow(y, :) = nxt;
    end
    Y = repmat((1:W)', 1, H);
    dUp = Y - upRow; dUp(isnan(dUp)) = inf;
    dDn = dnRow - Y; dDn(isnan(dDn)) = inf;
    useUp = dUp <= dDn;
    g = min(dUp, dDn);
    r = dnRow;
    r(useUp) = upRow(useUp);
    % 2) 行内：逐行求 min_x' [(x − x')² + g²]（min 等值返回第一个，即 x' 最小）
    g2 = g.^2;
    D2 = zeros(W, H);
    xs = zeros(W, H);
    dx2 = ((1:H)' - (1:H)).^2;           % dx2(x, x') = (x − x')²
    for y = 1:W
        [m, am] = min(dx2 + g2(y, :), [], 2);
        D2(y, :) = m';
        xs(y, :) = am';
    end
    D = sqrt(D2);
    rows = r(sub2ind([W H], repmat((1:W)', 1, H), xs));
    idx = (xs - 1) * W + rows;
end
