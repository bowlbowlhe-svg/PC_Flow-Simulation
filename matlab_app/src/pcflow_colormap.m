function cmap = pcflow_colormap(name, n)
%PCFLOW_COLORMAP 界面配色表（MATLAB / Octave 通用，不依赖工具箱）。
%   'diverging'：蓝—白—红发散色（温差视图，0 为白）。
    if nargin < 2, n = 256; end
    switch name
        case 'diverging'
            k = [0.23 0.30 0.75; 0.55 0.69 0.99; 0.87 0.87 0.87; 0.96 0.60 0.48; 0.71 0.02 0.15];
        otherwise
            error('pcflow_colormap:name', '未知配色：%s', name);
    end
    x = linspace(0, 1, size(k, 1));
    xi = linspace(0, 1, n)';
    cmap = [interp1(x, k(:,1), xi), interp1(x, k(:,2), xi), interp1(x, k(:,3), xi)];
end
