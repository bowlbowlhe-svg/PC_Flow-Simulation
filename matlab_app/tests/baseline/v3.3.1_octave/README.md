# v3.3.1 基线（Octave 8.4 + compat/octave 兼容层）

阶段 0 在无 MATLAB 环境下用 Octave 复算的原始 v3.3.1 结果，用作阶段 1"不改物理"的对照。

- `*_summary.txt`：三场景各 400 步（280² 网格，DT = 5 ms）的结温、节流、双轨内温、开口风量。
- `conservation_1200steps.log`：`test_conservation(400)` 输出（热身 400 + 两个 400 步计量窗口）。

与 MATLAB 版快照（`snapshots/*_summary.txt`）对比：默认场景结温 70.4/90.9/84.1°C
（MATLAB 70.3/91.1/84.2），守恒判据 A/B/B2/C = +0.0%/+3.3%/−0.00%/−12.4°C，与 MATLAB 记录一致。
运行时基线代码仅做了两处 Octave 语法兼容（抽象方法声明、属性缺省值引用本类常量），不影响数值。
