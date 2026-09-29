# PC 风道仿真器（MATLAB 版）

ATX 中塔机箱侧视 2D 风道与散热仿真：不可压 Navier–Stokes（MAC 交错网格投影法）+
k-ω 湍流 + 共轭传热，配交互式 MATLAB App。版本见 `src/pcflow_version.m`，更新记录见
[`../CHANGELOG.md`](../CHANGELOG.md)，开发计划见 [`../docs/ROADMAP.md`](../docs/ROADMAP.md)。

> ⚠ 2D 定性教学工具：用于理解风道布局、风扇配置与元件温度的趋势，不适用于产品级散热验证。

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
run_all_tests('quick') % 快速回归（约 1 分钟）
run_all_tests          % 完整回归（含方腔、风道、守恒 1200 步、湍流，较慢）
run_all_tests('ui')    % 界面烟雾测试（仅 MATLAB）
```

无界面使用求解器：

```matlab
setup_paths();
s = CFDSolverFEM(125, 250, 450);          % CPU/GPU 功率、电源输出负载 [W]，默认布局
s.stepMultiple(1000);                     % 推进 1000 步（DT = 5 ms，约 5 s 物理时间，接近稳态）
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
│   ├── layout_benchmark.m 验证用简化布局（空域、方腔、风道）
│   ├── fan_catalog.m      风扇型号库（参数 + P-Q 曲线）
│   ├── Fan.m              风扇（执行盘、P-Q 工作点、温控、噪音）
│   ├── CFDSolverBase.m    几何、风扇与开口、共轭传热、诊断、守恒计账、评分
│   ├── CFDSolverFEM.m     时间推进（扩散、投影、平流、湍流、温度）
│   ├── DetailedThermalNetwork.m  元件热网络（热阻 + 热惯性 + 节流）
│   └── pcflow_version.m
├── app/PCAirflowSimulatorApp.m   界面
├── tests/                 平流、reset、扩散、方腔、风道、守恒、湍流、界面测试
├── tools/                 快照生成、网格敏感性研究、单步耗时剖析
├── compat/octave/         Octave 兼容层（decomposition、griddedInterpolant）
└── snapshots/             快照输出（旧文件为 v3.3.1 口径，用 tools/generate_snapshots 重新生成）
```

## 布局配置

`layout_default()` 返回一个只含数据的 struct（可 `jsonencode` 保存）：

| 字段 | 内容 |
|---|---|
| `domain` / `chassis` | 计算域与机箱尺寸（mm）、机箱 Z 向深度、各壁温度（NaN = 绝热） |
| `cpu` / `gpu` / `psu` | 元件矩形（mm，相对机箱原点，x 向前面板、y 向下）、多孔区阻力、热阻、内置风扇；可缺省 |
| `caseFans` | 机箱风扇：安装壁（front/rear/top/bottom）、沿壁中心位置 `alongMm`、进/排气、型号、转速模式 |
| `vents` / `solidBlocks` / `porousBlocks` | 被动通风口、实心障碍、多孔障碍（可选） |
| `grille` / `fanDiskMm` | 风扇开口格栅阻力 ζ、执行盘厚度 |

求解器按 `格 = round(mm / 格距)` 换算，同一配置可用于不同网格细化倍数（常用 0.5 / 1 / 2）。

## 模型概要

| 部分 | 做法 |
|---|---|
| 网格 | 280×280、格距 2 mm；机箱 400 mm 见方，四周 80 mm 外部空气；最外 1 格为远场海绵层（阻尼 + 环境温度 + p=0）；机箱 Z 向有效深度 0.15 m |
| 动量 | MAC 交错网格；隐式扩散 → 投影 → 面心半拉格朗日平流 → 浮力、风扇 → 阻力耦合投影 |
| 湍流 | k-ω（Wilcox 2006 + 应力限制器 + 生产限制器）；可选 LVEL 或层流 |
| 温度 | 隐式扩散（定温壁 Dirichlet，其余绝热）→ 半拉格朗日平流（makima）→ 元件热量注入散热体内流体 |
| 风扇 | 执行盘：厚 12 mm、宽 = 风扇直径，穿盘静压升 = P-Q 曲线工作点 × 风扇定律（超过自由风量时外推为负压） |
| 阻力 | 散热器、电源内部为各向异性多孔区；开口格栅/滤网为穿壁面阻力 ζ·½ρv²；阻力与压力在同一投影中耦合求解 |
| 结温 | 串联热阻 + 一阶热惯性 + 节流；环境温度 = 散热器进风侧 CFD 温度，h 取散热体内平均风速 |
| 电源 | 自带风道：底部进风、后部排出；损耗 = 负载 × (1/η − 1)，80 PLUS 金牌典型效率曲线；超温只告警 |
| 温控 | 机箱风扇跟 CPU/GPU 最高温，塔扇跟 CPU，显卡风扇跟 GPU，电源风扇跟电源 |

单位：求解器内部速度为网格单位，物理速度 = 网格速度 × VEL_SCALE（(W−2)·格距 ≈ 0.556 m）；
扩散算子系数为 1/格距²（ν、α 为 m²/s）；浮力、风扇、阻力均换算到同一网格速度口径。

## 验证

| 测试 | 内容 | 结果（Octave） |
|---|---|---|
| `test_diffusion` | 高斯包方差增长 vs 解析解（温度两条装配路径、速度面场） | 比值 1.000 |
| `test_cavity` | 差分加热方腔 vs de Vahl Davis 1983 | Ra=1e4：Nu 2.300（基准 2.243，+2.5%）；Ra=1e5：4.613（4.519，+2.1%） |
| `test_fan_duct` | 风扇-风道工作点 vs P-Q 与系统曲线交点 | ζ=5/20/60：−7.6%/−7.8%/−7.2%（解析式未计入壁面摩擦与剖面不均） |
| `test_conservation` | 全域逐步能量计账、机箱内区算子平衡、收敛趋势 | 见 CHANGELOG |
| `test_advection` / `test_reset` | 平流方向、reset 与新建一致 | 通过 |

## 稳态参考（v3.5.0，280² 网格，1600 步 ≈ 8 s，自动温控，Octave）

| 场景 | CPU/GPU/电源负载 | Tj CPU | Tj GPU | 电源 | 机箱内均温 | 机箱风量 | 噪音 |
|---|---|---|---|---|---|---|---|
| 游戏 | 100/200/500 W | 61.1 | 59.3 | 51.8 | 35.6 | 28 CFM | 25.4 dB |
| 默认 | 125/250/450 W | 67.3 | 64.1 | 48.3 | 34.9 | 34 CFM | 26.0 dB |
| 满载 | 180/320/850 W | 82.9 | 70.0 | 78.1 | 33.2 | 60 CFM | 33.2 dB |

流场与温度场见 `../docs/images/`。

## 已知局限

- 2D 侧视：侧板风扇与 Z 向流路无法表示；风扇 2D 口径按体积流量守恒（盘宽 × 机箱深度），风速低于真实风扇出口。
- 显卡鳍片阻力取偏低值以补偿 2D 缺失的侧板方向出风；显卡风扇进风受限于显卡与挡板间的 30 mm 间隙。
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
