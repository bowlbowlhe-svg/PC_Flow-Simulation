function p = fan_noise_terms(base, qRatio, zeta, fin, posDb, ac)
%FAN_NOISE_TERMS 单台风扇在听音位置的声压级分项 [dB(A)]（经验模型）。
%   base   转速主项：风扇定律 noise_max + 50·log10(n/n_max)（自由出风工况）；停转为 −Inf
%   qRatio 实测流量 / 当前转速自由风量（低通）；0 = 堵死或倒流，1 = 自由出风
%   zeta   机箱风扇开口的格栅/滤网阻力 ζ（内置风扇为 0）
%   fin    鳍片附加噪音：塔扇、显卡风扇贴着致密鳍片吹（acoustics.finDb），其它风扇为 0
%   posDb  听音位置修正
%   ac     声学参数（layout.acoustics，见 acoustics_default）：stallQ、stallDb、grilleRefZeta
%   分项：
%     op     = stallDb·((stallQ − q)/stallQ)²（q < stallQ），否则 0。
%              轴流风扇背压过高、接近失速时气流分离，噪音上升；q = 0 时 +stallDb。
%     grille = 10·log10(1 + ζ/grilleRefZeta)：格栅/滤网紧贴风扇造成的进出口气流畸变。
%     pos    = posDb：机箱面板方向性与遮挡（前面板朝向听者为 0）。
%     floor  = 低转速底噪（电机、轴承，acoustics.floorDb）与气动噪音按能量相加后多出的部分（v4.9.0）：
%              aero = base + op + grille + fin，total = 10·log10(10^(aero/10) + 10^(floorDb/10)) + pos，floor = total − aero − pos。
%   total 可低于 0 dB(A)（听不见的风扇照常按能量叠加，只对总噪音取 0 下限）；
%   停转时 base = −Inf，total = −Inf（没有底噪），floor = 0。
    q = min(max(qRatio, 0), 2);
    op = 0;
    if q < ac.stallQ
        op = ac.stallDb * ((ac.stallQ - q) / ac.stallQ)^2;
    end
    grille = 10 * log10(1 + max(zeta, 0) / ac.grilleRefZeta);
    aero = base + op + grille + fin;
    if isinf(base) && base < 0
        total = -Inf; flo = 0;
    else
        withFloor = 10 * log10(10^(aero / 10) + 10^(ac.floorDb / 10));
        flo = withFloor - aero;
        total = withFloor + posDb;
    end
    p = struct('base', base, 'op', op, 'grille', grille, 'fin', fin, 'pos', posDb, 'floor', flo, 'total', total);
end
