classdef MockUI < handle
    %MOCKUI 界面桩对象（仅 Octave 测试用）：模拟 uifigure 组件与图形对象。
    %   只接受 MATLAB 中该类对象真实存在的属性（白名单见 allowedProps，按 MATLAB
    %   R2021a 文档整理，只列本项目用到的）；写错属性名会像 MATLAB 一样报错。
    %   已设置的属性按值读出，未设置的读出默认值（Enable/Visible 为 'on'，其余 []）。
    %   子组件构造函数与绘图函数作为方法分派（第一个参数是 MockUI 时 Octave 调用
    %   这里的同名方法）。测试通过读取回调属性（ButtonPushedFcn 等）并直接调用来
    %   模拟用户操作。不模拟：控件显示、drawnow 期间的回调重入。
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
                obj.checkProp(rest{j});
                obj.Props.(rest{j}) = rest{j+1};
            end
        end

        function checkProp(obj, name)
            ok = MockUI.allowedProps(obj.Kind);
            if ~ischar(name) || ~any(strcmp(ok, name))
                error('MockUI:prop', '%s 没有属性 "%s"（MATLAB 下会报错）', obj.Kind, name);
            end
        end

        function v = subsref(obj, s)
            if strcmp(s(1).type, '.') && ~any(strcmp(s(1).subs, {'Kind', 'Props', 'Alive', 'Id'})) ...
                    && ~ismethod(obj, s(1).subs)
                obj.checkProp(s(1).subs);
                if isfield(obj.Props, s(1).subs)
                    v = obj.Props.(s(1).subs);
                elseif any(strcmp(s(1).subs, {'Enable', 'Visible'}))
                    v = 'on';
                else
                    v = [];
                end
                if numel(s) > 1, v = subsref(v, s(2:end)); end
            else
                v = builtin('subsref', obj, s);
            end
        end

        function obj = subsasgn(obj, s, v)
            if strcmp(s(1).type, '.') && ~any(strcmp(s(1).subs, {'Kind', 'Props', 'Alive', 'Id'}))
                obj.checkProp(s(1).subs);
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
            obj.checkProp(name);
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

    methods (Static)
        function p = allowedProps(kind)
            % 各类对象的属性白名单（MATLAB R2021a，本项目用到的部分）
            persistent T
            if isempty(T)
                common = {'Position', 'Visible', 'Tag', 'UserData'};
                T = struct( ...
                    'uifigure', {[common, {'Name', 'Color', 'WindowStyle', 'ContextMenu', 'CloseRequestFcn', ...
                        'WindowButtonMotionFcn', 'Pointer'}]}, ...
                    'uipanel', {[common, {'BackgroundColor', 'BorderType', 'HighlightColor', 'Title', ...
                        'TitlePosition', 'FontSize', 'FontWeight', 'ForegroundColor'}]}, ...
                    'uiaxes', {[common, {'Color', 'XColor', 'YColor', 'XTick', 'YTick', 'ContextMenu', 'YDir', ...
                        'Colormap', 'CLim', 'XLim', 'YLim', 'CurrentPoint', 'Title'}]}, ...
                    'uilabel', {[common, {'Text', 'FontSize', 'FontWeight', 'FontColor', 'HorizontalAlignment', ...
                        'VerticalAlignment', 'BackgroundColor', 'Tooltip', 'Enable'}]}, ...
                    'uibutton', {[common, {'Text', 'FontSize', 'FontWeight', 'FontColor', 'BackgroundColor', ...
                        'ButtonPushedFcn', 'Enable', 'Tooltip'}]}, ...
                    'uislider', {[common, {'Limits', 'Value', 'ValueChangedFcn', 'ValueChangingFcn', 'Enable', ...
                        'MajorTicks', 'FontColor'}]}, ...
                    'uidropdown', {[common, {'Items', 'ItemsData', 'Value', 'FontSize', 'FontColor', ...
                        'BackgroundColor', 'ValueChangedFcn', 'Enable', 'Tooltip'}]}, ...
                    'uitable', {[common, {'Data', 'ColumnName', 'ColumnWidth', 'RowName', 'FontSize', ...
                        'ColumnEditable', 'ColumnFormat', 'CellEditCallback', 'BackgroundColor', ...
                        'ForegroundColor', 'Enable'}]}, ...
                    'uicheckbox', {[common, {'Value', 'Text', 'FontSize', 'FontColor', 'ValueChangedFcn', 'Enable'}]}, ...
                    'uitextarea', {[common, {'Value', 'Editable', 'BackgroundColor', 'FontColor', 'FontSize'}]}, ...
                    'uitabgroup', {[common, {'SelectedTab', 'SelectionChangedFcn'}]}, ...
                    'uitab', {{'Title', 'BackgroundColor', 'Tag', 'UserData'}}, ...
                    'uicontextmenu', {{'Tag'}}, ...
                    'timer', {{'ExecutionMode', 'Period', 'TimerFcn', 'Running', 'BusyMode', 'Tag'}}, ...
                    'uiprogressdlg', {{'Title', 'Message', 'Indeterminate', 'Value'}}, ...
                    'image', {{'CData', 'AlphaData', 'HitTest', 'PickableParts', 'Visible'}}, ...
                    'line', {{'XData', 'YData', 'Color', 'LineWidth', 'LineStyle', 'Marker', 'MarkerSize', ...
                        'MarkerFaceColor', 'DisplayName', 'HitTest', 'PickableParts', 'Visible'}}, ...
                    'text', {{'String', 'Position', 'Color', 'FontSize', 'FontWeight', 'HorizontalAlignment', ...
                        'VerticalAlignment', 'Interpreter', 'BackgroundColor', 'HitTest', 'PickableParts', 'Visible'}}, ...
                    'quiver', {{'AutoScale', 'Color', 'MaxHeadSize', 'LineWidth', 'HitTest', 'PickableParts', 'Visible'}}, ...
                    'patch', {{'XData', 'YData', 'FaceColor', 'FaceAlpha', 'EdgeColor', 'LineStyle', 'LineWidth', ...
                        'ButtonDownFcn', 'HitTest', 'PickableParts', 'Visible'}}, ...
                    'scatter', {{'XData', 'YData', 'CData', 'SizeData', 'MarkerFaceColor', 'MarkerEdgeColor', ...
                        'MarkerFaceAlpha', 'HitTest', 'PickableParts', 'Visible'}}, ...
                    'contour', {{'LineColor', 'LineWidth', 'HitTest', 'PickableParts', 'Visible'}}, ...
                    'streamslice', {{'Color', 'LineWidth', 'HitTest', 'PickableParts', 'Visible'}}, ...
                    'colorbar', {{'Color', 'FontSize', 'Label', 'Visible'}});
            end
            if isfield(T, kind), p = T.(kind); else, p = {}; end
        end
    end
end
