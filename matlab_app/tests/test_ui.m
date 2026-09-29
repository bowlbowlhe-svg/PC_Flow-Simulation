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
    for k = 1:60
        try
            app.runTestHook('onTimer');
        catch ME
            logErr(sprintf('onTimer iter=%d', k), ME);
            break;
        end
    end
    drawnow;
    shot(app, '06_after_60_frames');

    %% 7. 满载场景
    fprintf('\n[7/8] setScenario(heavy) + advance 60 frames...\n');
    try
        app.runTestHook('setScenario', 'heavy');
        drawnow;
    catch ME
        logErr('setScenario heavy', ME);
    end
    for k = 1:60
        try
            app.runTestHook('onTimer');
        catch ME
            logErr(sprintf('onTimer heavy iter=%d', k), ME);
            break;
        end
    end
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
    shot(app, '08_after_reset');

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
