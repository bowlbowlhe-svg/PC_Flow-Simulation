function allPass = run_all_tests(level)
%RUN_ALL_TESTS 统一测试入口。
%   run_all_tests('quick')  快速回归（几分钟）：平流方向、reset 一致性
%   run_all_tests('full')   完整回归（默认）：quick + 守恒（1200 步）+ 湍流
%   run_all_tests('ui')     界面烟雾测试（仅 MATLAB）
%   返回是否全部通过，并打印汇总。
    if nargin < 1 || isempty(level), level = 'full'; end
    setup_paths();
    isOctave = exist('OCTAVE_VERSION', 'builtin') ~= 0;

    tests = {};
    switch lower(level)
        case 'quick'
            tests = quickTests();
        case 'full'
            tests = [quickTests(), { ...
                {'守恒（1200 步）', @() test_conservation(400)}, ...
                {'湍流模型',        @() test_turbulence(400)}}];
        case 'ui'
            if isOctave
                fprintf('界面测试需要 MATLAB（uifigure），Octave 下【跳过】（未执行，不代表通过）。\n');
                allPass = true;
                return;
            end
            tests = {{'界面烟雾测试', @() test_ui()}};
        otherwise
            error('run_all_tests:level', '未知级别：%s（quick | full | ui）', level);
    end

    n = numel(tests);
    results = false(1, n);
    elapsed = zeros(1, n);
    for k = 1:n
        name = tests{k}{1};
        fprintf('\n########## [%d/%d] %s ##########\n', k, n, name);
        t0 = tic;
        try
            results(k) = logical(tests{k}{2}());
        catch err
            fprintf(2, '*** %s 抛出异常：%s\n', name, err.message);
            if isOctave
                for s = 1:numel(err.stack)
                    fprintf(2, '    at %s:%d\n', err.stack(s).name, err.stack(s).line);
                end
            else
                fprintf(2, '%s\n', getReport(err, 'extended'));
            end
            results(k) = false;
        end
        elapsed(k) = toc(t0);
    end

    fprintf('\n========== 测试汇总（%s，v%s）==========\n', level, pcflow_version());
    for k = 1:n
        if results(k), st = 'PASS'; else, st = 'FAIL'; end
        fprintf('  %-4s  %-20s  %7.1fs\n', st, tests{k}{1}, elapsed(k));
    end
    allPass = all(results);
    if allPass
        fprintf('全部通过（%d 项）\n', n);
    else
        fprintf('%d 项失败\n', sum(~results));
    end
end

function tests = quickTests()
    tests = { ...
        {'平流方向性',     @() test_advection()}, ...
        {'reset 一致性',   @() test_reset(20, 0.5)}};
end
