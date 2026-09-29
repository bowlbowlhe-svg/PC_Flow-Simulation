function restore = ui_mock_setup(oldPath)
%UI_MOCK_SETUP 在 Octave 下准备界面桩测试环境：
%   1) 桩目录置于路径最前（uifigure/timer/drawnow/parula 与 MockUI）；
%   2) 生成去掉属性类型注解的 App 副本（Octave 不支持 "Name matlab.ui.Figure" 语法），
%      并用它替换 app/ 目录；
%   返回 onCleanup 对象，释放时把路径恢复为 oldPath（缺省为调用时的路径）。
    here = fileparts(mfilename('fullpath'));
    root = fileparts(fileparts(here));
    appDir = fullfile(root, 'app');
    outDir = fullfile(tempdir, sprintf('pcflow_ui_mock_%d', getpid()));
    if ~exist(outDir, 'dir'), mkdir(outDir); end

    fid = fopen(fullfile(appDir, 'PCAirflowSimulatorApp.m'), 'r');
    raw = fread(fid, inf, 'uint8=>char')';
    fclose(fid);
    lines = strsplit(raw, "\n");
    inProps = false;
    for k = 1:numel(lines)
        l = lines{k};
        if ~isempty(regexp(l, '^\s*properties\>', 'once'))
            inProps = true;
        elseif inProps && ~isempty(regexp(l, '^\s*end\s*$', 'once'))
            inProps = false;
        elseif inProps
            lines{k} = regexprep(l, '^(\s+[A-Za-z]\w*)\s+[A-Za-z][\w.]*(\s*(=.*|%.*)?)$', '$1$2');
        end
    end
    fid = fopen(fullfile(outDir, 'PCAirflowSimulatorApp.m'), 'w');
    fwrite(fid, strjoin(lines, "\n"));
    fclose(fid);

    if nargin < 1, oldPath = path(); end
    w = warning('query', 'Octave:shadowed-function');
    warning('off', 'Octave:shadowed-function');
    rmpath(appDir);
    addpath(outDir);
    addpath(here);
    restore = onCleanup(@() restorePath(oldPath, outDir, w));
end

function restorePath(p, outDir, w)
    path(p);
    warning(w.state, 'Octave:shadowed-function');
    if exist(fullfile(outDir, 'PCAirflowSimulatorApp.m'), 'file')
        delete(fullfile(outDir, 'PCAirflowSimulatorApp.m'));
    end
    rmdir(outDir);
end
