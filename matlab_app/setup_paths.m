function setup_paths()
%SETUP_PATHS 把项目各目录加入路径；在 Octave 下额外加载兼容层与 image 包。
    root = fileparts(mfilename('fullpath'));
    addpath(root);
    addpath(fullfile(root, 'src'));
    addpath(fullfile(root, 'app'));
    addpath(fullfile(root, 'tests'));
    addpath(fullfile(root, 'tools'));
    if exist('OCTAVE_VERSION', 'builtin')
        addpath(fullfile(root, 'compat', 'octave'));
        try
            pkg('load', 'image');   % bwdist
        catch
            % 无 image 包时求解器自动走 bwdistFallback
        end
    end
end
