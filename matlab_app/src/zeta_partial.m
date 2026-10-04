function zeta = zeta_partial(z)
%ZETA_PARTIAL 只挡住 Z 向深度一部分（占比 z）的零件的阻力系数（以来流速度计；规格 §2.4）。
%   突缩 + 突扩：ζ = (0.5·z + z²)/(1 − z)²，开口比 σ = 1 − z。z = 0.8 → 26，0.2 → 0.22。
    zeta = (0.5 * z + z * z) / ((1 - z) * (1 - z));
end
