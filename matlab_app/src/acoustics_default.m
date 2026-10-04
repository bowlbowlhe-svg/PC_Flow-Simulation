function ac = acoustics_default()
%ACOUSTICS_DEFAULT 噪音模型的默认经验参数（布局 acoustics 字段缺省时使用）。
%   听者位于机箱前侧约 1 m；风扇 datasheet 噪音按 1 m 自由出风测得。
%   stallQ / stallDb：流量比低于 stallQ 时按二次方加噪，堵死时 +stallDb（近失速）。
%   grilleRefZeta：格栅修正 10·log10(1 + ζ/ζref)，ζ = ζref 时 +3 dB。
%   positionDb：听音位置修正。前面板正对听者为 0；顶部向上辐射 −1；底部朝地面 −2；
%   后部背向听者 −3；CPU/GPU 风扇在侧板内 −3；电源风扇在电源仓内 −4。
%   finDb：塔扇、显卡风扇贴着致密鳍片吹的附加噪音（公开评测里常见 +2–4 dB）。
%   floorDb（v4.9.0）：转动风扇的低转速底噪（电机、轴承）[dB(A)，1 m]，与气动噪音按能量相加：好的液压轴承风扇在
%     半消声室 1 m 处低转速时低于约 9 dBA（Cybenetics / Hardware Busters 的测量下限），取 8；停转的风扇没有底噪。
%   intermittentDb、cycleWindowS（v4.9.0）：半被动风扇（显卡低温停转、电源半被动）在启停阈值之间反复启停时，
%     间歇噪音比同样大小的持续噪音更容易被注意到，评分用的感知噪音按 BS 4142:2014 的间歇性修正 +3 dB；
%     最近 cycleWindowS 秒（仿真时间）内自动温控下启停切换 ≥ 2 次即判为"时转时停"。
%   这些是经验量级（公开评测里格栅/滤网常见 +1–4 dB，机箱遮挡 2–6 dB），不对应具体机箱。
    ac = struct('stallQ', 0.4, 'stallDb', 6, 'grilleRefZeta', 2, 'finDb', 2, ...
        'positionDb', struct('front', 0, 'top', -1, 'bottom', -2, 'rear', -3, ...
                             'cpu', -3, 'gpu', -3, 'psu', -4), ...
        'floorDb', 8, 'intermittentDb', 3, 'cycleWindowS', 10);
end
