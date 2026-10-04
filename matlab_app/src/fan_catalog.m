function cat = fan_catalog()
%FAN_CATALOG 风扇型号库。
%   每个型号：size [mm]、rpm_min/rpm_max、cfm_max（满速自由风量）、noise_max（满速噪音 [dB(A)]，1 m）、
%   pmax_pa（满速最大静压）、pq_curve（P/Pmax 在 Q/Qmax = 0,0.2,…,1.0 处的值）、price [元]、label。
%   低于满速时噪音按风扇定律 L = noise_max + 50·log10(n/n_max) 计算（Fan.baseNoise）。
%   noise_max（v4.9.0 起）按同一测量口径：Cybenetics / Hardware Busters 半消声室、麦克风 1 m（WebSearch 摘录，未逐页核对）。
%   各厂家标称值的测法不同，不能横向比较：同一实验室实测比标称高 3–9 dB（Noctua 约 +7、Arctic +5–9、Phanteks +3–5）。
%   实测转速与 rpm_max 不同的按 50·log10 折到 rpm_max：
%     NF_A12  31.3 dBA @2134 rpm（实测）→ 29.9           P12  28.6 @1889（实测，P12 PWM PST）→ 27.6
%     P14     31.9 @1769（实测，P14 PWM PST）→ 31.0      T30  32.1 @2000（实测，"性能"档）
%     NF_A14、NF_A9：没有同口径实测，按 Noctua 的实测差值 +7.2 dB（NF-A12x25 +7.3、G2 +7.1）→ 31.8、30.0
%     M25_140：按 M25 Gen2 120 的实测差值 +3.3 dB → 39.7
%     Tower120：按同系列 TL-C12C-X28 实测 30.4 @1606 折到 1550 rpm → 29.6
%     Stock120（通用机箱原装风扇）：按 Montech AX120（实测 30.0 @1581）折到 2200 rpm 约 37.2，取 37.0（通用风扇的近似值）
%     GPU80：TechPowerUp 5 张三风扇显卡游戏负载（50 cm，按 −6 dB 折到 1 m，开放平台）：3 台风扇能量叠加 + 鳍片 +2 dB
%            反推单扇满速 27.8–33.9，取中位 33.0（5070 Ti TUF 1413 rpm 30.8 dBA、4080 Super Gaming OC 1323/1610 rpm 31.0/36.3、
%            5080 Gaming OC 1786 rpm 38.4、7900 XT Pulse 1504 rpm 28.7）
%     PSU120：Cybenetics 3 台 850 W 电源 50% 负载（1 m，含电源内部气流与格栅）反推满速 40.6–43.4，取 41.5
%            （Seasonic Focus GX-850 924 rpm 26.4 dBA、Thermaltake GF3 1018 rpm 31.0、Cooler Master V850i 475 rpm 11.7）
%   price（v4.9.0）：京东单个零售价（什么值得买 smzdm 收录，2025–2026，未注日期）：P12 59.9、NF-A12x25 299、NF-A14 180、
%     T30-120 199；没找到人民币价的按美国零售价与同品牌已知价的比例估计：P14 75（$14.99，按 P12 的比例）、
%     NF-A9 142（$18.95，按 NF-A14 的比例）、M25 Gen2 140 79（约 $16，按 Arctic 的比例）。塔扇、显卡与电源风扇随整件附带，计 0。
%   满速转速、风量、静压取自厂家/零售商规格（v4.6.0 核对）：
%     Noctua NF-A14 PWM：1500 rpm、82.52 CFM、2.08 mmH₂O、24.6 dB(A)
%     Noctua NF-A12x25 PWM：450–2000 rpm、60.1 CFM、2.34 mmH₂O、22.6 dB(A)
%     Noctua NF-A9 PWM：400–2000 rpm、46.44 CFM、2.28 mmH₂O、22.8 dB(A)
%     Phanteks T30-120（默认"性能"档 2000 rpm）：67 CFM、27.3 dB(A)；静压按 3000 rpm 的 7.11 mmH₂O 以风扇定律折算
%     Phanteks M25 Gen2 140：350–1800 rpm、101.78 CFM、2.23 mmH₂O、36.4 dB(A)
%     Arctic P14 PWM：200–1700 rpm、72.8 CFM、2.4 mmH₂O、0.3 sone（标注约 22.5 dB(A)）
%     Arctic P12 PWM：200–1800 rpm、56.3 CFM、2.2 mmH₂O、0.3 sone（标注约 22.5 dB(A)）
%     Thermalright TL-C12C（双塔风冷原配，Tower120）：1550 rpm、66.17 CFM、1.53 mmH₂O、25.6 dB(A)
%   P-Q 曲线为读图近似；没标最低转速的取常见 PWM 下限。Stock120/GPU80/PSU120 为通用内置风扇的近似参数。
%   v4.5 及以前的型号名 RX120、RX140（数据并非真实型号）读取配置时改为 T30、M25_140（见 fan_model_alias）。
    generic = [1.00 0.92 0.79 0.60 0.36 0.00];
    mmH2O = 9.80665;                       % 1 mmH₂O = 9.80665 Pa
    cat = struct( ...
        'NF_A14', spec(140, 300, 1500, 82.52, 31.8, 2.08*mmH2O, [1.00 0.91 0.78 0.59 0.34 0.00], 180, 'Noctua NF-A14 PWM'), ...
        'NF_A12', spec(120, 450, 2000, 60.1,  29.9, 2.34*mmH2O, [1.00 0.93 0.80 0.62 0.36 0.00], 299, 'Noctua NF-A12x25 PWM'), ...
        'NF_A9',  spec(92,  400, 2000, 46.44, 30.0, 2.28*mmH2O, [1.00 0.89 0.74 0.55 0.32 0.00], 142, 'Noctua NF-A9 PWM'), ...
        'M25_140', spec(140, 350, 1800, 101.78, 39.7, 2.23*mmH2O, [1.00 0.95 0.85 0.70 0.45 0.00], 79, 'Phanteks M25 Gen2 140'), ...
        'T30',    spec(120, 400, 2000, 67,    32.1, 7.11*mmH2O*(2000/3000)^2, [1.00 0.94 0.83 0.67 0.42 0.00], 199, 'Phanteks T30-120'), ...
        'P14',    spec(140, 200, 1700, 72.8,  31.0, 2.4*mmH2O,  [1.00 0.92 0.77 0.57 0.32 0.00], 75,  'Arctic P14 PWM'), ...
        'P12',    spec(120, 200, 1800, 56.3,  27.6, 2.2*mmH2O,  [1.00 0.92 0.77 0.57 0.32 0.00], 60,  'Arctic P12 PWM'), ...
        'Stock120', spec(120, 600, 2200, 65,  37.0, 20.0, generic, 0, '机箱原装 120mm'), ...
        'Tower120', spec(120, 300, 1550, 66.17, 29.6, 1.53*mmH2O, generic, 0, 'CPU 塔扇（Thermalright TL-C12C）'), ...
        'GPU80',    spec(80,  800, 2600, 45,  33.0, 20.0, generic, 0, '显卡 80mm 风扇'), ...
        'PSU120',   spec(120, 500, 1800, 50,  41.5, 20.0, generic, 0, '电源 120mm 风扇'));
end

function s = spec(sz, rmin, rmax, cfm, nMax, pmax, pq, price, label)
    s = struct('size', sz, 'rpm_min', rmin, 'rpm_max', rmax, 'cfm_max', cfm, ...
               'noise_max', nMax, 'pmax_pa', pmax, 'pq_curve', pq, 'price', price, 'label', label);
end
