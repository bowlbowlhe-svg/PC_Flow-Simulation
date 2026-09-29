# PC 风道仿真器（MATLAB 版）

ATX 中塔机箱侧视 2D 风道与散热仿真：不可压 Navier–Stokes（MAC 交错网格投影法）+
k-ω 湍流 + 共轭传热，配交互式 MATLAB App。版本见 `src/pcflow_version.m`，更新记录见
[`../CHANGELOG.md`](../CHANGELOG.md)，开发计划见 [`../docs/ROADMAP.md`](../docs/ROADMAP.md)。

> ⚠ 2D 定性教学工具：用于理解风道布局、风扇配置与元件温度的趋势，不适用于产品级散热验证。

## 运行环境

- MATLAB R2021a 或更高（`decomposition`、`griddedInterpolant`、`uifigure` 为核心功能，无需工具箱）。
- 可选 Image Processing Toolbox（`bwdist`）；缺失时自动用内置慢速实现，初始化变慢。
- 求解器与数值测试也可在 GNU Octave 8+ 下无界面运行（`setup_paths` 自动加载
  `compat/octave/` 兼容层与 image 包）；App 仅支持 MATLAB（Octave 下的界面测试用桩对象，
  只验证回调逻辑）。
- 请用 `setup_paths`（`run_simulator`/`run_all_tests` 会自动调用）加路径，不要
  `addpath(genpath(...))`——那会把 Octave 兼容层加进 MATLAB 路径（兼容层在 MATLAB 下会报错提示）。

## 快速开始

```matlab
cd matlab_app
run_simulator          % 启动 App
run_all_tests('quick') % 快速回归（约 1 分钟）
run_all_tests          % 完整回归（含方腔、风道、稳态、守恒 1200 步、湍流，较慢）
run_all_tests('ui')    % 界面测试（MATLAB 驱动真实界面并截图；Octave 用桩对象）
```

## 界面

- **主视图**：速度场（流线）、温度场、涡量、固体温度、温差（当前 − 已保存方案）。
  机箱四壁外侧的虚线框是风扇安装位，**点击可切换 空 → 进气 → 排气**（绿 = 进气、红 = 排气）。
- **跑到稳态**：按收敛判据自动停止，运行中再点一次停止；结果显示在温度曲线标题上。
  网格可选"预览 140²"（快，结温与精确档相差约 0.2–1.3°C）或"精确 280²"。
- 右侧标签页：
  - **状态**：进气/排气/内部温度、结温、噪音、评分、CFD 诊断、智能诊断。
  - **功率与风扇**：CPU/GPU 功率、电源负载、场景按钮；全局风扇转速（自动温控 / 手动百分比）；
    每台风扇的转速、实测风量、自由风量、工作点静压、噪音。
  - **风扇布局**：8 个安装位的状态、型号、转速（自动 / 固定百分比）；预设布局；电源仓挡板
    前部开孔；标称进/排风量与正负压；安装冲突检查；"应用布局"或"应用并跑到稳态"；
    配置存取 JSON（含布局、功率与风扇设置）。
  - **方案对比**：把当前结果存为方案 A/B/C，逐项对比结温、内温、风量、正负压、噪音、评分；
    "载入布局"回到某个方案；"显示温差"查看当前温度场减去参考方案（需同一网格精度）。

无界面使用求解器：

```matlab
setup_paths();
s = CFDSolverFEM(125, 250, 450);          % CPU/GPU 功率、电源输出负载 [W]，默认布局
info = s.runToSteady();                   % 推进到稳态（约 600–1400 步，DT = 5 ms）
info.final                                % 最近一个窗口的均值，列名见 info.columns
s.thermalNetworks.gpu.T_junction          % GPU 结温（瞬时值）
s.setComponentPower('gpu', 320);          % 改功率
s.reset();                                % 回到初始态

L = layout_apply_preset(layout_default(), 'front_top');   % 换风扇布局预设
s = CFDSolverFEM(125, 250, 450, L, 0.5);                  % 0.5 = 预览网格
R = compare_presets(0.5);                                 % 全部预设跑到稳态并列表对比
```

## 目录

```
matlab_app/
├── run_simulator.m        启动 App
├── run_all_tests.m        测试入口（quick / full / ui）
├── setup_paths.m          加路径（Octave 下加载兼容层）
├── src/                   求解器
│   ├── layout_default.m   默认布局配置（几何 mm、热参数、风扇）
│   ├── layout_benchmark.m 验证用简化布局（空域、方腔、风道）
│   ├── fan_slots.m        机箱风扇安装位（前 3、顶 2、后 1、底 2）
│   ├── fan_presets.m      风扇布局预设；layout_apply_preset 应用预设
│   ├── layout_slots.m     安装位状态 ↔ 布局 caseFans；layout_fan_report 安装检查与标称风量
│   ├── layout_json.m      布局 JSON 存取
│   ├── scenario_table.m   方案对比表；fan_pressure_label 正负压判断；pcflow_colormap 配色
│   ├── fan_catalog.m      风扇型号库（参数 + P-Q 曲线）
│   ├── Fan.m              风扇（执行盘、P-Q 工作点、温控、噪音）
│   ├── CFDSolverBase.m    几何、风扇与开口、共轭传热、诊断、守恒计账、评分
│   ├── CFDSolverFEM.m     时间推进（扩散、投影、平流、湍流、温度）
│   ├── DetailedThermalNetwork.m  元件热网络（热阻 + 热惯性 + 节流）
│   └── pcflow_version.m
├── app/PCAirflowSimulatorApp.m   界面
├── tests/                 平流、reset、扩散、布局、方腔、风道、稳态、守恒、湍流、界面测试
│   ├── steady_reference.json  test_steady 的精确档参考值（tools/make_steady_reference 生成）
│   └── ui_mock/           Octave 界面桩（MockUI 等），test_ui 在 Octave 下自动使用
├── tools/                 预设对比（compare_presets）、参考值生成、快照、网格敏感性、耗时剖析
├── compat/octave/         Octave 兼容层（decomposition、griddedInterpolant）
└── snapshots/             快照输出（旧文件为 v3.3.1 口径，用 tools/generate_snapshots 重新生成）
```

## 布局配置

`layout_default()` 返回一个只含数据的 struct（可 `jsonencode` 保存）：

| 字段 | 内容 |
|---|---|
| `domain` / `chassis` | 计算域与机箱尺寸（mm）、机箱 Z 向深度、各壁温度（NaN = 绝热） |
| `cpu` / `gpu` / `psu` | 元件矩形（mm，相对机箱原点，x 向前面板、y 向下）、多孔区阻力、热阻、内置风扇；可缺省 |
| `caseFans` | 机箱风扇：安装壁（front/rear/top/bottom）、沿壁中心位置 `alongMm`、进/排气、型号、转速模式（`auto` 跟随全局 / `manual` + `manualPct`） |
| `shroud` | 电源仓挡板高度与缺口（`gaps` 为空 = 不开孔） |
| `vents` / `solidBlocks` / `porousBlocks` | 被动通风口、实心障碍、多孔障碍（可选） |
| `grille` / `fanDiskMm` | 风扇开口格栅阻力 ζ、执行盘厚度 |

求解器按 `格 = round(mm / 格距)` 换算，同一配置可用于不同网格细化倍数（常用 0.5 / 1 / 2）。

### 风扇安装位与预设

| 安装位 | F1 前上 | F2 前中 | F3 前下 | T1 顶后 | T2 顶前 | R1 后部 | B1 底中 | B2 底前 |
|---|---|---|---|---|---|---|---|---|
| 壁 / 中心 mm | 前 100 | 前 220 | 前 338 | 顶 140 | 顶 260 | 后 124 | 底 230 | 底 338 |

前/后壁的坐标从顶向下量，顶/底壁从后向前量（相对机箱外沿）。F2 正对显卡上半部与 CPU 塔扇进风，
F3 正对显卡风扇进风并跨过电源仓挡板前缺口。400 mm 机箱放不下两台并排的 120 mm 底部风扇，
B1/B2 按 2D 简化重叠 12 mm。`layout_fan_report` 会报出同壁重叠（> 15 mm）、超出壁面、
与电源重叠的风扇。

预设（`fan_presets`）：2 前进 · 后顶出（默认）、1 前进 · 后顶出、前进后出、前进顶出、底进顶出、
正压（3 进 1 出）、负压（1 进 3 出）、全装。

## 模型概要

| 部分 | 做法 |
|---|---|
| 网格 | 280×280、格距 2 mm；机箱 400 mm 见方，四周 80 mm 外部空气；最外 1 格为远场海绵层（阻尼 + 环境温度 + p=0）；机箱 Z 向有效深度 0.15 m |
| 动量 | MAC 交错网格；隐式扩散 → 投影 → 面心半拉格朗日平流 → 浮力、风扇 → 阻力耦合投影 |
| 湍流 | k-ω（Wilcox 2006 + 应力限制器 + 生产限制器）；可选 LVEL 或层流 |
| 温度 | 隐式扩散（定温壁 Dirichlet，其余绝热）→ 半拉格朗日平流（makima）→ 元件热量注入散热体内流体 |
| 风扇 | 执行盘：厚 12 mm、宽 = 风扇直径，穿盘静压升 = P-Q 曲线工作点 × 风扇定律（超过自由风量时外推为负压） |
| 阻力 | 散热器、电源内部为各向异性多孔区；开口格栅/滤网为穿壁面阻力 ζ·½ρv²；阻力与压力在同一投影中耦合求解（阻力系数按施加风扇力之前的速度取，避免风扇盘与格栅面重合处阻力被放大） |
| 结温 | 串联热阻 + 一阶热惯性 + 节流；环境温度 = 散热器进风侧 CFD 温度，h 取散热体内平均风速（不设下限，风扇提速即降温） |
| 电源 | 自带风道：底部进风、后部排出；损耗 = 负载 × (1/η − 1)，80 PLUS 金牌典型效率曲线；超温只告警 |
| 温控 | 机箱风扇跟 CPU/GPU 最高温，塔扇跟 CPU，显卡风扇跟 GPU，电源风扇跟电源 |

单位：求解器内部速度为网格单位，物理速度 = 网格速度 × VEL_SCALE（(W−2)·格距 ≈ 0.556 m）；
扩散算子系数为 1/格距²（ν、α 为 m²/s）；浮力、风扇、阻力均换算到同一网格速度口径。

## 验证

| 测试 | 内容 | 结果（Octave） |
|---|---|---|
| `test_diffusion` | 高斯包方差增长 vs 解析解（温度两条装配路径、速度 u/v 面） | 比值 1.000 |
| `test_cavity` | 差分加热方腔 vs de Vahl Davis 1983 | Ra=1e4：Nu 2.300（基准 2.243，+2.5%）；Ra=1e5：4.613（4.519，+2.1%） |
| `test_fan_duct` | 风扇-风道工作点 vs P-Q 与系统曲线交点 | ζ=5/20/60：−1.9%/−3.0%/−2.4%（解析式未计入壁面摩擦与剖面不均），容差 ±5% |
| `test_steady` | 预览档跑到稳态 vs 精确档参考值（`steady_reference.json`） | 结温 −0.2/−0.2/+1.3°C，风量 +2% |
| `test_conservation` | 全域逐步能量计账、机箱内区算子平衡、收敛趋势 | 见 CHANGELOG |
| `test_layout` | 安装位读写、8 个预设、JSON 往返（含绝热壁 NaN）、安装检查 | 通过 |
| `test_ui` | 按用户操作触发全部控件回调：视图、布局编辑、预设、跑稳态、方案对比、温差、JSON、网格切换 | Octave 桩：通过；MATLAB：待实测 |
| `test_advection` / `test_reset` | 平流方向、reset 与新建一致 | 通过 |

## 稳态参考（v3.7.0，默认布局，280² 网格跑到稳态，自动温控，Octave）

| 场景 | CPU/GPU/电源负载 | 步数 | Tj CPU | Tj GPU | 电源 | 机箱内均温 | 机箱风量 | 噪音 |
|---|---|---|---|---|---|---|---|---|
| 游戏 | 100/200/500 W | 700 | 60.5 | 55.1 | 56.6 | 32.5 | 39.5 CFM | 25.6 dB |
| 默认 | 125/250/450 W | 1100 | 67.2 | 61.0 | 53.3 | 32.3 | 51.7 CFM | 26.2 dB |
| 满载 | 180/320/850 W | 750 | 81.9 | 69.9 | 77.8 | 31.5 | 85.0 CFM | 32.6 dB |

结温等为最近一个收敛窗口（200 步）的均值；三场景均无节流、电源未超温。
流场与温度场见 `../docs/images/v3.7.0_default.png`、`v3.7.0_heavy.png`。

### 风扇布局预设对比（默认功率 125/250/450 W，预览 140² 跑到稳态）

`compare_presets(0.5)` 的结果（标称进/排为当前转速下的自由风量）：

| 预设 | 机箱风扇 | Tj CPU | Tj GPU | 电源 | 内温 | 机箱风量 | 噪音 | 标称进/排 |
|---|---|---|---|---|---|---|---|---|
| 2 前进 · 后顶出（默认） | F2 F3 进，R1 T1 出 | 67.0 | **60.8** | 54.6 | **31.6** | 52.5 | 26.2 | 56 / 67 |
| 1 前进 · 后顶出 | F2 进，R1 T1 出 | 66.4 | 74.0 | 54.6 | 36.1 | 44.0 | 28.2 | 37 / 84 |
| 前进后出 | F2 进，R1 出 | 66.9 | 78.0 | 54.5 | 35.1 | 41.8 | 29.5 | 43 / 43 |
| 前进顶出 | F1 F2 进，T1 T2 出 | **65.4** | 79.3 | 54.3 | 36.3 | 82.0 | 31.2 | 90 / 90 |
| 底进顶出 | B1 B2 进，R1 T1 T2 出 | 72.0 | 64.9 | 54.2 | 34.5 | 36.3 | 26.8 | 68 / 102 |
| 正压（3 进 1 出） | F1 F2 F3 进，R1 出 | 68.7 | 65.4 | 54.2 | 32.7 | 44.3 | **26.0** | 90 / 30 |
| 负压（1 进 3 出） | F2 进，R1 T1 T2 出 | 66.8 | 73.9 | 54.6 | 36.8 | 45.7 | 27.8 | 37 / 111 |
| 全装 | F1 F2 F3 B1 B2 进，R1 T1 出 | 66.7 | 62.6 | 54.5 | 32.0 | 75.6 | 26.9 | 139 / 84 |

要点（2D 模型下的趋势）：
- 显卡风扇从显卡下方 30 mm 的间隙吸风，**前下位（F3）进气对 GPU 最关键**：既没有 F3 也没有
  底部进气的布局，GPU 比默认高 13–19°C；底部进气可替代一部分（+4°C）。
- 只有 F1/F2 进气、顶部两扇排气时，进风从机箱上半部直接被顶扇抽走（风量最大但"短路"），
  CPU 最凉而 GPU 最热。
- 进风足够时加装风扇收益递减：全装比默认多 4 台风扇，CPU 只低 0.3°C，GPU 反而高 1.8°C。
- 自动温控下温度越低风扇越慢，散热好的布局往往也更安静。

## 已知局限

- 2D 侧视：侧板风扇与 Z 向流路无法表示；风扇 2D 口径按体积流量守恒（盘宽 × 机箱深度），风速低于真实风扇出口。
- 显卡鳍片阻力取偏低值以补偿 2D 缺失的侧板方向出风；显卡风扇进风受限于显卡与挡板间的 30 mm 间隙，
  靠后的两台显卡风扇实测风量只有自由风量的约 40%。
- 底部两个安装位在 400 mm 机箱内重叠 12 mm（2D 简化）。
- 预览档（140²）的电源温度比精确档高约 1.3°C（电源内部格数少），其余结温相差约 0.2°C。
- 结温热惯性时间常数取 0.25 s 仅为数值平滑，温度曲线的时间轴不代表真实升温过程。
- 热阻参数按公开评测的量级标定，不对应具体型号。

## 参考文献

- de Vahl Davis, G. (1983). Natural convection of air in a square cavity: a bench mark numerical solution. Int. J. Numer. Methods Fluids 3, 249–264.
- Wilcox, D. C. (2006). Turbulence Modeling for CFD, 3rd ed. DCW Industries.
- Idelchik, I. E. Handbook of Hydraulic Resistance（格栅、滤网阻力系数）。
- Yu, S. P., & Webb, R. L. (2001). Thermal design of a desktop computer system using CFD analysis. IEEE SEMI-THERM XVII.
- Gray, D. D., & Giorgini, A. (1976). The validity of the Boussinesq approximation for liquids and gases. Int. J. Heat Mass Transfer.

## 许可

仅供学习与个人研究使用。
