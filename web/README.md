# 网页版（开发中）

MATLAB 版 v4.2.2 的浏览器移植。规格见 [`../docs/ALGORITHM.md`](../docs/ALGORITHM.md)，验收数据见
[`../matlab_app/tests/reference/`](../matlab_app/tests/reference/)，阶段计划见 [`../docs/ROADMAP.md`](../docs/ROADMAP.md)（W0–W5）。

当前进度：W0（布局模型、数值例程、几何）与 W1（求解器）完成，**还没有界面**（W3 起）。

## 使用

需要 Node.js 18 以上。

```bash
cd web
npm install
npm test            # 全部测试（约 1 分钟，含 2 × 200 步的标准答案对照）
npm run typecheck
npm run bench -- 1 20            # 默认布局 280² 推进 20 步的每步耗时（0.5 → 140²，2 → 560²）
npm run diag -- fixed_default    # 与标准答案逐快照对照，打印超差的场
npm run profile -- fixed_default 40   # 各类线性求解的次数、迭代数与耗时
```

## 目录

| 路径 | 内容 |
|---|---|
| `src/model/` | 布局数据模型：类型、默认布局、风扇型号与安装位、预设、显卡槽数、基准布局、JSON 规整与校验（对应 `layout_default.m`、`fan_catalog.m`、`layout_json.m` 等） |
| `src/numerics/` | 自带数值例程：`gridInterp2`（linear/cubic/makima）、`edtNearest`（最近点距离变换，平局取线性索引最小）、`pchipEval`、CSR 稀疏矩阵、PCG（IC(0) 预条件）、稀疏 Cholesky（嵌套剖分排序） |
| `src/solver/` | 几何构建（§2）、矩阵装配、风扇状态（P-Q 工作点、温控、噪音分项）、元件热网络、时间推进求解器（§3–§4） |
| `test/` | Vitest 测试；`fixtures/numerics.json` 为 Octave 生成的数值例程逐位对照数据（生成脚本 `test/gen/gen_numerics_fixtures.m`） |
| `scripts/` | 诊断与性能脚本（见上） |

## 与 MATLAB 版的一致性

- 几何：`fixed_default`、`fixed_duct` 的全部几何导出逐项相同（整数、掩码逐元素相同，壁面距离与阻力系数相对差 ≤ 5e−6）。
- 数值例程：插值、最近点、pchip、稀疏矩阵运算与 Octave 8.4 逐位相同。
- 求解器：两个算例第 1、10、13、200 步的全部状态（温度、面速度、两次投影的压力、k、ω、各冻结算子的系数场与装配步、
  阻力耦合参考 β、固体温度、结温与风扇工作点）都在存储舍入内（温度 ≤ 5e−5°C，其余 ≤ 6 位有效数字的舍入），
  结温差约 1e−11°C。
- 线性系统：两个压力泊松用稀疏 Cholesky 直接解（PCG 要两百多次迭代）；扩散系统（速度、温度、k、ω）用 IC(0) 预条件 PCG
  解到相对残差 1e−12（约 3 次迭代）。冻结系数与重装策略与 MATLAB 相同（§3.10），这是逐步复现标准答案的前提。

## 性能（Node 22，单线程，默认布局）

| 网格 | 每步耗时 | 内存（类型化数组） |
|---|---|---|
| 140²（预览） | 约 80–90 ms | 约 50 MB |
| 280²（标准） | 约 380 ms | 约 160 MB |
| 560²（精细） | 约 2.0 s | 约 660 MB |

280² 以上的主要耗时是阻力耦合压力矩阵重装时的 Cholesky 分解与扩散系统的 PCG。560² 的内存偏大，W5 再优化
（超节点/多波前分解，或该档改用迭代解）。
