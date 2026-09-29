function v = pchip_eval(x, y, q)
%PCHIP_EVAL 分段三次保形插值（Fritsch–Carlson / Brodlie，与 MATLAB pchip 同式）。
%   v = pchip_eval(x, y, q)：x 严格递增（≥ 3 个节点），q 钳入 [x(1), x(end)]。
%   节点斜率：
%     内部 k：δ_{k−1}·δ_k ≤ 0 时 d_k = 0；否则
%             d_k = (w1 + w2) / (w1/δ_{k−1} + w2/δ_k)，w1 = 2h_k + h_{k−1}，w2 = h_k + 2h_{k−1}；
%     端点（以左端为例，右端对称）：d = ((2h_1 + h_2)δ_1 − h_1δ_2)/(h_1 + h_2)；
%             sign(d) ≠ sign(δ_1) 时 d = 0；否则 sign(δ_1) ≠ sign(δ_2) 且 |d| > 3|δ_1| 时 d = 3δ_1。
%   区间内三次 Hermite。风扇 P-Q 曲线用；自带实现使 MATLAB 与 Octave 口径一致。
    x = x(:)'; y = y(:)';
    n = numel(x);
    h = diff(x);
    del = diff(y) ./ h;
    d = zeros(1, n);
    for k = 2:n-1
        if del(k-1) * del(k) > 0
            w1 = 2*h(k) + h(k-1);
            w2 = h(k) + 2*h(k-1);
            d(k) = (w1 + w2) / (w1 / del(k-1) + w2 / del(k));
        end
    end
    d(1) = endSlope(h(1), h(2), del(1), del(2));
    d(n) = endSlope(h(n-1), h(n-2), del(n-1), del(n-2));
    qc = min(max(q, x(1)), x(n));
    v = zeros(size(q));
    for m = 1:numel(q)
        i = find(x(1:n-1) <= qc(m), 1, 'last');
        t = (qc(m) - x(i)) / h(i);
        t2 = t * t; t3 = t2 * t;
        v(m) = (2*t3 - 3*t2 + 1) * y(i) + (t3 - 2*t2 + t) * h(i) * d(i) + ...
               (-2*t3 + 3*t2) * y(i+1) + (t3 - t2) * h(i) * d(i+1);
    end
end

function d = endSlope(h1, h2, del1, del2)
    d = ((2*h1 + h2) * del1 - h1 * del2) / (h1 + h2);
    if sign(d) ~= sign(del1)
        d = 0;
    elseif sign(del1) ~= sign(del2) && abs(d) > abs(3 * del1)
        d = 3 * del1;
    end
end
