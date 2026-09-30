classdef CFDSolverFEM < CFDSolverBase
    %CFDSOLVERFEM 时间推进实现：MAC 交错网格投影法 + 稀疏直接求解。
    %
    %   每步（fluidStep）：
    %     1. 速度隐式扩散（u/v 面各自 5 点 Laplacian，ν_eff 空间场）
    %     2. 投影（D·G 压力泊松，散度与梯度严格互为转置）
    %     3. 速度半拉格朗日平流（面心 cubic）
    %     4. 浮力 → 风扇动量源 → 阻力耦合投影（多孔区、格栅）→ 海绵环阻尼
    %     5. k-ω 湍流输运
    %     6. 温度隐式扩散 → 半拉格朗日平流（makima 保形）→ 边界 → 共轭传热注热
    %
    %   扩散算子系数 diffScale = 1/格距²（ν、α 为物理量 m²/s）。速度/温度/k-ω 扩散的稀疏分解
    %   每隔 reassembleEvery（5）步按当前系数场（ν_eff、α_eff、ν_t）重装一次（系数场与装配时逐位
    %   相同则不重装，如层流基准），重装时刻与数值无关，移植实现可逐步复现。过期的算子会造成假平台
    %   与伪振荡：v4.1 按全域中位数判断（280² 默认布局先停在假平台，约 850 步才跳变）；v4.2.0 按全域
    %   相对 L1 变化 5%（140² 前进顶出假平台后振荡）；v4.2.1 每 10 步（280² 底进顶出 GPU 伪振荡 ±0.1°C、
    %   偏 +0.46°C）。每 5 步时，已对照的 9 个算例中 8 个与每步重装（forceReassemble）的结温差 ≤ 0.15°C，
    %   280² 正压布局 GPU 低 0.48°C（第 600–1800 步停在低约 0.7°C 的假平台）。每步重装约慢 3 倍，
    %   作为可选的精确模式保留（forceReassemble = true）。

    properties
        K_lap           % 5 点差分 Laplacian（外圈缺失邻居计入对角，即伪 Dirichlet）
        M_mass          % 质量矩阵（单位阵）
        decomp_velU = []   % u 面隐式扩散 LHS 分解
        decomp_velV = []   % v 面隐式扩散 LHS 分解
        velU_actIdx = []   % u 面激活子矩阵行映射
        velV_actIdx = []   % v 面激活子矩阵行映射
        decomp_pres        % 压力泊松 LHS 分解（无阻力，第一次投影）
        pProj1 = []        % 本步第一次投影的压力（网格单位）；与 p 相加为本步总压力
        decomp_presDrag = []  % 阻力耦合压力算子分解（第二次投影）
        betaRefU = []      % 阻力耦合算子装配时的 u 面权重 β = 1/(1+C|u|)
        betaRefV = []
        betaRefStep = -inf % 上次重装阻力耦合算子的步数
        decomp_temp        % 温度扩散 LHS 分解
        presRefIdx = []    % 压力参考点：不与远场连通的每个流体连通域各钉一格（消奇异）
        farFieldPresIdx = []  % 远场海绵环格（压力 p=0）
        temp_diag_oi    % 温度 LHS 在障碍格的对角值（障碍行 RHS 保值用）
        L_temp          % 温度 Laplacian（标量 α 路径；定温壁真 Dirichlet，其余障碍绝热）
        E_obs           % 障碍格对角选择矩阵
        edgeMissing     % 每格越出计算域的邻居数（外圈 ghost，温度取环境值）
        colDir          % dirichletIdx 在 obsIdx 中的列号
        tempCoupling = []   % 空间 α 场时：流体×障碍耦合块（Dirichlet RHS 修正用）
        lastNuEff = 0       % 上次速度扩散装配时的 ν_eff 中位数（仅记录）
        nuFieldStep = []    % 本步的 ν_eff 场（≥ 分子粘度；数据集导出用）
        nuFieldAssembled = []  % 当前速度扩散算子装配时所用的 ν_eff 场
        alphaFieldAssembled = []  % 当前温度扩散算子装配时所用的 α_eff 场
        nuTAssembled = []      % 当前 k-ω 扩散算子装配时所用的 ν_t 场
        reassembleEvery = 5    % 扩散算子（速度/温度/k-ω）每隔多少步重装
        nuAsmStep = -inf       % 各算子上次装配时的 iteration
        alphaAsmStep = -inf
        nuTAsmStep = -inf
        forceReassemble = false  % 诊断：每步重装全部冻结算子（含阻力耦合压力算子）
        lastAlphaEff = 0    % 上次温度扩散装配时的 α_eff 中位数（标量 α 路径的判据与边界项）
        lastAlphaField = [] % 本步温度扩散使用的 α 场（守恒校核用）
        % k-ω 输运缓存
        decomp_turbK = []
        decomp_turbW = []
        lastTurbDt = 0      % k-ω 矩阵装配时的推进时长（子循环步数变化时重装）
        wallAdjFluidIdx = []  % 障碍邻接流体格（ω 壁面边界）
        wallAdjCaseIdx = []   % 机箱壁邻接流体格（k 壁面边界）
    end

    methods
        function obj = CFDSolverFEM(cpuPower, gpuPower, psuPower, layout, gridScale, dtVal)
            if nargin < 1, cpuPower  = []; end
            if nargin < 2, gpuPower  = []; end
            if nargin < 3, psuPower  = []; end
            if nargin < 4, layout = []; end
            if nargin < 5, gridScale = []; end
            if nargin < 6, dtVal = []; end
            obj@CFDSolverBase(cpuPower, gpuPower, psuPower, layout, gridScale, dtVal);
            obj.assembleSparseMatrices();
        end

        function reset(obj)
            obj.K_lap = [];               % 让 buildModel 期间跳过压力重装
            obj.pProj1 = [];
            reset@CFDSolverBase(obj);
            obj.wallAdjFluidIdx = [];
            obj.wallAdjCaseIdx = [];
            obj.lastAlphaField = [];
            obj.assembleSparseMatrices();
        end

        function initFields(obj)
            initFields@CFDSolverBase(obj);
            obj.decomp_turbK = []; obj.decomp_turbW = [];
            obj.decomp_velU = []; obj.decomp_velV = [];
            obj.velU_actIdx = []; obj.velV_actIdx = [];
            obj.lastNuEff = 0;
            obj.nuFieldAssembled = []; obj.alphaFieldAssembled = []; obj.nuTAssembled = [];
            obj.nuAsmStep = -inf; obj.alphaAsmStep = -inf; obj.nuTAsmStep = -inf;
        end

        % ================================================================
        % 矩阵装配
        % ================================================================
        function assembleSparseMatrices(obj)
            W  = obj.GRID.W;
            H  = obj.GRID.H;
            N  = W * H;
            dt = obj.DT;
            nu = obj.AIR.nu;

            % 5 点差分 Laplacian（Dx = [+1 −2 +1]，L = +∇²，对角为负）
            e  = ones(W,1);
            Dx = spdiags([e -2*e e], [-1 0 1], W, W);
            e  = ones(H,1);
            Dy = spdiags([e -2*e e], [-1 0 1], H, H);
            L  = kron(speye(H), Dx) + kron(Dy, speye(W));
            gs = obj.diffScale;

            obj.M_mass = speye(N);
            obj.K_lap  = L;
            yy = mod((1:N)'-1, W) + 1;  xx = ceil((1:N)'/W);
            obj.edgeMissing = 4 - ((yy>1) + (yy<W) + (xx>1) + (xx<H));

            oi = obj.obsIdx;
            obj.E_obs = sparse(oi, oi, ones(length(oi),1), N, N);
            [~, obj.colDir] = ismember(obj.dirichletIdx, oi);
            obj.tempCoupling = [];

            % 速度扩散矩阵在首次 diffuseVelocity 时按面场懒装配
            obj.lastNuEff = 0;

            obj.assemblePressureMatrix();

            % 温度扩散（隐式，LHS = M/dt − α·gs·L_temp）：障碍行列清零后置 1；
            % 定温壁为 Dirichlet（耦合项在 RHS 恢复），其余障碍绝热（面权重回补流体对角）
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
            % 障碍（钉扎）行对角取 1/dt（行列已解耦，取正值避免矩阵不定/奇异）
            A_temp = obj.M_mass/dt - alpha * gs * Ltemp + alpha * gs * obj.E_obs;
            obj.decomp_temp  = decomposition(A_temp, 'ldl');
            obj.temp_diag_oi = 1/dt;
            obj.lastAlphaEff = alpha;
        end

        function assemblePressureMatrix(obj)
            % 无阻力压力算子（第一次投影用）与阻力耦合算子的初始参考
            W = obj.GRID.W; H = obj.GRID.H;
            obj.farFieldPresIdx = setdiff(obj.spongeRingIdx, obj.obsIdx);
            obj.presRefIdx = obj.isolatedFluidRefs();
            obj.decomp_pres = obj.buildPressureOperator(ones(W, H+1), ones(W+1, H));
            obj.betaRefU = [];
            obj.betaRefV = [];
            obj.betaRefStep = -inf;
            obj.decomp_presDrag = [];
        end

        function refs = isolatedFluidRefs(obj)
            % 不与远场海绵环连通的流体连通域（如封闭方腔）各取一格作压力参考
            W = obj.GRID.W; H = obj.GRID.H;
            fM = reshape(obj.obstacle == 0, W, H);
            lab = inf(W, H);
            lab(fM) = find(fM);
            while true
                nb = lab;
                nb(2:W,:)   = min(nb(2:W,:),   lab(1:W-1,:));
                nb(1:W-1,:) = min(nb(1:W-1,:), lab(2:W,:));
                nb(:,2:H)   = min(nb(:,2:H),   lab(:,1:H-1));
                nb(:,1:H-1) = min(nb(:,1:H-1), lab(:,2:H));
                nb(~fM) = inf;
                if isequal(nb, lab), break; end
                lab = nb;
            end
            comps = unique(lab(fM));
            ringComps = unique(lab(obj.farFieldPresIdx));
            refs = setdiff(comps, ringComps);
            refs = refs(:);
        end

        function dec = buildPressureOperator(obj, wU, wV)
            % 压力泊松 LHS = D·diag(w)·G：按格间激活面装配，面权重 w（无阻力时为 1）。
            % 贴障碍面不参与（天然 Neumann，无穿透）；远场海绵环 p=0；
            % 不与远场连通的流体连通域各钉一个参考点消奇异。
            W = obj.GRID.W; H = obj.GRID.H; N = W * H;
            uAct = reshape(obj.uFaceActive, W, H+1);
            vAct = reshape(obj.vFaceActive, W+1, H);
            [yu, xf] = find(uAct(:, 2:H)); xf = xf + 1;         % 格间 u 面
            cu1 = (xf-2)*W + yu; cu2 = (xf-1)*W + yu;
            wu = wU(sub2ind([W H+1], yu, xf));
            [yf, xv] = find(vAct(2:W, :)); yf = yf + 1;         % 格间 v 面
            cv1 = (xv-1)*W + yf - 1; cv2 = (xv-1)*W + yf;
            wv = wV(sub2ind([W+1 H], yf, xv));
            I = [cu1; cu2; cu1; cu2; cv1; cv2; cv1; cv2];
            J = [cu2; cu1; cu1; cu2; cv2; cv1; cv1; cv2];
            V = [wu; wu; -wu; -wu; wv; wv; -wv; -wv];
            Lp = sparse(I, J, V, N, N);
            % 钉扎格行列清零、对角置 −1，保持对称负定：分解 −Lp（Cholesky），
            % 求解时 p = dec \ (−rhs)
            pin = [obj.obsIdx; obj.farFieldPresIdx; obj.presRefIdx];
            Lp(pin, :) = 0; Lp(:, pin) = 0;
            Lp = Lp - sparse(pin, pin, ones(numel(pin),1), N, N);
            dec = decomposition(-Lp, 'chol');
        end

        function onOpeningsChanged(obj)
            % 开口变化后重装压力矩阵（构造期间 K_lap 尚未建立，跳过）
            if isempty(obj.K_lap)
                return;
            end
            obj.assemblePressureMatrix();
        end

        function [Lw, coupling] = buildWeightedLaplacian(obj, wField, preserveConstant, adiIdx)
            % 面加权 Laplacian（空间变化 ν/α 用）：off-diag = (w_i+w_j)/2，diag = −Σ面权重；
            % 外圈缺失邻居的面权重补回对角（与 K_lap 同为伪 Dirichlet）。
            %   preserveConstant=true（速度/湍流）：障碍面权重加回流体对角（L·1≈0），障碍行列清零。
            %   preserveConstant=false（温度）：障碍行列真清零（Dirichlet），coupling 返回
            %     清零前的 流体×障碍 耦合块供 RHS 修正；adiIdx（绝热件）面权重回补流体对角。
            if nargin < 4, adiIdx = []; end
            N = obj.GRID.TOTAL;
            [I, J, ~] = find(obj.K_lap);
            off = I ~= J;
            Io = I(off); Jo = J(off);
            wij = 0.5*(wField(Io) + wField(Jo));
            Lfull = sparse(Io, Jo, wij, N, N);
            Lfull = Lfull + spdiags(-full(sum(Lfull, 2)), 0, N, N);
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
                if ~isempty(adiIdx)
                    adjAdi = full(sum(Lfull(:, adiIdx), 2));
                    adjAdi(oi) = 0;
                    Lfull = Lfull + spdiags(adjAdi, 0, N, N);
                end
                Lfull(oi,:) = 0; Lfull(:,oi) = 0;
            end
            Lw = Lfull;
        end

        % ================================================================
        % 速度
        % ================================================================
        function diffuseVelocity(obj, nuEff)
            % 面场隐式扩散：u/v 面各自点阵 5 点 Laplacian（面粘性 = 两邻格 ν_eff 平均），
            % 未激活面钉 0（Dirichlet-0 链接 = 精确位于壁面的无滑移）。
            if nargin < 2 || isempty(nuEff)
                nuEff = obj.AIR.nu;
            end
            if numel(nuEff) > 1
                nuField = max(nuEff(:), obj.AIR.nu);
                nuVal = median(nuField);
            else
                nuVal = max(nuEff, obj.AIR.nu);
                nuField = ones(obj.GRID.TOTAL, 1) * nuVal;
            end

            obj.nuFieldStep = nuField;
            if obj.forceReassemble || isempty(obj.nuFieldAssembled) || ...
                    (obj.iteration - obj.nuAsmStep >= obj.reassembleEvery && ~isequal(nuField, obj.nuFieldAssembled))
                dt = obj.DT;
                gs = obj.diffScale;
                [obj.decomp_velU, obj.velU_actIdx] = obj.assembleFaceDiffusion(nuField, true,  dt, gs);
                [obj.decomp_velV, obj.velV_actIdx] = obj.assembleFaceDiffusion(nuField, false, dt, gs);
                obj.lastNuEff = nuVal;
                obj.nuFieldAssembled = nuField;
                obj.nuAsmStep = obj.iteration;
            end

            obj.uF(~obj.uFaceActive) = 0;
            obj.vF(~obj.vFaceActive) = 0;
            au = obj.velU_actIdx;
            obj.uF(au) = obj.decomp_velU \ (obj.uF(au) / obj.DT);
            av = obj.velV_actIdx;
            obj.vF(av) = obj.decomp_velV \ (obj.vF(av) / obj.DT);
        end

        function [dec, actIdx] = assembleFaceDiffusion(obj, nuField, isU, dt, gs)
            % 面点阵隐式扩散 LHS（仅激活面子矩阵）：A = I/dt − gs·L_face。
            % 激活邻居：off-diag = 0.5(w_f+w_g)；未激活邻居与越界方向以 w_f 计入对角。
            W = obj.GRID.W; H = obj.GRID.H;
            nuM = reshape(nuField, W, H);
            if isU
                wM = zeros(W, H+1);
                wM(:, 2:H) = 0.5*(nuM(:,1:H-1) + nuM(:,2:H));
                wM(:, 1)   = nuM(:,1);
                wM(:, H+1) = nuM(:,H);
                actM = reshape(obj.uFaceActive, W, H+1);
                nR = W; nC = H+1;
            else
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
                diagAcc(~inB) = diagAcc(~inB) - wF(~inB);
                g = af(inB) + off;
                actG = actL(g);
                wFs = wF(inB);
                diagAccSub = zeros(numel(wFs), 1);
                diagAccSub(:) = wFs;
                diagAccSub(actG) = 0.5*(wFs(actG) + wM(g(actG)));
                diagAcc(inB) = diagAcc(inB) - diagAccSub;
                if any(actG)
                    Io = [Io; af(inB)];    %#ok<AGROW>
                    Jo = [Jo; g];          %#ok<AGROW>
                    Vo = [Vo; diagAccSub]; %#ok<AGROW>
                end
            end
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
            % 单次满修正投影；速度上限 6 m/s（物理）
            vel_cap = 6.0 / obj.VEL_SCALE;
            obj.projectPass(1.0, vel_cap);
        end

        function clipped = projectPass(obj, omega, velCap)
            % 面场散度 → 泊松求解 → 面梯度修正（与 D·G 装配为同一算子）
            W = obj.GRID.W; H = obj.GRID.H;
            uM = reshape(obj.uF, W, H+1);
            vM = reshape(obj.vF, W+1, H);
            uActM = reshape(obj.uFaceActive, W, H+1);
            vActM = reshape(obj.vFaceActive, W+1, H);

            div = uM(:,2:H+1).*uActM(:,2:H+1) - uM(:,1:H).*uActM(:,1:H) ...
                + vM(2:W+1,:).*vActM(2:W+1,:) - vM(1:W,:).*vActM(1:W,:);
            rhs_p = div(:);
            rhs_p(obj.obsIdx) = 0;
            rhs_p(obj.farFieldPresIdx) = 0;
            rhs_p(obj.presRefIdx) = 0;

            obj.p = obj.decomp_pres \ (-rhs_p);
            obj.p(obj.obsIdx) = 0;
            obj.p(obj.farFieldPresIdx) = 0;
            obj.pProj1 = obj.p;

            pM = reshape(obj.p, W, H);
            % 只修正格间激活面；域边界面邻接 p=0 的环格，由海绵阻尼吸收
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

        function projectWithDrag(obj, uRef, vRef)
            % 阻力与压力耦合的投影（多孔区、开口格栅）：
            %   u^{n+1} = β·(u* − G p)，β = 1/(1 + C|u_ref|)，D(β G p) = D(β u*)。
            % u_ref 取施加风扇体积力之前的速度（fluidStep 传入）：风扇盘端面与格栅面/
            % 多孔区端面重合时，u* 含风扇单步冲量（满速约 7 m/s/步），用它算 β 会把
            % 阻力放大数倍。稳态下 u_ref ≈ u^{n+1}，每面阻力近似为 C|u|u（ζ·½ρv²）。
            % 算子按参考 β 装配（保证散度严格为零）。重装判据按两组分别统计（多孔区面、
            % 开口格栅面，只计流体活动面）：任一组 β 相对偏差均值超过 3% 或偏差超过
            % 10% 的面多于 2% 时重装（两次重装至少间隔 5 步）。
            W = obj.GRID.W; H = obj.GRID.H;
            uM = reshape(obj.uF, W, H+1);
            vM = reshape(obj.vF, W+1, H);
            if nargin < 3, uRef = obj.uF; vRef = obj.vF; end
            uActM = reshape(obj.uFaceActive, W, H+1);
            vActM = reshape(obj.vFaceActive, W+1, H);
            bU = 1 ./ (1 + reshape(obj.uDragCoef .* abs(uRef), W, H+1));
            bV = 1 ./ (1 + reshape(obj.vDragCoef .* abs(vRef), W+1, H));
            rebuild = isempty(obj.decomp_presDrag) || obj.forceReassemble;
            if ~rebuild && obj.iteration - obj.betaRefStep >= 5
                actU = obj.uDragCoef > 0 & obj.uFaceActive;
                actV = obj.vDragCoef > 0 & obj.vFaceActive;
                relU = abs(bU(:) - obj.betaRefU(:)) ./ obj.betaRefU(:);
                relV = abs(bV(:) - obj.betaRefV(:)) ./ obj.betaRefV(:);
                grpU = {actU & ~obj.uGrilleFace, actU & obj.uGrilleFace};
                grpV = {actV & ~obj.vGrilleFace, actV & obj.vGrilleFace};
                for g = 1:2
                    rel = [relU(grpU{g}); relV(grpV{g})];
                    if ~isempty(rel) && (mean(rel) > 0.03 || mean(rel > 0.10) > 0.02)
                        rebuild = true;
                    end
                end
            end
            if rebuild
                obj.betaRefU = bU;
                obj.betaRefV = bV;
                obj.betaRefStep = obj.iteration;
                obj.decomp_presDrag = obj.buildPressureOperator(bU, bV);
            end
            bU = obj.betaRefU; bV = obj.betaRefV;
            us = uM .* bU .* uActM;
            vs = vM .* bV .* vActM;
            div = us(:,2:H+1) - us(:,1:H) + vs(2:W+1,:) - vs(1:W,:);
            rhs_p = div(:);
            rhs_p(obj.obsIdx) = 0;
            rhs_p(obj.farFieldPresIdx) = 0;
            rhs_p(obj.presRefIdx) = 0;
            obj.p = obj.decomp_presDrag \ (-rhs_p);
            obj.p(obj.obsIdx) = 0;
            obj.p(obj.farFieldPresIdx) = 0;
            pM = reshape(obj.p, W, H);
            dpU = zeros(W, H+1);
            dpU(:, 2:H) = pM(:, 2:H) - pM(:, 1:H-1);
            dpV = zeros(W+1, H);
            dpV(2:W, :) = pM(2:W, :) - pM(1:W-1, :);
            % 格间面：β(u* − Gp)；域边界面无梯度修正，只施阻力
            uM = us - bU .* dpU .* uActM;
            vM = vs - bV .* dpV .* vActM;
            uM(~uActM) = 0;
            vM(~vActM) = 0;
            velCap = 6.0 / obj.VEL_SCALE;
            obj.uF = reshape(max(-velCap, min(velCap, uM)), [], 1);
            obj.vF = reshape(max(-velCap, min(velCap, vM)), [], 1);
        end

        function advectFaces(obj)
            % 面场半拉格朗日平流（cubic）。回溯速度：u 面取本地 u + 环绕四个 v 面平均，
            % v 面对称。插值器第 1 维为 y，查询为 (y 回溯, x 回溯)。
            W = obj.GRID.W; H = obj.GRID.H;
            dt0 = obj.DT * (W-2);
            uM = reshape(obj.uF, W, H+1);
            vM = reshape(obj.vF, W+1, H);

            yUp = [2:W W];
            vAtU = zeros(W, H+1);
            vAtU(:, 2:H) = 0.25*(vM(1:W, 1:H-1) + vM(yUp, 1:H-1) + ...
                                 vM(1:W, 2:H)   + vM(yUp, 2:H));
            vAtU(:, 1)   = 0.5*(vM(1:W,1) + vM(yUp,1));
            vAtU(:, H+1) = 0.5*(vM(1:W,H) + vM(yUp,H));
            [YuG, XuG] = ndgrid(1:W, 0.5:H+0.5);
            XqU = XuG - dt0 * uM;
            YqU = YuG - dt0 * vAtU;
            XqU = max(1.0, min(H, XqU));
            YqU = max(1.5, min(W-0.5, YqU));
            uNew = grid_interp2(uM, YqU, XqU, 'cubic', 1, 0.5);     % u 面位于 (y, xf − 0.5)
            uAtV = zeros(W+1, H);
            uAtV(2:W, :) = 0.25*(uM(1:W-1, 1:H) + uM(1:W-1, 2:H+1) + ...
                                 uM(2:W,   1:H) + uM(2:W,   2:H+1));
            uAtV(1, :)   = 0.5*(uM(1,1:H) + uM(1,2:H+1));
            uAtV(W+1, :) = 0.5*(uM(W,1:H) + uM(W,2:H+1));
            [YvG, XvG] = ndgrid(0.5:W+0.5, 1:H);
            XqV = XvG - dt0 * uAtV;
            YqV = YvG - dt0 * vM;
            XqV = max(1.5, min(H-0.5, XqV));
            YqV = max(1.0, min(W, YqV));
            vNew = grid_interp2(vM, YqV, XqV, 'cubic', 0.5, 1);     % v 面位于 (yf − 0.5, x)

            uNew(~reshape(obj.uFaceActive, W, H+1)) = 0;
            vNew(~reshape(obj.vFaceActive, W+1, H)) = 0;
            obj.uF = uNew(:);
            obj.vF = vNew(:);
        end

        % ================================================================
        % 标量（温度、k、ω）
        % ================================================================
        function d = advectScalar(obj, d0, uvel, vvel, inflowValue, dt)
            % 格心标量半拉格朗日平流（makima）。回溯点出域时取来流值 inflowValue；
            % 障碍格值先替换为最近流体格值，避免插值从固体带入/带走不可计量的量。
            % dt 缺省为 DT（湍流子循环时传入实际推进时长）。
            if nargin < 6, dt = obj.DT; end
            W   = obj.GRID.W; H = obj.GRID.H;
            dt0 = dt * (W-2);

            umat = reshape(uvel, W, H);
            vmat = reshape(vvel, W, H);
            [Igrid, Jgrid] = meshgrid(1:W, 1:H);

            Xq = Jgrid' - dt0 * umat;
            Yq = Igrid' - dt0 * vmat;
            outDomain = (Xq < 1.5) | (Xq > W-0.5) | (Yq < 1.5) | (Yq > H-0.5);
            Xq = max(1.5, min(W-0.5, Xq));
            Yq = max(1.5, min(H-0.5, Yq));

            d0mat = reshape(d0, W, H);
            if ~isempty(obj.nearestFluidIdx)
                obsM = reshape(obj.obstacle > 0, W, H);
                d0mat(obsM) = d0mat(obj.nearestFluidIdx(obsM));
            end
            dmat = grid_interp2(d0mat, Yq, Xq, 'makima', 1, 1);
            dmat(outDomain) = inflowValue;
            d = dmat(:);
        end

        function diffuseTemperature(obj, alphaEff)
            % 温度隐式扩散。α 为空间场时用面加权 Laplacian 装配，每隔 reassembleEvery 步按当前
            % α_eff 场重装（与装配时逐位相同则不重装）；边界 RHS 用装配时的 α 场（与矩阵一致）。
            % 定温壁 Dirichlet，其余障碍绝热。
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
            if isempty(alphaField)
                stale = obj.lastAlphaEff <= 0 || abs(alphaVal - obj.lastAlphaEff) / obj.lastAlphaEff > 0.05 || ...
                        ~isempty(obj.alphaFieldAssembled);
            else
                stale = isempty(obj.alphaFieldAssembled) || ...
                        (obj.iteration - obj.alphaAsmStep >= obj.reassembleEvery && ...
                         ~isequal(alphaField, obj.alphaFieldAssembled));
            end
            if obj.forceReassemble || stale
                dt = obj.DT;
                gs = obj.diffScale;
                if ~isempty(alphaField)
                    [Lw, coupling] = obj.buildWeightedLaplacian(alphaField, false, obj.adiabaticObsIdx);
                    A_temp = obj.M_mass/dt - gs*Lw;       % 钉扎行对角 = 1/dt
                    obj.tempCoupling = coupling;
                    obj.alphaFieldAssembled = alphaField;
                    obj.alphaAsmStep = obj.iteration;
                else
                    A_temp = obj.M_mass/dt - alphaVal * gs * obj.L_temp + alphaVal * gs * obj.E_obs;
                    obj.tempCoupling = [];
                    obj.alphaFieldAssembled = [];
                end
                obj.decomp_temp = decomposition(A_temp, 'ldl');
                obj.temp_diag_oi = 1/dt;
                obj.lastAlphaEff = alphaVal;
            end

            % 守恒校核用：本步实际使用的 α 场（冻结矩阵装配时的场）
            if ~isempty(obj.alphaFieldAssembled)
                obj.lastAlphaField = obj.alphaFieldAssembled;
            else
                obj.lastAlphaField = obj.lastAlphaEff * ones(size(obj.T_fluid));
            end

            gs    = obj.diffScale;
            rhs_T = obj.M_mass/obj.DT * obj.T_fluid;

            % 定温壁 Dirichlet；绝热障碍格被钉扎行覆盖，RHS 取 diag·T_old 保值
            rhs_T(obj.dirichletIdx) = obj.temp_diag_oi * obj.dirichletT;
            if ~isempty(obj.adiabaticObsIdx)
                rhs_T(obj.adiabaticObsIdx) = obj.temp_diag_oi .* obj.T_fluid(obj.adiabaticObsIdx);
            end

            % 非齐次 Dirichlet 修正：恢复清零障碍列后流体丢失的壁面耦合项；
            % 计算域外圈 ghost 取环境温度（远场）
            fluidMask = obj.obstacle == 0;
            if ~isempty(obj.alphaFieldAssembled)
                edgeW = obj.alphaFieldAssembled;   % 与冻结的矩阵同一 α 场
            else
                edgeW = obj.lastAlphaEff * ones(obj.GRID.TOTAL, 1);
            end
            edge = gs * obj.edgeMissing .* edgeW * obj.T_amb;
            rhs_T(fluidMask) = rhs_T(fluidMask) + edge(fluidMask);
            if ~isempty(obj.tempCoupling)
                if ~isempty(obj.colDir)
                    correction = gs * obj.tempCoupling(:, obj.colDir) * obj.dirichletT;
                    rhs_T(fluidMask) = rhs_T(fluidMask) + correction(fluidMask);
                end
            else
                if ~isempty(obj.dirichletIdx)
                    correction = obj.lastAlphaEff * gs * obj.K_lap(:, obj.dirichletIdx) * obj.dirichletT;
                    rhs_T(fluidMask) = rhs_T(fluidMask) + correction(fluidMask);
                end
            end

            TpreSolve = obj.T_fluid;
            obj.T_fluid = obj.decomp_temp \ rhs_T;
            obj.accDiffuse = obj.accDiffuse + sum((obj.T_fluid - TpreSolve) .* fluidMask);
            obj.accDiffuseCase = obj.accDiffuseCase + sum(obj.T_fluid(obj.insideMask) - TpreSolve(obj.insideMask));
            Tpre = obj.T_fluid;
            obj.T_fluid = max(obj.T_fluid, obj.T_amb);
            dCl = sum((obj.T_fluid - Tpre) .* fluidMask);
            obj.accClamp = obj.accClamp + dCl;
            obj.accClampSolve = obj.accClampSolve + dCl;
            obj.accClampCase = obj.accClampCase + sum(obj.T_fluid(obj.insideMask) - Tpre(obj.insideMask));
        end

        function stepTurbulence(obj, Svec)
            % k-ω 两方程（Wilcox 2006 + SST 式应力限制器）：
            %   ∂k/∂t + u·∇k = ∇·[(ν+σ_k·ν_t)∇k] + P_k − β*·k·ω
            %   ∂ω/∂t + u·∇ω = ∇·[(ν+σ_ω·ν_t)∇ω] + α·(ω/k)·P_k − β·ω²
            %   ν_t = a₁·k/max(a₁·ω, |S|)，P_k = min(ν_t·|S|², 20·β*·k·ω)（生产限制器）
            % 数值：半拉格朗日平流 → 隐式扩散（冻结 ν_t）→ 源项点积分
            % （k 产生-耗散平衡解析解，ω 半隐式）→ 边界：障碍邻接格 ω = 6ν/(β₁y²)，
            % 机箱壁邻接格 k → 0，远场环取来流值。
            betaS = 0.09; beta1 = 0.0708; alphaW = 5/9; sigK = 0.6; sigW = 0.5;
            % 每 turbUpdateEvery 步更新一次，推进时长相应放大
            nu = obj.AIR.nu; dt = obj.DT * obj.turbUpdateEvery;
            N = obj.GRID.TOTAL;
            gs = obj.diffScale;
            [kIn, wIn] = obj.turbulenceInletValues();

            if nargin < 2
                Svec = obj.computeStrainRateMag();
            end
            Svec = Svec(:);
            a1 = 0.31;
            nuT = a1 * obj.turbK ./ max(a1 * obj.turbOmega, Svec);
            nuT = min(nuT, 2000 * nu);
            nuT(obj.obsIdx) = 0;

            % 1) 平流
            [uTurb, vTurb] = obj.getCellVelocity();
            kA = obj.advectScalar(obj.turbK, uTurb, vTurb, kIn, dt);
            wA = obj.advectScalar(obj.turbOmega, uTurb, vTurb, wIn, dt);
            kA = max(kA, obj.nuTFloor);
            wA = max(wA, 1e-6);

            % 2) 隐式扩散（距上次装配 ≥ reassembleEvery 步或推进时长变化时按当前 ν_t 重装）
            if obj.forceReassemble || isempty(obj.decomp_turbK) || obj.lastTurbDt ~= dt || ...
                    (obj.iteration - obj.nuTAsmStep >= obj.reassembleEvery && ~isequal(nuT, obj.nuTAssembled))
                LwK = obj.buildWeightedLaplacian(nu + sigK * nuT, true);
                LwW = obj.buildWeightedLaplacian(nu + sigW * nuT, true);
                % 障碍行列已由 buildWeightedLaplacian 清零，钉扎行对角 = 1/dt（RHS 为 0）
                obj.decomp_turbK = decomposition(obj.M_mass/dt - gs*LwK, 'ldl');
                obj.decomp_turbW = decomposition(obj.M_mass/dt - gs*LwW, 'ldl');
                obj.nuTAssembled = nuT;
                obj.nuTAsmStep = obj.iteration;
                obj.lastTurbDt = dt;
            end
            rhsK = obj.M_mass/dt * kA;  rhsK(obj.obsIdx) = 0;
            rhsW = obj.M_mass/dt * wA;  rhsW(obj.obsIdx) = 0;
            kD = obj.decomp_turbK \ rhsK;
            wD = obj.decomp_turbW \ rhsW;
            kD = max(kD, obj.nuTFloor);
            wD = max(wD, 1e-6);

            % 3) 源项
            Pk = nuT .* Svec.^2;
            Pk = min(Pk, 20 * betaS * kD .* max(wD, 1e-6));
            wFloor = max(wD, 1e-6);
            kEq = Pk ./ (betaS * wFloor);
            kNew = kEq + (kD - kEq) .* exp(-betaS * wFloor * dt);
            wNew = (wD + dt * alphaW * (wD ./ kD) .* Pk) ./ (1 + dt * beta1 * wD);

            % 4) 边界与钳位
            kNew = max(kNew, obj.nuTFloor);
            wNew = min(max(wNew, 1e-6), 1e8);
            kNew(obj.obsIdx) = obj.nuTFloor;
            wNew(obj.obsIdx) = wIn;
            if isempty(obj.wallAdjFluidIdx)
                adj = full(sum(obj.K_lap(:, obj.obsIdx) ~= 0, 2));
                fm = true(N,1); fm(obj.obsIdx) = false;
                obj.wallAdjFluidIdx = find(adj > 0 & fm);
                adjCase = full(sum(obj.K_lap(:, obj.caseWallIdx) ~= 0, 2));
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
            if ~isempty(obj.spongeRingIdx)
                kNew(obj.spongeRingIdx) = kIn;
                wNew(obj.spongeRingIdx) = wIn;
            end

            obj.turbK = kNew;
            obj.turbOmega = wNew;
        end

        % ================================================================
        % 单步推进
        % ================================================================
        function fluidStep(obj)
            % 应变率场每步只算一次，粘性与湍流生产共用
            if strcmp(obj.turbulenceModel, 'laminar')
                S = [];
                nuEff = obj.computeNuEff();
            else
                [S, Vloc, yW] = obj.computeStrainRateMag();
                nuEff = obj.computeNuEff(S, Vloc, yW);
            end

            % ---- 动量 ----
            obj.diffuseVelocity(nuEff);
            obj.project();
            obj.advectFaces();
            obj.applyBuoyancy();
            uRef = obj.uF; vRef = obj.vF;          % 阻力 β 用施加风扇力之前的速度
            obj.applyFanForces();
            obj.projectWithDrag(uRef, vRef);       % 多孔区/格栅阻力与压力耦合投影
            % 远场海绵环速度阻尼（投影之后施加，不破坏刚建立的压力-速度一致性）
            obj.uF(obj.uFaceRing) = obj.uF(obj.uFaceRing) * obj.spongeDamping;
            obj.vF(obj.vFaceRing) = obj.vF(obj.vFaceRing) * obj.spongeDamping;

            % ---- 湍流（生产项用本步开始时的应变率 S，即动量更新前的速度，滞后一步；
            %      对稳态无影响，瞬态中 k 局部差异 ≲15%、结温 ≲0.2°C；ν_eff 下一步生效）----
            if strcmp(obj.turbulenceModel, 'komega') && ...
                    mod(obj.iteration, obj.turbUpdateEvery) == 0
                obj.stepTurbulence(S);
            end

            % ---- 温度：扩散 → 平流 → 边界 → 注热 ----
            obj.diffuseTemperature(nuEff / obj.AIR.Pr);
            fluidOnly = double(obj.obstacle == 0);
            Tpre = obj.T_fluid;
            [uAdv, vAdv] = obj.getCellVelocity();
            obj.T_fluid = obj.advectScalar(obj.T_fluid, uAdv, vAdv, obj.T_amb);
            obj.accAdvect = obj.accAdvect + sum((obj.T_fluid - Tpre) .* fluidOnly);
            obj.accAdvectCase = obj.accAdvectCase + sum(obj.T_fluid(obj.insideMask) - Tpre(obj.insideMask));
            Tpre = obj.T_fluid;
            obj.T_fluid = max(obj.T_fluid, obj.T_amb);
            dCl = sum((obj.T_fluid - Tpre) .* fluidOnly);
            obj.accClamp = obj.accClamp + dCl;
            obj.accClampAdvect = obj.accClampAdvect + dCl;
            obj.accClampCase = obj.accClampCase + sum(obj.T_fluid(obj.insideMask) - Tpre(obj.insideMask));
            % 障碍格温度仅作显示（不参与流体格的计算）：定温壁取壁温；发热元件固体格
            % （CPU 底座、GPU PCB、电源外壳）取 T_solid；其余绝热障碍取 4 邻域流体格均值
            % （无流体邻居取环境温度），避免温度视图出现假冷块
            obj.T_fluid(obj.dirichletIdx) = obj.dirichletT;
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
                Tm(adiM & ~hasN) = obj.T_amb;
                obj.T_fluid = Tm(:);
            end
            obj.T_fluid(obj.heatObsIdx) = obj.T_solid(obj.heatObsIdx);
            % 远场海绵环取环境温度（无限大外部空气池）
            Tpre = obj.T_fluid;
            obj.T_fluid(obj.spongeRingIdx) = obj.T_amb;
            obj.accResetOut = obj.accResetOut + sum(obj.T_fluid(obj.spongeRingIdx) - Tpre(obj.spongeRingIdx));

            obj.solveConjugateHeatTransfer();

            Tpre = obj.T_fluid;
            obj.T_fluid = min(obj.T_fluid, 200);
            dClCap = sum((obj.T_fluid - Tpre) .* fluidOnly);
            obj.accClampCase = obj.accClampCase + sum(obj.T_fluid(obj.insideMask) - Tpre(obj.insideMask));
            Tpre = obj.T_fluid;
            obj.T_fluid = max(obj.T_fluid, obj.T_amb);
            dClFloor = sum((obj.T_fluid - Tpre) .* fluidOnly);
            obj.accClampCase = obj.accClampCase + sum(obj.T_fluid(obj.insideMask) - Tpre(obj.insideMask));
            obj.accClamp = obj.accClamp + dClCap + dClFloor;
            obj.accClampCap = obj.accClampCap + dClCap;
            obj.accClampFloor = obj.accClampFloor + dClFloor;
            % 注热区可能触及远场格，再钉一次海绵环
            Tpre = obj.T_fluid;
            obj.T_fluid(obj.spongeRingIdx) = obj.T_amb;
            obj.accResetOut = obj.accResetOut + sum(obj.T_fluid(obj.spongeRingIdx) - Tpre(obj.spongeRingIdx));
            obj.accSteps = obj.accSteps + 1;

            obj.iteration = obj.iteration + 1;
        end
    end
end
