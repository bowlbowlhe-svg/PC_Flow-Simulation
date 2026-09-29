function c = parula(n)
%PARULA 桩（Octave 无 parula）：用 viridis 代替。
    if nargin < 1, n = 64; end
    c = viridis(n);
end
