function p = fan_noise_terms(base, qRatio, zeta, posDb, ac)
%FAN_NOISE_TERMS 单台风扇在听音位置的声压级分项 [dB(A)]（经验模型）。
%   base   转速主项：datasheet 怠速/满速噪音按转速插值（自由出风工况）
%   qRatio 实测流量 / 当前转速自由风量（低通）；0 = 堵死或倒流，1 = 自由出风
%   zeta   机箱风扇开口的格栅/滤网阻力 ζ（内置风扇为 0）
%   posDb  听音位置修正
%   ac     声学参数（layout.acoustics，见 layout_default）：stallQ、stallDb、grilleRefZeta
%   分项：
%     op     = stallDb·((stallQ − q)/stallQ)²（q < stallQ），否则 0。
%              轴流风扇背压过高、接近失速时气流分离，噪音上升；q = 0 时 +stallDb。
%     grille = 10·log10(1 + ζ/grilleRefZeta)：格栅/滤网紧贴风扇造成的进出口气流畸变。
%     pos    = posDb：机箱面板方向性与遮挡（前面板朝向听者为 0）。
%   total = base + op + grille + pos。
    q = min(max(qRatio, 0), 2);
    op = 0;
    if q < ac.stallQ
        op = ac.stallDb * ((ac.stallQ - q) / ac.stallQ)^2;
    end
    grille = 10 * log10(1 + max(zeta, 0) / ac.grilleRefZeta);
    p = struct('base', base, 'op', op, 'grille', grille, 'pos', posDb, ...
               'total', base + op + grille + posDb);
end
