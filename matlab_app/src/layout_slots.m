function varargout = layout_slots(action, varargin)
%LAYOUT_SLOTS 机箱风扇安装位状态与布局 caseFans 之间的转换。
%   states = layout_slots('get', L)          从布局读出各安装位状态（与 fan_slots 顺序一致）
%   L      = layout_slots('set', L, states)  按安装位状态重写 L.caseFans
%   状态 struct 字段：id、type（'none' | 'intake' | 'exhaust'）、model、
%   speedMode（'auto' | 'manual'）、manualPct。不在安装位上的机箱风扇保持不变。
    slots = fan_slots();
    switch action
        case 'get'
            L = varargin{1};
            states = repmat(emptyState(''), numel(slots), 1);
            for k = 1:numel(slots)
                states(k) = emptyState(slots(k).id);
            end
            if isfield(L, 'caseFans')
                for j = 1:numel(L.caseFans)
                    cf = L.caseFans(j);
                    k = findSlot(slots, cf.mount, cf.alongMm);
                    if k == 0, continue; end
                    states(k).type = cf.type;
                    states(k).model = cf.model;
                    if isfield(cf, 'speedMode'), states(k).speedMode = cf.speedMode; end
                    if isfield(cf, 'manualPct'), states(k).manualPct = cf.manualPct; end
                end
            end
            varargout{1} = states;
        case 'set'
            L = varargin{1}; states = varargin{2};
            keep = struct('mount', {}, 'alongMm', {}, 'type', {}, 'model', {}, 'speedMode', {}, 'manualPct', {});
            if isfield(L, 'caseFans')
                for j = 1:numel(L.caseFans)
                    cf = L.caseFans(j);
                    if findSlot(slots, cf.mount, cf.alongMm) == 0
                        keep(end+1) = normFan(cf); %#ok<AGROW>
                    end
                end
            end
            for k = 1:numel(slots)
                st = states(k);
                if strcmp(st.type, 'none'), continue; end
                keep(end+1) = struct('mount', slots(k).mount, 'alongMm', slots(k).alongMm, ...
                    'type', st.type, 'model', st.model, 'speedMode', st.speedMode, ...
                    'manualPct', st.manualPct); %#ok<AGROW>
            end
            L.caseFans = keep(:);
            varargout{1} = L;
        otherwise
            error('layout_slots:action', '未知操作：%s', action);
    end
end

function s = emptyState(id)
    s = struct('id', id, 'type', 'none', 'model', 'P12', 'speedMode', 'auto', 'manualPct', 60);
end

function k = findSlot(slots, mount, alongMm)
    k = 0;
    for i = 1:numel(slots)
        if strcmp(slots(i).mount, mount) && abs(slots(i).alongMm - alongMm) < 1
            k = i; return;
        end
    end
end

function f = normFan(cf)
    f = struct('mount', cf.mount, 'alongMm', cf.alongMm, 'type', cf.type, 'model', cf.model, ...
               'speedMode', 'auto', 'manualPct', 60);
    if isfield(cf, 'speedMode'), f.speedMode = cf.speedMode; end
    if isfield(cf, 'manualPct'), f.manualPct = cf.manualPct; end
end
