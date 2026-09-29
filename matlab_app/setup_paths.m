function setup_paths()
%SETUP_PATHS 把项目目录加入路径；在 Octave 下额外加载兼容层与 image 包。
%   MATLAB 用户无需调用（内置 decomposition/griddedInterpolant 可用）。
    root = fileparts(mfilename('fullpath'));
    addpath(root);
    if exist('OCTAVE_VERSION', 'builtin')
        addpath(fullfile(root, 'compat', 'octave'));
        try
            pkg('load', 'image');   % bwdist
        catch
            % 无 image 包时求解器自动走 bwdistFallback
        end
    end
end
