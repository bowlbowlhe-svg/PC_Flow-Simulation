classdef CFDSolverFEM < CFDSolverBase
    %CFDSOLVERFEM PC风道CFD求解器 — 稀疏FEM精确求解版
    % 使用核心函数 decomposition (R2017b+) 替代手写迭代法。
    % 实现 CFDSolverBase 抽象方法 fluidStep。

    properties
        % ===== FEM / 稀疏求解内部属性 =====
        K_lap           % 稀疏 Laplacian（5点差分，与P1 FEM等价）
        M_mass          % 对角质量矩阵（lumped）
        decomp_vel      % [v3.0 退役] 原格心速度扩散分解（面场扩散用 decomp_velU/V）
        decomp_velU = []   % v3.0：u 面格子隐式扩散 LHS 分解
        decomp_velV = []   % v3.0：v 面格子隐式扩散 LHS 分解
        velU_actIdx = []   % u 面激活子矩阵行映射
        velV_actIdx = []   % v 面激活子矩阵行映射
        decomp_pres     % decomposition 缓存：压力泊松 LHS
        decomp_temp     % decomposition 缓存：温度扩散 LHS
        pres_ref        % 压力参考节点（消除奇异性）
        openPresIdx = []  % [v2.8 起停用，置空] 原机箱开口格压力 Dirichlet p=0
        farFieldPresIdx = []  % 远场海绵环格（v2.8：压力 Dirichlet p=0，环境参考压力）
        projectSpongeRing = true  % v2.9：远场环格做单侧压力梯度修正（false 退回 v2.8）
        vel_diag_oi     % A_vel 在障碍物节点的对角值（用于 RHS pinning）
        temp_diag_oi    % A_temp 在障碍物节点的对角值（用于温度 RHS pinning）
        L_vel           % 存储的 velocity Laplacian（用于动态更新有效粘性）
        L_temp          % 温度 Laplacian（真 Dirichlet：无 adjCount 对角补偿，耦合项经 RHS 修正恢复）
        E_obs           % 障碍格对角选择矩阵 sparse(oi,oi,1)（装配用）
        colWall         % wallObsIdx 在 obsIdx 中的列号（tempCoupling 列映射）
        colHeat         % heatObsIdx 在 obsIdx 中的列号
        tempCoupling = []   % 空间 α 场时：加权 Laplacian 的流体×障碍耦合块（RHS 修正用）
        lastNuEff = 0   % 上次 velocity 扩散使用的有效粘性
        lastAlphaEff = 0% 上次温度扩散使用的有效热扩散率
        lastAlphaField = []  % 上次温度扩散使用的空间 α 场（v2.7.1：守恒校核逐格面加权用）
        % ===== v2.10：k-ω 湍流输运缓存 =====
        decomp_turbK = []   % k 方程隐式扩散 LHS 缓存
        decomp_turbW = []   % ω 方程隐式扩散 LHS 缓存
        lastNuTKMed = 0     % 上次装配时 ν_t 中位数（5% 变化触发重装配）
        wallAdjFluidIdx = []% 障碍邻接流体格（k-ω 壁面边界用，懒计算缓存）
        wallAdjCaseIdx = [] % 机箱壁邻接流体格（k Dirichlet 子集，v2.10.1）

        % ===== 三次插值器（griddedInterpolant）=====
        gridInterpF     % 通用 cubic 插值器，用于 u/v 速度场平流
        gridInterpT     % 温度场专用 makima 插值器（v2.7：保形无过冲）
        gridInterpUF    % v3.0：u 面点阵 cubic 插值器（W×(H+1)）
        gridInterpVF    % v3.0：v 面点阵 cubic 插值器((W+1)×H)
    end

    methods
        function obj = CFDSolverFEM(cpuPower, gpuPower, psuPower, layoutName, gridScale, dtVal)
            if nargin < 1, cpuPower  = 125; end
            if nargin < 2, gpuPower  = 250; end
            if nargin < 3, psuPower  = 450; end
            if nargin < 4, layoutName = 'atx_balanced'; end
            if nargin < 5, gridScale = 1; end
            if nargin < 6, dtVal = 0.005; end
            obj@CFDSolverBase(cpuPower, gpuPower, psuPower, layoutName, gridScale, dtVal);
            obj.assembleSparseMatrices();
            obj.initGridInterpolants();
        end

        function initFields(obj)
            % v2.10：重置基类场后清空 k-ω 装配缓存（ν_t 回到初值必触发重装配，
            % 显式清空避免任何陈旧分解残留）
            initFields@CFDSolverBase(obj);
            obj.decomp_turbK = []; obj.decomp_turbW = [];
            obj.lastNuTKMed = 0;
            % v3.0：面场扩散缓存一并作废（面掩码/ν 场均回到初态）
            obj.decomp_velU = []; obj.decomp_velV = [];
            obj.velU_actIdx = []; obj.velV_actIdx = [];
            obj.lastNuEff = 0;
        end

        function assembleSparseMatrices(obj)
            W  = obj.GRID.W;
            H  = obj.GRID.H;
            N  = W * H;
            dt = obj.DT;
            nu = obj.AIR.nu;

            % 5点差分 Laplacian（等价于结构网格 P1 FEM）
            e  = ones(W,1);
            Dx = spdiags([e -2*e e], [-1 0 1], W, W);
            e  = ones(H,1);
            Dy = spdiags([e -2*e e], [-1 0 1], H, H);
            L  = kron(speye(H), Dx) + kron(Dy, speye(W));

            % 网格-物理坐标换算因子：匹配原求解器 a = dt*nu*(W-2)*(H-2) 的隐式强度
            gs = (W-2) * (H-2);

            % Lumped 质量矩阵（每格面积=1）
            obj.M_mass = speye(N);
            obj.K_lap  = L;

            oi = obj.obsIdx;
            obj.E_obs = sparse(oi, oi, ones(length(oi),1), N, N);
            [~, obj.colWall] = ismember(obj.wallObsIdx, oi);
            [~, obj.colHeat] = ismember(obj.heatObsIdx, oi);
            obj.tempCoupling = [];

            % ---- 速度扩散（v3.0：MAC 面场格子，首次 diffuseVelocity 懒装配）----
            % 旧格心 L_vel/decomp_vel 装配退役；面场两套 decomp 见
            % assembleFaceDiffusion（ν_eff 中位数 5% 变化触发重装配）。
            % 隐式扩散符号约定：Dx=[+1 −2 +1] 给出 L = +∇²（对角负），
            % LHS = (M/dt − ν·gs·L)，符号为「−」。
            % v2.5 修复：之前误写为「+」相当于求解反扩散方程，导致 T_fluid runaway。
            obj.lastNuEff = 0;

            % ---- 压力泊松 LHS（障碍物 Dirichlet p=0 + 开口 Dirichlet p=0）----
            obj.assemblePressureMatrix();

            % ---- 温度扩散 LHS（热扩散率 alpha = nu/Pr；含 grid_scale）----
            % 机箱壁/散热器格是（非零）Dirichlet（25°C / T_solid），
            % 不能像速度那样做 adjCount 对角补偿，损失的耦合项由
            % diffuseTemperature 的 RHS 修正恢复。
            % v2.7：内部钉扎件（主板/隔板/RAM 等）改为 Neumann 绝热——
            % 被清零的绝热列权重回补流体对角（与 L_vel 的 adjCount 同型）。
            Ltemp = L;
            Ltemp(oi,:) = 0;
            Ltemp(:,oi) = 0;
            Ltemp = Ltemp + sparse(oi, oi, ones(length(oi),1), N, N);
            if ~isempty(obj.adiabaticObsIdx)
                adjAdi = full(sum(L(:, obj.adiabaticObsIdx) ~= 0, 2));
                fluidMsk = true(N,1); fluidMsk(oi) = false;
                Ltemp = Ltemp + spdiags(adjAdi .* fluidMsk, 0, N, N);
            end
            obj.L_temp = Ltemp;
            alpha  = nu / obj.AIR.Pr;
            A_temp = obj.M_mass/dt - alpha * gs * Ltemp;
            obj.decomp_temp  = decomposition(A_temp, 'ldl');
            obj.temp_diag_oi = 1/dt - alpha * gs;
            obj.lastAlphaEff = alpha;
        end

        function assemblePressureMatrix(obj)
            % 压力泊松 LHS（v3.0：D·G 复合装配）。
            % MAC 下散度与梯度严格互为转置：div∘grad 复合 = 标准 5 点 Laplacian，
            % 直接按格间面激活掩码装配——障碍面自动丢项（天然 Neumann，无穿透），
            % 替代旧 K_lap 清零的障碍伪 Dirichlet（v2.5 错配的根源之一）。
            % 远场环格 p=0 Dirichlet 钉扎保留：环面保留在流体格对角中
            % （环格列清零后 = p_ring=0 已知的伪 Dirichlet，无需 RHS 修正），
            % pres_ref 单点钉扎消奇异性同现状。
            % 注：v2.9 的环格单侧梯度修正（projectSpongeRing）随本算子退役（P3）。
            W = obj.GRID.W; H = obj.GRID.H; N = W * H;
            fluidM = obj.obstacle == 0;
            iif = find(fluidM);
            xx = ceil(iif / W);              % 格 x 坐标
            yy = iif - (xx-1)*W;             % 格 y 坐标
            % 各方向面激活 ⟺ 邻格为流体（面跨流体↔障碍即丢项）
            okR = false(size(iif)); m = xx < H; okR(m) = fluidM(iif(m) + W);
            okL = false(size(iif)); m = xx > 1; okL(m) = fluidM(iif(m) - W);
            okU = false(size(iif)); m = yy < W; okU(m) = fluidM(iif(m) + 1);
            okD = false(size(iif)); m = yy > 1; okD(m) = fluidM(iif(m) - 1);
            Io = [iif(okR); iif(okL); iif(okU); iif(okD)];
            Jo = [iif(okR)+W; iif(okL)-W; iif(okU)+1; iif(okD)-1];
            Lp = sparse(Io, Jo, 1, N, N);
            diagCnt = -(double(okR) + double(okL) + double(okU) + double(okD));
            Lp = Lp + sparse(iif, iif, diagCnt, N, N);
            ffIdx = setdiff(obj.spongeRingIdx, obj.obsIdx);  % 海绵环必是流体，双保险
            obj.farFieldPresIdx = ffIdx;
            obj.openPresIdx = [];   % v2.8：开口不再钉压
            pin = [obj.obsIdx; ffIdx];
            Lp(pin, :) = 0; Lp(:, pin) = 0;
            Lp = Lp + sparse(pin, pin, ones(numel(pin),1), N, N);
            obj.pres_ref = find(obj.obstacle == 0, 1);
            Lp(obj.pres_ref, :)            = 0;
            Lp(obj.pres_ref, obj.pres_ref) = 1;
            obj.decomp_pres = decomposition(Lp, 'auto');
        end

        function onOpeningsChanged(obj)
            % v2.7.1：开口变化（App 改风扇/布局）后重装压力矩阵。
            % 基类构造函数期间 K_lap 尚不存在，跳过（assembleSparseMatrices
            % 会随后显式调用 assemblePressureMatrix）。
            if isempty(obj.K_lap)
                return;
            end
            obj.assemblePressureMatrix();
        end

        function initGridInterpolants(obj)
            W = obj.GRID.W; H = obj.GRID.H;
            [Xnd, Ynd] = ndgrid(1:W, 1:H);
            obj.gridInterpF = griddedInterpolant(Xnd, Ynd, zeros(W,H), 'cubic','nearest');
            % v2.7：温度场单独用 makima（保形无过冲）。cubic 在热羽流边缘的
            % 过冲是真实的数值能源：下冲瓣被 max(T,25) 钳位吸收（计账约 +82W），
            % 上冲瓣无约束地注入能量——全功率注入下梯度变陡 5 倍后此问题暴露。
            obj.gridInterpT = griddedInterpolant(Xnd, Ynd, zeros(W,H), 'makima','nearest');
            % v3.0：MAC 面点阵插值器（面心平流回溯用）
            % u 面 (y, xf−0.5)：y ∈ 1..W，xf−0.5 ∈ 0.5..H+0.5
            [XndU, YndU] = ndgrid(1:W, 0.5:H+0.5);
            obj.gridInterpUF = griddedInterpolant(XndU, YndU, zeros(W, H+1), 'cubic','nearest');
            % v 面 (yf−0.5, x)：yf−0.5 ∈ 0.5..W+0.5，x ∈ 1..H
            [XndV, YndV] = ndgrid(0.5:W+0.5, 1:H);
            obj.gridInterpVF = griddedInterpolant(XndV, YndV, zeros(W+1, H), 'cubic','nearest');
        end

        function [Lw, coupling] = buildWeightedLaplacian(obj, wField, preserveConstant, adiIdx)
            % 面加权 Laplacian（v2.6，空间变化 ν_eff/α_eff 用）：
            %   off-diag(i,j) = +(w_i + w_j)/2，diag = -Σ 面权重
            % preserveConstant=true（速度）：障碍面权重加回流体对角，
            %   维持原 L_vel 的 adjCount（L·1≈0）行为；障碍行/列清零。
            % preserveConstant=false（温度）：真 Dirichlet，仅清零；
            %   coupling 返回清零前的 流体×障碍 耦合块，供 RHS 修正。
            %   v2.7：可选 adiIdx（内部钉扎件）做 Neumann 绝热——其面权重
            %   回补流体对角，coupling 仍含全部障碍列（RHS 只用 Dirichlet 列）。
            if nargin < 4, adiIdx = []; end
            N = obj.GRID.TOTAL;
            [I, J, ~] = find(obj.K_lap);
            off = I ~= J;
            Io = I(off); Jo = J(off);
            wij = 0.5*(wField(Io) + wField(Jo));
            Lfull = sparse(Io, Jo, wij, N, N);
            Lfull = Lfull + spdiags(-full(sum(Lfull, 2)), 0, N, N);
            % 外圈口径与 K_lap 一致（伪 Dirichlet）：K_lap 由 spdiags 生成，
            % 外圈 diag 恒含"缺失邻居"的权重；这里把缺失面权重补回对角，
            % 避免触发重装配后外圈算子从伪 Dirichlet 悄悄变 Neumann（v2.6.1 审计 S2）
            W = obj.GRID.W; H = obj.GRID.H;
            yy = mod((1:N)'-1, W) + 1;  xx = ceil((1:N)'/W);
            missing = 4 - ((yy>1) + (yy<W) + (xx>1) + (xx<H));
            Lfull = Lfull + spdiags(-missing .* wField, 0, N, N);
            oi = obj.obsIdx;
            coupling = Lfull(:, oi);
            if preserveConstant
                adjW = full(sum(Lfull(:, oi), 2));
                adjW(oi) = 0;
                Lfull(oi,:) = 0; Lfull(:,oi) = 0;
                Lfull = Lfull + spdiags(adjW, 0, N, N);
            else
                % v2.7：绝热格面权重回补流体对角（Neumann），Dirichlet 格保持真清零
                if ~isempty(adiIdx)
                    adjAdi = full(sum(Lfull(:, adiIdx), 2));
                    adjAdi(oi) = 0;
                    Lfull = Lfull + spdiags(adjAdi, 0, N, N);
                end
                Lfull(oi,:) = 0; Lfull(:,oi) = 0;
            end
            Lw = Lfull;
        end

        function diffuseVelocity(obj, nuEff)
            % v3.0：MAC 面场隐式扩散。u/v 面各自点阵上 5 点 Laplacian
            % （面粘性 = 两邻格 ν_eff 算术平均；面间链接权重 = 0.5(w_f+w_g)），
            % 未激活面钉 0（Dirichlet 0 链接保留在活动面对角 = 精确位于
            % 壁面的无滑移阻力，替代旧格心方案的"壁在格心"一格偏移）。
            % 仍按 ν_eff 中位数 5% 变化触发重装配（两套 decomp）。
            if nargin < 2 || isempty(nuEff)
                nuEff = obj.AIR.nu;
            end
            if numel(nuEff) > 1
                nuField = max(nuEff(:), obj.AIR.nu);
                nuVal = median(nuField);   % 变化检测用代表值
            else
                nuVal = max(nuEff, obj.AIR.nu);
                nuField = ones(obj.GRID.TOTAL, 1) * nuVal;
            end

            if obj.lastNuEff <= 0 || abs(nuVal - obj.lastNuEff) / obj.lastNuEff > 0.05
                dt = obj.DT;
                gs = (obj.GRID.W-2) * (obj.GRID.H-2);
                [obj.decomp_velU, obj.velU_actIdx] = obj.assembleFaceDiffusion(nuField, true,  dt, gs);
                [obj.decomp_velV, obj.velV_actIdx] = obj.assembleFaceDiffusion(nuField, false, dt, gs);
                obj.lastNuEff = nuVal;
            end

            obj.uF(~obj.uFaceActive) = 0;
            obj.vF(~obj.vFaceActive) = 0;
            au = obj.velU_actIdx;
            obj.uF(au) = obj.decomp_velU \ (obj.uF(au) / obj.DT);
            av = obj.velV_actIdx;
            obj.vF(av) = obj.decomp_velV \ (obj.vF(av) / obj.DT);
        end

        function [dec, actIdx] = assembleFaceDiffusion(obj, nuField, isU, dt, gs)
            % 面点阵隐式扩散 LHS（仅激活面子矩阵）：
            %   A = I/dt − gs·L_face；L_face off-diag = 0.5(w_f+w_g)（邻接激活面），
            %   diag = −Σ链接权重。未激活邻居（壁面钉 0 面）与点阵越界方向以
            %   w_f 计入对角（Dirichlet 0 链接，口径同 K_lap 外圈伪 Dirichlet）。
            W = obj.GRID.W; H = obj.GRID.H;
            nuM = reshape(nuField, W, H);
            if isU
                % u 面点阵 (W, H+1)，面粘性 = x 向两邻格平均
                wM = zeros(W, H+1);
                wM(:, 2:H) = 0.5*(nuM(:,1:H-1) + nuM(:,2:H));
                wM(:, 1)   = nuM(:,1);
                wM(:, H+1) = nuM(:,H);
                actM = reshape(obj.uFaceActive, W, H+1);
                nR = W; nC = H+1;
            else
                % v 面点阵 (W+1, H)，面粘性 = y 向两邻格平均
                wM = zeros(W+1, H);
                wM(2:W, :) = 0.5*(nuM(1:W-1,:) + nuM(2:W,:));
                wM(1, :)   = nuM(1,:);
                wM(W+1, :) = nuM(W,:);
                actM = reshape(obj.vFaceActive, W+1, H);
                nR = W+1; nC = H;
            end
            nTot = nR * nC;
            actL = actM(:);
            af = find(actL);
            rr = mod(af-1, nR) + 1;
            cc = ceil(af / nR);
            wF = wM(af);
            Io = []; Jo = []; Vo = [];
            diagAcc = zeros(numel(af), 1);
            offs = [-1, 1, -nR, nR];
            for d = 1:4
                off = offs(d);
                switch d
                    case 1, inB = rr > 1;
                    case 2, inB = rr < nR;
                    case 3, inB = cc > 1;
                    otherwise, inB = cc < nC;
                end
                % 越界方向：Dirichlet 0 链接（w_f）
                diagAcc(~inB) = diagAcc(~inB) - wF(~inB);
                g = af(inB) + off;
                actG = actL(g);
                wFs = wF(inB);
                % 未激活邻居（壁面钉 0 面）：Dirichlet 0 链接（w_f）
                diagAccSub = zeros(numel(wFs), 1);
                diagAccSub(:) = wFs;
                diagAccSub(actG) = 0.5*(wFs(actG) + wM(g(actG)));
                diagAcc(inB) = diagAcc(inB) - diagAccSub;
                % 激活邻居：对称 off-diag
                if any(actG)
                    Io = [Io; af(inB)];  %#ok<AGROW> 先全量收集，下方按 actG 过滤
                    Jo = [Jo; g];        %#ok<AGROW>
                    Vo = [Vo; diagAccSub]; %#ok<AGROW>
                end
            end
            % 仅保留激活邻居的 off-diag 项
            keep = false(numel(Io), 1);
            if ~isempty(Io)
                keep = actL(Jo);
            end
            Io = Io(keep); Jo = Jo(keep); Vo = Vo(keep);
            loc = zeros(nTot, 1); loc(af) = 1:numel(af);
            nA = numel(af);
            Lf = sparse(loc(Io), loc(Jo), Vo, nA, nA);
            Lf = Lf + spdiags(diagAcc, 0, nA, nA);
            A = speye(nA)/dt - gs * Lf;
            dec = decomposition(A, 'ldl');
            actIdx = af;
        end

        function project(obj)
            % v3.0：单次满修正 MAC 投影（ω=1）。div/grad 与压力算子严格互洽后
            % 无需欠松弛防过冲；v2.9 的削顶补偿第二投影退役——削顶极少触发，
            % 残散由下一步投影吸收。速度上限保留：物理 6 m/s。
            vel_cap = 6.0 / obj.VEL_SCALE;
            obj.projectPass(1.0, vel_cap);
        end

        function clipped = projectPass(obj, omega, velCap)
            % v3.0 MAC 投影：面场散度 → 泊松求解 → 面梯度修正。
            % div/grad 严格互为转置，且与 assemblePressureMatrix 的 D·G 装配
            % 是同一算子（L_p = D·G：off-diag +1 / diag −激活面数），错配消除。
            % 退役：v2.9 projectSpongeRing 环格单侧梯度修正（环格 p=0 已被
            % D·G 装配的伪 Dirichlet 正确处理，环面保留在流体格对角中）。
            W = obj.GRID.W; H = obj.GRID.H;
            uM = reshape(obj.uF, W, H+1);
            vM = reshape(obj.vF, W+1, H);
            uActM = reshape(obj.uFaceActive, W, H+1);
            vActM = reshape(obj.vFaceActive, W+1, H);

            % 散度：div(y,x) = uF(y,x+1)−uF(y,x) + vF(y+1,x)−vF(y,x)
            % 只累加激活面（未激活面恒 0，显式掩码防御脏值）
            div = uM(:,2:H+1).*uActM(:,2:H+1) - uM(:,1:H).*uActM(:,1:H) ...
                + vM(2:W+1,:).*vActM(2:W+1,:) - vM(1:W,:).*vActM(1:W,:);
            rhs_p = div(:);
            rhs_p(obj.obsIdx) = 0;
            rhs_p(obj.farFieldPresIdx) = 0;   % 远场海绵环压力 Dirichlet p=0
            rhs_p(obj.pres_ref) = 0;

            obj.p = obj.decomp_pres \ rhs_p;
            obj.p(obj.obsIdx) = 0;
            obj.p(obj.farFieldPresIdx) = 0;

            pM = reshape(obj.p, W, H);
            % 梯度修正：uF(y,xf) −= ω·(p(y,xf)−p(y,xf-1))，仅格间激活面；
            % 域边界面（xf=1/H+1）不修正——邻接环格 p=0，阻尼环吸收。
            dpU = zeros(W, H+1);
            dpU(:, 2:H) = pM(:, 2:H) - pM(:, 1:H-1);
            uM = uM - omega * dpU .* uActM;
            dpV = zeros(W+1, H);
            dpV(2:W, :) = pM(2:W, :) - pM(1:W-1, :);
            vM = vM - omega * dpV .* vActM;

            uM(~uActM) = 0;
            vM(~vActM) = 0;
            u0 = uM; v0 = vM;
            uM = max(-velCap, min(velCap, uM));
            vM = max(-velCap, min(velCap, vM));
            clipped = any(uM(:) ~= u0(:)) || any(vM(:) ~= v0(:));
            obj.uF = uM(:);
            obj.vF = vM(:);
        end

        function d = advect(obj, fieldId, ~, d0, uvel, vvel)
            W   = obj.GRID.W; H = obj.GRID.H;
            dt0 = obj.DT * (W-2);

            umat = reshape(uvel, W, H);
            vmat = reshape(vvel, W, H);
            [Igrid, Jgrid] = meshgrid(1:W, 1:H);

            Xq = Jgrid' - dt0 * umat;
            Yq = Igrid' - dt0 * vmat;
            % v2.9：温度场显式入流边界——回溯点出域时取远场值 25°C
            % （替代纯钳位采样；环格本就钉 25°C，语义等价但口径清晰）
            % v2.10：fieldId 3/4（k/ω 湍流场）同口径，出域点取来流湍流值
            outDomain = [];
            if fieldId == 0 || fieldId == 3 || fieldId == 4
                outDomain = (Xq < 1.5) | (Xq > W-0.5) | (Yq < 1.5) | (Yq > H-0.5);
            end
            Xq = max(1.5, min(W-0.5, Xq));
            Yq = max(1.5, min(H-0.5, Yq));

            d0mat = reshape(d0, W, H);
            % v2.7：温度场（fieldId==0）平流前把障碍格值替换为最近流体格值。
            % 防止回溯点落入钉扎热格（T_solid 无限热库）或冷壁格时插值
            % 带走/注入不可计量的热量——切断该系统级残差的主要来源。
            % v2.10：k/ω（fieldId 3/4）同样处理，障碍格的钉扎值不参与插值。
            if (fieldId == 0 || fieldId == 3 || fieldId == 4) && ~isempty(obj.nearestFluidIdx)
                obsM = reshape(obj.obstacle > 0, W, H);
                d0mat(obsM) = d0mat(obj.nearestFluidIdx(obsM));
            end
            % v3.0 修正：插值器 dim1=y，查询须为 (y回溯, x回溯)。
            % v2.x 及此前误写为 (Xq, Yq)（x 回溯传入 y 维）——数值实验
            % （均匀 +x 流 blob 试验）证实旧调用每步转置一次场，
            % 位移在两轴间交替，输运方向系统性错误。
            if fieldId == 0 || fieldId == 3 || fieldId == 4
                obj.gridInterpT.Values = d0mat;
                warning('off', 'MATLAB:griddedInterpolant:MeshgridEval2DWarnId');
                dmat = obj.gridInterpT(Yq, Xq);
                warning('on', 'MATLAB:griddedInterpolant:MeshgridEval2DWarnId');
                if fieldId == 0
                    dmat(outDomain) = 25;   % v2.9 入流边界：远场新风 25°C
                else
                    % v2.10 湍流入流边界：远场取来流 k/ω（低湍流度环境空气）
                    [kIn, wIn] = obj.turbulenceInletValues();
                    if fieldId == 3, dmat(outDomain) = kIn; else, dmat(outDomain) = wIn; end
                end
                d = dmat(:);
                return;
            end
            obj.gridInterpF.Values = d0mat;
            warning('off', 'MATLAB:griddedInterpolant:MeshgridEval2DWarnId');
            dmat = obj.gridInterpF(Yq, Xq);
            warning('on', 'MATLAB:griddedInterpolant:MeshgridEval2DWarnId');
            d = dmat(:);
        end

        function advectFaces(obj)
            % v3.0：MAC 面场半拉格朗日平流（cubic，各自面点阵插值）。
            % 回溯速度：u 面取本地 uF + 环绕四 v 面平均；v 面对称。
            % 查询/网格构造与格心 advect 同型（dim1=y 约定一致）。
            % 未激活面钉 0；回溯点钳位口径与格心版一致（避开远场环半格）。
            W = obj.GRID.W; H = obj.GRID.H;
            dt0 = obj.DT * (W-2);
            uM = reshape(obj.uF, W, H+1);
            vM = reshape(obj.vF, W+1, H);

            % ---- u 面 (y, xf)，位置 (y, xf−0.5) ----
            yUp = [2:W W];   % y+1 越界复制边值
            vAtU = zeros(W, H+1);
            vAtU(:, 2:H) = 0.25*(vM(1:W, 1:H-1) + vM(yUp, 1:H-1) + ...
                                 vM(1:W, 2:H)   + vM(yUp, 2:H));
            vAtU(:, 1)   = 0.5*(vM(1:W,1) + vM(yUp,1));
            vAtU(:, H+1) = 0.5*(vM(1:W,H) + vM(yUp,H));
            [YuG, XuG] = ndgrid(1:W, 0.5:H+0.5);   % XuG(i,j)=j−0.5（面 x 位置）
            XqU = XuG - dt0 * uM;
            YqU = YuG - dt0 * vAtU;
            XqU = max(1.0, min(H, XqU));       % 面 x 域 0.5..H+0.5，钳进 [1, H]
            YqU = max(1.5, min(W-0.5, YqU));
            obj.gridInterpUF.Values = uM;
            warning('off', 'MATLAB:griddedInterpolant:MeshgridEval2DWarnId');
            uNew = obj.gridInterpUF(YqU, XqU);   % dim1=y：查询 (y回溯, x回溯)
            % ---- v 面 (yf, x)，位置 (yf−0.5, x) ----
            uAtV = zeros(W+1, H);
            uAtV(2:W, :) = 0.25*(uM(1:W-1, 1:H) + uM(1:W-1, 2:H+1) + ...
                                 uM(2:W,   1:H) + uM(2:W,   2:H+1));
            uAtV(1, :)   = 0.5*(uM(1,1:H) + uM(1,2:H+1));
            uAtV(W+1, :) = 0.5*(uM(W,1:H) + uM(W,2:H+1));
            [YvG, XvG] = ndgrid(0.5:W+0.5, 1:H);   % YvG(i,j)=i−0.5（面 y 位置）
            XqV = XvG - dt0 * uAtV;
            YqV = YvG - dt0 * vM;
            XqV = max(1.5, min(H-0.5, XqV));
            YqV = max(1.0, min(W, YqV));
            obj.gridInterpVF.Values = vM;
            vNew = obj.gridInterpVF(YqV, XqV);   % dim1=y：查询 (y回溯, x回溯)
            warning('on', 'MATLAB:griddedInterpolant:MeshgridEval2DWarnId');

            uNew(~reshape(obj.uFaceActive, W, H+1)) = 0;
            vNew(~reshape(obj.vFaceActive, W+1, H)) = 0;
            obj.uF = uNew(:);
            obj.vF = vNew(:);
        end

        function diffuseTemperature(obj, alphaEff)
            % 若传入 alphaEff（中位数）与上次差异 >5%，则重新装配并分解温度扩散矩阵
            % v2.6：alphaEff 为空间场时（α=ν(x)/Pr），用面加权 Laplacian 装配，
            %       耦合块 tempCoupling 用于 Dirichlet RHS 修正。
            if nargin < 2 || isempty(alphaEff)
                alphaEff = obj.AIR.nu / obj.AIR.Pr;
            end
            if numel(alphaEff) > 1
                alphaField = max(alphaEff(:), obj.AIR.nu/obj.AIR.Pr);
                alphaVal = median(alphaField);
            else
                alphaField = [];
                alphaVal = max(alphaEff, obj.AIR.nu / obj.AIR.Pr);
            end
            % v2.7.1：存储本场 α 供守恒校核逐格面加权（标量路径存标量展开）
            if ~isempty(alphaField)
                obj.lastAlphaField = alphaField;
            else
                obj.lastAlphaField = alphaVal * ones(size(obj.T_fluid));
            end

            if obj.lastAlphaEff <= 0 || abs(alphaVal - obj.lastAlphaEff) / obj.lastAlphaEff > 0.05
                dt = obj.DT;
                gs = (obj.GRID.W-2) * (obj.GRID.H-2);
                if ~isempty(alphaField)
                    [Lw, coupling] = obj.buildWeightedLaplacian(alphaField, false, obj.adiabaticObsIdx);
                    A_temp = obj.M_mass/dt - gs*Lw - alphaVal*gs*obj.E_obs;
                    obj.tempCoupling = coupling;  % 与 obsIdx 列对齐
                else
                    A_temp = obj.M_mass/dt - alphaVal * gs * obj.L_temp;
                    obj.tempCoupling = [];
                end
                obj.decomp_temp = decomposition(A_temp, 'ldl');
                obj.temp_diag_oi = 1/dt - alphaVal * gs;
                obj.lastAlphaEff = alphaVal;
            end

            gs    = (obj.GRID.W-2) * (obj.GRID.H-2);
            rhs_T = obj.M_mass/obj.DT * obj.T_fluid;

            % 冷壁 Dirichlet BC: T = 25°C（仅机箱壁；v2.7 起主板等内部件绝热）
            rhs_T(obj.wallObsIdx) = obj.temp_diag_oi * 25;

            % v2.7.1：散热器格（heatObsIdx）已并入绝热集（Neumann）——
            % 全功率高斯注入是唯一物理热源，不再钉扎 T_solid（消除双重热源）。
            % v2.7 计账修复：绝热障碍格（主板/隔板/散热器等）被 E_obs 钉扎行
            % 覆盖，若 RHS 不保值，解每步向 0 衰减、随后又被钳回 25，污染钳位
            % 计账。钉扎行 rhs=diag·T_old 使解≈T_old（每步保值，无扩散衰减）。
            if ~isempty(obj.adiabaticObsIdx)
                rhs_T(obj.adiabaticObsIdx) = obj.temp_diag_oi .* obj.T_fluid(obj.adiabaticObsIdx);
            end

            % 非齐次 Dirichlet 修正：恢复清零障碍列后损失的流体耦合项
            % A_full = M/dt − gs·L_w；A_full(fluid, obs) = −gs·L_w(fluid, obs)
            % 移项到 RHS：rhs ← rhs + gs·L_w(fluid,obs)·T_obs
            % 标量路径：L_w = α·K_lap；空间路径：tempCoupling 已含面加权 α
            % v2.5 修复：扩散符号反转后，correction 也由 −= 改为 +=
            % v2.5.1 修复：L_temp 不再做 adjCount 补偿（真 Dirichlet），并补上
            % 此前缺失的冷壁（T=25°C）修正项，否则机箱壁冷却对流体完全无效。
            % v2.7.1：散热器修正项随 Dirichlet 一并移除（绝热面无通量）。
            fluidMask = obj.obstacle == 0;
            if ~isempty(obj.tempCoupling)
                if ~isempty(obj.colWall)
                    correction = gs * obj.tempCoupling(:, obj.colWall) * 25;
                    rhs_T(fluidMask) = rhs_T(fluidMask) + correction(fluidMask);
                end
            else
                if ~isempty(obj.wallObsIdx)
                    correction = obj.lastAlphaEff * gs * obj.K_lap(:, obj.wallObsIdx) * 25;
                    rhs_T(fluidMask) = rhs_T(fluidMask) + correction(fluidMask);
                end
            end

            TpreSolve = obj.T_fluid;
            obj.T_fluid = obj.decomp_temp \ rhs_T;
            % v2.7 分项计账：扩散求解步能量增量（应≈Q_R_wall 的逐步积分）
            obj.accDiffuse = obj.accDiffuse + sum((obj.T_fluid - TpreSolve) .* fluidMask);
            % v3.3.0：扩散步机箱内区 ΣΔT（算子级 B2 计账）
            obj.accDiffuseCase = obj.accDiffuseCase + sum(obj.T_fluid(obj.insideMask) - TpreSolve(obj.insideMask));
            Tpre = obj.T_fluid;   % v2.7：钳位计账（能量计账见 fluidStep）
            obj.T_fluid = max(obj.T_fluid, 25);
            % v2.7 计账修复：只累计流体格的钳位量（障碍格 T 为显示/Dirichlet 值，
            % 其钳位不对应流体域能量）
            dCl = sum((obj.T_fluid - Tpre) .* fluidMask);
            obj.accClamp = obj.accClamp + dCl;
            obj.accClampSolve = obj.accClampSolve + dCl;   % v3.0.2 分项
            % v3.3.0：钳位点机箱内区 ΣΔT（算子级 B2；扩散后抬底）
            obj.accClampCase = obj.accClampCase + sum(obj.T_fluid(obj.insideMask) - Tpre(obj.insideMask));
        end

        function stepTurbulence(obj)
            % v2.10：k-ω 两方程湍流输运（Wilcox 2006 + SST 式应力限制器）
            %   ∂k/∂t + u·∇k = ∇·[(ν+σ_k·ν_t)∇k] + P_k − β*·k·ω
            %   ∂ω/∂t + u·∇ω = ∇·[(ν+σ_ω·ν_t)∇ω] + α·(ω/k)·P_k − β·ω²
            %   P_k = ν_t·S²，ν_t = a₁·k/max(a₁·ω, S)（限制器，a₁=0.31）
            % 数值方案：
            %   1) 半拉格朗日平流（advect fieldId 3/4，makima 保形插值，保正；
            %      回溯出域点取来流值，与 v2.9 温度入流边界同口径）
            %   2) 隐式扩散（面加权 Laplacian，矩阵按 ν_t 中位数 5% 触发重装配，
            %      与 diffuseVelocity 同机制；扩散强度沿用项目 gs 约定）
            %   3) 源项点wise 积分（冻结系数）：k 用解析解（产生+耗散平衡，
            %      保正且无条件稳定），ω 用半隐式（产生显式、耗散隐式线性化）
            %   4) 边界：障碍邻接流体格 ω 施 Menter 壁面公式 6ν/(β·y²)、
            %      k 施 Dirichlet k→0（k-ω 直接积分到壁面，无壁面函数）；
            %      远场海绵环重置来流值
            betaS = 0.09; beta1 = 0.0708; alphaW = 5/9; sigK = 0.6; sigW = 0.5;
            nu = obj.AIR.nu; dt = obj.DT;
            N = obj.GRID.TOTAL;
            gs = (obj.GRID.W-2) * (obj.GRID.H-2);
            [kIn, wIn] = obj.turbulenceInletValues();

            % 当前 ν_t 场（冻结系数，与 computeNuEff k-ω 路径同式同限幅）
            Svec = obj.computeStrainRateMag();   % [1/s]，W×H → 向量化
            Svec = Svec(:);
            a1 = 0.31;
            nuT = a1 * obj.turbK ./ max(a1 * obj.turbOmega, Svec);
            nuT = min(nuT, 2000 * nu);
            nuT(obj.obsIdx) = 0;

            % ---- 1) 平流 ----
            [uTurb, vTurb] = obj.getCellVelocity();   % v3.0：走 getter（面平均回格心）
            kA = obj.advect(3, obj.turbK, obj.turbK, uTurb, vTurb);
            wA = obj.advect(4, obj.turbOmega, obj.turbOmega, uTurb, vTurb);
            kA = max(kA, obj.nuTFloor);
            wA = max(wA, 1e-6);

            % ---- 2) 隐式扩散（冻结 ν_t，5% 中位数触发重装配）----
            nuTmed = median(nuT);
            if isempty(obj.decomp_turbK) || obj.lastNuTKMed <= 0 || ...
                    abs(nuTmed - obj.lastNuTKMed) / obj.lastNuTKMed > 0.05
                LwK = obj.buildWeightedLaplacian(nu + sigK * nuT, true);
                LwW = obj.buildWeightedLaplacian(nu + sigW * nuT, true);
                pinK = (nu + sigK * nuTmed) * gs;   % 障碍对角钉扎权重（仿 vel_diag_oi）
                pinW = (nu + sigW * nuTmed) * gs;
                obj.decomp_turbK = decomposition(obj.M_mass/dt - gs*LwK - pinK*obj.E_obs, 'ldl');
                obj.decomp_turbW = decomposition(obj.M_mass/dt - gs*LwW - pinW*obj.E_obs, 'ldl');
                obj.lastNuTKMed = nuTmed;
            end
            rhsK = obj.M_mass/dt * kA;  rhsK(obj.obsIdx) = 0;
            rhsW = obj.M_mass/dt * wA;  rhsW(obj.obsIdx) = 0;
            kD = obj.decomp_turbK \ rhsK;
            wD = obj.decomp_turbW \ rhsW;
            kD = max(kD, obj.nuTFloor);
            wD = max(wD, 1e-6);

            % ---- 3) 源项点wise 积分（冻结 P_k、ω 或 k）----
            Pk = nuT .* Svec.^2;                    % [m²/s³]
            % 生产限制器（Menter 式，v2.10.1 稳定性修复）：P ≤ 20·β*·k·ω。
            % 网格级剪切（S ~ U/Δx 达数千 1/s）下裸 P_k=ν_t·S² 会压垮耗散、
            % ω 崩溃形成正反馈（实测 k 100 步内飙到 2000，ν_t 钉死保险帽）。
            % 触发限制后 ω 产生项 α·(ω/k)·P 同步增强 → ω 回升 → ν_t=k/ω 回落，
            % 构成负反馈；k/ω 两方程共用同一限制后 P_k 保持模型一致性。
            Pk = min(Pk, 20 * betaS * kD .* max(wD, 1e-6));
            wFloor = max(wD, 1e-6);
            kEq = Pk ./ (betaS * wFloor);           % 局部产生-耗散平衡值
            kNew = kEq + (kD - kEq) .* exp(-betaS * wFloor * dt);
            wNew = (wD + dt * alphaW * (wD ./ kD) .* Pk) ./ (1 + dt * beta1 * wD);

            % ---- 4) 边界与钳位 ----
            kNew = max(kNew, obj.nuTFloor);
            wNew = min(max(wNew, 1e-6), 1e8);       % 1e8 仅为数值保险
            % 障碍格：钉扎小 k / 大 ω（仅显示用；平流与 ν_t 均不读取障碍格值）
            kNew(obj.obsIdx) = obj.nuTFloor;
            wNew(obj.obsIdx) = wIn;
            % 障碍邻接流体格：Menter 壁面边界 ω_wall = 6ν/(β₁·y²)。
            % k 的 Dirichlet 壁面条件 k_wall→0 只施在【机箱壁】邻接格
            % （v2.10.1 细化：曾施在全部障碍邻接格——散热器/主板邻接面
            % 积巨大把内部湍流整体抽干，ν_t 中位数跌回分子级、欠混合；
            % 只钉机箱壁则精准压制 Q_wall_case 虚高路径而不伤内部混合）。
            if isempty(obj.wallAdjFluidIdx)
                adj = full(sum(obj.K_lap(:, obj.obsIdx) ~= 0, 2));
                fm = true(N,1); fm(obj.obsIdx) = false;
                obj.wallAdjFluidIdx = find(adj > 0 & fm);
                % 机箱壁邻接流体格（k Dirichlet 子集）
                adjCase = full(sum(obj.K_lap(:, obj.wallObsIdx) ~= 0, 2));
                obj.wallAdjCaseIdx = find(adjCase > 0 & fm);
            end
            if ~isempty(obj.wallAdjFluidIdx)
                cellM = obj.GRID.cell_size_mm / 1000;
                if isempty(obj.wallDistanceM) || numel(obj.wallDistanceM) ~= N
                    yW = cellM * ones(numel(obj.wallAdjFluidIdx), 1);
                else
                    yW = max(obj.wallDistanceM(obj.wallAdjFluidIdx), 0.5 * cellM);
                end
                wNew(obj.wallAdjFluidIdx) = 6 * nu ./ (beta1 * yW.^2);
            end
            if ~isempty(obj.wallAdjCaseIdx)
                kNew(obj.wallAdjCaseIdx) = obj.nuTFloor;
            end
            % 远场海绵环：重置来流湍流值（吸收层语义，与速度阻尼/温度钉扎一致）
            if ~isempty(obj.spongeRingIdx)
                kNew(obj.spongeRingIdx) = kIn;
                wNew(obj.spongeRingIdx) = wIn;
            end

            obj.turbK = kNew;
            obj.turbOmega = wNew;
        end
        function fluidStep(obj)
            nuEff = obj.computeNuEff();

            obj.diffuseVelocity(nuEff);   % v3.0：面场隐式扩散
            obj.project();                % 面场投影
            obj.advectFaces();            % v3.0：面场半拉格朗日平流
            obj.applyBuoyancy();          % v3.0：Boussinesq 浮力作用于 v 面场

            % v2.8：压升模型后风扇力已物理导出，flowGain 闭环停用
            if ~obj.spongeDampPostProject
                % v2.9 对照口径：阻尼在投影前（v2.8 行为）
                obj.uF(obj.uFaceRing) = obj.uF(obj.uFaceRing) * obj.spongeDamping;
                obj.vF(obj.vFaceRing) = obj.vF(obj.vFaceRing) * obj.spongeDamping;
            end
            obj.applyFanForces();         % v3.0：动量源按面法向分解到面场
            obj.applyPorousDrag();        % v3.1.0：多孔区（CPU鳍片/GPU散热片）Darcy-Forchheimer 阻力
            obj.project();
            if obj.spongeDampPostProject
                % 远场海绵环速度阻尼移到投影之后（v2.9 口径：先投影后阻尼，
                % 避免阻尼破坏刚建立的压力-速度一致性）；v3.0 直接作用于面场
                obj.uF(obj.uFaceRing) = obj.uF(obj.uFaceRing) * obj.spongeDamping;
                obj.vF(obj.vFaceRing) = obj.vF(obj.vFaceRing) * obj.spongeDamping;
            end

            % v2.10：k-ω 湍流输运（用当步最终速度场；ν_eff 经 computeNuEff
            % 在下一步生效——一步滞后显式耦合，与冻结系数装配一致）
            if strcmp(obj.turbulenceModel, 'komega') && ...
                    mod(obj.iteration, obj.turbUpdateEvery) == 0
                obj.stepTurbulence();
            end

            obj.diffuseTemperature(nuEff / obj.AIR.Pr);  % v2.6：空间场 α(x)=ν(x)/Pr 逐格装配
            fluidOnly = double(obj.obstacle == 0);
            Tpre = obj.T_fluid;
            [uAdv, vAdv] = obj.getCellVelocity();   % v3.0：标量平流速度走 getter（面平均回格心）
            obj.T_fluid = obj.advect(0, obj.T_fluid, obj.T_fluid, uAdv, vAdv);
            % v2.7 分项计账：平流步能量增量（理想应≈开口边界通量，
            % 半拉格朗日复制/过冲漂移会在此处显形）
            obj.accAdvect = obj.accAdvect + sum((obj.T_fluid - Tpre) .* fluidOnly);
            % v3.3.0：平流步机箱内区 ΣΔT（算子级 B2；真值 ≈ −163.5W·accScale）
            obj.accAdvectCase = obj.accAdvectCase + sum(obj.T_fluid(obj.insideMask) - Tpre(obj.insideMask));
            % v2.7 能量计账：钳位与钉扎重置都是流体域的能源/能汇，
            % 逐步累计 ΣΔT [K·cell]，供 computeConservationCheck 换算成功率。
            % 计账修复：只累计流体格（障碍格 T 为显示/Dirichlet 值）。
            Tpre = obj.T_fluid;
            obj.T_fluid = max(obj.T_fluid, 25);
            dCl = sum((obj.T_fluid - Tpre) .* fluidOnly);
            obj.accClamp = obj.accClamp + dCl;
            obj.accClampAdvect = obj.accClampAdvect + dCl;   % v3.0.2 分项
            % v3.3.0：钳位点机箱内区 ΣΔT（算子级 B2；平流后抬底）
            obj.accClampCase = obj.accClampCase + sum(obj.T_fluid(obj.insideMask) - Tpre(obj.insideMask));
            % 机箱壁=冷（25°C Dirichlet）；散热器格仅显示 T_solid（v2.7.1 起
            % Neumann 绝热，不参与换热——高斯注入是唯一物理热源）。
            % 注意（v2.7）：障碍格重置差不计账——障碍格不是流体，其 T_fluid 仅作
            % 显示/Dirichlet 值；与流体的换热只经扩散路径（Q_wall 精确计量），
            % 平流路径已被 advect 的最近流体格替换切断。
            obj.T_fluid(obj.wallObsIdx) = 25;
            obj.T_fluid(obj.heatObsIdx) = obj.T_solid(obj.heatObsIdx);
            % v2.7：内部钉扎件（主板/隔板等）已 Neumann 绝热化、不参与温度求解，
            % 其 T_fluid 仅作显示用途，取邻近流体格均值（避免温度视图出现假冷块）
            if ~isempty(obj.adiabaticObsIdx)
                W = obj.GRID.W; H = obj.GRID.H;
                Tm = reshape(obj.T_fluid, W, H);
                fm = reshape(obj.obstacle == 0, W, H);
                nbrSum = [zeros(1,H); Tm(1:W-1,:).*fm(1:W-1,:)] + [Tm(2:W,:).*fm(2:W,:); zeros(1,H)] + ...
                         [zeros(W,1) Tm(:,1:H-1).*fm(:,1:H-1)] + [Tm(:,2:H).*fm(:,2:H) zeros(W,1)];
                nbrCnt = [zeros(1,H); fm(1:W-1,:)] + [fm(2:W,:); zeros(1,H)] + ...
                         [zeros(W,1) fm(:,1:H-1)] + [fm(:,2:H) zeros(W,1)];
                adiM = false(W,H); adiM(obj.adiabaticObsIdx) = true;
                hasN = adiM & nbrCnt > 0;
                Tm(hasN) = nbrSum(hasN) ./ nbrCnt(hasN);
                Tm(adiM & ~hasN) = 25;
                obj.T_fluid = Tm(:);
            end
            % 远场海绵环温度 Dirichlet：强制 25°C（无限大外部空气池，v2.8 起
            % 仅最外圈 1 格——外围其余区域已是真实空气，排气热可自由输运至远场）
            Tpre = obj.T_fluid;
            obj.T_fluid(obj.spongeRingIdx) = 25;
            obj.accResetOut = obj.accResetOut + sum(obj.T_fluid(obj.spongeRingIdx) - Tpre(obj.spongeRingIdx));

            obj.solveConjugateHeatTransfer();

            Tpre = obj.T_fluid;
            obj.T_fluid = min(obj.T_fluid, 200);
            dClCap = sum((obj.T_fluid - Tpre) .* fluidOnly);   % 削顶（汇）
            % v3.3.0：削顶机箱内区 ΣΔT（算子级 B2）
            obj.accClampCase = obj.accClampCase + sum(obj.T_fluid(obj.insideMask) - Tpre(obj.insideMask));
            Tpre = obj.T_fluid;
            obj.T_fluid = max(obj.T_fluid, 25);
            dClFloor = sum((obj.T_fluid - Tpre) .* fluidOnly); % 抬底（源）
            % v3.3.0：抬底机箱内区 ΣΔT（算子级 B2）
            obj.accClampCase = obj.accClampCase + sum(obj.T_fluid(obj.insideMask) - Tpre(obj.insideMask));
            obj.accClamp = obj.accClamp + dClCap + dClFloor;
            obj.accClampCap = obj.accClampCap + dClCap;        % v3.0.2 分项
            obj.accClampFloor = obj.accClampFloor + dClFloor;
            % 热注入可能触及远场格，再钉一次海绵环（同样计账）
            Tpre = obj.T_fluid;
            obj.T_fluid(obj.spongeRingIdx) = 25;
            obj.accResetOut = obj.accResetOut + sum(obj.T_fluid(obj.spongeRingIdx) - Tpre(obj.spongeRingIdx));
            obj.accSteps = obj.accSteps + 1;

            obj.iteration = obj.iteration + 1;
        end
    end
end
