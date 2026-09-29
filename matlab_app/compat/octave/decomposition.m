classdef decomposition < handle
    %DECOMPOSITION Octave 兼容层：MATLAB decomposition 的最小替代。
    %   仅在 Octave 下由 setup_paths 加入路径；MATLAB 使用内置实现。
    %   支持 dec = decomposition(A, type) 与 x = dec \ b。
    %   一律用稀疏 LU（UMFPACK）分解，type 参数只做记录。

    properties
        Type = 'auto'
        L = []
        U = []
        P = []
        Q = []
        n = 0
    end

    methods
        function obj = decomposition(A, type)
            if nargin >= 2, obj.Type = type; end
            A = sparse(A);
            obj.n = size(A, 1);
            [obj.L, obj.U, obj.P, obj.Q] = lu(A);
        end

        function x = mldivide(obj, b)
            x = obj.Q * (obj.U \ (obj.L \ (obj.P * b)));
        end
    end
end
