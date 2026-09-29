function pass = test_ui()
%TEST_UI 界面烟雾测试（仅 MATLAB）：构造 App，触发场景/视图/推进/重置并截图。
%   产出 snapshots/ui_*.png；任何回调异常都会被捕获并计为失败。

    outDir = fullfile(fileparts(fileparts(mfilename('fullpath'))), 'snapshots');
    if ~exist(outDir, 'dir')
        mkdir(outDir);
    end

    errors = {};
    function logErr(stage, ME)
        errors{end+1} = sprintf('[%s] %s', stage, ME.message);
        fprintf(2, '*** ERROR @ %s: %s\n', stage, ME.message);
        fprintf(2, '%s\n', getReport(ME, 'extended'));
    end

    function checkState(app, stage, minIter)
        % 推进确实发生、场无 NaN/Inf、回调未吞异常
        if app.Solver.iteration < minIter
            errors{end+1} = sprintf('[%s] iteration=%d < %d（推进未发生，可能被回调吞掉异常）', ...
                stage, app.Solver.iteration, minIter);
        end
        if ~all(isfinite(app.Solver.T_fluid)) || ~all(isfinite(app.Solver.uF))
            errors{end+1} = sprintf('[%s] 场中出现 NaN/Inf', stage);
        end
        if ~isempty(app.LastError)
            errors{end+1} = sprintf('[%s] App 回调异常：%s', stage, app.LastError);
            app.LastError = '';
        end
    end

    function shot(app, name)
        try
            fname = fullfile(outDir, sprintf('ui_%s.png', name));
            exportapp(app.UIFigure, fname);
            fprintf('  → ui_%s.png\n', name);
        catch ME
            logErr(sprintf('shot %s', name), ME);
        end
    end

    fprintf('=== UI smoke test ===\n');

    %% 1. 构造 App
    fprintf('\n[1/8] Construct app...\n');
    app = [];
    try
        app = PCAirflowSimulatorApp();
        fprintf('  ok. UIFigure valid=%d\n', isvalid(app.UIFigure));
    catch ME
        logErr('construct', ME);
        pass = printReport(errors);
        return;
    end
    drawnow;
    shot(app, '01_initial');

    %% 2. 切换场景 - gaming
    fprintf('\n[2/8] setScenario(gaming)...\n');
    try
        app.runTestHook('setScenario', 'gaming');
        drawnow;
    catch ME
        logErr('setScenario gaming', ME);
    end
    shot(app, '02_gaming');

    %% 3. 切换可视化模式 - temperature
    fprintf('\n[3/8] setMode(temperature)...\n');
    try
        app.runTestHook('setMode', 'temperature');
        drawnow;
    catch ME
        logErr('setMode temperature', ME);
    end
    shot(app, '03_temperature');

    %% 4. 切换 vorticity
    fprintf('\n[4/8] setMode(vorticity)...\n');
    try
        app.runTestHook('setMode', 'vorticity');
        drawnow;
    catch ME
        logErr('setMode vorticity', ME);
    end
    shot(app, '04_vorticity');

    %% 5. 切换 solid
    fprintf('\n[5/8] setMode(solid)...\n');
    try
        app.runTestHook('setMode', 'solid');
        drawnow;
    catch ME
        logErr('setMode solid', ME);
    end
    shot(app, '05_solid');

    %% 6. 推进仿真（手动调用 onTimer 模拟 60 帧）
    fprintf('\n[6/8] advance 60 frames via onTimer()...\n');
    try
        app.runTestHook('setMode', 'velocity');
        drawnow;
    catch ME
        logErr('setMode velocity', ME);
    end
    it0 = app.Solver.iteration;
    for k = 1:60
        try
            app.runTestHook('onTimer');
        catch ME
            logErr(sprintf('onTimer iter=%d', k), ME);
            break;
        end
    end
    drawnow;
    checkState(app, 'after 60 frames', it0 + 60);
    shot(app, '06_after_60_frames');

    %% 7. 满载场景
    fprintf('\n[7/8] setScenario(heavy) + advance 60 frames...\n');
    try
        app.runTestHook('setScenario', 'heavy');
        drawnow;
    catch ME
        logErr('setScenario heavy', ME);
    end
    it0 = app.Solver.iteration;
    for k = 1:60
        try
            app.runTestHook('onTimer');
        catch ME
            logErr(sprintf('onTimer heavy iter=%d', k), ME);
            break;
        end
    end
    checkState(app, 'heavy 60 frames', it0 + 60);
    try
        app.runTestHook('setMode', 'temperature');
    catch ME
        logErr('setMode temperature (heavy)', ME);
    end
    drawnow;
    shot(app, '07_heavy_temp');

    %% 8. 重置
    fprintf('\n[8/8] resetSim()...\n');
    try
        app.runTestHook('resetSim');
        drawnow;
    catch ME
        logErr('resetSim', ME);
    end
    if app.Solver.iteration ~= 0
        errors{end+1} = sprintf('[resetSim] iteration=%d，应为 0', app.Solver.iteration);
    end
    shot(app, '08_after_reset');

    % App 回调内部捕获的异常（只打印不抛出）也计为失败
    if ~isempty(app.LastError)
        errors{end+1} = sprintf('[App 回调异常] %s', app.LastError);
    end

    %% 关闭
    try
        delete(app);
    catch ME
        logErr('delete app', ME);
    end

    pass = printReport(errors);
end

function pass = printReport(errors)
    fprintf('\n=== UI test report ===\n');
    pass = isempty(errors);
    if pass
        fprintf('PASSED: 0 errors\n');
    else
        fprintf('FAILED: %d errors\n', numel(errors));
        for k = 1:numel(errors)
            fprintf('  - %s\n', errors{k});
        end
    end
end
