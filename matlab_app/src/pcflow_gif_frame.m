function pcflow_gif_frame(file, rgb, first, delay, map)
%PCFLOW_GIF_FRAME 把一帧 RGB 图像（uint8，H×W×3）写入/追加到 GIF。
%   map（n×3，n ≤ 256，取值 0–1）给定时按最近颜色量化（录制时由当前色表与界面颜色组成，
%   色带明显少于固定色立方）；缺省用 6×6×6 固定色立方（216 色）。MATLAB 与 Octave 通用，
%   各帧调色板一致。first = true 时新建文件（无限循环），否则追加；delay 为帧间隔 [s]。
    if nargin < 4 || isempty(delay), delay = 0.1; end
    rgb = double(rgb(:, :, 1:3)) / 255;
    [h, w, ~] = size(rgb);
    if nargin < 5 || isempty(map)
        q = round(rgb * 5);
        X = uint8(q(:, :, 1) * 36 + q(:, :, 2) * 6 + q(:, :, 3));
        [b, g, r] = ndgrid(0:5, 0:5, 0:5);
        map = [r(:) g(:) b(:)] / 5;
    else
        map = map(1:min(256, size(map, 1)), :);
        P = reshape(rgb, h * w, 3);
        idx = zeros(h * w, 1);
        chunk = 20000;
        for s = 1:chunk:h * w                       % 分块求最近颜色，控制内存
            e = min(h * w, s + chunk - 1);
            d = zeros(e - s + 1, size(map, 1));
            for c = 1:3
                d = d + (P(s:e, c) - map(:, c)').^2;
            end
            [~, idx(s:e)] = min(d, [], 2);
        end
        X = uint8(reshape(idx - 1, h, w));
    end
    if first
        imwrite(X, map, file, 'gif', 'LoopCount', Inf, 'DelayTime', delay);
    else
        imwrite(X, map, file, 'gif', 'WriteMode', 'append', 'DelayTime', delay);
    end
end
