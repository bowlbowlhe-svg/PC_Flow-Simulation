classdef MockUI < handle
    %MOCKUI 界面桩对象（仅 Octave 测试用）：模拟 uifigure 组件与图形对象。
    %   任意属性可读写（未设置的属性读出 []），子组件构造函数与绘图函数作为方法
    %   分派（第一个参数是 MockUI 时 Octave 调用这里的同名方法）。
    %   测试通过读取回调属性（ButtonPushedFcn 等）并直接调用来模拟用户操作。
    properties
        Kind = ''
        Props = struct()
        Alive = true
        Id = 0
    end

    methods
        function obj = MockUI(kind, varargin)
            persistent counter
            if isempty(counter), counter = 0; end
            counter = counter + 1;
            obj.Id = counter;
            obj.Kind = kind;
            obj.setPairs(varargin);
        end

        function setPairs(obj, args)
            % 取末尾的 名称-值 对（跳过开头的数值参数与线型字符串）
            i = find(cellfun(@ischar, args), 1);
            if isempty(i), return; end
            rest = args(i:end);
            if mod(numel(rest), 2) == 1, rest = rest(2:end); end
            for j = 1:2:numel(rest)
                if ischar(rest{j}) && isvarname(rest{j})
                    obj.Props.(rest{j}) = rest{j+1};
                end
            end
        end

        function v = subsref(obj, s)
            if strcmp(s(1).type, '.') && ~any(strcmp(s(1).subs, {'Kind', 'Props', 'Alive', 'Id'})) ...
                    && ~ismethod(obj, s(1).subs)
                if isfield(obj.Props, s(1).subs), v = obj.Props.(s(1).subs); else, v = []; end
                if numel(s) > 1, v = subsref(v, s(2:end)); end
            else
                v = builtin('subsref', obj, s);
            end
        end

        function obj = subsasgn(obj, s, v)
            if strcmp(s(1).type, '.') && ~any(strcmp(s(1).subs, {'Kind', 'Props', 'Alive', 'Id'}))
                if numel(s) == 1
                    obj.Props.(s(1).subs) = v;
                else
                    if isfield(obj.Props, s(1).subs), cur = obj.Props.(s(1).subs); else, cur = struct(); end
                    obj.Props.(s(1).subs) = subsasgn(cur, s(2:end), v);
                end
            else
                obj = builtin('subsasgn', obj, s, v);
            end
        end

        function tf = eq(a, b)
            tf = isa(a, 'MockUI') && isa(b, 'MockUI') && a.Id == b.Id;
        end

        function v = isvalid(obj), v = obj.Alive; end
        function delete(obj), obj.Alive = false; end
        function set(obj, varargin), obj.setPairs(varargin); end
        function v = get(obj, name)
            if isfield(obj.Props, name), v = obj.Props.(name); else, v = []; end
        end

        % ---- 容器与控件 ----
        function h = uipanel(p, varargin),       h = MockUI('uipanel', varargin{:}); end
        function h = uilabel(p, varargin),       h = MockUI('uilabel', varargin{:}); end
        function h = uibutton(p, varargin),      h = MockUI('uibutton', varargin{:}); end
        function h = uislider(p, varargin),      h = MockUI('uislider', varargin{:}); end
        function h = uidropdown(p, varargin),    h = MockUI('uidropdown', varargin{:}); end
        function h = uitable(p, varargin),       h = MockUI('uitable', varargin{:}); end
        function h = uicheckbox(p, varargin),    h = MockUI('uicheckbox', varargin{:}); end
        function h = uitextarea(p, varargin),    h = MockUI('uitextarea', varargin{:}); end
        function h = uiaxes(p, varargin),        h = MockUI('uiaxes', varargin{:}); end
        function h = uicontextmenu(p, varargin), h = MockUI('uicontextmenu', varargin{:}); end
        function h = uitabgroup(p, varargin),    h = MockUI('uitabgroup', varargin{:}); end
        function h = uitab(p, varargin)
            h = MockUI('uitab', varargin{:});
            if ~isfield(p.Props, 'SelectedTab') || isempty(p.Props.SelectedTab)
                p.Props.SelectedTab = h;          % 与 MATLAB 一致：默认选中第一页
            end
        end
        function uialert(fig, msg, ttl)
            fig.Props.LastAlert = sprintf('%s: %s', ttl, msg);
            fprintf('[uialert] %s: %s\n', ttl, msg);
        end
        function exportapp(~, ~), end
        function h = uiprogressdlg(fig, varargin), h = MockUI('uiprogressdlg', varargin{:}); end
        function close(h), h.Alive = false; end
        function start(t), t.Props.Running = 'on'; end
        function stop(t), t.Props.Running = 'off'; end

        % ---- 绘图 ----
        function h = imagesc(ax, x, y, C, varargin), h = MockUI('image', 'CData', C); end
        function h = plot(ax, varargin),   h = MockUI('line', varargin{:}); end
        function h = quiver(ax, varargin), h = MockUI('quiver', varargin{:}); end
        function h = patch(ax, varargin),  h = MockUI('patch', varargin{:}); end
        function h = text(ax, x, y, str, varargin)
            h = MockUI('text', varargin{:});
            h.Props.String = str;
        end
        function [C, h] = contour(ax, varargin)
            C = [];
            h = MockUI('contour');
        end
        function h = streamslice(ax, varargin), h = MockUI('streamslice'); end
        function h = colorbar(ax, varargin)
            h = MockUI('colorbar');
            h.Props.Label = struct('String', '', 'Color', [0 0 0]);
        end
        function title(ax, str, varargin), ax.Props.TitleString = str; end
        function xlabel(ax, varargin), end
        function ylabel(ax, varargin), end
        function legend(ax, varargin), end
        function grid(ax, varargin), end
        function xlim(ax, v), ax.Props.XLim = v; end
        function ylim(ax, v), ax.Props.YLim = v; end
        function axis(ax, varargin), end
        function hold(ax, varargin), end
        function cla(ax), ax.Props.Cleared = true; end
        function disableDefaultInteractivity(ax), end
    end
end
