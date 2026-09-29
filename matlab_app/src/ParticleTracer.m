classdef ParticleTracer < handle
    %PARTICLETRACER 流场粒子示踪（可视化用，不参与计算）。
    %   粒子随格心速度场移动（双线性插值 + 中点法），记录最近 trail 帧的位置作为尾迹。
    %   粒子进入固体、离开计算域或寿命到期时在随机流体格重生（多数在机箱内）。
    %   坐标为格坐标：X 为列（x 向右），Y 为行（y 向下），与主视图 imagesc 一致。
    properties
        n = 1500           % 粒子数
        trail = 8          % 尾迹长度 [帧]
        maxAge = 150       % 寿命 [帧]（错开重生，避免集体消失）
        insideFrac = 0.85  % 重生在机箱内的比例
        X                  % n×(trail+1) 位置历史，第 1 列为最新
        Y
        age                % n×1 已存活帧数
        speed              % n×1 最新速度 [m/s]
    end
    properties (Access = private)
        fluidIdx           % 可重生的流体格（线性索引）
        insideIdx
        W
        H
    end

    methods
        function obj = ParticleTracer(n, trail)
            if nargin >= 1 && ~isempty(n), obj.n = n; end
            if nargin >= 2 && ~isempty(trail), obj.trail = trail; end
        end

        function reset(obj, solver)
            % 按求解器几何在流体格内随机撒点
            obj.W = solver.GRID.W; obj.H = solver.GRID.H;
            fluid = solver.obstacle == 0;
            ring = false(obj.W * obj.H, 1); ring(solver.spongeRingIdx) = true;
            obj.fluidIdx = find(fluid & ~ring);
            obj.insideIdx = intersect(obj.fluidIdx, solver.insideMask);
            [x, y] = obj.spawn(obj.n);
            obj.X = repmat(x, 1, obj.trail + 1);
            obj.Y = repmat(y, 1, obj.trail + 1);
            obj.age = floor(rand(obj.n, 1) * obj.maxAge);
            obj.speed = zeros(obj.n, 1);
        end

        function step(obj, solver, dtSec)
            % 推进 dtSec 秒（物理时间）；速度场取求解器当前格心速度
            if isempty(obj.X) || obj.W ~= solver.GRID.W, obj.reset(solver); end
            [uc, vc] = solver.getCellVelocity();
            s = solver.VEL_SCALE * dtSec / (solver.GRID.cell_size_mm / 1000);   % 网格速度 → 格/帧
            U = reshape(uc, obj.W, obj.H) * s;
            V = reshape(vc, obj.W, obj.H) * s;
            x = obj.X(:, 1); y = obj.Y(:, 1);
            [u1, v1] = obj.sample(U, V, x, y);
            [u2, v2] = obj.sample(U, V, x + 0.5*u1, y + 0.5*v1);
            xn = x + u2; yn = y + v2;
            obj.speed = hypot(u2, v2) / s * solver.VEL_SCALE .* (s > 0);
            obj.X = [xn, obj.X(:, 1:end-1)];
            obj.Y = [yn, obj.Y(:, 1:end-1)];
            obj.age = obj.age + 1;
            % 出界、进入固体、寿命到期 → 重生
            xi = round(xn); yi = round(yn);
            out = xi < 2 | xi > obj.H - 1 | yi < 2 | yi > obj.W - 1;
            idx = ones(obj.n, 1);
            idx(~out) = (xi(~out) - 1) * obj.W + yi(~out);
            solid = false(obj.n, 1);
            solid(~out) = solver.obstacle(idx(~out)) > 0;
            dead = out | solid | obj.age > obj.maxAge;
            if any(dead)
                [sx, sy] = obj.spawn(sum(dead));
                obj.X(dead, :) = repmat(sx, 1, obj.trail + 1);
                obj.Y(dead, :) = repmat(sy, 1, obj.trail + 1);
                obj.age(dead) = 0;
                obj.speed(dead) = 0;
            end
        end

        function [xs, ys] = trailLines(obj)
            % 尾迹折线（NaN 分隔），供一个 line 对象绘制
            m = obj.trail + 1;
            xs = [obj.X, nan(obj.n, 1)]'; ys = [obj.Y, nan(obj.n, 1)]';
            xs = reshape(xs, obj.n * (m + 1), 1);
            ys = reshape(ys, obj.n * (m + 1), 1);
        end
    end

    methods (Access = private)
        function [x, y] = spawn(obj, k)
            nIn = round(k * obj.insideFrac);
            pool = {obj.insideIdx, obj.fluidIdx};
            cnt = [nIn, k - nIn];
            x = zeros(k, 1); y = zeros(k, 1); j = 0;
            for p = 1:2
                P = pool{p};
                if isempty(P), P = obj.fluidIdx; end
                c = P(randi(numel(P), cnt(p), 1));
                x(j+1:j+cnt(p)) = ceil(c / obj.W) + rand(cnt(p), 1) - 0.5;
                y(j+1:j+cnt(p)) = mod(c - 1, obj.W) + 1 + rand(cnt(p), 1) - 0.5;
                j = j + cnt(p);
            end
        end

        function [u, v] = sample(~, U, V, x, y)
            u = interp2(U, x, y, 'linear', 0);
            v = interp2(V, x, y, 'linear', 0);
        end
    end
end
