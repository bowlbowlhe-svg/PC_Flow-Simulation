function ac = acoustics_default()
%ACOUSTICS_DEFAULT 噪音模型的默认经验参数（布局 acoustics 字段缺省时使用）。
%   听者位于机箱前侧约 1 m；风扇 datasheet 噪音按 1 m 自由出风测得。
%   stallQ / stallDb：流量比低于 stallQ 时按二次方加噪，堵死时 +stallDb（近失速）。
%   grilleRefZeta：格栅修正 10·log10(1 + ζ/ζref)，ζ = ζref 时 +3 dB。
%   positionDb：听音位置修正。前面板正对听者为 0；顶部向上辐射 −1；底部朝地面 −2；
%   后部背向听者 −3；CPU/GPU 风扇在侧板内 −3；电源风扇在电源仓内 −4。
%   finDb：塔扇、显卡风扇贴着致密鳍片吹的附加噪音（公开评测里常见 +2–4 dB）。
%   这些是经验量级（公开评测里格栅/滤网常见 +1–4 dB，机箱遮挡 2–6 dB），不对应具体机箱。
    ac = struct('stallQ', 0.4, 'stallDb', 6, 'grilleRefZeta', 2, 'finDb', 2, ...
        'positionDb', struct('front', 0, 'top', -1, 'bottom', -2, 'rear', -3, ...
                             'cpu', -3, 'gpu', -3, 'psu', -4));
end
