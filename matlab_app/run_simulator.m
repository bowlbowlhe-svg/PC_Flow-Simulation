function run_simulator()
%RUN_SIMULATOR 启动 PC 风道仿真器（在 MATLAB 命令行输入 run_simulator）。
    appDir = fileparts(mfilename('fullpath'));
    if isempty(appDir), appDir = pwd; end
    addpath(appDir);
    setup_paths();

    % 清理残留窗口与定时器，防止重复启动异常
    close all force;
    delete(timerfindall);

    fprintf('========================================\n');
    fprintf('  PC风道仿真器 v%s (MATLAB版)\n', pcflow_version());
    fprintf('========================================\n');
    fprintf('正在初始化CFD求解器...\n');

    try
        PCAirflowSimulatorApp();
        fprintf('App已启动。\n');
        fprintf('提示: 点击"开始仿真"启动实时计算，或点击"快速推进"快进 150 步（≈0.75s 物理时间）。\n');
    catch ME
        fprintf('启动失败: %s\n', ME.message);
        disp(getReport(ME));
    end
end
