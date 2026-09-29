# 标准答案数据集

网页版（或其它移植）对照用的参考数据，由 `tools/make_reference_dataset` 生成；
算法说明见 [`../../../docs/ALGORITHM.md`](../../../docs/ALGORITHM.md)。每个文件记录生成环境
（`generator.platform/version`）与仿真器版本（`generator.simulator`）。数据在 GNU Octave 8.4 下生成。
`fixed_default.json` 由 v4.1.0 生成（4 槽显卡）；`fixed_duct`、`bench` 与显卡无关；`steady_*.json` 仍为
v3.9.2 代码、3.5 槽显卡的结果（计算代码与 v4.0.0 相同），将在下一版重新生成。

| 文件 | 内容 | 建议对照容差 |
|---|---|---|
| `fixed_default.json` | 默认布局与功率（125/250/450 W），预览网格 140²，湍流逐步更新，从静止推进 200 步：完整场 `T`（°C）、`u`/`v`（格心速度，m/s）、`P`（静压 Pa，障碍格为 null）、`obstacle`，以及结温、风扇工作点、开口风量、噪音 | 同一插值口径：场逐点 ≤ 1e−3；跨实现：温度 ≤ 0.5°C、速度 ≤ 0.05 m/s（主要来自 cubic/makima 插值差异） |
| `fixed_duct.json` | 直风道基准（ζ = 20），预览网格，200 步：完整场与风扇工作点 | 同上 |
| `steady_{gaming,default,heavy}.json` | 默认布局三种功率，280² 跑到稳态：窗口均值（`windowMean`：各结温、机箱内均温、风量）与稳态时刻标量 | 结温 ≤ 1°C，风量 ≤ 5%，噪音 ≤ 0.5 dB |
| `steady_{front_top,positive,negative,bottom_top}.json` | 4 个风扇布局预设，默认功率，280² 跑到稳态 | 同上 |
| `bench.json` | 方腔 Nu（Ra = 1e4/1e5，DT = 0.02 s、1500 步）、风道工作点流量（ζ = 5/20/60，600 步） | Nu ≤ 3%，流量 ≤ 3% |

场数组为列优先（线性索引 `(x−1)·W + y`，y 为行向下、x 为列向右），6 位有效数字。
嵌入的 `layout` 可直接作为布局配置（MATLAB 下用 `layout_json` 的规整逻辑读取）。

`tests/test_reference.m` 在同一平台上复算 `fixed_default` 并逐场比较（`run_all_tests('full')` 包含）；
跨平台（例如数据由 Octave 生成、在 MATLAB 下复算）时只检查量级，并提示在本平台重新生成。
