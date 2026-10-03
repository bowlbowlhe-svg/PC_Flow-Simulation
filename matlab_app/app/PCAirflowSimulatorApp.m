classdef PCAirflowSimulatorApp < handle
    %PCAIRFLOWSIMULATORAPP PC 风道仿真器 MATLAB App（版本见 pcflow_version）。
    %   2D 不可压 Navier–Stokes + k-ω 湍流 + 共轭传热的交互式可视化。
    %   左侧：流场主视图（点击机箱风扇安装位可切换 空 → 进气 → 排气；粒子示踪、开口风量标注、
    %   悬停读数）、工具栏（下方图切换、粒子、标注、导出 PNG/GIF）、温度曲线或风扇工作点图。
    %   右侧：常驻的视图与运行控制，下方四个标签页：
    %     状态       实时温度、评分、CFD 诊断、智能诊断
    %     功率与风扇 元件功率、全局风扇转速、各风扇工作状态（转速/风量/静压/噪音）
    %     风扇布局   7 个安装位的 空/进气/排气、型号、转速；预设；电源仓挡板开孔；JSON 存取
    %     方案对比   保存 A/B/C 三个方案逐项对比，温差视图（当前 − 参考方案）

    properties (Constant)
        STATE_ITEMS = {'空', '进气', '排气'}
        STATE_KEYS  = {'none', 'intake', 'exhaust'}
        MODEL_ITEMS = {'P12', 'P14', 'NF_A12', 'NF_A14', 'RX120', 'RX140', 'Stock120'}
        SPEED_ITEMS = {'自动', '30%', '40%', '50%', '60%', '70%', '80%', '90%', '100%'}
        SCENARIO_NAMES = {'A', 'B', 'C'}
        GPU_SLOT_ITEMS = {'2.5 槽（51 mm）', '3 槽（61 mm）', '3.5 槽（71 mm）', '4 槽（81 mm）'}
        GPU_SLOT_VALUES = [2.5 3 3.5 4]
    end

    properties (Access = public)
        UIFigure      matlab.ui.Figure
        MainAxes      matlab.ui.control.UIAxes
        SideAxes      matlab.ui.control.UIAxes
        TabGroup      matlab.ui.container.TabGroup
        TabStatus     matlab.ui.container.Tab
        TabFans       matlab.ui.container.Tab
        TabLayout     matlab.ui.container.Tab
        TabScenario   matlab.ui.container.Tab

        % ----- 状态页 -----
        IntakeTempLabel    matlab.ui.control.Label
        TopExhaustLabel    matlab.ui.control.Label
        SideExhaustLabel   matlab.ui.control.Label
        InternalTempLabel  matlab.ui.control.Label
        NoiseLabel         matlab.ui.control.Label
        PerformanceLabel   matlab.ui.control.Label
        CPUTempLabel       matlab.ui.control.Label
        GPUTempLabel       matlab.ui.control.Label
        TotalScoreLabel    matlab.ui.control.Label
        ScoreCoolingLabel  matlab.ui.control.Label
        ScorePerfLabel     matlab.ui.control.Label
        ScoreBalanceLabel  matlab.ui.control.Label
        ScoreMarginLabel   matlab.ui.control.Label
        ScoreNoiseLabel    matlab.ui.control.Label
        ScoreValueLabel    matlab.ui.control.Label
        ReynoldsLabel      matlab.ui.control.Label
        GrashofLabel       matlab.ui.control.Label
        NusseltLabel       matlab.ui.control.Label
        FlowRegimeLabel    matlab.ui.control.Label
        RayleighLabel      matlab.ui.control.Label
        DeadZoneLabel      matlab.ui.control.Label
        RecTextArea        matlab.ui.control.TextArea

        % ----- 功率与风扇页 -----
        CPUPowerSlider     matlab.ui.control.Slider
        GPUPowerSlider     matlab.ui.control.Slider
        PSUPowerSlider     matlab.ui.control.Slider
        FanSpeedSlider     matlab.ui.control.Slider
        CPUPowerLbl        matlab.ui.control.Label
        GPUPowerLbl        matlab.ui.control.Label
        PSUPowerLbl        matlab.ui.control.Label
        FanSpeedLbl        matlab.ui.control.Label
        AutoFanButton      matlab.ui.control.Button
        DailyBtn           matlab.ui.control.Button
        GamingBtn          matlab.ui.control.Button
        HeavyBtn           matlab.ui.control.Button
        FanTable           matlab.ui.control.Table
        NoiseDetailLabel   matlab.ui.control.Label

        % ----- 风扇布局页 -----
        SlotTable          matlab.ui.control.Table
        PresetDrop         matlab.ui.control.DropDown
        LoadPresetBtn      matlab.ui.control.Button
        ShroudGapCheck     matlab.ui.control.CheckBox
        GpuSlotsDrop       matlab.ui.control.DropDown
        LayoutInfoLabel    matlab.ui.control.Label
        LayoutWarnArea     matlab.ui.control.TextArea
        ApplyLayoutBtn     matlab.ui.control.Button
        ApplySteadyBtn     matlab.ui.control.Button
        RevertLayoutBtn    matlab.ui.control.Button
        SaveJsonBtn        matlab.ui.control.Button
        LoadJsonBtn        matlab.ui.control.Button

        % ----- 方案对比页 -----
        ScenarioDrop       matlab.ui.control.DropDown
        SaveScenarioBtn    matlab.ui.control.Button
        LoadScenarioBtn    matlab.ui.control.Button
        ClearScenarioBtn   matlab.ui.control.Button
        ScenarioTable      matlab.ui.control.Table
        DiffRefDrop        matlab.ui.control.DropDown
        ShowDiffBtn        matlab.ui.control.Button

        % ----- 视图与操作（常驻）-----
        ModeVelocityBtn    matlab.ui.control.Button
        ModeTempBtn        matlab.ui.control.Button
        ModeVorticityBtn   matlab.ui.control.Button
        ModeSolidBtn       matlab.ui.control.Button
        ModeDiffBtn        matlab.ui.control.Button
        ModePressureBtn    matlab.ui.control.Button

        % ----- 主视图工具栏 -----
        HoverLabel         matlab.ui.control.Label
        SideModeDrop       matlab.ui.control.DropDown
        ParticleCheck      matlab.ui.control.CheckBox
        LabelCheck         matlab.ui.control.CheckBox
        ExportPngBtn       matlab.ui.control.Button
        GifBtn             matlab.ui.control.Button
        RunButton          matlab.ui.control.Button
        SteadyButton       matlab.ui.control.Button
        ResetButton        matlab.ui.control.Button
        GridDrop           matlab.ui.control.DropDown

        % ----- 核心求解器与运行状态 -----
        Solver         CFDSolverFEM
        SimTimer       timer
        IsRunning      logical = false
        VisMode        char = 'velocity'   % 'velocity','temperature','pressure','vorticity','solid','diff'
        StepsPerFrame  double = 2
        GridScale      double = 0.5        % 0.5 = 预览 140²，1 = 精确 280²
        SteadyRunning  logical = false
        CancelSteady   logical = false
        StepPending    logical = false     % 防止 timer 堆积
        SteadyIter     double = -1         % 最近一次判定稳态时的累计步数（-1 = 未稳态）
        SteadyOpts = struct()              % 附加的 runToSteady 选项（测试用于限制步数）
        QuietAlerts logical = false        % true：出错只记录 LastError 并打印，不弹对话框（测试用）
        StatusMsg      char = ''           % 最近一次跑稳态的结果（显示在温度曲线标题）

        % ----- 风扇布局编辑 -----
        PendingBase                        % 待应用布局的基底（机箱风扇以外的部分）
        SlotStates                         % 各安装位的待应用状态（layout_slots 'get' 格式）
        LayoutDirty    logical = false     % 有未应用的修改
        LayoutLabel    char = ''           % 待应用布局的名称（预设名 / 自定义 / 配置文件）
        AppliedLabel   char = ''           % 当前求解器布局的名称
        DefaultGaps                        % 电源仓挡板"前部开孔"勾选时使用的缺口
        Scenarios = cell(1, 3)             % 已保存方案快照（A/B/C），空位为 []
        DiffRef        double = 1          % 温差视图的参考方案序号

        % ----- 预渲染图形句柄 -----
        hImg
        hCbar
        hContour
        hParticles          % 粒子尾迹（一个 line，NaN 分隔）
        hHeads              % 粒子头部
        hOpenLabels = {}    % 开口风量标注
        hSideLine = {}      % CPU/GPU/后侧排气温度曲线
        hPQ = {}            % 风扇工作点图：每台风扇 {曲线, 工作点}

        % ----- 可视化状态 -----
        Tracer              % ParticleTracer
        ParticleTimer       % 暂停时驱动粒子动画的定时器
        SideMode char = 'temp'   % 'temp'（温度曲线）| 'pq'（风扇工作点）
        GifFile char = ''        % 正在录制的 GIF 文件（空 = 未录制）
        GifFrames double = 0
        GifSkip double = 0
        GifSize = []             % 第一帧的像素尺寸，后续帧裁剪/填充到同一尺寸
        GifMap = []              % GIF 调色板（录制开始时由当前色表与界面颜色组成）
        OpenMarkers = []         % 最近一次的开口风量（openingMarkers），安装位文字与标注共用
        LastHoverIdx double = 0
        ParticleTicks double = 0
        hSlot = {}          % 安装位标记（patch）
        hSlotText = {}      % 安装位文字

        % ----- 温度曲线历史 -----
        timeHistory = []
        cpuTempHistory = []
        gpuTempHistory = []
        rearExhaustTempHistory = []
        maxHistoryPoints = 300

        % 最近一次被回调捕获的异常（test_ui 检查；正常运行只打印不中断）
        LastError = ''
    end

    methods (Access = private)
        % ================= 界面构建 =================
        function createComponents(app)
            bg = [0.05 0.05 0.08];
            % 窗口 1200×850 居中放在屏幕内；屏幕放不下时可滚动查看（控件是绝对坐标，不随窗口缩放）
            scr = [1 1 1920 1080];
            try
                scr = get(groot, 'ScreenSize');
            catch
            end
            figW = 1200; figH = 850;
            figPos = [max(1, floor((scr(3) - figW)/2)), max(1, scr(4) - figH - 70), figW, figH];
            app.UIFigure = uifigure('Name', ['PC风道仿真器 v' pcflow_version()], 'Position', figPos, ...
                'Color', [0.02 0.02 0.05], 'WindowStyle', 'normal', 'Scrollable', 'on');

            % ========== 左侧可视化面板 ==========
            mainPanel = uipanel(app.UIFigure, 'Position', [10 10 750 830], ...
                'BackgroundColor', bg, 'BorderType', 'line', 'HighlightColor', [0.1 0.1 0.2]);

            app.MainAxes = uiaxes(mainPanel, 'Position', [10 420 730 400], ...
                'Color', bg, 'XColor', [0.3 0.3 0.4], 'YColor', [0.3 0.3 0.4]);
            title(app.MainAxes, '流场仿真', 'Color', [0.8 0.8 1], 'FontSize', 12);
            app.MainAxes.XTick = []; app.MainAxes.YTick = [];
            axis(app.MainAxes, 'equal', 'tight');
            hold(app.MainAxes, 'on');
            disableDefaultInteractivity(app.MainAxes);

            % 主视图与下方图之间的工具栏
            app.HoverLabel = uilabel(mainPanel, 'Position', [10 388 300 22], 'Text', '移动鼠标查看读数', ...
                'FontColor', [0.7 0.7 0.8], 'FontSize', 10);
            app.SideModeDrop = uidropdown(mainPanel, 'Position', [315 388 100 22], ...
                'Items', {'温度曲线', '风扇工作点'}, 'Value', '温度曲线', 'FontSize', 10, ...
                'ValueChangedFcn', @(src,event)app.setSideMode());
            app.ParticleCheck = uicheckbox(mainPanel, 'Position', [423 388 55 22], 'Text', '粒子', ...
                'Value', true, 'FontColor', [0.8 0.8 0.8], 'FontSize', 10, ...
                'ValueChangedFcn', @(src,event)app.onParticleToggle());
            app.LabelCheck = uicheckbox(mainPanel, 'Position', [480 388 80 22], 'Text', '风量标注', ...
                'Value', true, 'FontColor', [0.8 0.8 0.8], 'FontSize', 10, ...
                'ValueChangedFcn', @(src,event)app.updateOpeningLabels());
            app.ExportPngBtn = app.plainButton(mainPanel, [565 388 80 22], '导出 PNG', @(src,event)app.exportPngDialog());
            app.GifBtn = app.plainButton(mainPanel, [650 388 90 22], '● 录制 GIF', @(src,event)app.toggleGif());

            app.SideAxes = uiaxes(mainPanel, 'Position', [10 10 730 370], ...
                'Color', bg, 'XColor', [0.3 0.3 0.4], 'YColor', [0.3 0.3 0.4]);
            title(app.SideAxes, '温度曲线', 'Color', [0.8 0.8 1], 'FontSize', 12);
            app.SideAxes.XTick = []; app.SideAxes.YTick = [];
            hold(app.SideAxes, 'on');
            disableDefaultInteractivity(app.SideAxes);

            % 用空 ContextMenu 覆盖内置 WebContextMenuController，避免右键时报错
            cm = uicontextmenu(app.UIFigure);
            app.UIFigure.ContextMenu = cm;
            app.MainAxes.ContextMenu = cm;
            app.SideAxes.ContextMenu = cm;

            % ========== 右侧控制面板 ==========
            ctrlPanel = uipanel(app.UIFigure, 'Position', [770 10 420 830], ...
                'BackgroundColor', bg, 'BorderType', 'line', 'HighlightColor', [0.1 0.1 0.2]);
            uilabel(ctrlPanel, 'Position', [10 800 400 25], ...
                'Text', ['PC风道仿真器 v' pcflow_version()], 'FontSize', 16, 'FontWeight', 'bold', ...
                'FontColor', [0.27 0.53 1], 'HorizontalAlignment', 'center');

            app.createViewPanel(ctrlPanel);

            app.TabGroup = uitabgroup(ctrlPanel, 'Position', [10 10 400 672], ...
                'SelectionChangedFcn', @(src,event)app.onTabChanged());
            app.TabStatus   = uitab(app.TabGroup, 'Title', '状态', 'BackgroundColor', bg);
            app.TabFans     = uitab(app.TabGroup, 'Title', '功率与风扇', 'BackgroundColor', bg);
            app.TabLayout   = uitab(app.TabGroup, 'Title', '风扇布局', 'BackgroundColor', bg);
            app.TabScenario = uitab(app.TabGroup, 'Title', '方案对比', 'BackgroundColor', bg);
            app.createStatusTab(app.TabStatus);
            app.createFansTab(app.TabFans);
            app.createLayoutTab(app.TabLayout);
            app.createScenarioTab(app.TabScenario);

            % 窗口关闭时自动停止 timer；鼠标移动时显示主视图读数
            app.UIFigure.CloseRequestFcn = @(src,event)app.closeApp();
            app.UIFigure.WindowButtonMotionFcn = @(src,event)app.onHover();
        end

        function p = sectionPanel(~, parent, pos, titleText)
            p = uipanel(parent, 'Position', pos, 'BackgroundColor', [0.07 0.07 0.12], ...
                'BorderType', 'line', 'Title', titleText, 'TitlePosition', 'centertop', ...
                'FontSize', 11, 'ForegroundColor', [0 0.83 1], 'HighlightColor', [0.1 0.1 0.2]);
        end

        function b = plainButton(~, parent, pos, text, fcn)
            b = uibutton(parent, 'Position', pos, 'Text', text, 'FontSize', 10, ...
                'BackgroundColor', [0.1 0.1 0.2], 'FontColor', [0.8 0.8 0.8], 'ButtonPushedFcn', fcn);
        end

        function createViewPanel(app, parent)
            pView = app.sectionPanel(parent, [10 690 400 105], '视图与操作');
            x = 8 + (0:5) * 64;
            app.ModeVelocityBtn  = app.plainButton(pView, [x(1) 55 62 22], '速度',     @(src,event)app.setMode('velocity'));
            app.ModeTempBtn      = app.plainButton(pView, [x(2) 55 62 22], '温度',     @(src,event)app.setMode('temperature'));
            app.ModePressureBtn  = app.plainButton(pView, [x(3) 55 62 22], '压力',     @(src,event)app.setMode('pressure'));
            app.ModeVorticityBtn = app.plainButton(pView, [x(4) 55 62 22], '涡量',     @(src,event)app.setMode('vorticity'));
            app.ModeSolidBtn     = app.plainButton(pView, [x(5) 55 62 22], '固体温度', @(src,event)app.setMode('solid'));
            app.ModeDiffBtn      = app.plainButton(pView, [x(6) 55 62 22], '温差',     @(src,event)app.setMode('diff'));
            app.ModeVelocityBtn.BackgroundColor = [0 0.2 0.3];
            app.ModeVelocityBtn.FontColor = [0 0.83 1];

            app.RunButton = uibutton(pView, 'Position', [10 25 120 26], 'Text', '▶ 开始仿真', 'FontSize', 11, ...
                'BackgroundColor', [0 0.4 0.6], 'FontColor', [1 1 1], 'FontWeight', 'bold', ...
                'ButtonPushedFcn', @(src,event)app.toggleRun());
            app.SteadyButton = uibutton(pView, 'Position', [140 25 120 26], 'Text', '⏩ 跑到稳态', 'FontSize', 11, ...
                'BackgroundColor', [0.1 0.1 0.2], 'FontColor', [0.8 0.8 0.8], ...
                'ButtonPushedFcn', @(src,event)app.solveSteady());
            app.ResetButton = uibutton(pView, 'Position', [270 25 120 26], 'Text', '重置', 'FontSize', 11, ...
                'BackgroundColor', [0.1 0.1 0.2], 'FontColor', [0.8 0.8 0.8], ...
                'ButtonPushedFcn', @(src,event)app.resetSim());

            uilabel(pView, 'Position', [10 3 40 18], 'Text', '网格', 'FontColor', [0.8 0.8 0.8], 'FontSize', 10);
            app.GridDrop = uidropdown(pView, 'Position', [45 3 110 20], 'Items', {'预览 140²', '精确 280²'}, ...
                'Value', '预览 140²', 'FontSize', 10, 'ValueChangedFcn', @(src,event)app.setGrid());
            uilabel(pView, 'Position', [165 3 225 18], ...
                'Text', '⚠ 2D 定性模型，仅供理解风道趋势', 'FontColor', [0.85 0.55 0.2], 'FontSize', 9);
        end

        function createStatusTab(app, tab)
            fg = [0.8 0.8 0.8];
            pStatus = app.sectionPanel(tab, [5 555 388 80], '实时状态');
            app.IntakeTempLabel   = uilabel(pStatus, 'Position', [10 35 90 20],  'Text', '进气: --°C', 'FontColor', [0.27 0.53 1], 'FontSize', 11);
            app.TopExhaustLabel   = uilabel(pStatus, 'Position', [103 35 90 20], 'Text', '顶排: --°C', 'FontColor', [1 0.4 0.27], 'FontSize', 11);
            app.SideExhaustLabel  = uilabel(pStatus, 'Position', [196 35 90 20], 'Text', '后排: --°C', 'FontColor', [1 0.4 0.27], 'FontSize', 11);
            app.InternalTempLabel = uilabel(pStatus, 'Position', [289 35 95 20], 'Text', '内部: --°C', 'FontColor', [0.67 0.53 1], 'FontSize', 11);
            app.NoiseLabel        = uilabel(pStatus, 'Position', [10 10 90 20],  'Text', '噪音: --dB', 'FontColor', [1 0.8 0], 'FontSize', 11);
            app.PerformanceLabel  = uilabel(pStatus, 'Position', [103 10 90 20], 'Text', '性能: --%', 'FontColor', [0 1 0.53], 'FontSize', 11);
            app.CPUTempLabel      = uilabel(pStatus, 'Position', [196 10 90 20], 'Text', 'CPU: --°C', 'FontColor', fg, 'FontSize', 11);
            app.GPUTempLabel      = uilabel(pStatus, 'Position', [289 10 95 20], 'Text', 'GPU: --°C', 'FontColor', fg, 'FontSize', 11);

            pScore = app.sectionPanel(tab, [5 465 388 80], '综合评分');
            app.TotalScoreLabel   = uilabel(pScore, 'Position', [10 35 120 25], 'Text', '总分: --/100', 'FontSize', 16, 'FontWeight', 'bold', 'FontColor', [1 1 1]);
            app.ScoreCoolingLabel = uilabel(pScore, 'Position', [140 35 80 20], 'Text', '散热: --', 'FontColor', fg, 'FontSize', 11);
            app.ScorePerfLabel    = uilabel(pScore, 'Position', [225 35 80 20], 'Text', '性能: --', 'FontColor', fg, 'FontSize', 11);
            app.ScoreBalanceLabel = uilabel(pScore, 'Position', [310 35 75 20], 'Text', '均衡: --', 'FontColor', fg, 'FontSize', 11);
            app.ScoreMarginLabel  = uilabel(pScore, 'Position', [140 10 80 20], 'Text', '余量: --', 'FontColor', fg, 'FontSize', 11);
            app.ScoreNoiseLabel   = uilabel(pScore, 'Position', [225 10 80 20], 'Text', '噪音: --', 'FontColor', fg, 'FontSize', 11);
            app.ScoreValueLabel   = uilabel(pScore, 'Position', [310 10 75 20], 'Text', '性价比: --', 'FontColor', fg, 'FontSize', 11);

            pCFD = app.sectionPanel(tab, [5 345 388 110], 'CFD诊断');
            c = [0 0.83 1];
            app.ReynoldsLabel   = uilabel(pCFD, 'Position', [10 65 120 18],  'Text', 'Re: --', 'FontColor', c, 'FontSize', 11);
            app.GrashofLabel    = uilabel(pCFD, 'Position', [135 65 120 18], 'Text', 'Gr: --', 'FontColor', c, 'FontSize', 11);
            app.NusseltLabel    = uilabel(pCFD, 'Position', [260 65 120 18], 'Text', 'Nu: --', 'FontColor', c, 'FontSize', 11);
            app.FlowRegimeLabel = uilabel(pCFD, 'Position', [10 40 370 18],  'Text', '流动状态: --', 'FontColor', c, 'FontSize', 11);
            app.RayleighLabel   = uilabel(pCFD, 'Position', [10 15 120 18],  'Text', 'Ra: --', 'FontColor', c, 'FontSize', 11);
            app.DeadZoneLabel   = uilabel(pCFD, 'Position', [135 15 150 18], 'Text', '死区: --%', 'FontColor', [1 0.2 0.53], 'FontSize', 11);

            pRec = app.sectionPanel(tab, [5 5 388 330], '智能诊断');
            app.RecTextArea = uitextarea(pRec, 'Position', [8 8 372 292], 'Editable', 'off', ...
                'BackgroundColor', [0.07 0.07 0.12], 'FontColor', fg, 'FontSize', 11);
        end

        function createFansTab(app, tab)
            fg = [0.8 0.8 0.8];
            pPower = app.sectionPanel(tab, [5 525 388 110], '功率调整');
            uilabel(pPower, 'Position', [10 70 40 18], 'Text', 'CPU', 'FontColor', fg, 'FontSize', 11);
            app.CPUPowerSlider = uislider(pPower, 'Position', [60 78 170 3], 'Limits', [20 250], 'Value', 125);
            app.CPUPowerSlider.ValueChangedFcn = @(src,event)app.CPUPowerSliderValueChanged(event);
            app.CPUPowerLbl = uilabel(pPower, 'Position', [240 70 50 18], 'Text', '125W', 'FontColor', fg, 'FontSize', 11);

            uilabel(pPower, 'Position', [10 40 40 18], 'Text', 'GPU', 'FontColor', fg, 'FontSize', 11);
            app.GPUPowerSlider = uislider(pPower, 'Position', [60 48 170 3], 'Limits', [20 400], 'Value', 250);
            app.GPUPowerSlider.ValueChangedFcn = @(src,event)app.GPUPowerSliderValueChanged(event);
            app.GPUPowerLbl = uilabel(pPower, 'Position', [240 40 50 18], 'Text', '250W', 'FontColor', fg, 'FontSize', 11);

            uilabel(pPower, 'Position', [10 10 50 18], 'Text', '电源负载', 'FontColor', fg, 'FontSize', 10);
            app.PSUPowerSlider = uislider(pPower, 'Position', [60 18 170 3], 'Limits', [50 1200], 'Value', 450);
            app.PSUPowerSlider.ValueChangedFcn = @(src,event)app.PSUPowerSliderValueChanged(event);
            app.PSUPowerLbl = uilabel(pPower, 'Position', [240 10 50 18], 'Text', '450W', 'FontColor', fg, 'FontSize', 11);

            app.DailyBtn  = app.plainButton(pPower, [300 62 78 22], '办公', @(src,event)app.setScenario('daily'));
            app.GamingBtn = app.plainButton(pPower, [300 34 78 22], '游戏', @(src,event)app.setScenario('gaming'));
            app.HeavyBtn  = app.plainButton(pPower, [300 6 78 22],  '满载', @(src,event)app.setScenario('heavy'));

            pFan = app.sectionPanel(tab, [5 445 388 70], '风扇转速（"自动"档风扇）');
            app.AutoFanButton = uibutton(pFan, 'Position', [10 12 60 25], 'Text', '自动', 'FontSize', 10, ...
                'BackgroundColor', [0 0.2 0.3], 'FontColor', [0 0.83 1], 'ButtonPushedFcn', @(src,event)app.toggleAutoFan());
            uilabel(pFan, 'Position', [80 15 40 18], 'Text', '手动', 'FontColor', fg, 'FontSize', 11);
            app.FanSpeedSlider = uislider(pFan, 'Position', [120 23 170 3], 'Limits', [0 100], 'Value', 40);
            app.FanSpeedSlider.ValueChangedFcn = @(src,event)app.FanSpeedSliderValueChanged(event);
            app.FanSpeedLbl = uilabel(pFan, 'Position', [305 15 50 18], 'Text', '40%', 'FontColor', fg, 'FontSize', 11);

            pList = app.sectionPanel(tab, [5 5 388 430], '各风扇工作状态');
            app.FanTable = uitable(pList, 'Position', [8 95 372 300], ...
                'ColumnName', {'风扇', '转速', '实测CFM', '自由CFM', '静压Pa', '噪音dB', '占比%'}, ...
                'ColumnWidth', {96, 44, 50, 50, 44, 44, 40}, 'RowName', {}, 'FontSize', 10, ...
                'Data', cell(0, 7));
            app.NoiseDetailLabel = uilabel(pList, 'Position', [8 50 372 40], 'Text', '', ...
                'FontColor', [1 0.8 0], 'FontSize', 10, 'VerticalAlignment', 'top');
            uilabel(pList, 'Position', [8 5 372 42], 'FontColor', [0.6 0.6 0.7], 'FontSize', 9, ...
                'VerticalAlignment', 'top', 'Text', sprintf([ ...
                '实测 = 穿过风扇的流量；自由 = 当前转速下的自由风量（无阻力）；静压 = 工作点压升。\n' ...
                '噪音 = 听音位置（机箱前侧 1 m）单扇声压级 = 转速 + 工作点（背压过高/近失速）\n' ...
                '+ 格栅/滤网 + 位置修正；占比 = 声能占总噪音的百分比。']));
        end

        function createLayoutTab(app, tab)
            fg = [0.8 0.8 0.8];
            uilabel(tab, 'Position', [10 615 380 22], 'FontColor', [0.6 0.6 0.7], 'FontSize', 10, ...
                'Text', '编辑表格，或点击主视图中的风扇位（空 → 进气 → 排气）');
            app.SlotTable = uitable(tab, 'Position', [5 370 388 242], ...
                'ColumnName', {'位', '位置', '状态', '型号', '转速'}, ...
                'ColumnWidth', {40, 52, 70, 100, 70}, 'RowName', {}, 'FontSize', 10, ...
                'ColumnEditable', [false false true true true], ...
                'ColumnFormat', {'char', 'char', app.STATE_ITEMS, app.MODEL_ITEMS, app.SPEED_ITEMS}, ...
                'Data', cell(0, 5), 'CellEditCallback', @(src,event)app.onSlotEdit(event));

            P = fan_presets();
            uilabel(tab, 'Position', [10 338 40 22], 'Text', '预设', 'FontColor', fg, 'FontSize', 11);
            app.PresetDrop = uidropdown(tab, 'Position', [50 338 240 22], 'Items', {P.label}, ...
                'Value', P(1).label, 'FontSize', 10);
            app.LoadPresetBtn = app.plainButton(tab, [298 338 90 22], '载入预设', @(src,event)app.loadPreset());

            app.ShroudGapCheck = uicheckbox(tab, 'Position', [10 308 180 22], 'Value', true, ...
                'Text', '电源仓挡板前部开孔', 'FontColor', fg, 'FontSize', 10, ...
                'ValueChangedFcn', @(src,event)app.layoutEdited(false));
            uilabel(tab, 'Position', [196 308 55 22], 'Text', '显卡厚度', 'FontColor', fg, 'FontSize', 10);
            app.GpuSlotsDrop = uidropdown(tab, 'Position', [252 308 136 22], 'Items', app.GPU_SLOT_ITEMS, ...
                'Value', app.GPU_SLOT_ITEMS{end}, 'FontSize', 10, ...
                'ValueChangedFcn', @(src,event)app.layoutEdited(false));

            app.LayoutInfoLabel = uilabel(tab, 'Position', [10 258 380 46], 'Text', '', ...
                'FontColor', [0 0.83 1], 'FontSize', 11, 'VerticalAlignment', 'top');
            app.LayoutWarnArea = uitextarea(tab, 'Position', [10 170 378 86], 'Editable', 'off', ...
                'BackgroundColor', [0.07 0.07 0.12], 'FontColor', [1 0.75 0.3], 'FontSize', 10);

            app.ApplyLayoutBtn = uibutton(tab, 'Position', [10 128 185 32], 'Text', '应用布局', 'FontSize', 11, ...
                'BackgroundColor', [0 0.4 0.6], 'FontColor', [1 1 1], 'FontWeight', 'bold', ...
                'ButtonPushedFcn', @(src,event)app.applyLayout(false));
            app.ApplySteadyBtn = uibutton(tab, 'Position', [203 128 185 32], 'Text', '应用并跑到稳态', 'FontSize', 11, ...
                'BackgroundColor', [0 0.4 0.6], 'FontColor', [1 1 1], 'FontWeight', 'bold', ...
                'ButtonPushedFcn', @(src,event)app.applyLayout(true));
            app.RevertLayoutBtn = app.plainButton(tab, [10 90 185 28], '撤销未应用的修改', @(src,event)app.revertLayout());
            app.SaveJsonBtn = app.plainButton(tab, [10 52 185 28], '保存配置（JSON）', @(src,event)app.saveLayoutDialog());
            app.LoadJsonBtn = app.plainButton(tab, [203 52 185 28], '载入配置（JSON）', @(src,event)app.loadLayoutDialog());
            uilabel(tab, 'Position', [10 8 380 36], 'FontColor', [0.6 0.6 0.7], 'FontSize', 9, ...
                'Text', sprintf('应用布局会按当前功率重建流场（从静止开始）。\n配置文件包含整个布局、功率与各风扇转速设置。'));
        end

        function createScenarioTab(app, tab)
            fg = [0.8 0.8 0.8];
            uilabel(tab, 'Position', [10 612 36 22], 'Text', '方案', 'FontColor', fg, 'FontSize', 11);
            app.ScenarioDrop = uidropdown(tab, 'Position', [48 612 56 22], 'Items', app.SCENARIO_NAMES, ...
                'Value', 'A', 'FontSize', 10);
            app.SaveScenarioBtn  = app.plainButton(tab, [110 612 90 22], '保存当前', @(src,event)app.saveScenario());
            app.LoadScenarioBtn  = app.plainButton(tab, [205 612 90 22], '载入布局', @(src,event)app.loadScenario());
            app.ClearScenarioBtn = app.plainButton(tab, [300 612 88 22], '清除', @(src,event)app.clearScenario());

            [rowNames, data] = scenario_table(cell(1, 4));
            app.ScenarioTable = uitable(tab, 'Position', [5 232 388 372], ...
                'ColumnName', [{'当前'}, app.SCENARIO_NAMES], 'RowName', rowNames, ...
                'ColumnWidth', {66, 66, 66, 66}, 'FontSize', 10, 'Data', data);

            uilabel(tab, 'Position', [10 196 110 22], 'Text', '温差视图：当前 −', 'FontColor', fg, 'FontSize', 11);
            app.DiffRefDrop = uidropdown(tab, 'Position', [122 196 56 22], 'Items', app.SCENARIO_NAMES, ...
                'Value', 'A', 'FontSize', 10, 'ValueChangedFcn', @(src,event)app.onDiffRefChanged());
            app.ShowDiffBtn = app.plainButton(tab, [186 196 100 22], '显示温差', @(src,event)app.setMode('diff'));

            uilabel(tab, 'Position', [10 100 378 84], 'FontColor', [0.6 0.6 0.7], 'FontSize', 10, ...
                'VerticalAlignment', 'top', 'Text', sprintf([ ...
                '用法：先"跑到稳态"，把结果保存为方案 A；\n' ...
                '改布局、风扇或功率后再跑到稳态，保存为方案 B，\n' ...
                '表中逐项对比。"载入布局"可回到某个方案继续调整。\n' ...
                '温差视图 = 当前温度场 − 参考方案（需同一网格精度），\n' ...
                '红色表示当前更热。未到稳态的方案"稳态"一栏显示"否"。']));
        end

        % ================= 静态图形 =================
        function initStaticGraphics(app)
            ax = app.MainAxes;
            s = app.Solver;
            W = s.GRID.W; H = s.GRID.H;

            % 预创建图像对象（坐标轴范围 [1 W] x [1 H]）
            app.hImg = imagesc(ax, [1 W], [1 H], zeros(W, H));
            axis(ax, 'image');
            ax.YDir = 'reverse';  % y=1 在顶（顶排风扇），y=H 在底（PSU 在左下角）
            ax.XTick = []; ax.YTick = [];
            hold(ax, 'on');

            app.hCbar = colorbar(ax, 'eastoutside');
            app.hCbar.Color = [0.7 0.7 0.8];
            app.hCbar.Label.Color = [0.7 0.7 0.8];
            app.hCbar.FontSize = 7;

            % 等温线由 updateVisualizations 按需创建
            app.hContour = [];

            % ========== 静态几何（仅绘制一次）==========
            plotRect = @(x,y,w,h,col,lw) plot(ax, [x x+w x+w x x], [y y y+h y+h y], 'Color', col, 'LineWidth', lw, 'PickableParts', 'none');
            lb = @(x,y,w,h,t,col,sz) text(ax, x+w/2, y+h/2, t, 'Color', col, 'FontSize', sz, 'FontWeight', 'bold', ...
                'HorizontalAlignment', 'center', 'VerticalAlignment', 'middle', 'Interpreter', 'none', 'PickableParts', 'none');

            % 机箱外框（机箱壁位置，非计算域边界）
            co = s.CASE2D.outer;
            plotRect(co.x, co.y, co.w, co.h, [0.60 0.60 0.72], 2.5);

            % 主板区、VRM、内存、芯片组（布局中可缺省）
            if isfield(s.CASE2D, 'motherboard_tray')
                mb = s.CASE2D.motherboard_tray;
                plot(ax, [mb.x mb.x+mb.w mb.x+mb.w mb.x mb.x], [mb.y mb.y mb.y+mb.h mb.y+mb.h mb.y], '--', ...
                    'Color', [0.20 0.68 0.28], 'LineWidth', 1.2, 'PickableParts', 'none');
                lx = mb.x + 5;                                   % VRM 在左上角时移到其右侧，免得被 VRM 框压住
                if ~isempty(s.VRM) && s.VRM.heatsink.x <= lx + 8 && s.VRM.heatsink.y <= mb.y + 10
                    lx = max(lx, s.VRM.heatsink.x + s.VRM.heatsink.w + 2);
                end
                text(ax, lx, mb.y+6, '主板区', 'Color', [0.25 0.78 0.35], 'FontSize', 7, 'FontWeight', 'bold', ...
                    'HorizontalAlignment', 'left', 'VerticalAlignment', 'top', 'Interpreter', 'none', 'PickableParts', 'none');
            end
            if ~isempty(s.VRM)
                vrm = s.VRM.heatsink;
                plotRect(vrm.x, vrm.y, vrm.w, vrm.h, [0.85 0.85 0.85], 2.5);
                lb(vrm.x, vrm.y, vrm.w, vrm.h, 'VRM', [0.95 0.95 0.95], 5);
            end
            for ri = 1:numel(s.RAM_SLOTS)
                rm = s.RAM_SLOTS(ri);
                plotRect(rm.x, rm.y, rm.w, rm.h, [0.72 0.30 1.0], 2.5);
            end
            if ~isempty(s.RAM_SLOTS)
                r1 = s.RAM_SLOTS(1);
                yb = max([s.RAM_SLOTS.y] + [s.RAM_SLOTS.h]);     % 标签放在内存条下方，不压住内存条、不越出主板区
                text(ax, r1.x-0.5, yb+0.5, sprintf('RAMx%d', numel(s.RAM_SLOTS)), 'Color', [0.80 0.50 1.0], ...
                    'FontSize', 6, 'FontWeight', 'bold', 'HorizontalAlignment', 'left', 'VerticalAlignment', 'top', ...
                    'Interpreter', 'none', 'PickableParts', 'none');
            end
            if ~isempty(s.CHIPSET)
                chip = s.CHIPSET.heatsink;
                plotRect(chip.x, chip.y, chip.w, chip.h, [0.80 0.80 0.80], 1.0);
                lb(chip.x, chip.y, chip.w, chip.h, '芯', [0.90 0.90 0.90], 5);
            end

            % CPU 底座与塔式散热器
            if s.hasCpu
                cb = s.CPU_HEATSINK.base;                        % 虚线：只显示、不挡风（底座在鳍片内侧）
                plot(ax, [cb.x cb.x+cb.w cb.x+cb.w cb.x cb.x], [cb.y cb.y cb.y+cb.h cb.y+cb.h cb.y], '--', ...
                    'Color', [0.00 0.75 1.0], 'LineWidth', 2.0, 'PickableParts', 'none');
                lb(cb.x, cb.y, cb.w, cb.h, 'CPU', [0.40 0.90 1.0], 8);
                cf = s.CPU_HEATSINK.fin_area;
                cfW = min(W, cf.x+cf.w-1) - cf.x;
                plotRect(cf.x, cf.y, cfW, cf.h, [0.00 0.60 1.0], 2.0);
                th = max(3, min(6, cb.y - cf.y - 1));          % 标签放在散热器上沿（同网页），不与底座的"CPU"重叠
                text(ax, cf.x+cfW/2, cf.y+0.5+th/2, '塔式散热器', 'Color', [0.30 0.80 1.0], 'FontSize', 7, 'FontWeight', 'bold', ...
                    'HorizontalAlignment', 'center', 'VerticalAlignment', 'middle', 'Interpreter', 'none', 'PickableParts', 'none');
            end

            % 显卡：整卡外形（PCB + 散热片 + 风扇）画成一个半透明整体，内部细线分出 PCB 与散热片
            if s.hasGpu
                gh = s.GPU_HEATSINK.heatsink;
                gp = s.GPU_HEATSINK.pcb;
                yBot = gh.y + gh.h - 1;
                for k = 1:numel(s.builtInFans)
                    if strcmp(s.builtInFans{k}.role, 'gpu'), yBot = max(yBot, s.builtInFans{k}.rows(2)); end
                end
                x0 = min(gh.x, gp.x) - 0.5; x1 = min(W, max(gh.x + gh.w, gp.x + gp.w)) - 0.5;
                y0 = gp.y - 0.5; y1 = yBot + 0.5;
                patch(ax, 'XData', [x0 x1 x1 x0], 'YData', [y0 y0 y1 y1], 'FaceColor', [1.0 0.45 0.10], ...
                    'FaceAlpha', 0.16, 'EdgeColor', [1.0 0.50 0.10], 'LineWidth', 2.2, 'PickableParts', 'none');
                plot(ax, [gp.x-0.5, gp.x+gp.w-0.5], [gp.y+gp.h-0.5, gp.y+gp.h-0.5], '-', ...
                    'Color', [1.0 0.60 0.25], 'LineWidth', 1.2, 'PickableParts', 'none');
                plot(ax, [x0 x1], [gh.y+gh.h-0.5, gh.y+gh.h-0.5], ':', ...
                    'Color', [1.0 0.60 0.25], 'LineWidth', 1.0, 'PickableParts', 'none');
                % 挡板端（仅显示）：PCB 延伸到后面板的挡板，散热片后端到后壁之间是接口区；求解器里这段不是障碍
                xb = co.x + 0.5;                                 % 后壁内侧
                if x0 > xb && (x0 - xb) * s.GRID.cell_size_mm <= 60
                    plot(ax, [xb x0 x0 xb xb], [gp.y-0.5 gp.y-0.5 gp.y+gp.h-0.5 gp.y+gp.h-0.5 gp.y-0.5], '--', ...
                        'Color', [1.0 0.60 0.25], 'LineWidth', 1.0, 'PickableParts', 'none');
                    plot(ax, [xb xb], [y0 y1], '-', 'Color', [1.0 0.50 0.10], 'LineWidth', 2.2, 'PickableParts', 'none');
                end
                sl = layout_gpu_slots(s.layout);
                lb(x0 + 0.5, y0 + 0.5, x1 - x0, y1 - y0, sprintf('GPU（%g 槽）', sl), [1.0 0.80 0.50], 9);
            end

            % PSU
            if s.hasPsu
                psu = s.PSU2D.body;
                plotRect(psu.x, psu.y, psu.w, psu.h, [0.88 0.80 0.00], 2.0);
                lb(psu.x, psu.y, psu.w, psu.h, 'PSU', [1.0 0.95 0.30], 8);
            end

            % 风扇：执行盘矩形 + 送风方向箭头（机箱进气绿、排气红，内置风扇青/橙/黄）
            allF = s.allFans();
            for k = 1:numel(allF)
                f = allF{k};
                bnd = f.getBounds();
                switch f.role
                    case 'case'
                        if strcmp(f.type, 'intake'), col = [0.00 0.92 0.55]; else, col = [1.00 0.28 0.28]; end
                    case 'cpu', col = [0.00 0.85 0.85];
                    case 'gpu', col = [1.00 0.55 0.15];
                    otherwise,  col = [0.95 0.85 0.20];
                end
                plotRect(bnd.x - 0.5, bnd.y - 0.5, bnd.w, bnd.h, col, 1.2);
                cx = bnd.x + (bnd.w - 1)/2; cy = bnd.y + (bnd.h - 1)/2;
                len = 0.35 * max(bnd.w, bnd.h);
                quiver(ax, cx - f.normal(1)*len/2, cy - f.normal(2)*len/2, f.normal(1)*len, f.normal(2)*len, ...
                    'AutoScale', 'off', 'Color', col, 'MaxHeadSize', 2, 'LineWidth', 1.4, 'PickableParts', 'none');
            end

            % 方位标注（YDir='reverse'：y=1 在顶，y=H 在底）
            text(ax, W/2, 3, '▲ 顶部', 'Color', [0.55 0.55 0.65], 'FontSize', 6, 'HorizontalAlignment', 'center', ...
                'VerticalAlignment', 'top', 'Interpreter', 'none', 'PickableParts', 'none');
            text(ax, 3, H-3, '← 后部', 'Color', [0.55 0.55 0.65], 'FontSize', 7, 'HorizontalAlignment', 'left', ...
                'VerticalAlignment', 'bottom', 'Interpreter', 'none', 'PickableParts', 'none');
            text(ax, W-3, H-3, '前面板 →', 'Color', [0.55 0.55 0.65], 'FontSize', 7, 'HorizontalAlignment', 'right', ...
                'VerticalAlignment', 'bottom', 'Interpreter', 'none', 'PickableParts', 'none');

            % 尺度条（100 mm）
            L100 = 100 / s.GRID.cell_size_mm;
            x0 = 5; y0 = H - 8;
            plot(ax, [x0 x0+L100], [y0 y0], '-', 'Color', [0.90 0.90 0.90], 'LineWidth', 2.5, 'PickableParts', 'none');
            plot(ax, [x0 x0], [y0-2 y0+2], '-', 'Color', [0.90 0.90 0.90], 'LineWidth', 1.5, 'PickableParts', 'none');
            plot(ax, [x0+L100 x0+L100], [y0-2 y0+2], '-', 'Color', [0.90 0.90 0.90], 'LineWidth', 1.5, 'PickableParts', 'none');
            text(ax, x0 + L100/2, y0 + 4, '100 mm', 'Color', [0.90 0.90 0.90], 'FontSize', 7, ...
                'HorizontalAlignment', 'center', 'Interpreter', 'none', 'PickableParts', 'none');

            % 粒子示踪（尾迹 + 头部），替代每帧重算的流线
            app.hParticles = plot(ax, nan, nan, '-', 'Color', [0.70 0.78 0.86], 'LineWidth', 0.6, ...
                'PickableParts', 'none');
            app.hHeads = plot(ax, nan, nan, '.', 'Color', [0.92 0.97 1], 'MarkerSize', 5, ...
                'PickableParts', 'none');
            app.Tracer = ParticleTracer(round(1500 * max(1, s.gridScale)), 8);
            app.Tracer.reset(s);

            % 开口风量标注（壁外侧，箭头 = 流向，数字 = 净风量 CFM）
            M = s.openingMarkers();
            app.hOpenLabels = cell(numel(M), 1);
            for k = 1:numel(M)
                app.hOpenLabels{k} = text(ax, M(k).x, M(k).y, '', 'FontSize', 7, 'FontWeight', 'bold', ...
                    'HorizontalAlignment', 'center', 'VerticalAlignment', 'middle', 'Interpreter', 'none', ...
                    'PickableParts', 'none');
            end

            % 安装位标记最后绘制，位于最上层以接收点击
            app.drawSlotMarkers();

            app.initSideAxes();
        end

        function initSideAxes(app)
            % 下方图：温度曲线（CPU/GPU/后侧排气随仿真时间）或风扇工作点（P-Q 曲线 + 工作点）
            ax2 = app.SideAxes;
            for k = 1:numel(app.hPQ)                  % 句柄隐藏的工作点圆点 cla 删不掉，先显式删除
                for j = 1:numel(app.hPQ{k})
                    h = app.hPQ{k}{j};
                    if ~isempty(h) && isvalid(h), delete(h); end
                end
            end
            cla(ax2);
            hold(ax2, 'on');
            ax2.XTickMode = 'auto';                   % 构造时关了刻度，这里恢复
            ax2.YTickMode = 'auto';
            ax2.Color = [0.05 0.05 0.08];
            ax2.XColor = [0.4 0.4 0.5];
            ax2.YColor = [0.4 0.4 0.5];
            grid(ax2, 'on');
            app.hSideLine = cell(3, 1);
            app.hPQ = {};
            if strcmp(app.SideMode, 'pq')
                % 机箱风扇与 CPU 塔扇：当前转速下的 P-Q 曲线（实线）与工作点（圆点）
                F = app.pqFans();
                pal = [0.35 0.80 1.00; 1.00 0.60 0.25; 0.50 1.00 0.50; 1.00 0.45 0.75; ...
                       0.95 0.90 0.30; 0.75 0.65 1.00; 0.30 1.00 0.85; 1.00 0.50 0.40];   % 深色背景上的亮色
                for k = 1:numel(F)
                    c = pal(mod(k - 1, size(pal, 1)) + 1, :);
                    app.hPQ{k} = {plot(ax2, nan, nan, '-', 'Color', c, 'LineWidth', 1.3, 'DisplayName', F{k}.name), ...
                                  plot(ax2, nan, nan, 'o', 'Color', c, 'MarkerFaceColor', c, 'MarkerSize', 6, ...
                                       'HandleVisibility', 'off')};
                end
                if ~isempty(F)
                    legend(ax2, 'Location', 'northeast', 'Color', [0.1 0.1 0.15], ...
                        'TextColor', [0.7 0.7 0.8], 'FontSize', 8);
                else
                    legend(ax2, 'off');
                end
                xlabel(ax2, '风量 (CFM)', 'Color', [0.6 0.6 0.7], 'FontSize', 11);
                ylabel(ax2, '静压 (Pa)', 'Color', [0.6 0.6 0.7], 'FontSize', 11);
                xlim(ax2, 'auto'); ylim(ax2, 'auto');
            else
                app.hSideLine{1} = plot(ax2, nan, nan, 'Color', [1 0.3 0.3], 'LineWidth', 1.5, 'DisplayName', 'CPU');
                app.hSideLine{2} = plot(ax2, nan, nan, 'Color', [0.3 1 0.3], 'LineWidth', 1.5, 'DisplayName', 'GPU');
                app.hSideLine{3} = plot(ax2, nan, nan, 'Color', [0.3 0.6 1], 'LineWidth', 1.5, 'DisplayName', '后侧排气');
                legend(ax2, 'Location', 'northwest', 'Color', [0.1 0.1 0.15], 'TextColor', [0.7 0.7 0.8], 'FontSize', 8);
                xlabel(ax2, '仿真时间 (s)', 'Color', [0.6 0.6 0.7], 'FontSize', 11);
                ylabel(ax2, '温度 (°C)', 'Color', [0.6 0.6 0.7], 'FontSize', 11);
                ylim(ax2, [20, 110]);
                if numel(app.timeHistory) > 1
                    set(app.hSideLine{1}, 'XData', app.timeHistory, 'YData', app.cpuTempHistory);
                    set(app.hSideLine{2}, 'XData', app.timeHistory, 'YData', app.gpuTempHistory);
                    set(app.hSideLine{3}, 'XData', app.timeHistory, 'YData', app.rearExhaustTempHistory);
                end
            end
            hold(ax2, 'off');
        end

        function F = pqFans(app)
            % 工作点图显示的风扇：机箱风扇 + CPU 塔扇（显卡、电源风扇不画，避免曲线过密）
            list = app.Solver.fanStatusList();
            allF = app.Solver.allFans();
            F = {};
            for k = 1:numel(allF)
                if any(strcmp(allF{k}.role, {'case', 'cpu'}))
                    F{end+1} = struct('fan', allF{k}, 'name', list(k).name); %#ok<AGROW>
                end
            end
        end

        function setSideMode(app)
            if strcmp(app.SideModeDrop.Value, '风扇工作点'), app.SideMode = 'pq'; else, app.SideMode = 'temp'; end
            app.initSideAxes();
            app.updateSideView();
        end

        function drawSlotMarkers(app)
            % 机箱风扇安装位标记：盘区域向壁外延伸几格，便于点击
            ax = app.MainAxes;
            s = app.Solver;
            slots = fan_slots();
            app.hSlot = cell(numel(slots), 1);
            app.hSlotText = cell(numel(slots), 1);
            pad = max(2, s.fanDiskCells);
            for k = 1:numel(slots)
                sl = slots(k);
                [cols, rows] = s.wallFanSpan(sl.mount, sl.alongMm, 120);
                switch sl.mount
                    case 'front'
                        cols(2) = cols(2) + 1 + pad; tx = cols(2) + 1; ty = mean(rows); ha = 'left'; va = 'middle';
                    case 'rear'
                        cols(1) = cols(1) - 1 - pad; tx = cols(1) - 1; ty = mean(rows); ha = 'right'; va = 'middle';
                    case 'top'
                        rows(1) = rows(1) - 1 - pad; tx = mean(cols); ty = rows(1) - 1; ha = 'center'; va = 'bottom';
                    otherwise
                        rows(2) = rows(2) + 1 + pad; tx = mean(cols); ty = rows(2) + 1; ha = 'center'; va = 'top';
                end
                X = [cols(1)-0.5, cols(2)+0.5, cols(2)+0.5, cols(1)-0.5];
                Y = [rows(1)-0.5, rows(1)-0.5, rows(2)+0.5, rows(2)+0.5];
                app.hSlot{k} = patch(ax, 'XData', X, 'YData', Y, 'FaceColor', [0.55 0.55 0.60], ...
                    'FaceAlpha', 0.10, 'EdgeColor', [0.55 0.55 0.60], 'LineStyle', '--', 'LineWidth', 1, ...
                    'PickableParts', 'all', 'ButtonDownFcn', @(src,event)app.onSlotClick(k));
                app.hSlotText{k} = text(ax, tx, ty, sl.id, 'Color', [0.75 0.75 0.8], 'FontSize', 7, ...
                    'HorizontalAlignment', ha, 'VerticalAlignment', va, 'Interpreter', 'none', 'PickableParts', 'none');
            end
            app.updateSlotMarkers();
        end

        function updateSlotMarkers(app)
            % 标记颜色反映待应用的状态（绿 = 进气，红 = 排气，灰虚线 = 空）；
            % 文字附已应用风扇的开口净风量。待应用状态与正在计算的不同时，边框与文字改为琥珀色虚线，
            % 文字写成"T1 出 ↑32 → 空（待应用）"：流场仍按已应用的布局计算，点"应用布局"后才生效。
            slots = fan_slots();
            word = struct('intake', '进', 'exhaust', '出', 'none', '空');
            amber = [1.00 0.67 0.00];
            for k = 1:numel(app.hSlot)
                h = app.hSlot{k};
                if isempty(h) || ~isvalid(h), continue; end
                st = app.SlotStates(k);
                switch st.type
                    case 'intake',  col = [0.00 0.92 0.55]; a = 0.30; ls = '-';  cap = [st.id ' 进'];
                    case 'exhaust', col = [1.00 0.28 0.28]; a = 0.30; ls = '-';  cap = [st.id ' 出'];
                    otherwise,      col = [0.55 0.55 0.60]; a = 0.10; ls = '--'; cap = st.id;
                end
                applied = app.slotApplied(k);
                changed = ~strcmp(applied, st.type);
                if changed
                    set(h, 'FaceColor', col, 'FaceAlpha', a, 'EdgeColor', amber, 'LineStyle', '--');
                else
                    set(h, 'FaceColor', col, 'FaceAlpha', a, 'EdgeColor', col, 'LineStyle', ls);
                end
                t = app.hSlotText{k};
                if ~isempty(t) && isvalid(t)
                    ft = '';
                    q = app.slotFlow(k);
                    if ~isnan(q) && app.LabelCheck.Value && abs(q) >= 0.5
                        [ft, ~] = app.flowText(slots(k).mount, q);
                        ft = [' ' ft]; %#ok<AGROW>
                    end
                    if changed
                        cap = sprintf('%s %s%s → %s（待应用）', st.id, word.(applied), ft, word.(st.type));
                        set(t, 'String', cap, 'Color', amber);
                    else
                        set(t, 'String', [cap ft], 'Color', col);
                    end
                end
            end
        end

        function type = slotApplied(app, k)
            % 安装位 k 上已应用（正在计算）的机箱风扇类型：'intake' | 'exhaust' | 'none'
            type = 'none';
            if ~isfield(app.Solver.layout, 'caseFans') || isempty(app.Solver.layout.caseFans), return; end
            slots = fan_slots();
            cf = app.Solver.layout.caseFans;
            j = find(strcmp({cf.mount}, slots(k).mount) & abs([cf.alongMm] - slots(k).alongMm) < 1, 1);
            if ~isempty(j), type = cf(j).type; end
        end

        function q = slotFlow(app, k)
            % 安装位 k 上已应用的机箱风扇的开口净风量（CFM，> 0 流出）；没有则 NaN
            q = NaN;
            M = app.OpenMarkers;
            if isempty(M) || ~isfield(app.Solver.layout, 'caseFans'), return; end
            slots = fan_slots();
            cf = app.Solver.layout.caseFans;
            j = find(strcmp({cf.mount}, slots(k).mount) & abs([cf.alongMm] - slots(k).alongMm) < 1, 1);
            if isempty(j), return; end
            m = find(strcmp({M.kind}, 'fan') & [M.fan] == j, 1);
            if ~isempty(m), q = M(m).cfm; end
        end

        function setupSimulation(app)
            app.Solver = CFDSolverFEM([], [], [], [], app.GridScale);
            app.applyGridMode();
            L0 = layout_default();
            app.DefaultGaps = L0.shroud.gaps;
            P = fan_presets();
            app.LayoutLabel = P(1).label;
            app.AppliedLabel = P(1).label;
            app.setPendingFromLayout(app.Solver.layout);
            app.SimTimer = timer('ExecutionMode', 'fixedRate', 'Period', 0.3, 'TimerFcn', @(t,event)app.onTimer());
            app.initStaticGraphics();
        end

        % ================= 运行循环与刷新 =================
        function onTimer(app)
            try
                if ~isvalid(app.UIFigure) || ~isvalid(app.MainAxes) || ~isvalid(app.IntakeTempLabel)
                    if ~isempty(app.SimTimer) && isvalid(app.SimTimer)
                        stop(app.SimTimer);
                    end
                    return;
                end
                if app.StepPending, return; end
                app.StepPending = true;
                % 自适应 StepsPerFrame：根据当前最大速度动态调整
                [uCgA, vCgA] = app.Solver.getCellVelocity();
                maxVel = max(sqrt(uCgA.^2 + vCgA.^2));
                if maxVel < 0.3
                    app.StepsPerFrame = 4;   % 低速时加速收敛
                elseif maxVel > 1.2
                    app.StepsPerFrame = 1;   % 高速时保持响应与稳定
                else
                    app.StepsPerFrame = 2;   % 常规工况
                end
                app.Solver.stepMultiple(app.StepsPerFrame);
                app.advanceParticles();
                app.updateVisualizations();
                app.updateUI();
                app.StepPending = false;
            catch ME
                app.StepPending = false;
                if ~isempty(app.SimTimer) && isvalid(app.SimTimer)
                    stop(app.SimTimer);
                end
                app.LastError = ME.message;
                fprintf('Timer error: %s\n', ME.message);
                disp(getReport(ME));
            end
        end

        function field = temperatureField(app)
            % 温度场（W×H）：流体格取 T_fluid，障碍格取元件温度 T_solid
            s = app.Solver;
            W = s.GRID.W; H = s.GRID.H;
            field = reshape(s.T_fluid, W, H);
            obs = reshape(s.obstacle, W, H) > 0;
            Ts = reshape(s.T_solid, W, H);
            field(obs) = Ts(obs);
        end

        function updateVisualizations(app)
            if ~isvalid(app.UIFigure) || ~isvalid(app.MainAxes), return; end
            try
                ax = app.MainAxes;
                hold(ax, 'on');   % 保持 hold on，防止 contour 清除 hImg 等静态图层
                W = app.Solver.GRID.W; H = app.Solver.GRID.H;
                contourLevels = [];
                contourColor = [1 1 1];

                switch app.VisMode
                    case 'velocity'
                        [uCgV, vCgV] = app.Solver.getCellVelocity();
                        % 网格速度 × VEL_SCALE → m/s
                        field = reshape(sqrt(uCgV.^2 + vCgV.^2), W, H) * app.Solver.VEL_SCALE;
                        obs2d = reshape(app.Solver.obstacle, W, H) > 0;
                        field(obs2d) = NaN;
                        ax.Colormap = pcflow_colormap('speed', 256);
                        ax.CLim = [0 2];
                        cbLabel = '速度 (m/s)';
                        ttl = '速度场 (m/s)';
                    case 'temperature'
                        field = app.temperatureField();
                        ax.Colormap = pcflow_colormap('heat', 256);
                        ax.CLim = [20 100];
                        cbLabel = '温度 (°C)';
                        ttl = '温度场 (°C)';
                        contourLevels = [30 40 50 60];
                        contourColor = [0.4 0.9 1];
                    case 'pressure'
                        % 相对机箱外（远场）的静压；零压线分开正压区与负压区
                        field = reshape(app.Solver.pressureFieldPa(), W, H);
                        v = sort(abs(field(isfinite(field))));
                        lim = 2;
                        if ~isempty(v), lim = max(lim, v(max(1, round(0.99 * numel(v))))); end
                        ax.Colormap = pcflow_colormap('diverging', 256);
                        ax.CLim = [-lim lim];
                        cbLabel = '静压 (Pa，相对机箱外)';
                        ins = app.Solver.insideMask;
                        pin = mean(field(ins(isfinite(field(ins)))));
                        if abs(pin) < 0.05, pst = '≈ 机箱外'; else, pst = app.pick(pin > 0, '正压', '负压'); end
                        ttl = sprintf('压力场：机箱内平均 %+.2f Pa（%s）', pin, pst);
                        contourLevels = [0 0];
                        contourColor = [0.3 0.3 0.3];
                    case 'vorticity'
                        % 求解器 ω = ∂v/∂x − ∂u/∂y 以 y 向下为正；主视图 y 轴反向显示，
                        % 取 −ω 使屏幕上逆时针旋转为正（红）
                        field = -reshape(app.Solver.latestVorticity, W, H);
                        ax.Colormap = pcflow_colormap('diverging', 256);
                        ax.CLim = [-60 60];
                        cbLabel = '涡量 (1/s)';
                        ttl = '涡量场 (1/s，红 = 逆时针)';
                    case 'solid'
                        field = reshape(app.Solver.T_solid, W, H);
                        ax.Colormap = pcflow_colormap('heat', 256);
                        ax.CLim = [20 90];
                        cbLabel = '固体温度 (°C)';
                        ttl = '固体温度 (°C)';
                        contourLevels = [40 60 80];
                        contourColor = [1 1 1];
                    case 'diff'
                        field = app.temperatureField();
                        name = app.SCENARIO_NAMES{app.DiffRef};
                        ref = app.Scenarios{app.DiffRef};
                        if ~isempty(ref) && isequal(size(ref.T), size(field))
                            field = field - ref.T;
                            ttl = sprintf('温差：当前 − 方案 %s (°C)', name);
                            contourLevels = [-5 5];
                            contourColor = [0.3 0.3 0.3];
                        elseif isempty(ref)
                            field = zeros(W, H);
                            ttl = sprintf('温差：方案 %s 尚未保存（在"方案对比"页保存）', name);
                        else
                            field = zeros(W, H);
                            ttl = sprintf('温差：方案 %s 的网格精度与当前不同', name);
                        end
                        ax.Colormap = pcflow_colormap('diverging', 256);
                        ax.CLim = [-10 10];
                        cbLabel = '温差 (°C)';
                end
                % 固体格（NaN）透明，露出坐标轴背景色，避免被画成色表第一色
                set(app.hImg, 'CData', field, 'AlphaData', double(isfinite(field)));
                title(ax, ttl, 'Color', [0.8 0.8 1]);
                % 发散色（中点浅灰）上用深色粒子，其余用浅色
                if any(strcmp(app.VisMode, {'pressure', 'vorticity', 'diff'}))
                    set(app.hParticles, 'Color', [0.25 0.25 0.32]); set(app.hHeads, 'Color', [0.10 0.10 0.15]);
                else
                    set(app.hParticles, 'Color', [0.70 0.78 0.86]); set(app.hHeads, 'Color', [0.92 0.97 1.00]);
                end
                app.hCbar.Label.String = cbLabel;

                % 等温线 / 涡量线（删除重建；contour 第二输出才是句柄）
                if ~isempty(app.hContour) && all(isvalid(app.hContour))
                    delete(app.hContour);
                end
                app.hContour = [];
                if ~isempty(contourLevels) && (max(field(:)) - min(field(:))) > 0.5
                    [~, hc] = contour(ax, 1:W, 1:H, field, contourLevels, 'LineColor', contourColor, 'LineWidth', 1.2);
                    set(hc, 'PickableParts', 'none');
                    app.hContour = hc;
                end

                app.drawParticles();
                app.updateOpeningLabels();
                drawnow limitrate;
                app.captureGifFrame();
            catch ME
                app.LastError = ME.message;
                fprintf('updateVisualizations error: %s\n', ME.message);
            end
            app.updateSideView();
        end

        function updateSideView(app)
            if ~isvalid(app.SideAxes), return; end
            try
                % iteration 是累计总步数，物理时间 = 步数 × 固定步长 DT
                t = app.Solver.iteration * app.Solver.DT;
                cpuT = app.junctionOrNaN('cpu');
                gpuT = app.junctionOrNaN('gpu');
                if ~isempty(app.Solver.lastTemps)
                    rearT = app.Solver.lastTemps.rearExhaust;
                else
                    rearT = app.Solver.T_amb;
                end

                app.timeHistory(end+1) = t;
                app.cpuTempHistory(end+1) = cpuT;
                app.gpuTempHistory(end+1) = gpuT;
                app.rearExhaustTempHistory(end+1) = rearT;
                if length(app.timeHistory) > app.maxHistoryPoints
                    app.timeHistory(1) = [];
                    app.cpuTempHistory(1) = [];
                    app.gpuTempHistory(1) = [];
                    app.rearExhaustTempHistory(1) = [];
                end

                if strcmp(app.SideMode, 'pq')
                    app.updatePQ();
                    ttl = '风扇工作点（曲线 = 当前转速 P-Q，圆点 = 实测工作点）';
                else
                    set(app.hSideLine{1}, 'XData', app.timeHistory, 'YData', app.cpuTempHistory);
                    set(app.hSideLine{2}, 'XData', app.timeHistory, 'YData', app.gpuTempHistory);
                    set(app.hSideLine{3}, 'XData', app.timeHistory, 'YData', app.rearExhaustTempHistory);
                    if length(app.timeHistory) > 1 && app.timeHistory(end) > app.timeHistory(1)
                        xlim(app.SideAxes, [app.timeHistory(1), app.timeHistory(end)]);
                    end
                    ttl = '温度曲线';
                end
                if ~isempty(app.StatusMsg), ttl = [ttl ' — ' app.StatusMsg]; end
                title(app.SideAxes, ttl, 'Color', [0.8 0.8 1]);
                drawnow limitrate;
            catch ME
                app.LastError = ME.message;
                fprintf('updateSideView error: %s\n', ME.message);
            end
        end

        function updateUI(app)
            if ~isvalid(app.UIFigure), return; end
            try
                scores = app.Solver.calculateScores();
            catch ME
                app.LastError = ME.message;
                scores = struct('intake',25,'topExhaust',25,'rearExhaust',25,'internalAmbient',25,...
                    'noiseDb',0,'performance',0,'cpuTemp',25,'gpuTemp',25,'total',0,...
                    'cooling',0,'balance',0,'margin',0,'noise',0,'value',0);
            end
            app.IntakeTempLabel.Text   = sprintf('进气: %.1f°C', scores.intake);
            app.TopExhaustLabel.Text   = sprintf('顶排: %.1f°C', scores.topExhaust);
            app.SideExhaustLabel.Text  = sprintf('后排: %.1f°C', scores.rearExhaust);
            app.InternalTempLabel.Text = sprintf('内部: %.1f°C', scores.internalAmbient);
            app.NoiseLabel.Text        = sprintf('噪音: %ddB', scores.noiseDb);
            app.PerformanceLabel.Text  = sprintf('性能: %d%%', scores.performance);
            if app.Solver.hasCpu, app.CPUTempLabel.Text = sprintf('CPU: %d°C', scores.cpuTemp);
            else, app.CPUTempLabel.Text = 'CPU: —'; end
            if app.Solver.hasGpu, app.GPUTempLabel.Text = sprintf('GPU: %d°C', scores.gpuTemp);
            else, app.GPUTempLabel.Text = 'GPU: —'; end
            app.TotalScoreLabel.Text   = sprintf('总分: %d/100', scores.total);
            app.ScoreCoolingLabel.Text = sprintf('散热: %d', scores.cooling);
            app.ScorePerfLabel.Text    = sprintf('性能: %d', scores.performance);
            app.ScoreBalanceLabel.Text = sprintf('均衡: %d', scores.balance);
            app.ScoreMarginLabel.Text  = sprintf('余量: %d', scores.margin);
            app.ScoreNoiseLabel.Text   = sprintf('噪音: %d', scores.noise);
            app.ScoreValueLabel.Text   = sprintf('性价比: %d', scores.value);

            if ~isempty(app.Solver.lastDiag)
                dg = app.Solver.lastDiag;
                app.ReynoldsLabel.Text   = sprintf('Re: %.1e', dg.Re);
                app.GrashofLabel.Text    = sprintf('Gr: %.1e', dg.Gr);
                app.NusseltLabel.Text    = sprintf('Nu: %.1f', dg.Nu);
                app.FlowRegimeLabel.Text = sprintf('流动状态: %s', dg.flowRegime);
                app.RayleighLabel.Text   = sprintf('Ra: %.1e', dg.Ra);
            else
                % 初始/重置态：清空诊断标签，避免显示上一轮残值
                app.ReynoldsLabel.Text   = 'Re: --';
                app.GrashofLabel.Text    = 'Gr: --';
                app.NusseltLabel.Text    = 'Nu: --';
                app.FlowRegimeLabel.Text = '流动状态: --';
                app.RayleighLabel.Text   = 'Ra: --';
            end
            app.DeadZoneLabel.Text = sprintf('死区: %.1f%%', app.Solver.deadZoneRatio*100);

            recs = app.Solver.getRecommendations();
            recLines = cell(numel(recs), 1);
            for k = 1:numel(recs)
                r = recs{k};
                switch r.level
                    case 'good',    prefix = '[OK] ';
                    case 'warning', prefix = '[!] ';
                    case 'info',    prefix = '[i] ';
                    otherwise,      prefix = '[-] ';
                end
                recLines{k} = sprintf('%s%s: %s', prefix, r.title, r.desc);
            end
            app.RecTextArea.Value = recLines;

            % 表格只在所在标签页可见时刷新（uitable 更新较慢）
            if app.isTabSelected(app.TabFans), app.refreshFanTable(); end
            if app.isTabSelected(app.TabScenario), app.refreshScenarioTable(); end
        end

        function updatePQ(app)
            % 刷新工作点图：各风扇当前转速的 P-Q 曲线与实测工作点
            F = app.pqFans();
            s = app.Solver;
            for k = 1:min(numel(F), numel(app.hPQ))
                f = F{k}.fan;
                rpm = f.getRPM(s);
                qFree = f.cfm_max * rpm / f.rpm_max;               % CFM
                q = linspace(0, 1, 21);
                dp = f.pmax_pa * (rpm / f.rpm_max)^2 * pchip_eval(f.PQ_QGRID, f.pq_curve, q);
                set(app.hPQ{k}{1}, 'XData', q * qFree, 'YData', dp);
                set(app.hPQ{k}{2}, 'XData', max(s.diskFlow(f), 0) * Fan.CFM_PER_M3S, 'YData', max(f.lastDp, 0));
            end
        end

        function out = pick(~, cond, a, b)
            if cond, out = a; else, out = b; end
        end

        % ================= 粒子示踪、标注、悬停、导出 =================
        function advanceParticles(app)
            % 粒子前进一帧（0.02 s 物理时间）；关闭粒子时不计算
            if isempty(app.Tracer) || ~app.ParticleCheck.Value, return; end
            app.Tracer.step(app.Solver, 0.02);
        end

        function drawParticles(app)
            if isempty(app.hParticles) || ~isvalid(app.hParticles), return; end
            if isempty(app.Tracer) || ~app.ParticleCheck.Value
                set(app.hParticles, 'XData', nan, 'YData', nan);
                set(app.hHeads, 'XData', nan, 'YData', nan);
                return;
            end
            [xs, ys] = app.Tracer.trailLines();
            set(app.hParticles, 'XData', xs, 'YData', ys);
            set(app.hHeads, 'XData', app.Tracer.X(:, 1), 'YData', app.Tracer.Y(:, 1));
        end

        function updateOpeningLabels(app)
            % 开口旁的风量标注：箭头为流向（进 / 出机箱），数字为净风量 CFM
            % 机箱风扇开口的风量并入安装位文字（避免与其重叠），这里只标电源与被动通风口
            show = app.LabelCheck.Value;
            M = app.Solver.openingMarkers();
            app.OpenMarkers = M;
            for k = 1:min(numel(M), numel(app.hOpenLabels))
                h = app.hOpenLabels{k};
                if isempty(h) || ~isvalid(h), continue; end
                if ~show || strcmp(M(k).kind, 'fan') || abs(M(k).cfm) < 0.5
                    set(h, 'String', '');
                else
                    [txt, col] = app.flowText(M(k).mount, M(k).cfm);
                    set(h, 'String', txt, 'Color', col);
                end
            end
            app.updateSlotMarkers();
        end

        function [txt, col] = flowText(~, mount, cfm)
            % 流向箭头 + 净风量（CFM）：青 = 流入机箱，橙 = 流出
            % {进, 出}；用 cell 而不是按字符下标取，Octave 的字符串是 UTF-8 字节
            arrows = struct('front', {{'←', '→'}}, 'rear', {{'→', '←'}}, 'top', {{'↓', '↑'}}, 'bottom', {{'↑', '↓'}});
            a = arrows.(mount);
            if cfm > 0
                txt = sprintf('%s%.0f', a{2}, cfm); col = [1.00 0.62 0.30];
            else
                txt = sprintf('%s%.0f', a{1}, -cfm); col = [0.35 0.90 1.00];
            end
        end

        function onParticleToggle(app)
            if app.ParticleCheck.Value
                app.Tracer.reset(app.Solver);
                app.startParticleAnim();
            else
                app.stopParticleAnim();
            end
            app.drawParticles();
        end

        function startParticleAnim(app)
            % 暂停/稳态时用单独的定时器让粒子在当前流场里继续运动（流场本身不推进）
            if app.IsRunning || app.SteadyRunning || ~app.ParticleCheck.Value, return; end
            if isempty(app.ParticleTimer) || ~isvalid(app.ParticleTimer)
                app.ParticleTimer = timer('ExecutionMode', 'fixedSpacing', 'Period', 0.05, ...
                    'BusyMode', 'drop', 'TimerFcn', @(t,event)app.particleTick());
            end
            app.ParticleTicks = 0;
            if ~strcmp(char(app.ParticleTimer.Running), 'on'), start(app.ParticleTimer); end
        end

        function stopParticleAnim(app)
            if ~isempty(app.ParticleTimer) && isvalid(app.ParticleTimer) && strcmp(char(app.ParticleTimer.Running), 'on')
                stop(app.ParticleTimer);
            end
        end

        function particleTick(app)
            try
                if ~isvalid(app.UIFigure), app.stopParticleAnim(); return; end
                if app.IsRunning || app.SteadyRunning || app.StepPending, return; end
                app.ParticleTicks = app.ParticleTicks + 1;
                if app.ParticleTicks > 2400 && isempty(app.GifFile)   % 空闲约 2 分钟后自动停，省 CPU
                    app.stopParticleAnim();
                    app.HoverLabel.Text = '粒子动画已暂停（重新勾选"粒子"继续）';
                    return;
                end
                app.advanceParticles();
                app.drawParticles();
                drawnow limitrate;
                app.captureGifFrame();
            catch ME
                app.stopParticleAnim();
                app.LastError = ME.message;
                fprintf('particleTick error: %s\n', ME.message);
            end
        end

        function onHover(app)
            try
                cp = app.MainAxes.CurrentPoint;
                if isempty(cp), return; end
                app.hoverAt(cp(1, 1), cp(1, 2));
            catch
                % 悬停读数失败不影响仿真
            end
        end

        function hoverAt(app, x, y)
            % 主视图读数：位置（mm，相对机箱外沿）、速度、温度、压力；x/y 为格坐标
            try
                s = app.Solver;
                j = round(x); i = round(y);
                if i < 1 || i > s.GRID.W || j < 1 || j > s.GRID.H
                    return;
                end
                idx = (j - 1) * s.GRID.W + i;
                if idx == app.LastHoverIdx && ~app.IsRunning, return; end   % 同一格不重复刷新
                app.LastHoverIdx = idx;
                co = s.CASE2D.outer;
                xm = (j - co.x + 0.5) * s.GRID.cell_size_mm;
                ym = (i - co.y + 0.5) * s.GRID.cell_size_mm;
                r = s.cellReadout(idx);
                if r.solid
                    txt = sprintf('x %.0f  y %.0f mm │ 固体 %.1f°C', xm, ym, r.Tsolid);
                else
                    txt = sprintf('x %.0f  y %.0f mm │ %.2f m/s │ %.1f°C │ %+.2f Pa', xm, ym, r.speed, r.T, r.P);
                    if strcmp(app.VisMode, 'solid')      % 固体温度视图里散热片、CPU 底座等流体格按 T_solid 上色
                        txt = sprintf('%s │ 固体 %.1f°C', txt, r.Tsolid);
                    end
                end
                app.HoverLabel.Text = txt;
            catch
                % 悬停读数失败不影响仿真
            end
        end

        function exportPngDialog(app)
            [f, p] = uiputfile('*.png', '导出主视图', 'pcflow_view.png');
            if isequal(f, 0), return; end
            app.exportPng(fullfile(p, f));
        end

        function exportPng(app, file)
            try
                exportgraphics(app.MainAxes, file, 'Resolution', 150);
                app.HoverLabel.Text = ['已导出 ' file];
            catch ME
                app.reportError('导出 PNG 失败', ME);
            end
        end

        function toggleGif(app)
            if isempty(app.GifFile)
                [f, p] = uiputfile('*.gif', '录制 GIF（再点一次停止）', 'pcflow_anim.gif');
                if isequal(f, 0), return; end
                app.startGif(fullfile(p, f));
            else
                app.stopGif();
            end
        end

        function startGif(app, file)
            app.GifFile = file;
            app.GifFrames = 0;
            app.GifSkip = 0;
            app.GifSize = [];
            % 调色板：当前色表 192 色 + 灰阶 32 色 + 界面与标注颜色
            cm = app.MainAxes.Colormap;
            if isempty(cm), cm = pcflow_colormap('speed', 256); end
            cm = cm(round(linspace(1, size(cm, 1), 192)), :);
            ui = [0.05 0.05 0.08; 0.02 0.02 0.05; 0.60 0.60 0.72; 0.00 0.92 0.55; 1.00 0.28 0.28; ...
                  0.35 0.90 1.00; 1.00 0.62 0.30; 0.92 0.97 1.00; 0.70 0.78 0.86; 0.00 0.75 1.00; ...
                  1.00 0.38 0.00; 0.88 0.80 0.00; 0.72 0.30 1.00; 0.80 0.80 1.00; 0.25 0.25 0.32];
            app.GifMap = [cm; repmat(linspace(0, 1, 32)', 1, 3); ui];
            app.GifBtn.Text = '■ 停止录制';
            app.GifBtn.BackgroundColor = [0.6 0.2 0.2];
        end

        function stopGif(app)
            n = app.GifFrames; f = app.GifFile;
            app.GifFile = '';
            app.GifBtn.Text = '● 录制 GIF';
            app.GifBtn.BackgroundColor = [0.1 0.1 0.2];
            if n > 0
                app.HoverLabel.Text = sprintf('GIF 已保存（%d 帧）：%s', n, f);
            elseif ~isempty(f)
                app.HoverLabel.Text = '未录到帧：请开始仿真或打开粒子动画后再录制';
            end
        end

        function captureGifFrame(app)
            % 录制中每隔一次刷新截取主视图一帧；最多 300 帧后自动停止
            if isempty(app.GifFile), return; end
            app.GifSkip = app.GifSkip + 1;
            if mod(app.GifSkip, 2) ~= 1, return; end
            tmp = [tempname() '.png'];
            try
                exportgraphics(app.MainAxes, tmp, 'Resolution', 72);
                img = imread(tmp);
                delete(tmp);
                if isempty(app.GifSize)
                    app.GifSize = [size(img, 1), size(img, 2)];
                else                               % 裁剪/填充到第一帧尺寸（色标刻度变化会改变裁剪边界）
                    fit = zeros(app.GifSize(1), app.GifSize(2), 3, 'uint8');
                    fit(:, :, 1) = 13; fit(:, :, 2) = 13; fit(:, :, 3) = 20;
                    r = min(size(img, 1), app.GifSize(1)); c = min(size(img, 2), app.GifSize(2));
                    fit(1:r, 1:c, :) = img(1:r, 1:c, 1:3);
                    img = fit;
                end
                pcflow_gif_frame(app.GifFile, img, app.GifFrames == 0, 0.1, app.GifMap);
                app.GifFrames = app.GifFrames + 1;
            catch ME
                if exist(tmp, 'file'), delete(tmp); end
                app.stopGif();
                app.reportError('录制 GIF 失败', ME);
                return;
            end
            if app.GifFrames >= 300, app.stopGif(); end
        end

        function T = junctionOrNaN(app, name)
            % 元件结温；布局中缺该元件时为 NaN（曲线不画）
            if isfield(app.Solver.thermalNetworks, name)
                T = app.Solver.thermalNetworks.(name).T_junction;
            else
                T = NaN;
            end
        end

        function tf = isTabSelected(app, tab)
            sel = app.TabGroup.SelectedTab;
            tf = ~isempty(sel) && sel == tab;
        end

        function onTabChanged(app)
            if app.isTabSelected(app.TabFans), app.refreshFanTable(); end
            if app.isTabSelected(app.TabScenario), app.refreshScenarioTable(); end
        end

        function refreshFanTable(app)
            list = app.Solver.fanStatusList();
            D = cell(numel(list), 7);
            for k = 1:numel(list)
                f = list(k);
                D(k, :) = {f.name, sprintf('%.0f', f.rpm), sprintf('%.1f', f.cfm), ...
                    sprintf('%.1f', f.freeCfm), sprintf('%.1f', f.dp), sprintf('%.1f', f.noiseDb), ...
                    sprintf('%.0f', f.sharePct)};
            end
            app.FanTable.Data = D;
            if isempty(list)
                app.NoiseDetailLabel.Text = '';
                return;
            end
            [db, ~] = app.Solver.totalNoise();
            [~, i] = max([list.sharePct]);
            p = list(i).noise;
            app.NoiseDetailLabel.Text = sprintf('总噪音 %.1f dB(A)；最响：%s %.1f dB（占 %.0f%%）\n= 转速 %.1f %+.1f 工作点 %+.1f 格栅 %+.1f 位置', ...
                db, list(i).name, p.total, list(i).sharePct, p.base, p.op, p.grille, p.pos);
        end

        % ================= 功率与全局风扇 =================
        function CPUPowerSliderValueChanged(app, ~)
            val = round(app.CPUPowerSlider.Value);
            app.Solver.setComponentPower('cpu', val);
            app.CPUPowerLbl.Text = sprintf('%dW', val);
            app.stateChanged();
        end

        function GPUPowerSliderValueChanged(app, ~)
            val = round(app.GPUPowerSlider.Value);
            app.Solver.setComponentPower('gpu', val);
            app.GPUPowerLbl.Text = sprintf('%dW', val);
            app.stateChanged();
        end

        function PSUPowerSliderValueChanged(app, ~)
            val = round(app.PSUPowerSlider.Value);
            app.Solver.setComponentPower('psu', val);
            app.PSUPowerLbl.Text = sprintf('%dW', val);
            app.stateChanged();
        end

        function stateChanged(app)
            % 功率或风扇设置改变：当前流场不再是稳态结果
            app.SteadyIter = -1;
            app.StatusMsg = '';
        end

        function setPowers(app, p)
            % 设置 CPU/GPU/电源负载功率（夹在滑块范围内），同步滑块、标签与求解器
            sliders = {app.CPUPowerSlider, app.GPUPowerSlider, app.PSUPowerSlider};
            for k = 1:3
                lim = sliders{k}.Limits;
                sliders{k}.Value = min(lim(2), max(lim(1), p(k)));
            end
            app.CPUPowerSliderValueChanged([]);
            app.GPUPowerSliderValueChanged([]);
            app.PSUPowerSliderValueChanged([]);
        end

        function FanSpeedSliderValueChanged(app, ~)
            app.setGlobalFan(false, round(app.FanSpeedSlider.Value));
        end

        function toggleAutoFan(app)
            app.setGlobalFan(~app.Solver.autoFanEnabled, app.Solver.fanSpeedRatio);
            if ~app.IsRunning
                app.updateUI();
            end
        end

        function setGlobalFan(app, auto, pct)
            % 全局风扇模式（自动温控 / 手动转速），作用于转速设为"自动"的风扇
            if app.Solver.autoFanEnabled ~= auto || app.Solver.fanSpeedRatio ~= pct
                app.stateChanged();
            end
            app.Solver.autoFanEnabled = auto;
            app.Solver.fanSpeedRatio = pct;
            app.FanSpeedSlider.Value = pct;
            app.FanSpeedLbl.Text = sprintf('%d%%', round(pct));
            if auto
                app.AutoFanButton.Text = '自动';
                app.AutoFanButton.BackgroundColor = [0 0.2 0.3];
            else
                app.AutoFanButton.Text = '手动';
                app.AutoFanButton.BackgroundColor = [0.1 0.1 0.2];
            end
        end

        function setScenario(app, scenario)
            switch scenario
                case 'daily',  p = [40 35 200];
                case 'gaming', p = [100 200 500];
                case 'heavy',  p = [180 320 850];
                otherwise, return;
            end
            app.setPowers(p);
        end

        % ================= 视图与运行 =================
        function setMode(app, mode)
            if strcmp(mode, 'diff')
                app.DiffRef = find(strcmp(app.SCENARIO_NAMES, app.DiffRefDrop.Value), 1);
            end
            app.VisMode = mode;
            buttons = {app.ModeVelocityBtn, app.ModeTempBtn, app.ModePressureBtn, app.ModeVorticityBtn, ...
                       app.ModeSolidBtn, app.ModeDiffBtn};
            modes = {'velocity', 'temperature', 'pressure', 'vorticity', 'solid', 'diff'};
            for k = 1:numel(buttons)
                if strcmp(modes{k}, mode)
                    buttons{k}.BackgroundColor = [0 0.2 0.3];
                    buttons{k}.FontColor = [0 0.83 1];
                else
                    buttons{k}.BackgroundColor = [0.1 0.1 0.2];
                    buttons{k}.FontColor = [0.8 0.8 0.8];
                end
            end
            app.updateVisualizations();
        end

        function onDiffRefChanged(app)
            app.DiffRef = find(strcmp(app.SCENARIO_NAMES, app.DiffRefDrop.Value), 1);
            if strcmp(app.VisMode, 'diff'), app.updateVisualizations(); end
        end

        function toggleRun(app)
            if app.IsRunning
                if ~isempty(app.SimTimer) && isvalid(app.SimTimer) && strcmp(char(app.SimTimer.Running), 'on')
                    stop(app.SimTimer);
                end
                app.RunButton.Text = '▶ 开始仿真';
                app.RunButton.BackgroundColor = [0 0.4 0.6];
                app.IsRunning = false;
                app.startParticleAnim();
            else
                app.stopParticleAnim();
                if ~isempty(app.SimTimer) && isvalid(app.SimTimer)
                    if strcmp(char(app.SimTimer.Running), 'on')
                        stop(app.SimTimer);
                    end
                else
                    app.SimTimer = timer('ExecutionMode', 'fixedRate', 'Period', 0.3, 'TimerFcn', @(t,event)app.onTimer());
                end
                start(app.SimTimer);
                app.RunButton.Text = '⏸ 暂停仿真';
                app.RunButton.BackgroundColor = [0.6 0.2 0.2];
                app.IsRunning = true;
            end
        end

        function setBusy(app, busy)
            % 跑稳态期间禁用会重建求解器的操作
            if busy, en = 'off'; else, en = 'on'; end
            ctrls = {app.RunButton, app.ResetButton, app.GridDrop, app.ApplyLayoutBtn, ...
                     app.ApplySteadyBtn, app.LoadJsonBtn, app.LoadScenarioBtn};
            for k = 1:numel(ctrls)
                ctrls{k}.Enable = en;
            end
        end

        function solveSteady(app)
            % 推进到稳态（runToSteady），每 50 步刷新一次画面；运行中再次点击则中止
            if app.SteadyRunning
                app.CancelSteady = true;
                return;
            end
            if app.IsRunning, app.toggleRun(); end
            app.stopParticleAnim();
            app.SteadyRunning = true;
            app.CancelSteady = false;
            app.setBusy(true);
            app.SteadyButton.Text = '■ 停止';
            app.SteadyButton.BackgroundColor = [0.6 0.2 0.2];
            drawnow;
            opts = app.SteadyOpts;
            if app.GridScale >= 1 && ~isfield(opts, 'chunk')
                opts.chunk = 25;              % 精确档每块耗时较长，缩短停止响应时间
            end
            opts.progressFcn = @(info) app.steadyProgress(info);
            try
                info = app.Solver.runToSteady(opts);
                if info.converged
                    app.SteadyIter = app.Solver.iteration;
                    msg = sprintf('已稳态（%d 步）', info.steps);
                elseif info.diverged
                    msg = sprintf('计算发散（%d 步），请重置', info.steps);
                elseif info.aborted
                    msg = sprintf('已停止（%d 步）', info.steps);
                else
                    msg = sprintf('未完全收敛（%d 步）', info.steps);
                end
            catch ME
                app.LastError = ME.message;
                msg = '计算出错';
                fprintf('runToSteady error: %s\n', ME.message);
            end
            app.SteadyRunning = false;
            if ~isvalid(app.UIFigure), return; end
            app.SteadyButton.Text = '⏩ 跑到稳态';
            app.SteadyButton.BackgroundColor = [0.1 0.1 0.2];
            app.SteadyButton.Tooltip = msg;
            app.StatusMsg = msg;
            app.setBusy(false);
            app.updateVisualizations();
            app.updateUI();
            app.startParticleAnim();
        end

        function stop = steadyProgress(app, info)
            % runToSteady 的进度回调：刷新画面，返回 true 表示中止
            stop = app.CancelSteady || ~isvalid(app.UIFigure);
            if stop, return; end
            app.SteadyButton.Text = sprintf('■ 停止（%d 步）', info.steps);
            app.updateVisualizations();
            app.updateUI();
            drawnow;
            stop = app.CancelSteady || ~isvalid(app.UIFigure);
        end

        function setGrid(app)
            % 切换网格精度：按当前布局、功率与风扇设置重建求解器
            if app.SteadyRunning, return; end
            if strcmp(app.GridDrop.Value, '精确 280²'), newScale = 1; else, newScale = 0.5; end
            if ~app.rebuildSolver(app.Solver.layout, newScale)
                % 重建失败：下拉框回到原网格档（GridScale 由 rebuildSolver 保持原值）
                if app.GridScale >= 1, app.GridDrop.Value = '精确 280²'; else, app.GridDrop.Value = '预览 140²'; end
            end
        end

        function applyGridMode(app)
            % 预览档（140²）湍流隔步更新，稳态结温与逐步更新相差约 1°C，耗时约减半
            if app.GridScale < 1
                app.Solver.turbUpdateEvery = 2;
            else
                app.Solver.turbUpdateEvery = 1;
            end
        end

        function ok = rebuildSolver(app, L, gridScale)
            % 按布局 L（与网格档 gridScale，缺省为当前档）重建求解器，保留功率与全局风扇设置，
            % 重绘全部图层。构建或重画任何一步出错都整体回滚到原求解器与原网格档并报错，
            % 返回 false；回滚本身再出错时至少保证求解器、网格档与湍流子循环设置一致。
            if nargin < 3, gridScale = app.GridScale; end
            if app.IsRunning, app.toggleRun(); end
            old = app.Solver; oldScale = app.GridScale;
            oldTurb = old.turbUpdateEvery;
            oldSteady = app.SteadyIter; oldMsg = app.StatusMsg;
            dlg = [];
            try
                dlg = uiprogressdlg(app.UIFigure, 'Title', '请稍候', 'Message', '正在重建流场…', 'Indeterminate', 'on');
            catch
            end
            closer = onCleanup(@() app.closeDialog(dlg)); %#ok<NASGU>   % 任何退出路径都关闭进度框
            ok = false;
            try
                s = CFDSolverFEM(old.powerW.cpu, old.powerW.gpu, old.powerW.psu, L, gridScale);
                s.autoFanEnabled = old.autoFanEnabled;
                s.fanSpeedRatio = old.fanSpeedRatio;
                app.GridScale = gridScale;
                app.installSolver(s);
                ok = true;
            catch ME
                app.GridScale = oldScale;
                try
                    app.installSolver(old);
                catch ME2
                    app.Solver = old;           % 重画失败：至少保持求解器引用一致
                    fprintf('回滚重画失败：%s\n', ME2.message);
                end
                old.turbUpdateEvery = oldTurb;
                app.SteadyIter = oldSteady; app.StatusMsg = oldMsg;
                app.reportError('重建失败，已保留原布局', ME);
            end
        end

        function closeDialog(~, dlg)
            if ~isempty(dlg) && isvalid(dlg), close(dlg); end
        end

        function installSolver(app, s)
            % 设为当前求解器并重画全部图层与数值显示；重画中被捕获的异常转为抛出
            prevErr = app.LastError;
            app.LastError = '';
            app.Solver = s;
            app.applyGridMode();
            app.SteadyIter = -1;
            app.StatusMsg = '';
            cla(app.MainAxes);
            cla(app.SideAxes);
            app.hContour = [];
            app.initStaticGraphics();
            app.clearHistory();
            app.updateVisualizations();
            app.updateUI();
            if ~isempty(app.LastError)
                err = app.LastError;
                app.LastError = prevErr;
                error('PCAirflowSimulatorApp:redraw', '%s', err);
            end
            app.LastError = prevErr;
        end

        function clearHistory(app)
            app.timeHistory = [];
            app.cpuTempHistory = [];
            app.gpuTempHistory = [];
            app.rearExhaustTempHistory = [];
            for k = 1:numel(app.hSideLine)
                h = app.hSideLine{k};
                if ~isempty(h) && isvalid(h), set(h, 'XData', nan, 'YData', nan); end
            end
            xlim(app.SideAxes, 'auto');
        end

        function resetSim(app)
            if app.IsRunning, app.toggleRun(); end
            app.Solver.reset();   % 场、几何、风扇状态、热网络全部回到初始态
            app.SteadyIter = -1;
            app.StatusMsg = '';
            if ~isempty(app.Tracer), app.Tracer.reset(app.Solver); end
            app.clearHistory();
            app.updateVisualizations();
            app.updateUI();
        end

        % ================= 风扇布局编辑 =================
        function setPendingFromLayout(app, L)
            % 以布局 L 作为待编辑布局（安装位状态、电源仓挡板开孔）
            app.PendingBase = L;
            app.SlotStates = layout_slots('get', L);
            sl = layout_gpu_slots(L);
            if isnan(sl)
                app.GpuSlotsDrop.Enable = 'off';
            else
                [~, i] = min(abs(app.GPU_SLOT_VALUES - sl));
                app.GpuSlotsDrop.Value = app.GPU_SLOT_ITEMS{i};
                app.GpuSlotsDrop.Enable = 'on';
            end
            if isfield(L, 'shroud') && isfield(L.shroud, 'gaps')
                if ~isempty(L.shroud.gaps), app.DefaultGaps = L.shroud.gaps; end
                app.ShroudGapCheck.Value = ~isempty(L.shroud.gaps);
            end
        end

        function L = pendingLayout(app)
            % 待应用的完整布局：基底 + 安装位状态 + 挡板开孔 + 当前功率
            L = layout_slots('set', app.PendingBase, app.SlotStates);
            if isfield(L, 'shroud')
                if app.ShroudGapCheck.Value
                    L.shroud.gaps = app.DefaultGaps;
                else
                    L.shroud.gaps = struct('x0Mm', {}, 'x1Mm', {});
                end
            end
            if isfield(L, 'gpu') && ~isempty(L.gpu)
                sl = app.GPU_SLOT_VALUES(strcmp(app.GPU_SLOT_ITEMS, app.GpuSlotsDrop.Value));
                if ~isempty(sl) && sl ~= layout_gpu_slots(L)
                    L = layout_set_gpu_slots(L, sl);
                end
            end
            p = app.Solver.powerW;
            L.power = struct('cpu', p.cpu, 'gpu', p.gpu, 'psu', p.psu);
        end

        function D = slotTableData(app)
            slots = fan_slots();
            D = cell(numel(slots), 5);
            for k = 1:numel(slots)
                st = app.SlotStates(k);
                D{k, 1} = slots(k).id;
                D{k, 2} = slots(k).label;
                D{k, 3} = app.STATE_ITEMS{strcmp(app.STATE_KEYS, st.type)};
                D{k, 4} = st.model;
                if strcmp(st.speedMode, 'manual')
                    D{k, 5} = sprintf('%d%%', round(st.manualPct));
                else
                    D{k, 5} = '自动';
                end
            end
        end

        function refreshLayoutPanel(app)
            % 安装位表格、主视图标记、标称风量与冲突提示
            app.SlotTable.Data = app.slotTableData();
            app.updateSlotMarkers();
            try
                R = layout_fan_report(app.pendingLayout());
            catch ME
                R = layout_fan_report(app.PendingBase);
                R.warnings = [{['布局无效：' ME.message]}, R.warnings];
            end
            if app.LayoutDirty
                st = sprintf('待应用：%s（点"应用布局"后生效）', app.LayoutLabel);
                app.ApplyLayoutBtn.BackgroundColor = [0.75 0.45 0.05];
            else
                st = sprintf('当前：%s', app.AppliedLabel);
                app.ApplyLayoutBtn.BackgroundColor = [0 0.4 0.6];
            end
            app.LayoutInfoLabel.Text = sprintf('%s\n标称进/排 满速 %.0f / %.0f CFM（%s）\n低速 %.0f / %.0f CFM（%s）', ...
                st, R.intakeCfm, R.exhaustCfm, R.pressure, R.intakeCfmIdle, R.exhaustCfmIdle, R.pressureIdle);
            if isempty(R.warnings)
                app.LayoutWarnArea.Value = {'安装检查：无冲突'};
            else
                app.LayoutWarnArea.Value = R.warnings(:);
            end
        end

        function layoutEdited(app, fansChanged)
            % 布局有未应用的修改；改动风扇时布局名变为"自定义"（挡板开孔单列在方案表中）
            if nargin < 2, fansChanged = true; end
            app.LayoutDirty = true;
            if fansChanged, app.LayoutLabel = '自定义'; end
            app.refreshLayoutPanel();
        end

        function onSlotClick(app, k)
            % 点击主视图安装位：空 → 进气 → 排气 → 空
            i = find(strcmp(app.STATE_KEYS, app.SlotStates(k).type), 1);
            app.SlotStates(k).type = app.STATE_KEYS{mod(i, 3) + 1};
            app.layoutEdited();
        end

        function onSlotEdit(app, event)
            r = event.Indices(1); c = event.Indices(2);
            v = event.NewData;
            switch c
                case 3
                    i = find(strcmp(app.STATE_ITEMS, v), 1);
                    if ~isempty(i), app.SlotStates(r).type = app.STATE_KEYS{i}; end
                case 4
                    if any(strcmp(app.MODEL_ITEMS, v)), app.SlotStates(r).model = v; end
                case 5
                    if strcmp(v, '自动')
                        app.SlotStates(r).speedMode = 'auto';
                    else
                        pct = sscanf(v, '%f');
                        if ~isempty(pct)
                            app.SlotStates(r).speedMode = 'manual';
                            app.SlotStates(r).manualPct = min(100, max(0, pct(1)));
                        end
                    end
            end
            app.layoutEdited();
        end

        function loadPreset(app)
            P = fan_presets();
            i = find(strcmp({P.label}, app.PresetDrop.Value), 1);
            if isempty(i), return; end
            L = layout_apply_preset(app.PendingBase, P(i).name);
            app.PendingBase = L;
            app.SlotStates = layout_slots('get', L);
            app.LayoutDirty = true;
            app.LayoutLabel = P(i).label;
            app.refreshLayoutPanel();
        end

        function revertLayout(app)
            app.setPendingFromLayout(app.Solver.layout);
            app.LayoutDirty = false;
            app.LayoutLabel = app.AppliedLabel;
            app.refreshLayoutPanel();
        end

        function ok = applyLayout(app, runSteady)
            % 按待应用布局重建求解器；构建失败时保持原求解器，返回 false
            ok = false;
            if app.SteadyRunning, return; end
            try
                L = app.pendingLayout();
            catch ME
                app.reportError('布局无效', ME);
                return;
            end
            if ~app.rebuildSolver(L), return; end
            ok = true;
            app.PendingBase = L;
            app.LayoutDirty = false;
            app.AppliedLabel = app.LayoutLabel;
            app.refreshLayoutPanel();
            if runSteady, app.solveSteady(); end
        end

        function saveLayoutDialog(app)
            [f, p] = uiputfile('*.json', '保存风扇布局配置', 'pcflow_layout.json');
            if isequal(f, 0), return; end
            app.saveLayoutFile(fullfile(p, f));
        end

        function saveLayoutFile(app, file)
            try
                layout_json('save', app.pendingLayout(), file);
            catch ME
                app.reportError('保存配置失败', ME);
            end
        end

        function loadLayoutDialog(app)
            [f, p] = uigetfile('*.json', '载入风扇布局配置');
            if isequal(f, 0), return; end
            app.loadLayoutFile(fullfile(p, f));
        end

        function loadLayoutFile(app, file)
            if app.SteadyRunning, return; end
            try
                L = layout_json('load', file);
            catch ME
                app.reportError('读取配置失败', ME);
                return;
            end
            old = app.Solver.layout;
            oldP = app.Solver.powerW;
            try
                app.setPendingFromLayout(L);
                if isfield(L, 'power'), app.setPowers([L.power.cpu L.power.gpu L.power.psu]); end
                [~, name, ext] = fileparts(file);
                app.LayoutLabel = ['配置 ' name ext];
                ok = app.applyLayout(false);
            catch ME
                app.reportError('配置无效', ME);
                ok = false;
            end
            if ~ok        % 恢复原布局与功率
                app.setPendingFromLayout(old);
                app.setPowers([oldP.cpu oldP.gpu oldP.psu]);
                app.LayoutLabel = app.AppliedLabel;
                app.LayoutDirty = false;
                app.refreshLayoutPanel();
            end
        end

        function reportError(app, msg, ME)
            app.LastError = sprintf('%s：%s', msg, ME.message);
            fprintf('%s\n', app.LastError);
            if app.QuietAlerts, return; end
            try
                uialert(app.UIFigure, ME.message, msg);
            catch
            end
        end

        % ================= 方案对比 =================
        function idx = selectedScenario(app)
            idx = find(strcmp(app.SCENARIO_NAMES, app.ScenarioDrop.Value), 1);
        end

        function snap = snapshot(app, withField)
            % 当前方案快照（summary 等见 scenario_table；T 为温度场，温差视图用）
            s = app.Solver;
            p = s.powerW;
            snap = struct('summary', s.scenarioSummary(), 'label', app.AppliedLabel, ...
                'powers', [p.cpu p.gpu p.psu], 'gridScale', app.GridScale, ...
                'steady', s.iteration == app.SteadyIter, 'layout', s.layout, ...
                'autoFan', s.autoFanEnabled, 'fanSpeedRatio', s.fanSpeedRatio, 'T', []);
            if withField, snap.T = app.temperatureField(); end
        end

        function saveScenario(app, idx)
            if nargin < 2, idx = app.selectedScenario(); end
            app.Scenarios{idx} = app.snapshot(true);
            app.refreshScenarioTable();
            if strcmp(app.VisMode, 'diff'), app.updateVisualizations(); end
        end

        function loadScenario(app, idx)
            if app.SteadyRunning, return; end
            if nargin < 2, idx = app.selectedScenario(); end
            snap = app.Scenarios{idx};
            if isempty(snap), return; end
            s0 = app.Solver;
            p0 = s0.powerW; auto0 = s0.autoFanEnabled; pct0 = s0.fanSpeedRatio;
            ok = false;
            try
                app.setPendingFromLayout(snap.layout);
                app.setPowers(snap.powers);
                app.setGlobalFan(snap.autoFan, snap.fanSpeedRatio);
                app.LayoutLabel = snap.label;
                ok = app.applyLayout(false);
            catch ME
                app.reportError('载入方案失败', ME);
            end
            if ~ok                              % 失败：恢复原布局、功率与风扇设置
                app.setPendingFromLayout(s0.layout);
                app.setPowers([p0.cpu p0.gpu p0.psu]);
                app.setGlobalFan(auto0, pct0);
                app.LayoutLabel = app.AppliedLabel;
                app.LayoutDirty = false;
                app.refreshLayoutPanel();
            end
        end

        function clearScenario(app, idx)
            if nargin < 2, idx = app.selectedScenario(); end
            app.Scenarios{idx} = [];
            app.refreshScenarioTable();
            if strcmp(app.VisMode, 'diff'), app.updateVisualizations(); end
        end

        function refreshScenarioTable(app)
            [~, data] = scenario_table([{app.snapshot(false)}, app.Scenarios]);
            app.ScenarioTable.Data = data;
        end
    end

    methods (Access = public)
        function app = PCAirflowSimulatorApp()
            app.createComponents();
            app.setupSimulation();
            app.refreshLayoutPanel();
            app.refreshScenarioTable();
            app.updateVisualizations();
            app.updateUI();
            app.startParticleAnim();
        end

        function closeApp(app)
            app.CancelSteady = true;     % 跑稳态中关窗：下一次进度回调即停止
            if ~isempty(app.GifFile), app.stopGif(); end
            app.deleteTimers();
            app.IsRunning = false;
            drawnow;
            if ~isempty(app.UIFigure) && isvalid(app.UIFigure)
                delete(app.UIFigure);
            end
        end

        function delete(app)
            app.deleteTimers();
            drawnow;
            if ~isempty(app.UIFigure) && isvalid(app.UIFigure)
                delete(app.UIFigure);
            end
        end

        function deleteTimers(app)
            tm = {app.SimTimer, app.ParticleTimer};
            for k = 1:2
                t = tm{k};
                if ~isempty(t) && isvalid(t)
                    stop(t);
                    delete(t);
                end
            end
        end

        function runTestHook(app, action, varargin)
            %RUNTESTHOOK Headless 测试钩子：将外部调用转发到私有方法（仅供 test_ui.m 使用）。
            %   界面控件的回调可直接由测试调用（见 test_ui 的 ui_press 等），
            %   这里只转发没有对应控件或会弹出文件对话框的操作。
            switch action
                case 'setScenario',    app.setScenario(varargin{:});
                case 'setMode',        app.setMode(varargin{:});
                case 'toggleRun',      app.toggleRun();
                case 'resetSim',       app.resetSim();
                case 'onTimer',        app.onTimer();
                case 'saveLayoutFile', app.saveLayoutFile(varargin{:});
                case 'loadLayoutFile', app.loadLayoutFile(varargin{:});
                case 'particleTick',   app.particleTick();
                case 'hoverAt',        app.hoverAt(varargin{:});
                case 'exportPng',      app.exportPng(varargin{:});
                case 'startGif',       app.startGif(varargin{:});
                case 'stopGif',        app.stopGif();
                case 'refresh'
                    app.updateVisualizations();
                    app.updateUI();
                otherwise
                    error('Unknown test action: %s', action);
            end
        end
    end
end
