classdef griddedInterpolant < handle
    %GRIDDEDINTERPOLANT Octave 兼容层：MATLAB griddedInterpolant 的最小替代。
    %   仅在 Octave 下由 setup_paths 加入路径；MATLAB 使用内置实现。
    %   支持均匀网格上的 1D/2D 'linear' / 'cubic' / 'makima' 插值，
    %   外插一律按 'nearest'（查询点钳入网格范围）。
    %   2D 为逐维张量积（先沿第 2 维、再沿第 1 维做三次 Hermite），
    %   边界按二次外插延拓两格（与 MATLAB cubic/makima 的边界口径一致）。
    %   与 MATLAB 数值不保证逐位一致，仅供 Octave 下无界面自检。

    properties
        GridVectors = {}
        Values = []
        Method = 'linear'
        ExtrapolationMethod = 'nearest'
    end

    methods
        function obj = griddedInterpolant(varargin)
            if ~exist('OCTAVE_VERSION', 'builtin')
                error('compat:octaveOnly', ['compat/octave 兼容层只供 Octave 使用；MATLAB 下请勿把它加入路径' ...
                    '（不要 addpath(genpath(...))，用 setup_paths）。']);
            end
            isStr = cellfun(@ischar, varargin);
            strs = varargin(isStr);
            nums = varargin(~isStr);
            if numel(strs) >= 1, obj.Method = lower(strs{1}); end
            if numel(strs) >= 2, obj.ExtrapolationMethod = lower(strs{2}); end
            V = nums{end};
            G = nums(1:end-1);
            if isempty(G)
                if isvector(V)
                    obj.GridVectors = {1:numel(V)};
                else
                    obj.GridVectors = {1:size(V,1), 1:size(V,2)};
                end
            elseif numel(G) == 1
                obj.GridVectors = {G{1}(:).'};
            else
                obj.GridVectors = {reshape(G{1}(:,1), 1, []), reshape(G{2}(1,:), 1, [])};
            end
            obj.Values = V;
        end

        function varargout = subsref(obj, s)
            if strcmp(s(1).type, '()')
                out = evaluate(obj, s(1).subs{:});
                if numel(s) > 1
                    out = subsref(out, s(2:end));
                end
                varargout = {out};
            else
                varargout = cell(1, max(1, nargout));
                [varargout{:}] = builtin('subsref', obj, s);
            end
        end

        function out = evaluate(obj, varargin)
            if numel(obj.GridVectors) == 1
                out = evaluate1d(obj, varargin{1});
            else
                out = evaluate2d(obj, varargin{1}, varargin{2});
            end
        end
    end

    methods (Access = private)
        function out = evaluate1d(obj, q)
            g = obj.GridVectors{1};
            v = obj.Values(:).';
            n = numel(g);
            u = (q - g(1)) / (g(2) - g(1)) + 1;
            u = min(max(u, 1), n);
            i = min(floor(u), n - 1);
            t = u - i;
            if strcmp(obj.Method, 'linear')
                out = v(i) .* (1 - t) + v(i + 1) .* t;
            else
                S = griddedInterpolant.slopesDim2(v, obj.Method);
                out = griddedInterpolant.hermite(v(i), v(i + 1), S(i), S(i + 1), t);
            end
            out = reshape(out, size(q));
        end

        function out = evaluate2d(obj, q1, q2)
            g1 = obj.GridVectors{1}; g2 = obj.GridVectors{2};
            V = obj.Values;
            n1 = numel(g1); n2 = numel(g2);
            u1 = (q1(:) - g1(1)) / (g1(2) - g1(1)) + 1;
            u2 = (q2(:) - g2(1)) / (g2(2) - g2(1)) + 1;
            u1 = min(max(u1, 1), n1);
            u2 = min(max(u2, 1), n2);
            i1 = min(floor(u1), n1 - 1); t1 = u1 - i1;
            i2 = min(floor(u2), n2 - 1); t2 = u2 - i2;
            if strcmp(obj.Method, 'linear')
                a = V(i1 + (i2 - 1) * n1);      b = V(i1 + i2 * n1);
                c = V(i1 + 1 + (i2 - 1) * n1);  d = V(i1 + 1 + i2 * n1);
                out = (a .* (1 - t2) + b .* t2) .* (1 - t1) + (c .* (1 - t2) + d .* t2) .* t1;
                out = reshape(out, size(q1));
                return;
            end
            % 第 1 维两端各二次外插 2 行，再沿第 2 维求 Hermite 斜率
            Vp = griddedInterpolant.padDim1(V);          % (n1+4) × n2
            S2 = griddedInterpolant.slopesDim2(Vp, obj.Method);
            m = n1 + 4;
            f = zeros(numel(u1), 6);
            for k = -2:3
                r = i1 + k + 2;                            % 填充后行号
                la = r + (i2 - 1) * m;  lb = r + i2 * m;
                f(:, k + 3) = griddedInterpolant.hermite(Vp(la), Vp(lb), S2(la), S2(lb), t2);
            end
            [d3, d4] = griddedInterpolant.slopesFromSix(f, obj.Method);
            out = griddedInterpolant.hermite(f(:, 3), f(:, 4), d3, d4, t1);
            out = reshape(out, size(q1));
        end
    end

    methods (Static, Access = private)
        function y = hermite(a, b, da, db, t)
            t2 = t .* t; t3 = t2 .* t;
            y = (2*t3 - 3*t2 + 1) .* a + (t3 - 2*t2 + t) .* da + ...
                (-2*t3 + 3*t2) .* b + (t3 - t2) .* db;
        end

        function Ap = padDim1(A)
            % 沿第 1 维两端各二次外插 2 格（二阶差分为常数）
            f0 = 3*A(1,:) - 3*A(2,:) + A(3,:);
            fm = 3*f0 - 3*A(1,:) + A(2,:);
            g0 = 3*A(end,:) - 3*A(end-1,:) + A(end-2,:);
            gm = 3*g0 - 3*A(end,:) + A(end-1,:);
            Ap = [fm; f0; A; g0; gm];
        end

        function S = slopesDim2(A, method)
            % 沿第 2 维的节点斜率（单位格距），与 A 同尺寸
            f0 = 3*A(:,1) - 3*A(:,2) + A(:,3);
            fm = 3*f0 - 3*A(:,1) + A(:,2);
            g0 = 3*A(:,end) - 3*A(:,end-1) + A(:,end-2);
            gm = 3*g0 - 3*A(:,end) + A(:,end-1);
            Ap = [fm, f0, A, g0, gm];
            n = size(A, 2);
            if strcmp(method, 'makima')
                dl = diff(Ap, 1, 2);                       % 列 j..j+3 对应 δ_{i-2}..δ_{i+1}
                S = griddedInterpolant.makimaSlope(dl(:, 1:n), dl(:, 2:n+1), dl(:, 3:n+2), dl(:, 4:n+3));
            else
                S = 0.5 * (Ap(:, 4:n+3) - Ap(:, 2:n+1));   % cubic 卷积（中心差分）
            end
        end

        function [d3, d4] = slopesFromSix(f, method)
            if strcmp(method, 'makima')
                dl = diff(f, 1, 2);                        % δ1..δ5
                d3 = griddedInterpolant.makimaSlope(dl(:,1), dl(:,2), dl(:,3), dl(:,4));
                d4 = griddedInterpolant.makimaSlope(dl(:,2), dl(:,3), dl(:,4), dl(:,5));
            else
                d3 = 0.5 * (f(:,4) - f(:,2));
                d4 = 0.5 * (f(:,5) - f(:,3));
            end
        end

        function s = makimaSlope(dm2, dm1, d0, dp1)
            % 修正 Akima 斜率（与 MATLAB makima 同式）
            wLo = abs(dm1 - dm2) + abs(dm1 + dm2) / 2;
            wHi = abs(dp1 - d0)  + abs(dp1 + d0)  / 2;
            wSum = wLo + wHi;
            s = (wHi .* dm1 + wLo .* d0) ./ wSum;
            s(wSum == 0) = 0;
        end
    end
end
