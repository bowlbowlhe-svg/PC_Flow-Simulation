# PC 风道仿真器（MATLAB 版）

ATX 中塔机箱侧视 2D 风道与散热仿真：不可压 Navier–Stokes（MAC 交错网格投影法）+
k-ω 湍流 + 共轭传热，配交互式 MATLAB App。版本见 `src/pcflow_version.m`，更新记录见
[`../CHANGELOG.md`](../CHANGELOG.md)，开发计划见 [`../docs/ROADMAP.md`](../docs/ROADMAP.md)。

> ⚠ 2D 定性教学工具：用于理解风道布局、元件相对发热和趋势，不适用于产品级散热验证。

## 运行环境

- MATLAB R2021a 或更高（`decomposition`、`griddedInterpolant`、`uifigure` 为核心功能，无需工具箱）。
- 可选 Image Processing Toolbox（`bwdist`）；缺失时自动用内置慢速实现，初始化变慢。
- 求解器与数值测试也可在 GNU Octave 8+ 下无界面运行（`setup_paths` 自动加载
  `compat/octave/` 兼容层与 image 包）；App 仅支持 MATLAB。
- 请用 `setup_paths`（`run_simulator`/`run_all_tests` 会自动调用）加路径，不要
  `addpath(genpath(...))`——那会把 Octave 兼容层加进 MATLAB 路径（兼容层在 MATLAB 下会报错提示）。

## 快速开始

```matlab
cd matlab_app
run_simulator          % 启动 App
run_all_tests('quick') % 快速回归（几分钟）
run_all_tests          % 完整回归（守恒 1200 步 + 湍流，较慢）
run_all_tests('ui')    % 界面烟雾测试（仅 MATLAB）
```

无界面使用求解器：

```matlab
setup_paths();
s = CFDSolverFEM(125, 250, 450);          % CPU/GPU/电源负载 [W]，默认布局
s.stepMultiple(400);                      % 推进 400 步（DT = 5 ms）
s.thermalNetworks.gpu.T_junction          % GPU 结温
s.setComponentPower('gpu', 320);          % 改功率
s.reset();                                % 回到初始态
```

## 目录

```
matlab_app/
├── run_simulator.m        启动 App
├── run_all_tests.m        测试入口（quick / full / ui）
├── setup_paths.m          加路径（Octave 下加载兼容层）
├── src/                   求解器
│   ├── layout_default.m   默认布局配置（几何 mm、热参数、风扇）
│   ├── CFDSolverBase.m    几何、风扇、共轭传热、诊断、守恒计账、评分
│   ├── CFDSolverFEM.m     时间推进（扩散、投影、平流、湍流、温度）
│   ├── DetailedThermalNetwork.m  元件热网络（热阻 + 热惯性 + 节流）
│   ├── RealFan.m          机箱风扇（型号库、P-Q 曲线、格栅压损）
│   ├── BuiltInFan.m       内置风扇（顶排、CPU 塔扇、GPU 风扇）
│   └── pcflow_version.m
├── app/PCAirflowSimulatorApp.m   界面
├── tests/                 test_advection / test_reset / test_conservation / test_turbulence / test_ui
├── tools/                 generate_snapshots、网格敏感性研究、锚点标定
├── compat/octave/         Octave 兼容层（decomposition、griddedInterpolant）
└── snapshots/             快照输出
```

## 布局配置

`layout_default()` 返回一个只含数据的 struct：计算域与机箱尺寸、CPU/GPU/电源/内存等
元件矩形（mm，相对机箱原点，x 向前面板、y 向下）、多孔区参数、热阻参数、机箱风扇与
内置风扇。求解器按 `格 = round(mm / 格距)` 换算，同一配置可用于不同网格细化倍数（常用 0.5 / 1 / 2）。
`CFDSolverFEM(cpu, gpu, psu, layout, gridScale, dt)` 的 `layout` 可传布局名或配置 struct。

## 模型概要

| 部分 | 做法 |
|---|---|
| 网格 | 280×280、格距 2 mm；机箱 400 mm 见方，四周 80 mm 外部空气；最外 1 格为远场海绵层（阻尼 + 25°C + p=0）；机箱 Z 向有效深度 0.15 m |
| 动量 | MAC 交错网格；隐式扩散 → D·G 投影 → 面心半拉格朗日平流（cubic）→ 浮力、风扇、多孔阻力 → 再投影 |
| 湍流 | k-ω（Wilcox 2006 + 应力限制器 + 生产限制器）；可回退 LVEL |
| 温度 | 隐式扩散（机箱壁 25°C，内部件绝热）→ 半拉格朗日平流（makima）→ 元件热量以高斯核注入邻近流体 |
| 风扇 | 执行盘模型：P-Q 曲线工作点静压 × 风扇定律 −格栅压损 → 体积力 |
| 散热器 | CPU 鳍片、GPU 散热片为各向异性多孔区（Darcy-Forchheimer） |
| 结温 | 串联热阻 + 一阶热惯性 + 节流；环境温度取代数热平衡内温，h 取散热器附近 CFD 风速 |

## 稳态参考（v3.3.1 口径，400 步）

| 场景 | CPU/GPU/电源负载 | Tj CPU | Tj GPU | Tj PSU | 节流 |
|---|---|---|---|---|---|
| 游戏 | 100/200/500 W | 63 | 89 | 77 | PSU 25% |
| 默认 | 125/250/450 W | 70 | 91 | 84 | GPU 19%、PSU 3% |
| 满载 | 180/320/850 W | 84 | 96 | 98 | CPU 5%、GPU/PSU 35% |

Octave 兼容层下复算与 MATLAB 快照一致（默认场景 70.4/90.9/84.1°C）。

## 已知问题（阶段 2 修复中）

- 扩散系数少了 1/L² 因子（分子与湍流扩散弱约 3.2 倍）；浮力少除 `VEL_SCALE`（约为应有值 56%）。
- 风扇推力作用于半径 30 格的圆盘，但压升按 6 格盘厚换算，实际压升被放大（截面平均约 3.6 倍）。
- 进气风扇把盘内流体每步拉回 25°C，是机箱内的人为热汇。
- 结温的环境温度取整机充分混合的代数内温，CFD 温度场几乎不影响结温。
- GPU 固定热阻栈 0.23 K/W 偏大，默认/游戏/满载三场景自动风扇全部满速。
- 2D 侧视无法表示侧板风扇与 Z 向流路。

## 参考文献

- Yu, S. P., & Webb, R. L. (2001). Thermal design of a desktop computer system using CFD analysis. IEEE SEMI-THERM XVII.
- Agonafer, D., Liao, L., & Spalding, D. B. (1996). LVEL turbulence model for conjugate heat transfer at low Reynolds numbers. ASME EEP.
- Wilcox, D. C. (2006). Turbulence Modeling for CFD, 3rd ed. DCW Industries.
- Gray, D. D., & Giorgini, A. (1976). The validity of the Boussinesq approximation for liquids and gases. Int. J. Heat Mass Transfer.

## 许可

仅供学习与个人研究使用。
