function pass = test_ui()
%TEST_UI 界面测试：构造 App，按用户操作的方式触发各控件回调，检查状态与异常。
%   MATLAB：驱动真实 uifigure，并在 snapshots/ 下截图 ui_*.png。
%   Octave：用 tests/ui_mock 的桩对象驱动同一套 App 代码（无截图）。
%   控件操作通过读取回调属性并直接调用来模拟（ui_press / ui_choose / ui_edit ...），
%   两种环境走同一条代码路径。
    isOctave = exist('OCTAVE_VERSION', 'builtin') ~= 0;
    if isOctave
        p0 = path();
        restoreEarly = onCleanup(@() path(p0)); %#ok<NASGU>   % ui_mock_setup 之前出错也恢复路径
        warning('off', 'Octave:shadowed-function');
        addpath(fullfile(fileparts(mfilename('fullpath')), 'ui_mock'));
        restore = ui_mock_setup(p0); %#ok<NASGU>          % 测试结束时恢复路径与警告状态
        warning('on', 'Octave:shadowed-function');
    end
    outDir = fullfile(fileparts(fileparts(mfilename('fullpath'))), 'snapshots');
    if ~isOctave && ~exist(outDir, 'dir'), mkdir(outDir); end

    errs = {};
    fprintf('=== UI test（%s）===\n', ternary(isOctave, 'Octave 桩', 'MATLAB'));
    if isOctave            % 桩自检：未知属性必须报错，否则属性名写错会被掩盖
        try
            b = MockUI('uibutton'); b.NoSuchProp = 1;
            errs{end+1} = '[mock] 桩未拒绝未知属性';
        catch
        end
    end

    %% 1. 构造
    fprintf('[1] 构造 App\n');
    try
        app = PCAirflowSimulatorApp();
        app.SteadyOpts = struct('minSteps', 40, 'maxSteps', 80, 'chunk', 20, 'window', 40);
    catch ME
        errs = logErr(errs, 'construct', ME);
        pass = printReport(errs);
        return;
    end
    errs = expect(errs, numel(app.Solver.fans) == 4, 'construct', '默认布局应有 4 台机箱风扇');
    errs = expect(errs, ~app.LayoutDirty, 'construct', '初始不应有未应用修改');
    shot(app, '01_initial', isOctave, outDir);

    %% 2. 功率场景与视图模式
    fprintf('[2] 场景按钮与视图模式\n');
    errs = act(errs, 'gaming', @() ui_press(app.GamingBtn));
    errs = expect(errs, app.Solver.powerW.gpu == 200, 'gaming', 'GPU 功率应为 200 W');
    modeBtns = {app.ModeTempBtn, app.ModeVorticityBtn, app.ModeSolidBtn, app.ModeDiffBtn, app.ModeVelocityBtn};
    modeNames = {'temperature', 'vorticity', 'solid', 'diff', 'velocity'};
    for k = 1:numel(modeBtns)
        errs = act(errs, ['mode ' modeNames{k}], @() ui_press(modeBtns{k}));
        errs = expect(errs, strcmp(app.VisMode, modeNames{k}), 'mode', ['视图应为 ' modeNames{k}]);
    end
    errs = checkState(app, errs, 'modes', 0);

    %% 3. 推进（手动调用 onTimer）
    fprintf('[3] 推进 30 帧\n');
    it0 = app.Solver.iteration;
    for k = 1:30
        errs = act(errs, 'onTimer', @() app.runTestHook('onTimer'));
    end
    errs = checkState(app, errs, 'frames', it0 + 30);
    errs = act(errs, 'run on', @() ui_press(app.RunButton));
    errs = expect(errs, app.IsRunning && strcmp(char(app.SimTimer.Running), 'on'), 'run', '开始仿真后应在运行');
    errs = act(errs, 'run off', @() ui_press(app.RunButton));
    errs = expect(errs, ~app.IsRunning, 'run', '暂停后应停止');
    errs = act(errs, 'cpu slider', @() ui_slide(app.CPUPowerSlider, 150));
    errs = expect(errs, app.Solver.powerW.cpu == 150, 'cpu slider', 'CPU 功率应为 150 W');
    errs = act(errs, 'tab fans', @() ui_tab(app.TabGroup, app.TabFans));
    errs = expect(errs, size(app.FanTable.Data, 1) == numel(app.Solver.allFans()), 'fan table', '风扇表行数应等于风扇数');
    errs = expect(errs, size(app.FanTable.Data, 2) == 7 && ~isempty(app.NoiseDetailLabel.Text), 'fan table', ...
        '风扇表应有 7 列（含噪音占比）并显示最响风扇的噪音分项');
    shot(app, '02_running', isOctave, outDir);

    %% 4. 风扇布局编辑
    fprintf('[4] 风扇布局：点击安装位、编辑表格、预设、挡板开孔\n');
    errs = act(errs, 'tab layout', @() ui_tab(app.TabGroup, app.TabLayout));
    errs = act(errs, 'click F1', @() ui_click(app.hSlot{1}));
    errs = expect(errs, strcmp(app.SlotStates(1).type, 'intake'), 'click F1', 'F1 应变为进气');
    errs = expect(errs, app.LayoutDirty, 'click F1', '应标记为未应用');
    errs = expect(errs, strcmp(app.SlotTable.Data{1, 3}, '进气'), 'click F1', '表格应同步为 进气');
    errs = act(errs, 'click F1 again', @() ui_click(app.hSlot{1}));
    errs = expect(errs, strcmp(app.SlotStates(1).type, 'exhaust'), 'click F1', 'F1 应变为排气');
    errs = act(errs, 'edit T1 speed', @() ui_edit(app.SlotTable, [4 5], '70%'));
    errs = expect(errs, strcmp(app.SlotStates(4).speedMode, 'manual') && app.SlotStates(4).manualPct == 70, ...
        'edit T1', 'T1 应为手动 70%');
    errs = act(errs, 'edit B1 state', @() ui_edit(app.SlotTable, [7 3], '进气'));
    errs = act(errs, 'edit B1 model', @() ui_edit(app.SlotTable, [7 4], 'NF_A12'));
    errs = expect(errs, strcmp(app.SlotStates(7).type, 'intake') && strcmp(app.SlotStates(7).model, 'NF_A12'), ...
        'edit B1', 'B1 应为进气 NF_A12');
    errs = act(errs, 'revert', @() ui_press(app.RevertLayoutBtn));
    errs = expect(errs, ~app.LayoutDirty && strcmp(app.SlotStates(7).type, 'none'), 'revert', '撤销后应回到已应用布局');
    errs = act(errs, 'edit B1 state', @() ui_edit(app.SlotTable, [7 3], '进气'));
    errs = act(errs, 'edit B1 model', @() ui_edit(app.SlotTable, [7 4], 'NF_A12'));
    errs = act(errs, 'click F1', @() ui_click(app.hSlot{1}));
    errs = act(errs, 'click F1', @() ui_click(app.hSlot{1}));
    errs = act(errs, 'edit T1 speed', @() ui_edit(app.SlotTable, [4 5], '70%'));
    errs = act(errs, 'apply custom', @() ui_press(app.ApplyLayoutBtn));
    errs = expect(errs, numel(app.Solver.fans) == 6 && ~app.LayoutDirty, 'apply custom', '应用后应有 6 台机箱风扇');

    P = fan_presets();
    ft = P(strcmp({P.name}, 'front_top'));
    errs = act(errs, 'choose preset', @() ui_choose(app.PresetDrop, ft.label));
    errs = act(errs, 'load preset', @() ui_press(app.LoadPresetBtn));
    errs = expect(errs, sum(~strcmp({app.SlotStates.type}, 'none')) == 4, 'preset', '前进顶出应有 4 个安装位');
    errs = act(errs, 'shroud gap off', @() ui_check(app.ShroudGapCheck, false));
    errs = act(errs, 'apply preset', @() ui_press(app.ApplyLayoutBtn));
    errs = expect(errs, numel(app.Solver.fans) == 4, 'apply preset', '应用后应有 4 台机箱风扇');
    errs = expect(errs, isempty(app.Solver.layout.shroud.gaps), 'apply preset', '挡板开孔应已关闭');
    errs = expect(errs, strcmp(app.AppliedLabel, ft.label), 'apply preset', '布局名应为预设名');
    it0 = app.Solver.iteration;
    for k = 1:10
        errs = act(errs, 'onTimer', @() app.runTestHook('onTimer'));
    end
    errs = checkState(app, errs, 'after preset', it0 + 10);
    shot(app, '03_layout', isOctave, outDir);

    %% 5. 跑到稳态（测试中限制步数）并保存方案 A
    fprintf('[5] 跑到稳态并保存方案 A\n');
    it0 = app.Solver.iteration;
    errs = act(errs, 'steady', @() ui_press(app.SteadyButton));
    errs = checkState(app, errs, 'steady', it0 + 40);
    errs = expect(errs, ~app.SteadyRunning && strcmp(char(app.RunButton.Enable), 'on'), 'steady', '跑完后应恢复按钮');
    errs = act(errs, 'tab scenario', @() ui_tab(app.TabGroup, app.TabScenario));
    errs = act(errs, 'choose A', @() ui_choose(app.ScenarioDrop, 'A'));
    errs = act(errs, 'save A', @() ui_press(app.SaveScenarioBtn));
    errs = expect(errs, ~isempty(app.Scenarios{1}), 'save A', '方案 A 应已保存');
    errs = expect(errs, strcmp(app.ScenarioTable.Data{12, 2}, ft.short), 'save A', '方案表 A 列布局名（简称）');

    %% 6. 另一布局 → 方案 B → 温差视图
    fprintf('[6] 默认布局 → 方案 B → 温差视图\n');
    errs = act(errs, 'tab layout', @() ui_tab(app.TabGroup, app.TabLayout));
    errs = act(errs, 'choose balanced', @() ui_choose(app.PresetDrop, P(1).label));
    errs = act(errs, 'load balanced', @() ui_press(app.LoadPresetBtn));
    errs = act(errs, 'shroud gap on', @() ui_check(app.ShroudGapCheck, true));
    errs = act(errs, 'apply+steady', @() ui_press(app.ApplySteadyBtn));
    errs = expect(errs, numel(app.Solver.fans) == 4, 'apply+steady', '默认布局应有 4 台机箱风扇');
    errs = expect(errs, ~isempty(app.Solver.layout.shroud.gaps), 'apply+steady', '挡板开孔应已恢复');
    errs = act(errs, 'tab scenario', @() ui_tab(app.TabGroup, app.TabScenario));
    errs = act(errs, 'choose B', @() ui_choose(app.ScenarioDrop, 'B'));
    errs = act(errs, 'save B', @() ui_press(app.SaveScenarioBtn));
    errs = act(errs, 'diff ref A', @() ui_choose(app.DiffRefDrop, 'A'));
    errs = act(errs, 'show diff', @() ui_press(app.ShowDiffBtn));
    errs = expect(errs, strcmp(app.VisMode, 'diff') && app.DiffRef == 1, 'diff', '应为温差视图、参考 A');
    cd = app.hImg.CData;
    errs = expect(errs, all(isfinite(cd(:))) && max(abs(cd(:))) > 0, 'diff', '温差场应有限且非零');
    errs = checkState(app, errs, 'diff', 0);
    shot(app, '04_diff', isOctave, outDir);

    %% 7. JSON 存取与方案载入
    fprintf('[7] JSON 存取、载入方案 A\n');
    f = [tempname() '.json'];
    errs = act(errs, 'save json', @() app.runTestHook('saveLayoutFile', f));
    errs = act(errs, 'click T2', @() ui_click(app.hSlot{5}));
    errs = act(errs, 'load json', @() app.runTestHook('loadLayoutFile', f));
    errs = expect(errs, numel(app.Solver.fans) == 4 && ~app.LayoutDirty, 'load json', '载入后应回到 4 台风扇');
    errs = expect(errs, strcmp(app.SlotStates(5).type, 'none'), 'load json', 'T2 应为空');
    % 失败路径：字段取值错误的 JSON → 报错、布局不变
    nF = numel(app.Solver.fans);
    Lbad = layout_default(); Lbad.caseFans(1).type = 'Intake';
    writeJson(f, Lbad);
    errs = act(errs, 'bad json', @() app.runTestHook('loadLayoutFile', f));
    errs = expect(errs, ~isempty(app.LastError) && numel(app.Solver.fans) == nF && ~app.LayoutDirty, ...
        'bad json', '错误的 JSON 应报错且布局不变');
    app.LastError = '';
    % 失败路径：能读入但无法构建的布局（未知显卡风扇型号）→ 回滚到原求解器
    L0 = app.Solver.layout; it0 = app.Solver.iteration;
    Lbad = layout_default(); Lbad.gpu.fans.model = 'NoSuchFan';
    layout_json('save', Lbad, f);
    errs = act(errs, 'unbuildable json', @() app.runTestHook('loadLayoutFile', f));
    errs = expect(errs, ~isempty(app.LastError) && isequal(app.Solver.layout, L0) && ...
        app.Solver.iteration == it0 && ~app.LayoutDirty, ...
        'unbuildable json', '无法构建的布局应回滚到原求解器');
    app.LastError = '';
    % 缺元件的布局（无显卡）可以载入、推进、显示
    Lng = rmfield(layout_default(), 'gpu');
    layout_json('save', Lng, f);
    errs = act(errs, 'no-gpu json', @() app.runTestHook('loadLayoutFile', f));
    errs = expect(errs, ~app.Solver.hasGpu && ~app.LayoutDirty, 'no-gpu json', '应载入无显卡布局');
    it0 = app.Solver.iteration;
    for k = 1:5
        errs = act(errs, 'onTimer', @() app.runTestHook('onTimer'));
    end
    errs = act(errs, 'tab scenario', @() ui_tab(app.TabGroup, app.TabScenario));
    errs = checkState(app, errs, 'no-gpu', it0 + 5);
    errs = expect(errs, strcmp(app.ScenarioTable.Data{2, 1}, '—'), 'no-gpu', '无显卡时方案表 GPU 应为 —');
    if exist(f, 'file'), delete(f); end
    errs = act(errs, 'choose A', @() ui_choose(app.ScenarioDrop, 'A'));
    errs = act(errs, 'load A', @() ui_press(app.LoadScenarioBtn));
    errs = expect(errs, numel(app.Solver.fans) == 4 && isempty(app.Solver.layout.shroud.gaps), 'load A', ...
        '载入方案 A 后应为 4 台风扇且挡板无开孔');
    errs = act(errs, 'clear B', @() ui_choose(app.ScenarioDrop, 'B'));
    errs = act(errs, 'clear B', @() ui_press(app.ClearScenarioBtn));
    errs = expect(errs, isempty(app.Scenarios{2}), 'clear B', '方案 B 应已清除');

    %% 8. 全局风扇、网格切换、重置
    fprintf('[8] 全局风扇、网格切换、重置\n');
    errs = act(errs, 'fan manual', @() ui_slide(app.FanSpeedSlider, 70));
    errs = expect(errs, ~app.Solver.autoFanEnabled && app.Solver.fanSpeedRatio == 70, 'fan manual', '应为手动 70%');
    errs = act(errs, 'fan auto', @() ui_press(app.AutoFanButton));
    errs = expect(errs, app.Solver.autoFanEnabled, 'fan auto', '应恢复自动');
    errs = act(errs, 'heavy', @() ui_press(app.HeavyBtn));
    errs = act(errs, 'grid fine', @() ui_choose(app.GridDrop, '精确 280²'));
    errs = expect(errs, app.GridScale == 1 && app.Solver.GRID.W == 280, 'grid fine', '应为 280² 网格');
    errs = expect(errs, app.Solver.powerW.gpu == 320 && numel(app.Solver.fans) == 4, 'grid fine', '切换网格应保留功率与布局');
    errs = act(errs, 'mode diff', @() ui_press(app.ModeDiffBtn));  % 参考方案网格不同：应提示而非报错
    it0 = app.Solver.iteration;
    for k = 1:3
        errs = act(errs, 'onTimer', @() app.runTestHook('onTimer'));
    end
    errs = checkState(app, errs, 'fine grid', it0 + 3);
    errs = act(errs, 'grid preview', @() ui_choose(app.GridDrop, '预览 140²'));
    errs = act(errs, 'reset', @() ui_press(app.ResetButton));
    errs = expect(errs, app.Solver.iteration == 0, 'reset', '重置后 iteration 应为 0');
    shot(app, '05_final', isOctave, outDir);

    if ~isempty(app.LastError)
        errs{end+1} = sprintf('[App 回调异常] %s', app.LastError);
    end
    try
        delete(app);
    catch ME
        errs = logErr(errs, 'delete app', ME);
    end
    pass = printReport(errs);
end

% ---------- 模拟用户操作（真实控件与桩对象通用）----------
function ui_press(b)
    f = b.ButtonPushedFcn;
    f(b, []);
end

function ui_choose(dd, value)
    old = dd.Value;
    dd.Value = value;
    f = dd.ValueChangedFcn;
    if ~isempty(f), f(dd, struct('Value', value, 'PreviousValue', old)); end
end

function ui_slide(sl, value)
    old = sl.Value;
    sl.Value = value;
    f = sl.ValueChangedFcn;
    if ~isempty(f), f(sl, struct('Value', value, 'PreviousValue', old)); end
end

function ui_check(cb, value)
    cb.Value = value;
    f = cb.ValueChangedFcn;
    if ~isempty(f), f(cb, struct('Value', value)); end
end

function ui_edit(tbl, rc, value)
    D = tbl.Data;
    old = D{rc(1), rc(2)};
    D{rc(1), rc(2)} = value;
    tbl.Data = D;
    f = tbl.CellEditCallback;
    f(tbl, struct('Indices', rc, 'NewData', value, 'PreviousData', old, 'EditData', value));
end

function ui_click(h)
    f = h.ButtonDownFcn;
    f(h, []);
end

function ui_tab(tg, tab)
    tg.SelectedTab = tab;
    f = tg.SelectionChangedFcn;
    if ~isempty(f), f(tg, struct('NewValue', tab)); end
end

function writeJson(f, L)
    % 不经 layout_json 校验直接写文件（构造错误输入）
    fid = fopen(f, 'w');
    fwrite(fid, jsonencode(L));
    fclose(fid);
end

% ---------- 检查与报告 ----------
function errs = act(errs, stage, fcn)
    try
        fcn();
    catch ME
        errs = logErr(errs, stage, ME);
    end
end

function errs = expect(errs, cond, stage, msg)
    if ~cond
        errs{end+1} = sprintf('[%s] %s', stage, msg);
        fprintf(2, '*** FAIL @ %s: %s\n', stage, msg);
    end
end

function errs = checkState(app, errs, stage, minIter)
    % 推进确实发生、场无 NaN/Inf、回调未吞异常
    if app.Solver.iteration < minIter
        errs{end+1} = sprintf('[%s] iteration=%d < %d（推进未发生，可能被回调吞掉异常）', ...
            stage, app.Solver.iteration, minIter);
    end
    if ~all(isfinite(app.Solver.T_fluid)) || ~all(isfinite(app.Solver.uF))
        errs{end+1} = sprintf('[%s] 场中出现 NaN/Inf', stage);
    end
    if ~isempty(app.LastError)
        errs{end+1} = sprintf('[%s] App 回调异常：%s', stage, app.LastError);
        app.LastError = '';
    end
end

function errs = logErr(errs, stage, ME)
    errs{end+1} = sprintf('[%s] %s', stage, ME.message);
    fprintf(2, '*** ERROR @ %s: %s\n', stage, ME.message);
    for s = 1:numel(ME.stack)
        fprintf(2, '    at %s:%d\n', ME.stack(s).name, ME.stack(s).line);
    end
end

function shot(app, name, isOctave, outDir)
    if isOctave, return; end
    try
        exportapp(app.UIFigure, fullfile(outDir, sprintf('ui_%s.png', name)));
        fprintf('  → ui_%s.png\n', name);
    catch ME
        fprintf(2, '截图失败 %s：%s\n', name, ME.message);
    end
end

function out = ternary(c, a, b)
    if c, out = a; else, out = b; end
end

function pass = printReport(errs)
    fprintf('\n=== UI test report ===\n');
    pass = isempty(errs);
    if pass
        fprintf('PASSED: 0 errors\n');
    else
        fprintf('FAILED: %d errors\n', numel(errs));
        for k = 1:numel(errs)
            fprintf('  - %s\n', errs{k});
        end
    end
end
