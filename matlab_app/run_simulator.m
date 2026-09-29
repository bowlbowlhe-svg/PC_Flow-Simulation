function run_simulator()
    %RUN_SIMULATOR 启动PC风道仿真器
    % 用法: 在MATLAB命令行输入 run_simulator
    %
    % 确保本文件所在文件夹在MATLAB路径中，或直接从该文件夹运行。
    
    scriptPath = mfilename('fullpath');
    if isempty(scriptPath)
        appDir = pwd;
    else
        appDir = fileparts(scriptPath);
    end
    
    % 添加依赖目录到路径
    addpath(appDir);
    
    % 清理残留窗口与定时器，防止重复启动异常
    close all force;
    delete(timerfindall);
    
    fprintf('========================================\n');
    fprintf('  PC风道仿真器 v3.3.1 (MATLAB版)\n');
    fprintf('========================================\n');
    fprintf('正在初始化CFD求解器...\n');
    
    try
        PCAirflowSimulatorApp();
        fprintf('App已启动。\n');
        fprintf('提示: 点击"开始仿真"按钮启动实时计算，\n');
        fprintf('      或点击"快速推进"快进 150 步（≈0.75s 物理时间，加速预览趋势；真稳态需数千步热浸透）。\n');
    catch ME
        fprintf('启动失败: %s\n', ME.message);
        disp(getReport(ME));
    end
end
