function L = layout_benchmark(kind, varargin)
%LAYOUT_BENCHMARK 验证用的简化布局（无元件）。
%   L = layout_benchmark('empty')         空计算域（无机箱），用于扩散算子测试
%   L = layout_benchmark('cavity', Ra)    差分加热方腔自然对流（de Vahl Davis 1983）：
%       后壁（左）45°C、前壁（右）25°C、顶/底绝热，按 Ra 反推空气粘性（Pr = 0.71）
%   L = layout_benchmark('duct', zetaPlug) 风扇-直风道：前壁进气 P12 满速，
%       中部多孔塞（阻力 zetaPlug），后壁被动通风口（ζ = 1）
    L = struct();
    L.name = ['bench_' kind];
    L.ambientC = 25;
    L.turbulenceModel = 'laminar';
    L.fanDiskMm = 12;
    L.grille = struct('intakeZeta', 2.0, 'exhaustZeta', 0.8);
    L.power = struct('cpu', 0, 'gpu', 0, 'psu', 0);
    switch kind
        case 'empty'
            L.domain = struct('sizeMm', 200, 'baseCellMm', 2);
            L.chassis = struct('enabled', false, 'originMm', 40, 'sizeMm', 120, 'depthM', 0.15, ...
                'wallTempC', struct('rear', NaN, 'front', NaN, 'top', NaN, 'bottom', NaN));
        case 'cavity'
            Ra = 1e5;
            if ~isempty(varargin), Ra = varargin{1}; end
            L.domain = struct('sizeMm', 160, 'baseCellMm', 2);
            L.chassis = struct('enabled', true, 'originMm', 20, 'sizeMm', 120, 'depthM', 0.15, ...
                'wallTempC', struct('rear', 45, 'front', 25, 'top', NaN, 'bottom', NaN));
            % 冷热壁定温点在壁格中心，间距 = (边长格数 − 1)·格距
            Lc = (120/2 - 1) * 0.002;
            dT = 20; g = 9.81; beta = 3.4e-3; Pr = 0.71;
            nu = sqrt(Pr * g * beta * dT * Lc^3 / Ra);
            L.air = struct('nu', nu, 'Pr', Pr);
            L.benchmark = struct('Ra', Ra, 'Lc', Lc, 'dT', dT);
        case 'duct'
            zetaPlug = 20;
            if ~isempty(varargin), zetaPlug = varargin{1}; end
            L.turbulenceModel = 'komega';
            L.domain = struct('sizeMm', 560, 'baseCellMm', 2);
            L.chassis = struct('enabled', true, 'originMm', 80, 'sizeMm', 400, 'depthM', 0.15, ...
                'wallTempC', struct('rear', 25, 'front', 25, 'top', 25, 'bottom', 25));
            % 上下实心块围出 120 mm 高、贯通前后的风道
            L.solidBlocks = [struct('x', 2, 'y', 2,   'w', 396, 'h', 138); ...
                             struct('x', 2, 'y', 260, 'w', 396, 'h', 138)];
            L.porousBlocks = struct('rect', struct('x', 180, 'y', 140, 'w', 20, 'h', 120), ...
                'zetaThru', zetaPlug, 'zetaCross', zetaPlug, 'thru', 'x');
            L.caseFans = struct('mount', 'front', 'alongMm', 200, 'type', 'intake', 'model', 'P12', ...
                'speedMode', 'manual', 'manualPct', 100);
            L.vents = struct('mount', 'rear', 'alongMm', 200, 'lengthMm', 120, 'zeta', 1.0);
            L.benchmark = struct('zetaPlug', zetaPlug, 'zetaIn', 2.0, 'zetaOut', 1.0, ...
                'areaM2', 0.12 * 0.15);
        otherwise
            error('layout_benchmark:kind', '未知基准：%s', kind);
    end
end
