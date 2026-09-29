classdef PCAirflowSimulatorApp < handle
    %PCAIRFLOWSIMULATORAPP PC风道仿真器 MATLAB App v3.3.1
    % 基于Navier-Stokes + LVEL 湍流模型 + 共轭传热的可视化仿真程序
    % 视图优化版：预渲染静态几何、等温线、流线图、area填充
    
    properties (Access = public)
        UIFigure      matlab.ui.Figure
        MainAxes      matlab.ui.control.UIAxes
        SideAxes      matlab.ui.control.UIAxes
        
        % 功率标签引用
        CPUPowerLbl       matlab.ui.control.Label
        GPUPowerLbl       matlab.ui.control.Label
        PSUPowerLbl       matlab.ui.control.Label
        FanSpeedLbl       matlab.ui.control.Label
        
        % 状态标签
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
        
        % CFD诊断标签
        ReynoldsLabel      matlab.ui.control.Label
        GrashofLabel       matlab.ui.control.Label
        NusseltLabel       matlab.ui.control.Label
        FlowRegimeLabel    matlab.ui.control.Label
        RayleighLabel      matlab.ui.control.Label
        DeadZoneLabel      matlab.ui.control.Label
        
        % 智能诊断文本区
        RecTextArea        matlab.ui.control.TextArea
        
        % 滑块
        CPUPowerSlider     matlab.ui.control.Slider
        GPUPowerSlider     matlab.ui.control.Slider
        PSUPowerSlider     matlab.ui.control.Slider
        FanSpeedSlider     matlab.ui.control.Slider
        
        % 按钮
        AutoFanButton      matlab.ui.control.Button
        ModeVelocityBtn    matlab.ui.control.Button
        ModeTempBtn        matlab.ui.control.Button
        ModeVorticityBtn   matlab.ui.control.Button
        ModeSolidBtn       matlab.ui.control.Button
        RunButton          matlab.ui.control.Button
        SteadyButton       matlab.ui.control.Button
        ResetButton        matlab.ui.control.Button
        DailyBtn           matlab.ui.control.Button
        GamingBtn          matlab.ui.control.Button
        HeavyBtn           matlab.ui.control.Button
        
        % 核心求解器
        Solver         CFDSolverFEM
        SimTimer       timer
        IsRunning      logical = false
        VisMode        char = 'velocity'   % 'velocity','temperature','vorticity','solid'
        StepsPerFrame  double = 2
        StepPending    logical = false     % 防止timer堆积
        
        % ===== 预渲染图形 handle（视图优化）=====
        hImg
        hCbar
        hContour
        hStream
        hSideLine          % 3×1 handle数组：CPU/GPU/后侧排气温度曲线
        
        % ===== 温度曲线历史数据 =====
        timeHistory = []
        cpuTempHistory = []
        gpuTempHistory = []
        rearExhaustTempHistory = []
        maxHistoryPoints = 300
    end
    
    methods (Access = private)
        function createComponents(app)
            app.UIFigure = uifigure('Name','PC风道仿真器 v3.3.1','Position',[100 50 1200 850],...
                'Color',[0.02 0.02 0.05],'WindowStyle','normal');
            
            % ========== 左侧可视化面板 ==========
            mainPanel = uipanel(app.UIFigure,'Position',[10 10 750 830],...
                'BackgroundColor',[0.05 0.05 0.08],'BorderType','line','HighlightColor',[0.1 0.1 0.2]);
            
            app.MainAxes = uiaxes(mainPanel,'Position',[10 420 730 400],...
                'Color',[0.05 0.05 0.08],'XColor',[0.3 0.3 0.4],'YColor',[0.3 0.3 0.4]);
            title(app.MainAxes,'流场仿真','Color',[0.8 0.8 1],'FontSize',12);
            app.MainAxes.XTick = []; app.MainAxes.YTick = [];
            axis(app.MainAxes,'equal','tight');
            hold(app.MainAxes,'on');
            disableDefaultInteractivity(app.MainAxes);
            
            app.SideAxes = uiaxes(mainPanel,'Position',[10 10 730 400],...
                'Color',[0.05 0.05 0.08],'XColor',[0.3 0.3 0.4],'YColor',[0.3 0.3 0.4]);
            title(app.SideAxes,'温度曲线','Color',[0.8 0.8 1],'FontSize',12);
            app.SideAxes.XTick = []; app.SideAxes.YTick = [];
            hold(app.SideAxes,'on');
            disableDefaultInteractivity(app.SideAxes);

            % 用空 ContextMenu 覆盖内置 WebContextMenuController，避免右键时报错
            cm = uicontextmenu(app.UIFigure);
            app.UIFigure.ContextMenu = cm;
            app.MainAxes.ContextMenu = cm;
            app.SideAxes.ContextMenu = cm;

            % ========== 右侧控制面板 ==========
            ctrlPanel = uipanel(app.UIFigure,'Position',[770 10 420 830],...
                'BackgroundColor',[0.05 0.05 0.08],'BorderType','line','HighlightColor',[0.1 0.1 0.2]);
            yPos = 800;
            
            % --- 标题 ---
            uilabel(ctrlPanel,'Position',[10 yPos 400 25],...
                'Text','PC风道仿真器 v3.3.1','FontSize',16,'FontWeight','bold',...
                'FontColor',[0.27 0.53 1],'HorizontalAlignment','center');
            yPos = yPos - 30;
            
            % --- 温度/状态显示 ---
            pStatus = uipanel(ctrlPanel,'Position',[10 yPos-80 400 80],...
                'BackgroundColor',[0.07 0.07 0.12],'BorderType','line','Title','实时状态','TitlePosition','centertop',...
                'FontSize',11,'ForegroundColor',[0 0.83 1],'HighlightColor',[0.1 0.1 0.2]);
            app.IntakeTempLabel = uilabel(pStatus,'Position',[10 45 90 20],'Text','进气: --°C','FontColor',[0.27 0.53 1],'FontSize',11);
            app.TopExhaustLabel = uilabel(pStatus,'Position',[105 45 90 20],'Text','顶排: --°C','FontColor',[1 0.4 0.27],'FontSize',11);
            app.SideExhaustLabel = uilabel(pStatus,'Position',[200 45 90 20],'Text','后排: --°C','FontColor',[1 0.4 0.27],'FontSize',11);
            app.InternalTempLabel = uilabel(pStatus,'Position',[295 45 90 20],'Text','内部: --°C','FontColor',[0.67 0.53 1],'FontSize',11);
            app.NoiseLabel = uilabel(pStatus,'Position',[10 20 90 20],'Text','噪音: --dB','FontColor',[1 0.8 0],'FontSize',11);
            app.PerformanceLabel = uilabel(pStatus,'Position',[105 20 90 20],'Text','性能: --%','FontColor',[0 1 0.53],'FontSize',11);
            app.CPUTempLabel = uilabel(pStatus,'Position',[200 20 90 20],'Text','CPU: --°C','FontColor',[0.8 0.8 0.8],'FontSize',11);
            app.GPUTempLabel = uilabel(pStatus,'Position',[295 20 90 20],'Text','GPU: --°C','FontColor',[0.8 0.8 0.8],'FontSize',11);
            yPos = yPos - 90;
            
            % --- 综合评分 ---
            pScore = uipanel(ctrlPanel,'Position',[10 yPos-80 400 80],...
                'BackgroundColor',[0.07 0.07 0.12],'BorderType','line','Title','综合评分','TitlePosition','centertop',...
                'FontSize',11,'ForegroundColor',[0 0.83 1],'HighlightColor',[0.1 0.1 0.2]);
            app.TotalScoreLabel = uilabel(pScore,'Position',[10 45 120 25],'Text','总分: --/100','FontSize',16,'FontWeight','bold','FontColor',[1 1 1]);
            app.ScoreCoolingLabel = uilabel(pScore,'Position',[140 45 80 20],'Text','散热: --','FontColor',[0.8 0.8 0.8],'FontSize',11);
            app.ScorePerfLabel = uilabel(pScore,'Position',[230 45 80 20],'Text','性能: --','FontColor',[0.8 0.8 0.8],'FontSize',11);
            app.ScoreBalanceLabel = uilabel(pScore,'Position',[320 45 80 20],'Text','均衡: --','FontColor',[0.8 0.8 0.8],'FontSize',11);
            app.ScoreMarginLabel = uilabel(pScore,'Position',[140 20 80 20],'Text','余量: --','FontColor',[0.8 0.8 0.8],'FontSize',11);
            app.ScoreNoiseLabel = uilabel(pScore,'Position',[230 20 80 20],'Text','噪音: --','FontColor',[0.8 0.8 0.8],'FontSize',11);
            app.ScoreValueLabel = uilabel(pScore,'Position',[320 20 80 20],'Text','性价比: --','FontColor',[0.8 0.8 0.8],'FontSize',11);
            yPos = yPos - 90;
            
            % --- CFD诊断 ---
            pCFD = uipanel(ctrlPanel,'Position',[10 yPos-110 400 110],...
                'BackgroundColor',[0.07 0.07 0.12],'BorderType','line','Title','CFD诊断','TitlePosition','centertop',...
                'FontSize',11,'ForegroundColor',[0 0.83 1],'HighlightColor',[0.1 0.1 0.2]);
            app.ReynoldsLabel = uilabel(pCFD,'Position',[10 75 120 18],'Text','Re: --','FontColor',[0 0.83 1],'FontSize',11);
            app.GrashofLabel = uilabel(pCFD,'Position',[140 75 120 18],'Text','Gr: --','FontColor',[0 0.83 1],'FontSize',11);
            app.NusseltLabel = uilabel(pCFD,'Position',[270 75 120 18],'Text','Nu: --','FontColor',[0 0.83 1],'FontSize',11);
            app.FlowRegimeLabel = uilabel(pCFD,'Position',[10 50 380 18],'Text','流动状态: --','FontColor',[0 0.83 1],'FontSize',11);
            app.RayleighLabel = uilabel(pCFD,'Position',[10 25 120 18],'Text','Ra: --','FontColor',[0 0.83 1],'FontSize',11);
            app.DeadZoneLabel = uilabel(pCFD,'Position',[140 25 120 18],'Text','死区: --%','FontColor',[1 0.2 0.53],'FontSize',11);
            yPos = yPos - 120;
            
            % --- 智能诊断 ---
            pRec = uipanel(ctrlPanel,'Position',[10 yPos-120 400 120],...
                'BackgroundColor',[0.07 0.07 0.12],'BorderType','line','Title','智能诊断','TitlePosition','centertop',...
                'FontSize',11,'ForegroundColor',[0 0.83 1],'HighlightColor',[0.1 0.1 0.2]);
            app.RecTextArea = uitextarea(pRec,'Position',[10 10 380 90],'Editable','off',...
                'BackgroundColor',[0.07 0.07 0.12],'FontColor',[0.8 0.8 0.8],'FontSize',11);
            yPos = yPos - 130;
            
            % --- 功率调整 ---
            pPower = uipanel(ctrlPanel,'Position',[10 yPos-110 400 110],...
                'BackgroundColor',[0.07 0.07 0.12],'BorderType','line','Title','功率调整','TitlePosition','centertop',...
                'FontSize',11,'ForegroundColor',[0 0.83 1],'HighlightColor',[0.1 0.1 0.2]);
            uilabel(pPower,'Position',[10 80 40 18],'Text','CPU','FontColor',[0.8 0.8 0.8],'FontSize',11);
            app.CPUPowerSlider = uislider(pPower,'Position',[60 88 180 3],'Limits',[20 250],'Value',125);
            app.CPUPowerSlider.ValueChangedFcn = @(src,event)app.CPUPowerSliderValueChanged(event);
            app.CPUPowerLbl = uilabel(pPower,'Position',[250 80 50 18],'Text','125W','FontColor',[0.8 0.8 0.8],'FontSize',11);
            
            uilabel(pPower,'Position',[10 50 40 18],'Text','GPU','FontColor',[0.8 0.8 0.8],'FontSize',11);
            app.GPUPowerSlider = uislider(pPower,'Position',[60 58 180 3],'Limits',[20 400],'Value',250);
            app.GPUPowerSlider.ValueChangedFcn = @(src,event)app.GPUPowerSliderValueChanged(event);
            app.GPUPowerLbl = uilabel(pPower,'Position',[250 50 50 18],'Text','250W','FontColor',[0.8 0.8 0.8],'FontSize',11);
            
            uilabel(pPower,'Position',[10 20 40 18],'Text','PSU','FontColor',[0.8 0.8 0.8],'FontSize',11);
            app.PSUPowerSlider = uislider(pPower,'Position',[60 28 180 3],'Limits',[50 1200],'Value',450);
            app.PSUPowerSlider.ValueChangedFcn = @(src,event)app.PSUPowerSliderValueChanged(event);
            app.PSUPowerLbl = uilabel(pPower,'Position',[250 20 50 18],'Text','450W','FontColor',[0.8 0.8 0.8],'FontSize',11);
            
            app.DailyBtn = uibutton(pPower,'Position',[310 70 80 22],'Text','办公','FontSize',10,...
                'BackgroundColor',[0.1 0.1 0.2],'FontColor',[0.8 0.8 0.8],'ButtonPushedFcn',@(src,event)app.setScenario('daily'));
            app.GamingBtn = uibutton(pPower,'Position',[310 40 80 22],'Text','游戏','FontSize',10,...
                'BackgroundColor',[0.1 0.1 0.2],'FontColor',[0.8 0.8 0.8],'ButtonPushedFcn',@(src,event)app.setScenario('gaming'));
            app.HeavyBtn = uibutton(pPower,'Position',[310 10 80 22],'Text','满载','FontSize',10,...
                'BackgroundColor',[0.1 0.1 0.2],'FontColor',[0.8 0.8 0.8],'ButtonPushedFcn',@(src,event)app.setScenario('heavy'));
            yPos = yPos - 120;
            
            % --- 风扇控制 ---
            pFan = uipanel(ctrlPanel,'Position',[10 yPos-80 400 80],...
                'BackgroundColor',[0.07 0.07 0.12],'BorderType','line','Title','风扇控制','TitlePosition','centertop',...
                'FontSize',11,'ForegroundColor',[0 0.83 1],'HighlightColor',[0.1 0.1 0.2]);
            app.AutoFanButton = uibutton(pFan,'Position',[10 45 60 25],'Text','自动','FontSize',10,...
                'BackgroundColor',[0 0.2 0.3],'FontColor',[0 0.83 1],'ButtonPushedFcn',@(src,event)app.toggleAutoFan());
            uilabel(pFan,'Position',[80 45 40 18],'Text','全局','FontColor',[0.8 0.8 0.8],'FontSize',11);
            app.FanSpeedSlider = uislider(pFan,'Position',[120 53 180 3],'Limits',[0 100],'Value',40);
            app.FanSpeedSlider.ValueChangedFcn = @(src,event)app.FanSpeedSliderValueChanged(event);
            app.FanSpeedLbl = uilabel(pFan,'Position',[310 45 50 18],'Text','40%','FontColor',[0.8 0.8 0.8],'FontSize',11);
            yPos = yPos - 90;
            
            % --- 视图与操作 ---
            pView = uipanel(ctrlPanel,'Position',[10 yPos-110 400 110],...
                'BackgroundColor',[0.07 0.07 0.12],'BorderType','line','Title','视图与操作','TitlePosition','centertop',...
                'FontSize',11,'ForegroundColor',[0 0.83 1],'HighlightColor',[0.1 0.1 0.2]);
            app.ModeVelocityBtn = uibutton(pView,'Position',[10 75 85 22],'Text','速度场','FontSize',10,...
                'BackgroundColor',[0 0.2 0.3],'FontColor',[0 0.83 1],'ButtonPushedFcn',@(src,event)app.setMode('velocity'));
            app.ModeTempBtn = uibutton(pView,'Position',[105 75 85 22],'Text','温度场','FontSize',10,...
                'BackgroundColor',[0.1 0.1 0.2],'FontColor',[0.8 0.8 0.8],'ButtonPushedFcn',@(src,event)app.setMode('temperature'));
            app.ModeVorticityBtn = uibutton(pView,'Position',[200 75 85 22],'Text','涡量','FontSize',10,...
                'BackgroundColor',[0.1 0.1 0.2],'FontColor',[0.8 0.8 0.8],'ButtonPushedFcn',@(src,event)app.setMode('vorticity'));
            app.ModeSolidBtn = uibutton(pView,'Position',[295 75 85 22],'Text','固体温度','FontSize',10,...
                'BackgroundColor',[0.1 0.1 0.2],'FontColor',[0.8 0.8 0.8],'ButtonPushedFcn',@(src,event)app.setMode('solid'));
            
            app.RunButton = uibutton(pView,'Position',[10 40 120 28],'Text','▶ 开始仿真','FontSize',11,...
                'BackgroundColor',[0 0.4 0.6],'FontColor',[1 1 1],'FontWeight','bold','ButtonPushedFcn',@(src,event)app.toggleRun());
            app.SteadyButton = uibutton(pView,'Position',[140 40 120 28],'Text','⏩ 快速推进','FontSize',11,...
                'BackgroundColor',[0.1 0.1 0.2],'FontColor',[0.8 0.8 0.8],'ButtonPushedFcn',@(src,event)app.solveSteady());
            app.ResetButton = uibutton(pView,'Position',[270 40 120 28],'Text','重置','FontSize',11,...
                'BackgroundColor',[0.1 0.1 0.2],'FontColor',[0.8 0.8 0.8],'ButtonPushedFcn',@(src,event)app.resetSim());
            
            uilabel(pView,'Position',[10 10 380 18],...
                'Text','⚠ 2D 定性教学模型，结温预测精度 ±25% 仅供参考','FontColor',[0.85 0.55 0.2],'FontSize',9);
            
            % 窗口关闭时自动停止timer
            app.UIFigure.CloseRequestFcn = @(src,event)app.closeApp();
        end
        
        function initStaticGraphics(app)
            ax = app.MainAxes;
            s = app.Solver;
            W = s.GRID.W; H = s.GRID.H;
            
            % 预创建图像对象（坐标轴范围 [1 W] x [1 H]）
            app.hImg = imagesc(ax, [1 W], [1 H], zeros(W, H));
            axis(ax, 'image');
            ax.YDir = 'reverse';  % y=1在顶（顶排风扇），y=H在底（PSU在左下角）
            ax.XTick = []; ax.YTick = [];
            hold(ax, 'on');
            
            % 预创建 colorbar
            app.hCbar = colorbar(ax, 'eastoutside');
            app.hCbar.Color = [0.7 0.7 0.8];
            app.hCbar.Label.Color = [0.7 0.7 0.8];
            app.hCbar.FontSize = 7;
            
            % 等温线按需创建（初始速度为零时跳过，避免常量ZData警告）
            app.hContour = gobjects(0);
            
            % 流线图对象由 updateVisualizations 按需创建（初始速度为零时 streamslice 返回空）
            app.hStream = [];
            
            % ========== 静态几何（仅绘制一次）==========
            plotRect = @(x,y,w,h,col,lw) plot(ax,[x x+w x+w x x],[y y y+h y+h y],'Color',col,'LineWidth',lw);
            lb = @(x,y,w,h,t,col,sz) text(ax,x+w/2,y+h/2,t,'Color',col,'FontSize',sz,'FontWeight','bold','HorizontalAlignment','center','VerticalAlignment','middle','Interpreter','none');
            
            % 机箱外框（机箱壁位置，非计算域边界）
            plotRect(s.caseOffsetX+1, s.caseOffsetY+1, 200, 200, [0.60 0.60 0.72], 2.5);
            
            % 主板区
            mb = s.CASE2D.motherboard_tray;
            plot(ax,[mb.x mb.x+mb.w mb.x+mb.w mb.x mb.x],[mb.y mb.y mb.y+mb.h mb.y+mb.h mb.y],'--','Color',[0.20 0.68 0.28],'LineWidth',1.2);
            text(ax,mb.x+5,mb.y+6,'主板区','Color',[0.25 0.78 0.35],'FontSize',7,'FontWeight','bold','HorizontalAlignment','left','VerticalAlignment','top','Interpreter','none');
            
            % VRM
            vrm = s.VRM.heatsink;
            plotRect(vrm.x,vrm.y,vrm.w,vrm.h,[0.85 0.85 0.85],2.5);
            lb(vrm.x,vrm.y,vrm.w,vrm.h,'VRM',[0.95 0.95 0.95],5);
            
            % RAM x4
            for ri = 1:size(s.RAM_SLOTS,1)
                rm = s.RAM_SLOTS(ri);
                plotRect(rm.x,rm.y,rm.w,rm.h,[0.72 0.30 1.0],2.5);
            end
            r1 = s.RAM_SLOTS(1);
            text(ax,r1.x+r1.w+2,r1.y+7,'RAMx4','Color',[0.80 0.50 1.0],'FontSize',6,'FontWeight','bold','HorizontalAlignment','left','VerticalAlignment','middle','Interpreter','none');
            
            % CPU底座
            cb = s.CPU_HEATSINK.base;
            plotRect(cb.x,cb.y,cb.w,cb.h,[0.00 0.75 1.0],2.0);
            lb(cb.x,cb.y,cb.w,cb.h,'CPU',[0.40 0.90 1.0],8);
            
            % 塔式风冷散热器
            cf = s.CPU_HEATSINK.fin_area;
            cfW = min(W, cf.x+cf.w-1) - cf.x;
            plotRect(cf.x,cf.y,cfW,cf.h,[0.00 0.60 1.0],2.0);
            text(ax,cf.x+cfW/2,cf.y+cf.h/2,'塔式散热器','Color',[0.30 0.80 1.0],'FontSize',7,'FontWeight','bold','HorizontalAlignment','center','VerticalAlignment','middle','Interpreter','none');
            
            % Chipset
            chip = s.CHIPSET.heatsink;
            plotRect(chip.x,chip.y,chip.w,chip.h,[0.80 0.80 0.80],2.0);
            lb(chip.x,chip.y,chip.w,chip.h,'芯',[0.90 0.90 0.90],5);
            
            % GPU散热片
            gh = s.GPU_HEATSINK.heatsink;
            ghW = min(W, gh.x+gh.w-1) - gh.x;
            plotRect(gh.x,gh.y,ghW,gh.h,[0.85 0.28 0.05],1.5);
            
            % GPU PCB
            gp = s.GPU_HEATSINK.pcb;
            plotRect(gp.x,gp.y,gp.w,gp.h,[1.0 0.38 0.00],2.0);
            lb(gp.x,gp.y,gp.w,gp.h,'GPU',[1.0 0.75 0.40],9);
            
            % PSU
            psu = s.PSU2D.body;
            plotRect(psu.x,psu.y,psu.w,psu.h,[0.88 0.80 0.00],2.0);
            lb(psu.x,psu.y,psu.w,psu.h,'PSU',[1.0 0.95 0.30],8);
            
            % 机箱风扇 RealFan
            th36 = linspace(0,2*pi,36);
            for k = 1:length(s.fans)
                f   = s.fans{k};
                bnd = f.getBounds();
                cx  = bnd.x + bnd.w/2;
                cy  = bnd.y + bnd.h/2;
                r   = max(bnd.w,bnd.h)/2;
                switch f.mount
                    case {'front','right'};  rawDx= 1; rawDy= 0;
                    case 'rear';             rawDx=-1; rawDy= 0;
                    case 'top';              rawDx= 0; rawDy=-1;
                    case 'bottom';           rawDx= 0; rawDy= 1;
                    otherwise;               rawDx= 1; rawDy= 0;
                end
                if strcmp(f.type,'intake')
                    col = [0.00 0.92 0.55]; lbl = '进风'; dxi = -rawDx; dyi = -rawDy;
                else
                    col = [1.00 0.28 0.28]; lbl = '出风'; dxi =  rawDx; dyi =  rawDy;
                end
                plot(ax,cx+r*cos(th36),cy+r*sin(th36),'-','Color',col,'LineWidth',1.8);
                text(ax,cx,cy,lbl,'Color',col,'FontSize',6,'FontWeight','bold','HorizontalAlignment','center','VerticalAlignment','middle','Interpreter','none');
                quiver(ax,cx-dxi*r*0.5,cy-dyi*r*0.5,dxi*r*0.8,dyi*r*0.8,'AutoScale','off','Color',col,'MaxHeadSize',1.5,'LineWidth',1.2);
            end
            
            % 内置风扇（顶部排气风扇 + GPU底部风扇）
            th28 = linspace(0,2*pi,28);
            for k = 1:length(s.builtInFans)
                f   = s.builtInFans{k};
                bnd = f.getBounds();
                cx  = bnd.x + bnd.w/2;
                r   = max(bnd.w,bnd.h)/2;
                if strcmp(f.mount,'top')
                    % 顶部机箱排气风扇：画在顶边实际位置
                    col  = [0.35 0.75 1.0];
                    cy_t = max(r, bnd.y + bnd.h/2);
                    rf   = min(r, cy_t - 1);
                    plot(ax, cx+rf*cos(th28), cy_t+rf*sin(th28), '--', 'Color', col, 'LineWidth', 1.0);
                    % 排气箭头：向上（-y方向）
                    quiver(ax, cx, cy_t+rf*0.5, 0, -(rf+4), 'AutoScale','off','Color',col,'MaxHeadSize',2.5,'LineWidth',1.1);
                    text(ax, cx, cy_t, '排气', 'Color', col, 'FontSize', 6, 'FontWeight','bold', ...
                        'HorizontalAlignment','center','VerticalAlignment','middle','Interpreter','none');
                elseif strcmp(f.mount,'cpu_tower')
                    % CPU塔式风冷风扇：画在鳍片区中心，气流从右到左
                    col  = [0.0 0.85 0.85];
                    cy_t = bnd.y + bnd.h/2;
                    rf   = min(r, 30);
                    plot(ax, cx+rf*cos(th28), cy_t+rf*sin(th28), '--', 'Color', col, 'LineWidth', 1.0);
                    % 气流从右到左（-x方向），机箱内部
                    quiver(ax, cx+rf*0.5, cy_t, -rf*0.8, 0, 'AutoScale','off','Color',col,'MaxHeadSize',1.5,'LineWidth',1.1);
                    text(ax, cx, cy_t, 'CPU风扇', 'Color', col, 'FontSize', 6, 'FontWeight','bold', ...
                        'HorizontalAlignment','center','VerticalAlignment','middle','Interpreter','none');
                elseif strcmp(f.mount,'gpu_bottom')
                    % GPU底部风扇：画在GPU卡下方
                    col  = [1.0 0.55 0.15];
                    cy_b = bnd.y + bnd.h/2;
                    rf   = max(bnd.w, bnd.h)/2;
                    plot(ax, cx+rf*cos(th28), cy_b+rf*sin(th28), '--', 'Color', col, 'LineWidth', 1.0);
                    % 风扇将冷气向上（-y）抽入GPU散热片
                    quiver(ax, cx, cy_b, 0, -12, 'AutoScale','off','Color',col,'MaxHeadSize',1.5,'LineWidth',1.0);
                end
            end
            
            % 方位标注（YDir='reverse'：y=1在顶，y=H在底）
            text(ax,W/2,3,'▲ 顶排出风','Color',[0.55 0.55 0.65],'FontSize',6,'HorizontalAlignment','center','VerticalAlignment','top','Interpreter','none');
            text(ax,3,H-3,'← 后排气','Color',[0.55 0.55 0.65],'FontSize',7,'HorizontalAlignment','left','VerticalAlignment','bottom','Interpreter','none');
            text(ax,W-3,H-3,'前进气 →','Color',[0.55 0.55 0.65],'FontSize',7,'HorizontalAlignment','right','VerticalAlignment','bottom','Interpreter','none');
            
            % 尺度条
            plot(ax,[5 55],[H-8 H-8],'-','Color',[0.90 0.90 0.90],'LineWidth',2.5);
            plot(ax,[5  5],[H-10 H-6],'-','Color',[0.90 0.90 0.90],'LineWidth',1.5);
            plot(ax,[55 55],[H-10 H-6],'-','Color',[0.90 0.90 0.90],'LineWidth',1.5);
            text(ax,30,H-4,'100 mm','Color',[0.90 0.90 0.90],'FontSize',7,'HorizontalAlignment','center','Interpreter','none');
            
            % 主坐标轴保持 hold on，防止 streamslice/contour 清除静态图层

            % ========== SideAxes 预创建（时间-温度曲线）==========
            ax2 = app.SideAxes;
            hold(ax2, 'on');
            app.hSideLine = gobjects(3,1);
            app.hSideLine(1) = plot(ax2, nan, nan, 'Color', [1 0.3 0.3], 'LineWidth', 1.5, 'DisplayName', 'CPU');
            app.hSideLine(2) = plot(ax2, nan, nan, 'Color', [0.3 1 0.3], 'LineWidth', 1.5, 'DisplayName', 'GPU');
            app.hSideLine(3) = plot(ax2, nan, nan, 'Color', [0.3 0.6 1], 'LineWidth', 1.5, 'DisplayName', '后侧排气');
            legend(ax2, 'Location', 'northwest', 'Color', [0.1 0.1 0.15], 'TextColor', [0.7 0.7 0.8], 'FontSize', 8);
            xlabel(ax2,'时间 (s)','Color',[0.6 0.6 0.7],'FontSize',11);
            ylabel(ax2,'温度 (°C)','Color',[0.6 0.6 0.7],'FontSize',11);
            ax2.Color = [0.05 0.05 0.08];
            ax2.XColor = [0.4 0.4 0.5];
            ax2.YColor = [0.4 0.4 0.5];
            grid(ax2,'on');
            ylim(ax2, [20, 110]);
            hold(ax2, 'off');
        end
        
        function setupSimulation(app)
            app.Solver = CFDSolverFEM();
            app.SimTimer = timer('ExecutionMode','fixedRate','Period',0.3,'TimerFcn',@(t,event)app.onTimer());
            app.initStaticGraphics();
        end
        
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
                [uCgA, vCgA] = app.Solver.getCellVelocity();  % v3.0: 统一读取口
                maxVel = max(sqrt(uCgA.^2 + vCgA.^2));
                if maxVel < 0.3
                    app.StepsPerFrame = 4;   % 低速时加速收敛
                elseif maxVel > 1.2
                    app.StepsPerFrame = 1;   % 高速时保持响应与稳定
                else
                    app.StepsPerFrame = 2;   % 常规工况
                end
                app.Solver.stepMultiple(app.StepsPerFrame);
                app.updateVisualizations();
                app.updateUI();
                app.StepPending = false;
            catch ME
                app.StepPending = false;
                if ~isempty(app.SimTimer) && isvalid(app.SimTimer)
                    stop(app.SimTimer);
                end
                fprintf('Timer error: %s\n', ME.message);
                disp(getReport(ME));
            end
        end
        
        function updateVisualizations(app)
            if ~isvalid(app.UIFigure) || ~isvalid(app.MainAxes), return; end
            try
                ax = app.MainAxes;
                hold(ax, 'on');   % 保持 hold on，防止 streamslice/contour 清除 hImg 等静态图层
                W = app.Solver.GRID.W; H = app.Solver.GRID.H;
                cbLabel = '';
                contourLevels = [];
                contourColor = [1 1 1];
                showStream = false;
                
                switch app.VisMode
                    case 'velocity'
                        [uCgV, vCgV] = app.Solver.getCellVelocity();  % v3.0: 统一读取口
                        % v3.3.1：×VEL_SCALE 转 m/s（审计 P1——旧版直接显示网格
                        % 单位却标注 m/s，显示值比真实速度高 1.8 倍且满屏削顶；
                        % 与 generate_snapshots 渲染路径同口径，CLim 同步 [0 2]）
                        velMag = reshape(sqrt(uCgV.^2 + vCgV.^2), W, H) * app.Solver.VEL_SCALE;
                        obs2d  = reshape(app.Solver.obstacle, W, H) > 0;
                        velMag(obs2d) = NaN;
                        field = velMag;
                        set(app.hImg, 'CData', field);
                        ax.Colormap = jet(256);
                        ax.CLim = [0 2];
                        cbLabel = '速度 (m/s)';
                        title(ax,'速度场 (m/s)','Color',[0.8 0.8 1]);
                        showStream = true;
                    case 'temperature'
                        field = reshape(app.Solver.T_fluid, W, H);
                        % v3.0.7：障碍格改显示 T_solid（元件结温/壁温），不再显示
                        % 平流采样残留的 ~25°C 冷值（旧版 CPU/GPU/PSU 体内一片深黑，
                        % 易被误读为"元件很冷"）；CLim 上限 80→100，减少高端截断
                        % （旧版 ≥80°C 全白，85 与钳位 200 无法区分）。
                        obsT = reshape(app.Solver.obstacle, W, H) > 0;
                        TsolT = reshape(app.Solver.T_solid, W, H);
                        field(obsT) = TsolT(obsT);
                        set(app.hImg, 'CData', field);
                        ax.Colormap = hot(256);
                        ax.CLim = [20 100];
                        cbLabel = '温度 (°C)';
                        title(ax,'流体温度场 (°C)','Color',[0.8 0.8 1]);
                        contourLevels = [30 40 50 60];
                        contourColor = [0 1 1];
                    case 'vorticity'
                        field = reshape(app.Solver.latestVorticity, W, H);
                        set(app.hImg, 'CData', field);
                        ax.Colormap = cool(256);
                        ax.CLim = [-2 2];
                        cbLabel = '涡量';
                        title(ax,'涡量场','Color',[0.8 0.8 1]);
                        contourLevels = 0;
                        contourColor = [1 1 0];
                    case 'solid'
                        field = reshape(app.Solver.T_solid, W, H);
                        set(app.hImg, 'CData', field);
                        ax.Colormap = parula(256);
                        ax.CLim = [20 90];
                        cbLabel = '固体温度 (°C)';
                        title(ax,'固体温度 (°C)','Color',[0.8 0.8 1]);
                        contourLevels = [40 60 80];
                        contourColor = [1 1 1];
                end
                
                app.hCbar.Label.String = cbLabel;
                
                % 等温线 / 涡量线（删除重建；contour 第二输出才是句柄）
                if ~isempty(app.hContour) && all(isvalid(app.hContour))
                    delete(app.hContour);
                end
                app.hContour = gobjects(0);
                if ~isempty(contourLevels) && range(field(:)) > 0.5
                    [~, hc] = contour(ax, 1:W, 1:H, field, contourLevels, 'LineColor', contourColor, 'LineWidth', 1.2);
                    app.hContour = hc;
                end
                
                % 流线图（速度场模式）— 障碍物区域 NaN 屏蔽，防止流线穿固体
                if showStream
                    if ~isempty(app.hStream) && all(isvalid(app.hStream))
                        delete(app.hStream);
                    end
                    app.hStream = [];
                    [uCgS, vCgS] = app.Solver.getCellVelocity();  % v3.0: 统一读取口
                    umat = reshape(uCgS, W, H);
                    vmat = reshape(vCgS, W, H);
                    obs2d = reshape(app.Solver.obstacle, W, H) > 0;
                    umat(obs2d) = NaN;
                    vmat(obs2d) = NaN;
                    % density=1.5，单标量避免被误判为3D调用
                    hs = streamslice(ax, 1:W, 1:H, umat, vmat, 1.5);
                    if ~isempty(hs)
                        set(hs, 'Color', [1 1 1], 'LineWidth', 0.8);
                        app.hStream = hs;
                    end
                else
                    if ~isempty(app.hStream) && all(isvalid(app.hStream))
                        set(app.hStream, 'Visible', 'off');
                    end
                end
                
                drawnow limitrate;
            catch ME
                fprintf('updateVisualizations error: %s\n', ME.message);
            end
            app.updateSideView();
        end
        
        function updateSideView(app)
            if ~isvalid(app.SideAxes), return; end
            try
                % iteration 是累计总步数，物理时间 = 步数 × 固定步长 DT；
                % 不能再乘自适应的 StepsPerFrame（会放大且跳变时非单调）
                t = app.Solver.iteration * app.Solver.DT;
                
                cpuT = app.Solver.thermalNetworks.cpu.T_junction;
                gpuT = app.Solver.thermalNetworks.gpu.T_junction;
                if ~isempty(app.Solver.lastTemps)
                    rearT = app.Solver.lastTemps.rearExhaust;
                else
                    rearT = 25;
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
                
                set(app.hSideLine(1), 'XData', app.timeHistory, 'YData', app.cpuTempHistory);
                set(app.hSideLine(2), 'XData', app.timeHistory, 'YData', app.gpuTempHistory);
                set(app.hSideLine(3), 'XData', app.timeHistory, 'YData', app.rearExhaustTempHistory);
                
                if length(app.timeHistory) > 1 && app.timeHistory(end) > app.timeHistory(1)
                    xlim(app.SideAxes, [app.timeHistory(1), app.timeHistory(end)]);
                end
                title(app.SideAxes, '温度曲线', 'Color', [0.8 0.8 1]);
                drawnow limitrate;
            catch ME
                fprintf('updateSideView error: %s\n', ME.message);
            end
        end
        
        function updateUI(app)
            if ~isvalid(app.UIFigure), return; end
            try
                scores = app.Solver.calculateScores();
            catch
                scores = struct('intake',25,'topExhaust',25,'rearExhaust',25,'internalAmbient',25,...
                    'noiseDb',0,'performance',0,'cpuTemp',25,'gpuTemp',25,'total',0,...
                    'cooling',0,'balance',0,'margin',0,'noise',0,'value',0);
            end
            if isvalid(app.IntakeTempLabel)
                app.IntakeTempLabel.Text = sprintf('进气: %.1f°C', scores.intake);
            end
            if isvalid(app.TopExhaustLabel), app.TopExhaustLabel.Text = sprintf('顶排: %.1f°C', scores.topExhaust); end
            if isvalid(app.SideExhaustLabel), app.SideExhaustLabel.Text = sprintf('后排: %.1f°C', scores.rearExhaust); end
            if isvalid(app.InternalTempLabel), app.InternalTempLabel.Text = sprintf('内部: %.1f°C', scores.internalAmbient); end
            if isvalid(app.NoiseLabel), app.NoiseLabel.Text = sprintf('噪音: %ddB', scores.noiseDb); end
            if isvalid(app.PerformanceLabel), app.PerformanceLabel.Text = sprintf('性能: %d%%', scores.performance); end
            if isvalid(app.CPUTempLabel), app.CPUTempLabel.Text = sprintf('CPU: %d°C', scores.cpuTemp); end
            if isvalid(app.GPUTempLabel), app.GPUTempLabel.Text = sprintf('GPU: %d°C', scores.gpuTemp); end
            if isvalid(app.TotalScoreLabel), app.TotalScoreLabel.Text = sprintf('总分: %d/100', scores.total); end
            if isvalid(app.ScoreCoolingLabel), app.ScoreCoolingLabel.Text = sprintf('散热: %d', scores.cooling); end
            if isvalid(app.ScorePerfLabel), app.ScorePerfLabel.Text = sprintf('性能: %d', scores.performance); end
            if isvalid(app.ScoreBalanceLabel), app.ScoreBalanceLabel.Text = sprintf('均衡: %d', scores.balance); end
            if isvalid(app.ScoreMarginLabel), app.ScoreMarginLabel.Text = sprintf('余量: %d', scores.margin); end
            if isvalid(app.ScoreNoiseLabel), app.ScoreNoiseLabel.Text = sprintf('噪音: %d', scores.noise); end
            if isvalid(app.ScoreValueLabel), app.ScoreValueLabel.Text = sprintf('性价比: %d', scores.value); end
            
            if ~isempty(app.Solver.lastDiag)
                diag = app.Solver.lastDiag;
                if isvalid(app.ReynoldsLabel), app.ReynoldsLabel.Text = sprintf('Re: %.1e', diag.Re); end
                if isvalid(app.GrashofLabel), app.GrashofLabel.Text = sprintf('Gr: %.1e', diag.Gr); end
                if isvalid(app.NusseltLabel), app.NusseltLabel.Text = sprintf('Nu: %.1f', diag.Nu); end
                if isvalid(app.FlowRegimeLabel), app.FlowRegimeLabel.Text = sprintf('流动状态: %s', diag.flowRegime); end
                if isvalid(app.RayleighLabel), app.RayleighLabel.Text = sprintf('Ra: %.1e', diag.Ra); end
            else
                % 初始/重置态：清空诊断标签，避免显示上一轮残值
                if isvalid(app.ReynoldsLabel),   app.ReynoldsLabel.Text   = 'Re: --'; end
                if isvalid(app.GrashofLabel),    app.GrashofLabel.Text    = 'Gr: --'; end
                if isvalid(app.NusseltLabel),    app.NusseltLabel.Text    = 'Nu: --'; end
                if isvalid(app.FlowRegimeLabel), app.FlowRegimeLabel.Text = '流动状态: --'; end
                if isvalid(app.RayleighLabel),   app.RayleighLabel.Text   = 'Ra: --'; end
            end
            if isvalid(app.DeadZoneLabel), app.DeadZoneLabel.Text = sprintf('死区: %.1f%%', app.Solver.deadZoneRatio*100); end
            
            recs = app.Solver.getRecommendations();
            nRec = length(recs);
            recLines = cell(nRec, 1);
            for k = 1:nRec
                r = recs{k};
                switch r.level
                    case 'good', prefix = '[OK] ';
                    case 'warning', prefix = '[!] ';
                    otherwise, prefix = '[-] ';
                end
                recLines{k} = sprintf('%s%s: %s', prefix, r.title, r.desc);
            end
            if isvalid(app.RecTextArea), app.RecTextArea.Value = recLines; end
        end
        
        % ---------- 回调函数 ----------
        function CPUPowerSliderValueChanged(app, ~)
            val = round(app.CPUPowerSlider.Value);
            app.Solver.heatSources.cpu.power = val;
            app.Solver.thermalNetworks.cpu.power = val;
            app.Solver.thermalNetworks.cpu.actual_power = val;
            app.Solver.thermalNetworks.cpu.throttling_ratio = 0;
            app.CPUPowerLbl.Text = sprintf('%dW', val);
        end
        
        function GPUPowerSliderValueChanged(app, ~)
            val = round(app.GPUPowerSlider.Value);
            app.Solver.heatSources.gpu.power = val;
            app.Solver.thermalNetworks.gpu.power = val;
            app.Solver.thermalNetworks.gpu.actual_power = val;
            app.Solver.thermalNetworks.gpu.throttling_ratio = 0;
            app.GPUPowerLbl.Text = sprintf('%dW', val);
        end
        
        function PSUPowerSliderValueChanged(app, ~)
            val = round(app.PSUPowerSlider.Value);
            app.Solver.heatSources.psu.power = val;
            app.Solver.thermalNetworks.psu.power = val*(1-0.90);
            app.Solver.thermalNetworks.psu.actual_power = app.Solver.thermalNetworks.psu.power;
            app.Solver.thermalNetworks.psu.throttling_ratio = 0;
            app.PSUPowerLbl.Text = sprintf('%dW', val);
        end
        
        function FanSpeedSliderValueChanged(app, ~)
            val = round(app.FanSpeedSlider.Value);
            app.Solver.fanSpeedRatio = val;
            app.Solver.autoFanEnabled = false;
            app.AutoFanButton.Text = '手动';
            app.AutoFanButton.BackgroundColor = [0.1 0.1 0.2];
            app.FanSpeedLbl.Text = sprintf('%d%%', val);
        end
        
        function toggleAutoFan(app)
            app.Solver.autoFanEnabled = ~app.Solver.autoFanEnabled;
            if app.Solver.autoFanEnabled
                app.AutoFanButton.Text = '自动';
                app.AutoFanButton.BackgroundColor = [0 0.2 0.3];
            else
                app.AutoFanButton.Text = '手动';
                app.AutoFanButton.BackgroundColor = [0.1 0.1 0.2];
            end
            if ~app.IsRunning
                app.updateUI();
            end
        end
        
        function setScenario(app, scenario)
            switch scenario
                case 'daily', cpu=40; gpu=35; psu=200;
                case 'gaming', cpu=100; gpu=200; psu=500;
                case 'heavy', cpu=180; gpu=320; psu=850;
                otherwise, return;
            end
            app.CPUPowerSlider.Value = cpu;
            app.GPUPowerSlider.Value = gpu;
            app.PSUPowerSlider.Value = psu;
            app.CPUPowerSliderValueChanged([]);
            app.GPUPowerSliderValueChanged([]);
            app.PSUPowerSliderValueChanged([]);
        end
        
        function setMode(app, mode)
            app.VisMode = mode;
            buttons = [app.ModeVelocityBtn, app.ModeTempBtn, app.ModeVorticityBtn, app.ModeSolidBtn];
            modes = {'velocity','temperature','vorticity','solid'};
            for k = 1:length(buttons)
                if strcmp(modes{k}, mode)
                    buttons(k).BackgroundColor = [0 0.2 0.3];
                    buttons(k).FontColor = [0 0.83 1];
                else
                    buttons(k).BackgroundColor = [0.1 0.1 0.2];
                    buttons(k).FontColor = [0.8 0.8 0.8];
                end
            end
            app.updateVisualizations();
        end
        
        function toggleRun(app)
            if app.IsRunning
                if ~isempty(app.SimTimer) && isvalid(app.SimTimer) && strcmp(app.SimTimer.Running, 'on')
                    stop(app.SimTimer);
                end
                if isvalid(app.RunButton)
                    app.RunButton.Text = '▶ 开始仿真';
                    app.RunButton.BackgroundColor = [0 0.4 0.6];
                end
                app.IsRunning = false;
            else
                if ~isempty(app.SimTimer) && isvalid(app.SimTimer)
                    if strcmp(app.SimTimer.Running, 'on')
                        stop(app.SimTimer);
                    end
                else
                    app.SimTimer = timer('ExecutionMode','fixedRate','Period',0.3,'TimerFcn',@(t,event)app.onTimer());
                end
                start(app.SimTimer);
                if isvalid(app.RunButton)
                    app.RunButton.Text = '⏸ 暂停仿真';
                    app.RunButton.BackgroundColor = [0.6 0.2 0.2];
                end
                app.IsRunning = true;
            end
        end
        
        function solveSteady(app)
            % 按钮防抖：计算期间禁用相关按钮
            app.SteadyButton.Enable = 'off';
            app.RunButton.Enable = 'off';
            app.ResetButton.Enable = 'off';
            app.SteadyButton.Text = '计算中...';
            app.SteadyButton.BackgroundColor = [0.4 0.4 0.4];
            drawnow;
            batch = 30;
            for k = 1:5
                app.Solver.stepMultiple(batch);
                app.updateVisualizations();
                app.updateUI();
                drawnow;
            end
            app.SteadyButton.Text = '⏩ 快速推进';
            app.SteadyButton.BackgroundColor = [0.1 0.1 0.2];
            app.SteadyButton.Enable = 'on';
            app.RunButton.Enable = 'on';
            app.ResetButton.Enable = 'on';
        end
        
        function resetSim(app)
            if app.IsRunning
                if isvalid(app.SimTimer)
                    stop(app.SimTimer);
                end
                app.IsRunning = false;
                % v3.3.1（审计 P3）：图窗高负载死亡后残余回调路径，
                % 与 toggleRun 的 isvalid 防护对齐
                if isvalid(app.RunButton)
                    app.RunButton.Text = '▶ 开始仿真';
                    app.RunButton.BackgroundColor = [0 0.4 0.6];
                end
            end
            app.Solver.initFields();
            app.Solver.initObstacles();
            app.Solver.initOpenBoundaries();  % 重建开口边界（风扇墙面格子）
            app.Solver.iteration = 0;
            % v3.3.1（审计 P2）：风扇 P-Q 折减系数同步复位——旧 lastFlowFactor
            % （运行中已衰减）叠加冷启动零流场，代数轨 T_rear=Q/(CFM·ρCp)
            % 在 CFM 估计暖机期发散，后排气曲线出现 ~119°C 启动尖峰
            for k = 1:numel(app.Solver.fans)
                app.Solver.fans{k}.lastFlowFactor = 1;
            end
            app.Solver.thermalNetworks.cpu.T_junction = 25;
            app.Solver.thermalNetworks.cpu.T_theory_f = 25;  % v3.0.7 节流滤波态同步复位
            app.Solver.thermalNetworks.cpu.throttling_ratio = 0;
            app.Solver.thermalNetworks.cpu.actual_power = app.Solver.thermalNetworks.cpu.power;
            app.Solver.thermalNetworks.gpu.T_junction = 25;
            app.Solver.thermalNetworks.gpu.T_theory_f = 25;
            app.Solver.thermalNetworks.gpu.throttling_ratio = 0;
            app.Solver.thermalNetworks.gpu.actual_power = app.Solver.thermalNetworks.gpu.power;
            app.Solver.thermalNetworks.psu.T_junction = 25;
            app.Solver.thermalNetworks.psu.T_theory_f = 25;
            app.Solver.thermalNetworks.psu.throttling_ratio = 0;
            app.Solver.thermalNetworks.psu.actual_power = app.Solver.thermalNetworks.psu.power;
            % 清空温度曲线历史
            app.timeHistory = [];
            app.cpuTempHistory = [];
            app.gpuTempHistory = [];
            app.rearExhaustTempHistory = [];
            for k = 1:3
                set(app.hSideLine(k), 'XData', nan, 'YData', nan);
            end
            % 清空 CFD 诊断与温度场缓存（避免 reset 后右侧面板显示上一轮残值）
            app.Solver.lastDiag  = [];
            app.Solver.lastTemps = [];
            app.Solver.deadZoneRatio = 0;
            app.updateVisualizations();
            app.updateUI();
        end
    end
    
    methods (Access = public)
        function app = PCAirflowSimulatorApp()
            app.createComponents();
            app.setupSimulation();
            app.updateVisualizations();
            app.updateUI();
        end
        
        function closeApp(app)
            if ~isempty(app.SimTimer) && isvalid(app.SimTimer)
                stop(app.SimTimer);
                delete(app.SimTimer);
            end
            app.IsRunning = false;
            drawnow;
            if ~isempty(app.UIFigure) && isvalid(app.UIFigure)
                delete(app.UIFigure);
            end
        end

        function delete(app)
            if ~isempty(app.SimTimer) && isvalid(app.SimTimer)
                stop(app.SimTimer);
                delete(app.SimTimer);
            end
            drawnow;
            if ~isempty(app.UIFigure) && isvalid(app.UIFigure)
                delete(app.UIFigure);
            end
        end

        function runTestHook(app, action, varargin)
            %RUNTESTHOOK Headless 测试钩子：将外部调用转发到私有方法
            % 仅供 test_ui.m 使用；正常运行时由按钮回调直接触发对应私有方法
            switch action
                case 'setScenario', app.setScenario(varargin{:});
                case 'setMode',     app.setMode(varargin{:});
                case 'toggleRun',   app.toggleRun();
                case 'resetSim',    app.resetSim();
                case 'onTimer',     app.onTimer();
                case 'refresh'
                    app.updateVisualizations();
                    app.updateUI();
                otherwise
                    error('Unknown test action: %s', action);
            end
        end
    end
end
