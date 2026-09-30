function gen_numerics_fixtures(outFile)
%GEN_NUMERICS_FIXTURES 生成网页版数值例程的逐位对照数据（web/test/fixtures/numerics.json）。
%   用法（在 matlab_app 目录下）：
%     OMP_NUM_THREADS=1 octave-cli --no-gui --eval "setup_paths(); addpath('../web/test/gen'); gen_numerics_fixtures"
%   覆盖 grid_interp2（linear/cubic/makima × 三种原点 × 越界/平台/小网格）、edt_nearest（随机与
%   真实 140² 障碍掩码）、pchip_eval（风扇型号 P-Q 曲线与随机非均匀节点）。
%   浮点数组一律以 IEEE-754 双精度的 16 位十六进制（num2hex，大端）首尾相接成一个字符串，逐位无损；
%   edt 的距离以整数 D² 存（生成时断言 sqrt(D²) 与 D 逐位相同），最近格索引为 1 基整数。
    if nargin < 1
        here = fileparts(mfilename('fullpath'));
        outFile = fullfile(here, '..', 'fixtures', 'numerics.json');
    end
    rand('state', 20240917); randn('state', 20240917); %#ok<RAND>

    parts = {};
    ver = version();
    parts{end+1} = sprintf('"generator":{"tool":"octave","version":"%s","script":"web/test/gen/gen_numerics_fixtures.m","floatEncoding":"num2hex concatenated (16 hex chars per double, big-endian)"}', ver);

    %% ---------------- grid_interp2 ----------------
    grids = {};
    grids{end+1} = struct('name', 'rand9x7',   'V', randn(9, 7),  'nq', 250);
    grids{end+1} = struct('name', 'small4x4',  'V', randn(4, 4),  'nq', 150);
    grids{end+1} = struct('name', 'small3x5',  'V', randn(3, 5),  'nq', 150);
    grids{end+1} = struct('name', 'tiny3x3',   'V', randn(3, 3),  'nq', 100);
    % 平台区：常值块（makima 零分母）与一片零区
    P = kron(randi([0 2], 3, 2), ones(4, 5));   % 12×10
    P(1:5, 1:4) = 0;
    grids{end+1} = struct('name', 'plateau12x10', 'V', P, 'nq', 300);
    [Xs, Ys] = meshgrid(1:8, 1:8);
    grids{end+1} = struct('name', 'step8x8', 'V', double(Ys > Xs) * 2.5 - 1, 'nq', 200);
    grids{end+1} = struct('name', 'const5x6', 'V', 3.7 * ones(5, 6), 'nq', 60);
    % 平流式：平滑场 + 噪声，查询 = 全部节点坐标 − 位移
    [Xr, Yr] = meshgrid(1:25, 1:24);
    R = sin(Xr / 3.1) .* cos(Yr / 4.3) + 0.05 * randn(24, 25);
    R(10:13, 8:11) = 0;                        % 一块静止区（障碍）
    grids{end+1} = struct('name', 'advect24x25', 'V', R, 'nq', -1);

    origins = [1 1; 1 0.5; 0.5 1];
    methods = {'linear', 'cubic', 'makima'};
    gi = {};
    for g = 1:numel(grids)
        G = grids{g};
        [n1, n2] = size(G.V);
        for oi = 1:size(origins, 1)
            o1 = origins(oi, 1); o2 = origins(oi, 2);
            if G.nq < 0
                [q2n, q1n] = meshgrid(o2 + (0:n2-1), o1 + (0:n1-1));
                d1 = 1.6 * randn(n1, n2); d2 = 1.6 * randn(n1, n2);
                q1 = q1n(:) - d1(:); q2 = q2n(:) - d2(:);
                % 一部分查询落在节点/半格/边界上
                k = randperm(numel(q1), 60);
                q1(k(1:20)) = q1n(k(1:20)); q2(k(1:20)) = q2n(k(1:20));
                q1(k(21:40)) = round(q1(k(21:40))) + o1 - 1 + 0.5;
                q2(k(41:60)) = o2 + n2 - 1;
            else
                [q1, q2] = makeQueries(G.nq, n1, n2, o1, o2);
            end
            outs = cell(1, 3);
            for mi = 1:3
                outs{mi} = grid_interp2(G.V, q1, q2, methods{mi}, o1, o2);
            end
            gi{end+1} = sprintf(['{"name":"%s","n1":%d,"n2":%d,"o1":%.17g,"o2":%.17g,"nq":%d,' ...
                '"V":"%s","q1":"%s","q2":"%s","linear":"%s","cubic":"%s","makima":"%s"}'], ...
                G.name, n1, n2, o1, o2, numel(q1), hexs(G.V), hexs(q1), hexs(q2), ...
                hexs(outs{1}), hexs(outs{2}), hexs(outs{3})); %#ok<AGROW>
        end
    end
    parts{end+1} = ['"gridInterp2":[' strjoin(gi, ',') ']'];

    %% ---------------- edt_nearest ----------------
    masks = {};
    masks{end+1} = struct('name', 'rand7x5', 'M', rand(7, 5) < 0.3);
    masks{end+1} = struct('name', 'one_true_1x1', 'M', true(1, 1));
    masks{end+1} = struct('name', 'one_false_1x1', 'M', false(1, 1));
    masks{end+1} = struct('name', 'all_true_4x6', 'M', true(4, 6));
    masks{end+1} = struct('name', 'all_false_5x3', 'M', false(5, 3));
    M = false(9, 11); M(4, 7) = true;
    masks{end+1} = struct('name', 'single_9x11', 'M', M);
    masks{end+1} = struct('name', 'sparse13x6', 'M', rand(13, 6) < 0.1);
    masks{end+1} = struct('name', 'sparse6x13', 'M', rand(6, 13) < 0.1);
    M = false(17, 17); M(1:4:end, 1:4:end) = true;
    masks{end+1} = struct('name', 'lattice17x17_ties', 'M', M);
    M = false(15, 15); M([3 3 13 13 8], [3 13 3 13 8]) = true;
    masks{end+1} = struct('name', 'symmetric15x15_ties', 'M', M);
    M = false(16, 12); M([2 15], [2 11]) = true; M(8:9, 6:7) = true;
    masks{end+1} = struct('name', 'symmetric16x12_ties', 'M', M);
    [Xc, Yc] = meshgrid(1:21, 1:19);
    M = abs(hypot(Xc - 11, Yc - 10) - 6) < 0.5;
    masks{end+1} = struct('name', 'ring19x21', 'M', M);
    masks{end+1} = struct('name', 'row1x20', 'M', rand(1, 20) < 0.2);
    masks{end+1} = struct('name', 'col20x1', 'M', rand(20, 1) < 0.2);
    masks{end+1} = struct('name', 'sparse60x45', 'M', rand(60, 45) < 0.02);
    masks{end+1} = struct('name', 'dense40x40', 'M', rand(40, 40) < 0.5);
    s = CFDSolverFEM([], [], [], [], 0.5);
    obs = reshape(s.obstacle > 0, s.GRID.W, s.GRID.H);
    masks{end+1} = struct('name', 'obstacle140', 'M', obs);
    masks{end+1} = struct('name', 'fluid140', 'M', ~obs);

    ed = {};
    for k = 1:numel(masks)
        Mk = masks{k}.M;
        [W, H] = size(Mk);
        [D, idx] = edt_nearest(Mk);
        maskStr = char('0' + Mk(:)');
        if any(Mk(:))
            D2 = round(D.^2);
            assert(isequal(sqrt(D2), D), 'edt: sqrt(D2) 与 D 不逐位相同');
            assert(isequal(D2, floor(D2)));
            ed{end+1} = sprintf('{"name":"%s","W":%d,"H":%d,"mask":"%s","allFalse":false,"D2":%s,"idx":%s}', ...
                masks{k}.name, W, H, maskStr, ints(D2), ints(idx)); %#ok<AGROW>
        else
            assert(all(isinf(D(:))) && all(idx(:) == 0));
            ed{end+1} = sprintf('{"name":"%s","W":%d,"H":%d,"mask":"%s","allFalse":true,"D2":null,"idx":null}', ...
                masks{k}.name, W, H, maskStr); %#ok<AGROW>
        end
    end
    parts{end+1} = ['"edt":[' strjoin(ed, ',') ']'];

    %% ---------------- pchip_eval ----------------
    pc = {};
    catalog = fan_catalog();
    names = fieldnames(catalog);
    xg = [0 0.2 0.4 0.6 0.8 1.0];
    qf = [linspace(-0.1, 1.1, 61), xg, 0.3, 1/3, 0.999999, 1e-12, NaN, rand(1, 20)];
    for k = 1:numel(names)
        y = catalog.(names{k}).pq_curve;
        v = pchip_eval(xg, y, qf);
        pc{end+1} = pchipCase(['fan_' names{k}], xg, y, qf, v); %#ok<AGROW>
    end
    rcases = {};
    for n = [3 4 5 7 10 15]
        x = cumsum(0.05 + rand(1, n)) - 0.7;
        rcases{end+1} = {sprintf('randn_n%d', n), x, randn(1, n)}; %#ok<AGROW>
        rcases{end+1} = {sprintf('monotone_n%d', n), x, cumsum(rand(1, n))}; %#ok<AGROW>
    end
    x = cumsum(0.05 + rand(1, 9));
    rcases{end+1} = {'flat_segments', x, [1 1 1 2 2 0.5 0.5 0.5 3]};
    rcases{end+1} = {'alternating', x, (-1).^(1:9) .* (1 + rand(1, 9))};
    rcases{end+1} = {'large_scale', x, 1e6 * randn(1, 9)};
    rcases{end+1} = {'tiny_scale', x * 1e-3, 1e-9 * randn(1, 9)};
    rcases{end+1} = {'end_clip_3del', [0 1 1.1], [0 1 -0.1]};           % |d| > 3|δ1| → d = 3δ1
    rcases{end+1} = {'end_clip_3del_right', [0 0.1 1.1], [-0.1 1 0]};
    rcases{end+1} = {'end_sign_flip', [0 1 2 3], [0 1 5 5.2]};             % sign(d) ≠ sign(δ1) → 0
    rcases{end+1} = {'end_zero_del', [0 1 2 3 4], [2 2 3 3 1]};
    for k = 1:numel(rcases)
        c = rcases{k};
        x = c{2}; y = c{3};
        span = x(end) - x(1);
        q = [linspace(x(1) - 0.1 * span, x(end) + 0.1 * span, 41), x, x(1) + span * rand(1, 12), NaN];
        v = pchip_eval(x, y, q);
        pc{end+1} = pchipCase(c{1}, x, y, q, v); %#ok<AGROW>
    end
    parts{end+1} = ['"pchip":[' strjoin(pc, ',') ']'];

    %% ---------------- sparse（三元组装配、A*x、sum(A,2)、A'*y）----------------
    sp = {};
    for c = 1:2
        m = 50; n = 40; nz = 700;
        I = randi(m, nz, 1); J = randi(n, nz, 1);
        V = randn(nz, 1) .* 10 .^ randi([-3 3], nz, 1);
        % 故意制造重复项、相消为 0 的重复项与大小悬殊的重复项
        I(601:700) = I(1:100); J(601:700) = J(1:100);
        V(601:650) = -V(1:50);
        V(651:700) = V(51:100) * 1e16;
        if c == 2
            p = randperm(nz); I = I(p); J = J(p); V = V(p);
        end
        A = sparse(I, J, V, m, n);
        [ai, aj, av] = find(A);                 % 列优先次序
        x = randn(n, 1); y = randn(m, 1);
        Ax = A * x; rs = full(sum(A, 2)); Aty = A' * y;
        sp{end+1} = sprintf(['{"name":"triplets%d","m":%d,"n":%d,"I":%s,"J":%s,"V":"%s","x":"%s","y":"%s",' ...
            '"nnz":%d,"Ai":%s,"Aj":%s,"Av":"%s","Ax":"%s","rowSum":"%s","Aty":"%s"}'], c, m, n, ints(I), ints(J), hexs(V), ...
            hexs(x), hexs(y), nnz(A), ints(ai), ints(aj), hexs(av), hexs(Ax), hexs(rs), hexs(Aty)); %#ok<AGROW>
    end
    parts{end+1} = ['"sparse":[' strjoin(sp, ',') ']'];

    fid = fopen(outFile, 'w');
    assert(fid > 0, ['cannot open ' outFile]);
    fprintf(fid, '{%s}\n', strjoin(parts, ','));
    fclose(fid);
    info = dir(outFile);
    printf('wrote %s (%d bytes)\n', outFile, info.bytes);
end

function [q1, q2] = makeQueries(nq, n1, n2, o1, o2)
    % 查询：越界均匀 + 节点 + 半格 + 边界（含相邻浮点）+ 少量 NaN/±Inf
    q1 = zeros(nq, 1); q2 = zeros(nq, 1);
    for k = 1:nq
        q1(k) = pick(n1, o1);
        q2(k) = pick(n2, o2);
    end
    specials = [NaN, Inf, -Inf];
    if nq >= 60
        q1(1:3) = specials; q2(4:6) = specials;
    end
end

function q = pick(n, o)
    lo = o; hi = o + n - 1;
    r = rand();
    if r < 0.5
        q = lo - 1.5 + (hi - lo + 3) * rand();
    elseif r < 0.65
        q = o + randi(n) - 1;
    elseif r < 0.75
        c = randi(4);
        switch c
            case 1, q = lo;
            case 2, q = hi;
            case 3, q = hi - eps(hi);
            otherwise, q = lo + eps(lo);
        end
    elseif r < 0.85
        q = o + randi(n) - 1 + 0.5;
    else
        q = lo + (hi - lo) * rand();
    end
end

function s = pchipCase(name, x, y, q, v)
    s = sprintf('{"name":"%s","n":%d,"x":"%s","y":"%s","q":"%s","v":"%s"}', ...
        name, numel(x), hexs(x), hexs(y), hexs(q), hexs(v));
end

function s = hexs(x)
    if isempty(x)
        s = '';
        return;
    end
    h = num2hex(double(x(:)));
    s = reshape(h', 1, []);
end

function s = ints(x)
    s = sprintf('%d,', x(:));
    s = ['[' s(1:end-1) ']'];
end
