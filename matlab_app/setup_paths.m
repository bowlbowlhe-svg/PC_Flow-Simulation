function setup_paths()
%SETUP_PATHS 把项目各目录加入路径；在 Octave 下额外加入兼容层（decomposition）。
    root = fileparts(mfilename('fullpath'));
    addpath(root);
    addpath(fullfile(root, 'src'));
    addpath(fullfile(root, 'app'));
    addpath(fullfile(root, 'tests'));
    addpath(fullfile(root, 'tools'));
    if exist('OCTAVE_VERSION', 'builtin')
        addpath(fullfile(root, 'compat', 'octave'));
    end
end
