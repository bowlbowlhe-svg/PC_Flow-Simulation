# 标准答案数据集

网页版（或其它移植）对照用的参考数据，由 `tools/make_reference_dataset` 生成；
算法说明见 [`../../../docs/ALGORITHM.md`](../../../docs/ALGORITHM.md)。每个文件记录生成环境
（`generator.platform/version`）与仿真器版本（`generator.simulator`）。本目录的数据由 v4.2.2 在
GNU Octave 8.4 下生成（单线程）。

| 文件 | 内容 |
|---|---|
| `fixed_default.json` | 默认布局与功率（125/250/450 W），预览网格 140²，湍流逐步更新，从静止推进 200 步 |
| `fixed_duct.json` | 直风道基准（ζ = 20，无热源），预览网格，200 步 |
| `steady_{gaming,default,heavy}.json` | 默认布局三种功率（100/200/500、125/250/450、180/320/850 W），280² 固定推进 3000 步（15 s） |
| `steady_{front_top,positive,negative,bottom_top}.json` | 4 个风扇布局预设，默认功率，280² 固定推进 3000 步 |
| `bench.json` | 方腔 Nu（Ra = 1e4/1e5，DT = 0.02 s、1500 步）、风道工作点流量（ζ = 5/20/60，DT = 0.005 s、600 步），含所用布局与网格尺寸 |

## 通用约定

- 场数组为列优先：线性索引 `(x−1)·W + y`（从 1 起），y 为行、向下为正，x 为列、向右为正。
  数值保留 6 位有效数字；NaN 写为 `null`。
- 列表字段（`caseFans`、`vents`、`solidBlocks`、`porousBlocks`、`shroud.gaps`、`fans`、`openings`）
  即使只有一个元素也是数组。
- 嵌入的 `layout` 可直接作为布局配置（MATLAB/Octave 下经 `layout_json('load')` 的规整逻辑读取）。
- 字符串为 UTF-8。

## `fixed_*.json` 字段

| 字段 | 含义 |
|---|---|
| `W`、`H`、`cellMm`、`DT`、`VEL_SCALE`、`turbUpdateEvery` | 网格、时间步（s）、网格速度 → m/s 的换算、湍流更新间隔 |
| `geometry` | 几何导出（与步数无关）：`obstacleType`（障碍类型码，码表见 `obstacleCodes`）、`uFaceActive`/`vFaceActive`（W×(H+1) 与 (W+1)×H 的面掩码）、`uDragCoef`/`vDragCoef`（阻力系数 C，β = 1/(1+C·|u|)，网格速度单位）、`uGrilleFace`/`vGrilleFace`、`nearestFluid`（障碍格的最近流体格，平局取线性索引最小；流体格为 0）、`wallDistanceM`、`spongeRing`（海绵环格）、`inside`（机箱内流体格）、`dirichletIdx`/`dirichletT`（定温壁）、`heatObsIdx`（发热元件固体格）、`cht`（共轭传热的进风采样带与散热体格）、`fans`（行/列范围 `[起 止]`、送风方向 `normal`）、`openings`（开口格与格栅 ζ） |
| `snapshots` | 第 1、10、13、200 步的完整状态（网格单位，与求解器内部一致；第 13 步位于重装区间中途）：`T`（°C，障碍格为显示值）、`uF`/`vF`（面速度，网格速度，×VEL_SCALE 得 m/s）、`p`（第二次即阻力耦合投影的压力）、`pProj1`（第一次投影压力）、`k`、`omega`、`nuStep`（本步 ν_eff）、`nuAssembled`/`alphaAssembled`/`nuTAssembled`（速度、温度、k-ω 扩散算子装配时的 ν_eff、α_eff、ν_t）、`asmStep`（三者上次装配时的 iteration）、`betaRefU`/`betaRefV`（阻力耦合算子的参考 β，形状 W×(H+1) 与 (W+1)×H，列优先展平）、`betaRefStep`、`Tsolid`，以及当步 `scalars`。续算配方见 ALGORITHM §11（p、pProj1 每步被覆盖，不是状态量）。逐步定位移植差异时先比第 1 步，再比第 10、13 步 |
| `fields` | 第 200 步的显示量：`T`、`u`/`v`（格心速度 m/s，v 向下为正）、`P`（静压 Pa，`P = ρ·VEL_SCALE·Δx·(p + pProj1)/DT`，障碍格为 null）、`obstacle`（0/1） |
| `scalars` | `Tj_*`（结温）、`Tsink_*`（散热片基座温度）、`Ttheory_*`（节流判据用的无节流理论稳态温度的滤波值）、`power_*`（节流后的发热功率；电源为**损耗**，不是输出负载）、`hConv_*`、`throttle_*`、`internalAmbient`（机箱内均温，含开口格与电源内部流体格）、`totalCFM`、`noiseDb`、`fans`（`cfm` = 推进结束时穿盘中面流量的绝对值 × 2118.88；`dp` = 本步施力前中间流场上的工作点静压；`lastQ_m3s` 为该中间流场上的流量，约低 4%；`lastQRatio` 为其与自由风量之比；`flowFactor` 为代数轨用的低通流量比；`noiseQRatio` 为噪音用的低通流量比，初值 1）、`openings`（净风量，流出机箱为正）、`meanInteriorPressurePa`（机箱内流体格静压均值） |

## `steady_*.json` 字段

单一时刻或 `runToSteady` 的判稳结果受判稳时刻与冻结算子造成的假平台影响（ALGORITHM §3.10、§7），因此取长时统计：

| 字段 | 含义 |
|---|---|
| `steps`、`avgFrom` | 总步数 3000；统计取 `avgFrom`（1000）步之后**每一步**的瞬时值（按每 50 步采样会与周期整除 50 的伪振荡混叠） |
| `columns` | 统计列：`cpu`/`gpu`/`psu`（结温 °C）、`interior`（机箱内均温 °C）、`cfm`（机箱风量） |
| `mean`、`std`、`min`、`max` | 各列统计量 |
| `history` | 每 10 步一行：`[步数, 各列瞬时值]` |
| `scalars` | 第 3000 步的标量（同上） |

## 对照建议

按下面顺序逐级对照，前一级不过就不要看后一级：

1. **几何**（`fixed_*.json` 的 `geometry`）：整数与逻辑数组逐元素相同，`wallDistanceM`、阻力系数的相对差
   ≤ 1e−6。几何不同时，后面的差异没有意义。常见原因是取整规则（必须四舍五入、0.5 远离零）和最近流体格的平局规则。
2. **第 1、10、13、200 步快照**（同一算法、双精度实现）：逐点差应在存储舍入量级，即温度 ≤ 1e−3°C，
   其余场 ≤ 1e−5 × 该场最大绝对值。依据：同平台复算的最大差为 5e−5°C；审计把压力解扰动 1e−6（相对）
   推进 200 步，差异仍停留在舍入量级。反过来，只改最近流体格的平局规则或 makima 的计算顺序，
   200 步后差 1.5–13°C。所以超过约 0.01°C 的差异通常说明算法不一致，而不是舍入。先比第 1 步定位是哪一步
   出了差异（ALGORITHM §3 的每步顺序）。
3. **单精度 / GPU 实现**：逐点差会累积。建议先用双精度参考实现通过第 2 级，再比较单精度版本的标量：
   结温 ≤ 0.2°C、风量 ≤ 1%、风扇工作点静压 ≤ 2%；场只看 RMS 或 p95 差，作诊断用。这些阈值是建议值，
   尚未有单精度实现验证过。
4. **稳态**（`steady_*.json`）：在 280²、同样推进 3000 步，比较 1000 步之后的均值。结温与内温
   ≤ max(0.3°C, 3σ)，风量 ≤ max(2%, 3σ)，噪音 ≤ 0.3 dB（σ 取文件里的 `std`，目前结温 σ ≤ 0.24°C，
   其中正压布局的 σ 来自冻结算子造成的假平台——第 600–1800 步 GPU 停在低约 0.7°C 的状态，约第 2000 步跳到第二个平台，
   长时均值比每步重装的精确解低 0.48°C，见 ALGORITHM §3.10；其余 ≤ 0.06°C；风量 σ ≤ 0.6 CFM）。
   **精确模式对照值**（`forceReassemble = true`，全部冻结算子每步重装，1000 步之后的均值；供选择精确模式的移植实现验收，
   容差同上）：默认 66.69 / 61.23 / 53.02°C、50.09 CFM；正压 68.94 / 64.94°C、45.67 CFM；底进顶出 71.82 / 64.11°C。不要拿 `runToSteady` 的判稳结果对照：判稳时刻受实现细节影响。
5. **基准**（`bench.json`）：Nu 与风道流量的相对差 ≤ 1%（本数据与解析解/文献值的偏差：Nu +2.5/+2.1%，
   风道 +1.1/+0.6/+0.4%）。

`tests/test_reference.m` 按第 2 级复算两个 `fixed_*` 算例（`run_all_tests('full')` 包含）。
数据由 Octave 生成，而插值、最近流体格、pchip 都是项目自带实现，MATLAB 下的差异应只来自线性求解与求和的舍入。
超出存储舍入但 ≤ 0.05°C 时判为通过，并提示反馈；更大的差异判为失败。
