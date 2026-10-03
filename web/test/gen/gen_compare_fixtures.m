function gen_compare_fixtures(outFile)
%GEN_COMPARE_FIXTURES 生成对比计算口径的对照数据（web/test/fixtures/compare.json）：
%   tools/compare_scenarios 用缩短的口径（140²、湍流隔步、自动 24 步取后 12 步、全局 40/100% 各 10 步取后 6 步）
%   算两个算例（正压 / 办公：显卡低温停转、电源半被动；默认 / 满载），网页版 CompareRunner 应逐项相同。
%   用法（在 matlab_app 目录下）：
%     OMP_NUM_THREADS=1 octave-cli --no-gui --eval "setup_paths(); addpath('../web/test/gen'); gen_compare_fixtures"
    if nargin < 1
        here = fileparts(mfilename('fullpath'));
        outFile = fullfile(here, '..', 'fixtures', 'compare.json');
    end
    p = struct('gridScale', 0.5, 'turbUpdateEvery', 2, 'autoSteps', 24, 'autoAvgFrom', 12, ...
               'sweepPct', [40 100], 'sweepSteps', 10, 'sweepAvgFrom', 4);
    R1 = compare_scenarios({'positive'}, {'office'}, p);
    R2 = compare_scenarios({'balanced'}, {'heavy'}, p);
    R = struct('generator', struct('tool', 'octave', 'version', version(), 'script', 'web/test/gen/gen_compare_fixtures.m'), ...
        'protocol', p, 'cases', {{R1, R2}});
    fid = fopen(outFile, 'w');
    fwrite(fid, unicode2native(jsonencode(R), 'UTF-8'));
    fclose(fid);
    fprintf('已写入 %s\n', outFile);
end
