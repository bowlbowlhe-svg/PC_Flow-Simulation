classdef decomposition < handle
    %DECOMPOSITION Octave 兼容层：MATLAB decomposition 的最小替代。
    %   仅在 Octave 下由 setup_paths 加入路径；MATLAB 使用内置实现。
    %   支持 dec = decomposition(A, type) 与 x = dec \ b。
    %   'chol'/'ldl'：尝试稀疏 Cholesky（对称正定时），否则与 'auto' 一样用稀疏 LU。

    properties
        Type = 'auto'
        L = []
        U = []
        P = []
        Q = []
        Rt = []       % chol：R 的转置（预存，避免每次求解转置）
        perm = []     % chol：置换向量，R'R = A(perm,perm)
        n = 0
    end

    methods
        function obj = decomposition(A, type)
            if ~exist('OCTAVE_VERSION', 'builtin')
                error('compat:octaveOnly', ['compat/octave 兼容层只供 Octave 使用；MATLAB 下请勿把它加入路径' ...
                    '（不要 addpath(genpath(...))，用 setup_paths）。']);
            end
            if nargin >= 2, obj.Type = type; end
            A = sparse(A);
            obj.n = size(A, 1);
            if any(strcmp(obj.Type, {'chol', 'ldl'}))
                % 对称正定：稀疏 Cholesky（带填充最小化置换）；不正定时退回 LU
                [R, flag, q] = chol(A, 'vector');
                if flag == 0
                    obj.Type = 'chol';
                    obj.U = R; obj.Rt = R'; obj.perm = q;
                    return;
                end
            end
            obj.Type = 'lu';
            [obj.L, obj.U, obj.P, obj.Q] = lu(A);
        end

        function x = mldivide(obj, b)
            if strcmp(obj.Type, 'chol')
                x = zeros(size(b));
                x(obj.perm, :) = obj.U \ (obj.Rt \ b(obj.perm, :));
            else
                x = obj.Q * (obj.U \ (obj.L \ (obj.P * b)));
            end
        end
    end
end
