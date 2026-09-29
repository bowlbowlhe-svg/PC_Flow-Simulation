function h = timer(varargin)
%TIMER 定时器桩（仅 Octave 测试用）：不会自动触发，测试手动调用 onTimer。
    h = MockUI('timer', varargin{:});
    h.Running = 'off';   % 类外赋值走重载的 subsasgn
end
