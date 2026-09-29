function pcflow_gif_frame(file, rgb, first, delay)
%PCFLOW_GIF_FRAME 把一帧 RGB 图像（uint8，H×W×3）写入/追加到 GIF。
%   用 6×6×6 固定色立方量化（216 色），MATLAB 与 Octave 通用、各帧调色板一致。
%   first = true 时新建文件（无限循环），否则追加；delay 为帧间隔 [s]。
    if nargin < 4, delay = 0.1; end
    q = round(double(rgb(:, :, 1:3)) / 255 * 5);
    X = uint8(q(:, :, 1) * 36 + q(:, :, 2) * 6 + q(:, :, 3));
    [b, g, r] = ndgrid(0:5, 0:5, 0:5);
    map = [r(:) g(:) b(:)] / 5;
    if first
        imwrite(X, map, file, 'gif', 'LoopCount', Inf, 'DelayTime', delay);
    else
        imwrite(X, map, file, 'gif', 'WriteMode', 'append', 'DelayTime', delay);
    end
end
