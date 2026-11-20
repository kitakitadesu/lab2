function result = make_report_figures(varargin)
% MAKE_REPORT_FIGURES  Generate 300-dpi publication figures and R3 Raw-vs-LPF metrics.
%
% Supports both a single unified analyzed run folder (e.g. stepper_data/final_5trials)
% and legacy multi-folder layouts (e.g. stepper_data/ containing 3-trial + LPF runs),
% with zero hardcoded dataset paths or pull-out numbers.
%
% Usage:
%   make_report_figures()
%   make_report_figures(dataDir)
%   make_report_figures(dataDir, outDir)
%   make_report_figures(dataDir, outDir, 'DPI', 300, ...)
%   make_report_figures('DataDir', dataDir, 'OutDir', outDir, ...)
%
% Optional Name-Value pairs:
%   'DataDir'         - Unified run folder or parent folder with legacy run subdirs
%   'OutDir'          - Output directory (default: <DataDir>/report_final)
%   'R3Dir'           - Explicit folder override for R3 data/tables
%   'R4Dir'           - Explicit folder override for R4_R5 data/tables
%   'R6Dirs'          - Explicit folder override(s) (char/string/cellstr) for R6
%   'R8Dirs'          - Explicit folder override(s) (char/string/cellstr) for R8
%   'DPI'             - Export resolution in dots per inch (default: 300)
%   'CopySimulinkPng' - Copy Simulink_MotorXploer_Stepper.png if missing (default: true)
%
% Outputs (written to outDir):
%   Fig1_R4_FreqVsSpeed.png
%   Fig2_R3_DriveModes_Raw_vs_LPF.png
%   Fig3_R6_R8_LossStep_TimeSeries.png
%   Fig4_R8_Accel_vs_PullOut.png
%   Fig5_Raw_vs_LPF_FFT.png
%   Fig6_R6_PullIn_Full_vs_Half.png
%   Raw_vs_LPF_R3_metrics.csv
%   Simulink_MotorXploer_Stepper.png (copied if available and absent in outDir)

cfg = parse_inputs(varargin{:});
repo_root = fileparts(fileparts(mfilename('fullpath')));
src = resolve_sources(cfg, repo_root);

if ~isfolder(src.out_dir)
    mkdir(src.out_dir);
end

fprintf('\n=== Generating Lab 2.2 Report Figures (%s mode) ===\n', src.mode);
fprintf('Data source : %s\n', src.data_dir);
fprintf('Output dir  : %s\n', src.out_dir);
fprintf('Resolution  : %d dpi\n', cfg.DPI);

result = struct();
result.mode       = src.mode;
result.data_dir   = src.data_dir;
result.out_dir    = src.out_dir;
result.sources    = src;
result.files      = struct();
result.r3_metrics = table();
result.warnings   = {};

% ---- Fig 1: R4 & R5 Frequency vs Speed across modes
if ~isempty(src.r4_dir)
    f1_path = fullfile(src.out_dir, 'Fig1_R4_FreqVsSpeed.png');
    [ok1, warn1] = make_fig1_freq_vs_speed(src.r4_dir, f1_path, cfg.DPI);
    if ok1
        result.files.Fig1_R4_FreqVsSpeed = f1_path;
    elseif ~isempty(warn1)
        result.warnings{end+1} = warn1;
    end
else
    result.warnings{end+1} = 'No R4_R5 source folder found; skipped Fig1_R4_FreqVsSpeed.png.';
end

% ---- Fig 2 & Fig 5 + Raw_vs_LPF_R3_metrics.csv
if ~isempty(src.r3_dir)
    f2_path  = fullfile(src.out_dir, 'Fig2_R3_DriveModes_Raw_vs_LPF.png');
    f5_path  = fullfile(src.out_dir, 'Fig5_Raw_vs_LPF_FFT.png');
    csv_path = fullfile(src.out_dir, 'Raw_vs_LPF_R3_metrics.csv');
    [ok2, ok5, T_lpf, warn_r3] = make_fig2_fig5_r3_lpf(src.r3_dir, f2_path, f5_path, csv_path, cfg.DPI);
    if ~isempty(T_lpf)
        result.r3_metrics = T_lpf;
        result.files.Raw_vs_LPF_R3_metrics = csv_path;
    end
    if ok2, result.files.Fig2_R3_DriveModes_Raw_vs_LPF = f2_path; end
    if ok5, result.files.Fig5_Raw_vs_LPF_FFT = f5_path; end
    if ~isempty(warn_r3), result.warnings{end+1} = warn_r3; end
else
    result.warnings{end+1} = 'No R3 source folder found; skipped Fig2, Fig5, and Raw_vs_LPF_R3_metrics.csv.';
end

% ---- Fig 3: R8 Loss-Step / Speed Time Series (representative run)
if ~isempty(src.r8_mode_dirs)
    f3_path = fullfile(src.out_dir, 'Fig3_R6_R8_LossStep_TimeSeries.png');
    [ok3, warn3] = make_fig3_loss_step_timeseries(src.r8_mode_dirs, f3_path, cfg.DPI);
    if ok3
        result.files.Fig3_R6_R8_LossStep_TimeSeries = f3_path;
    elseif ~isempty(warn3)
        result.warnings{end+1} = warn3;
    end
else
    result.warnings{end+1} = 'No R8 source folder found; skipped Fig3_R6_R8_LossStep_TimeSeries.png.';
end

% ---- Fig 4: R8 (+ R6 Pull-In) Acceleration Limit vs Pull-Out Frequency (Full vs Half)
if ~isempty(src.r8_mode_dirs) || ~isempty(src.r6_mode_dirs)
    f4_path = fullfile(src.out_dir, 'Fig4_R8_Accel_vs_PullOut.png');
    [ok4, warn4] = make_fig4_accel_vs_pullout(src.r8_mode_dirs, src.r6_mode_dirs, f4_path, cfg.DPI);
    if ok4
        result.files.Fig4_R8_Accel_vs_PullOut = f4_path;
    elseif ~isempty(warn4)
        result.warnings{end+1} = warn4;
    end
else
    result.warnings{end+1} = 'No R6/R8 source folders found; skipped Fig4_R8_Accel_vs_PullOut.png.';
end

% ---- Fig 6: R6 Pull-In Comparison (Full Step vs Half Step)
if ~isempty(src.r6_mode_dirs)
    f6_path = fullfile(src.out_dir, 'Fig6_R6_PullIn_Full_vs_Half.png');
    [ok6, warn6] = make_fig6_r6_pullin(src.r6_mode_dirs, f6_path, cfg.DPI);
    if ok6
        result.files.Fig6_R6_PullIn_Full_vs_Half = f6_path;
    elseif ~isempty(warn6)
        result.warnings{end+1} = warn6;
    end
else
    result.warnings{end+1} = 'No R6 source folders found; skipped Fig6_R6_PullIn_Full_vs_Half.png.';
end

% ---- Copy Simulink screenshot into outDir if available and absent
if cfg.CopySimulinkPng
    sim_src = fullfile(repo_root, 'stepper_data', 'report_final', 'Simulink_MotorXploer_Stepper.png');
    sim_dst = fullfile(src.out_dir, 'Simulink_MotorXploer_Stepper.png');
    if isfile(sim_src) && ~isfile(sim_dst)
        copyfile(sim_src, sim_dst);
    end
    if isfile(sim_dst)
        result.files.Simulink_MotorXploer_Stepper = sim_dst;
    end
end

for k = 1:numel(result.warnings)
    warning('make_report_figures:partial', '%s', result.warnings{k});
end

written = fieldnames(result.files);
fprintf('Generated %d report asset(s) -> %s\n', numel(written), src.out_dir);
for k = 1:numel(written)
    fprintf('  - %s\n', result.files.(written{k}));
end
end

% =========================================================================
% Input Parsing & Dynamic Source Discovery
% =========================================================================
function cfg = parse_inputs(varargin)
nv_names = {'DataDir', 'OutDir', 'R3Dir', 'R4Dir', 'R6Dirs', 'R8Dirs', 'DPI', 'CopySimulinkPng'};
pos_data = '';
pos_out  = '';
rest = varargin;

if ~isempty(rest) && ~is_nv_key(rest{1}, nv_names)
    pos_data = to_char_path(rest{1});
    rest = rest(2:end);
    if ~isempty(rest) && ~is_nv_key(rest{1}, nv_names)
        pos_out = to_char_path(rest{1});
        rest = rest(2:end);
    end
end

p = inputParser;
p.FunctionName = 'make_report_figures';
addParameter(p, 'DataDir',         pos_data, @(x) ischar(x) || isstring(x));
addParameter(p, 'OutDir',          pos_out,  @(x) ischar(x) || isstring(x));
addParameter(p, 'R3Dir',           '',       @(x) ischar(x) || isstring(x));
addParameter(p, 'R4Dir',           '',       @(x) ischar(x) || isstring(x));
addParameter(p, 'R6Dirs',          {},       @(x) ischar(x) || isstring(x) || iscellstr(x));
addParameter(p, 'R8Dirs',          {},       @(x) ischar(x) || isstring(x) || iscellstr(x));
addParameter(p, 'DPI',             300,      @(x) isnumeric(x) && isscalar(x) && x >= 72);
addParameter(p, 'CopySimulinkPng', true,     @(x) islogical(x) && isscalar(x));
parse(p, rest{:});

cfg = p.Results;
cfg.DataDir = to_char_path(cfg.DataDir);
cfg.OutDir  = to_char_path(cfg.OutDir);
cfg.R3Dir   = to_char_path(cfg.R3Dir);
cfg.R4Dir   = to_char_path(cfg.R4Dir);
cfg.R6Dirs  = to_dir_list(cfg.R6Dirs);
cfg.R8Dirs  = to_dir_list(cfg.R8Dirs);
end

function tf = is_nv_key(val, keys)
tf = (ischar(val) || (isstring(val) && isscalar(val))) && any(strcmpi(char(val), keys));
end

function s = to_char_path(x)
if isempty(x)
    s = '';
else
    s = strtrim(char(x));
end
end

function dirs = to_dir_list(x)
if isempty(x)
    dirs = {};
elseif ischar(x)
    dirs = {strtrim(x)};
elseif isstring(x)
    dirs = cellstr(strtrim(x(:)))';
else
    dirs = cellfun(@(c) strtrim(char(c)), x(:)', 'UniformOutput', false);
end
dirs = dirs(~cellfun(@isempty, dirs));
end

function src = resolve_sources(cfg, repo_root)
stepper_root = fullfile(repo_root, 'stepper_data');
data_dir = cfg.DataDir;

if isempty(data_dir)
    cand5 = fullfile(stepper_root, 'final_5trials');
    if isfolder(cand5) && (has_analyzed_tables(cand5) || has_run_mats(cand5))
        data_dir = cand5;
    else
        data_dir = stepper_root;
    end
end
assert(isfolder(data_dir), 'make_report_figures:missingDir', 'Data directory not found: %s', data_dir);

is_unified = has_analyzed_tables(data_dir) || has_run_mats(data_dir);
src = struct();
src.data_dir = data_dir;
if isempty(cfg.OutDir)
    src.out_dir = fullfile(data_dir, 'report_final');
else
    src.out_dir = cfg.OutDir;
end

if is_unified
    src.mode         = 'unified';
    src.r3_dir       = pick_str(cfg.R3Dir, data_dir);
    src.r4_dir       = pick_str(cfg.R4Dir, data_dir);
    src.r6_mode_dirs = build_override_mode_dirs(pick_dirs(cfg.R6Dirs, {data_dir}), 'R6');
    src.r8_mode_dirs = build_override_mode_dirs(pick_dirs(cfg.R8Dirs, {data_dir}), 'R8');
else
    src.mode = 'legacy_multi';
    sub_infos = discover_run_subfolders(data_dir);
    assert(~isempty(sub_infos), 'make_report_figures:noData', ...
        'No analyzed tables or run .mat files found in %s or its subdirectories.', data_dir);

    src.r3_dir = pick_str(cfg.R3Dir, select_best_r3_dir(sub_infos));
    src.r4_dir = pick_str(cfg.R4Dir, select_best_r4_dir(sub_infos));

    if ~isempty(cfg.R6Dirs)
        src.r6_mode_dirs = build_override_mode_dirs(cfg.R6Dirs, 'R6');
    else
        src.r6_mode_dirs = select_best_mode_dirs(sub_infos, 'R6');
    end

    if ~isempty(cfg.R8Dirs)
        src.r8_mode_dirs = build_override_mode_dirs(cfg.R8Dirs, 'R8');
    else
        src.r8_mode_dirs = select_best_mode_dirs(sub_infos, 'R8');
    end
end
end

function s = pick_str(override_val, default_val)
if ~isempty(override_val)
    s = override_val;
else
    s = default_val;
end
end

function d = pick_dirs(override_val, default_val)
if ~isempty(override_val)
    d = override_val;
else
    d = default_val;
end
end

function tf = has_analyzed_tables(folder)
tbl_dir = fullfile(folder, 'tables');
if ~isfolder(tbl_dir)
    tf = false;
    return;
end
csvs = dir(fullfile(tbl_dir, '*.csv'));
tf = ~isempty(csvs);
end

function tf = has_run_mats(folder)
mats = list_run_mat_files(folder);
tf = ~isempty(mats);
end

function mats = list_run_mat_files(folder)
d = dir(fullfile(folder, '*.mat'));
if isempty(d)
    mats = d;
    return;
end
keep = ~ismember({d.name}, {'run_config.mat', 'analysis_summary.mat'});
mats = d(keep);
end

function infos = discover_run_subfolders(parent_dir)
d = dir(parent_dir);
skip = {'.', '..', 'report_final', 'figures', 'figures_raw', 'tables', 'raw_csv'};
d = d([d.isdir] & ~ismember({d.name}, skip));
infos = struct('dir', {}, 'datenum', {}, ...
    'has_r3', {}, 'r3_live_lpf', {}, 'r3_trials', {}, ...
    'has_r4', {}, 'r4_n_modes', {}, 'r4_trials', {}, ...
    'r6_modes', {}, 'r6_live_lpf', {}, 'r6_trials', {}, ...
    'r8_modes', {}, 'r8_live_lpf', {}, 'r8_prehold', {}, 'r8_trials', {});

for i = 1:numel(d)
    fp = fullfile(parent_dir, d(i).name);
    if ~(has_analyzed_tables(fp) || has_run_mats(fp))
        continue;
    end
    infos(end+1) = inspect_run_folder(fp, d(i).datenum); %#ok<AGROW>
end
end

function info = inspect_run_folder(folder, folder_datenum)
info = struct('dir', folder, 'datenum', folder_datenum, ...
    'has_r3', false, 'r3_live_lpf', false, 'r3_trials', 0, ...
    'has_r4', false, 'r4_n_modes', 0, 'r4_trials', 0, ...
    'r6_modes', [], 'r6_live_lpf', false, 'r6_trials', 0, ...
    'r8_modes', [], 'r8_live_lpf', false, 'r8_prehold', false, 'r8_trials', 0);

% Inspect tables first (fast, no heavy MAT reads)
r3_csv = fullfile(folder, 'tables', 'R3_drive_modes_summary.csv');
if isfile(r3_csv)
    T = readtable(r3_csv, 'TextType', 'string');
    if height(T) > 0
        info.has_r3 = true;
        if ismember('N_Trials', T.Properties.VariableNames)
            info.r3_trials = max(to_num_col(T.N_Trials));
        else
            info.r3_trials = 1;
        end
        if ismember('LPF_Source', T.Properties.VariableNames)
            info.r3_live_lpf = any(strcmpi(string(T.LPF_Source), "live"));
        end
    end
end

r4_csv = fullfile(folder, 'tables', 'R4_R5_freq_vs_speed.csv');
if isfile(r4_csv)
    T = readtable(r4_csv, 'TextType', 'string');
    if height(T) > 0
        info.has_r4 = true;
        if ismember('Microstep_M', T.Properties.VariableNames)
            info.r4_n_modes = numel(unique(to_num_col(T.Microstep_M)));
        end
        if ismember('N_Trials', T.Properties.VariableNames)
            info.r4_trials = max(to_num_col(T.N_Trials));
        else
            info.r4_trials = 1;
        end
    end
end

r6_sum_csv = fullfile(folder, 'tables', 'R6_pullin_summary.csv');
r6_stp_csv = fullfile(folder, 'tables', 'R6_pullin_steps.csv');
if isfile(r6_sum_csv)
    T = readtable(r6_sum_csv, 'TextType', 'string');
    if height(T) > 0 && ismember('Drive_Mode', T.Properties.VariableNames)
        info.r6_modes = unique(to_num_col(T.Drive_Mode))';
        if ismember('N_Trials', T.Properties.VariableNames)
            info.r6_trials = max(to_num_col(T.N_Trials));
        end
    end
elseif isfile(r6_stp_csv)
    T = readtable(r6_stp_csv, 'TextType', 'string');
    if height(T) > 0
        if ismember('Drive_Mode', T.Properties.VariableNames)
            info.r6_modes = unique(to_num_col(T.Drive_Mode))';
        end
        if ismember('Trial', T.Properties.VariableNames)
            info.r6_trials = max(to_num_col(T.Trial));
        end
    end
end

r8_csv = fullfile(folder, 'tables', 'R8_accel_pullout.csv');
if isfile(r8_csv)
    T = readtable(r8_csv, 'TextType', 'string');
    if height(T) > 0 && ismember('Accel_Hz_s', T.Properties.VariableNames)
        has_ramp = any(isfinite(to_num_col(T.Accel_Hz_s)));
        if has_ramp && ismember('Drive_Mode', T.Properties.VariableNames)
            acc = to_num_col(T.Accel_Hz_s);
            info.r8_modes = unique(to_num_col(T.Drive_Mode(isfinite(acc))))';
            if ismember('N_Trials', T.Properties.VariableNames)
                info.r8_trials = max(to_num_col(T.N_Trials(isfinite(acc))));
            end
        end
    end
end

% Inspect .mat metadata (fast: loads 'meta' only, checks 1 sample per lab for live LPF / pre-hold)
mats = list_run_mat_files(folder);
r3_sample = '';
r6_sample = '';
r8_sample = '';
r3_cnt = 0; r6_cnt = 0; r8_cnt = 0;
r6_m = []; r8_m = [];

for i = 1:numel(mats)
    fp = fullfile(folder, mats(i).name);
    info.datenum = max(info.datenum, mats(i).datenum);
    M = load_meta_only(fp);
    if isempty(M) || ~isfield(M, 'lab')
        continue;
    end
    lab = upper(strtrim(char(M.lab)));
    dm = 1;
    if isfield(M, 'drive_mode') && ~isempty(M.drive_mode)
        dm = round(double(M.drive_mode));
    end
    switch lab
        case 'R3'
            info.has_r3 = true;
            r3_cnt = r3_cnt + 1;
            if isempty(r3_sample), r3_sample = fp; end
        case 'R4_R5'
            info.has_r4 = true;
        case 'R6'
            r6_cnt = r6_cnt + 1;
            r6_m = unique([r6_m, dm]);
            if isempty(r6_sample), r6_sample = fp; end
        case 'R8'
            r8_cnt = r8_cnt + 1;
            r8_m = unique([r8_m, dm]);
            if isempty(r8_sample), r8_sample = fp; end
    end
end

if r3_cnt > 0, info.r3_trials = max(info.r3_trials, r3_cnt); end
if ~isempty(r6_m), info.r6_modes = unique([info.r6_modes, r6_m]); end
if r6_cnt > 0 && info.r6_trials == 0, info.r6_trials = r6_cnt; end
if ~isempty(r8_m), info.r8_modes = unique([info.r8_modes, r8_m]); end
if r8_cnt > 0 && info.r8_trials == 0, info.r8_trials = r8_cnt; end

if ~isempty(r3_sample) && ~info.r3_live_lpf
    info.r3_live_lpf = mat_has_live_lpf(r3_sample);
end
if ~isempty(r6_sample)
    info.r6_live_lpf = mat_has_live_lpf(r6_sample);
end
if ~isempty(r8_sample)
    [info.r8_live_lpf, info.r8_prehold] = inspect_r8_sample(r8_sample);
end
end

function M = load_meta_only(fp)
M = [];
try
    S = load(fp, 'meta');
    if isfield(S, 'meta')
        M = S.meta;
    end
catch
    M = [];
end
end

function tf = mat_has_live_lpf(fp)
tf = false;
try
    S = load(fp, 'logsout');
    if isfield(S, 'logsout')
        tf = any(strcmp(S.logsout.getElementNames, 'rpm_meas_lpf'));
    end
catch
    tf = false;
end
end

function [has_lpf, has_prehold] = inspect_r8_sample(fp)
has_lpf = false;
has_prehold = false;
try
    S = load(fp, 'logsout');
    if ~isfield(S, 'logsout'), return; end
    lo = S.logsout;
    names = lo.getElementNames;
    has_lpf = any(strcmp(names, 'rpm_meas_lpf'));
    if any(strcmp(names, 'freq_cmd'))
        fc = double(squeeze(lo.get('freq_cmd').Values.Data));
        nz = fc(fc > 1);
        if ~isempty(nz)
            has_prehold = (nz(1) >= 150);
        end
    end
catch
    has_lpf = false;
    has_prehold = false;
end
end

function best = select_best_r3_dir(infos)
best = '';
best_score = [-inf, -inf, -inf];
for i = 1:numel(infos)
    if ~infos(i).has_r3, continue; end
    sc = [double(infos(i).r3_live_lpf), infos(i).r3_trials, infos(i).datenum];
    if is_score_better(sc, best_score)
        best_score = sc;
        best = infos(i).dir;
    end
end
end

function best = select_best_r4_dir(infos)
best = '';
best_score = [-inf, -inf, -inf];
for i = 1:numel(infos)
    if ~infos(i).has_r4, continue; end
    sc = [infos(i).r4_n_modes, infos(i).r4_trials, infos(i).datenum];
    if is_score_better(sc, best_score)
        best_score = sc;
        best = infos(i).dir;
    end
end
end

function md = select_best_mode_dirs(infos, lab_name)
all_modes = [];
for i = 1:numel(infos)
    if strcmpi(lab_name, 'R6')
        all_modes = unique([all_modes, infos(i).r6_modes]);
    else
        all_modes = unique([all_modes, infos(i).r8_modes]);
    end
end

md = struct('drive_mode', {}, 'dir', {});
for dm = sort(all_modes)
    best_dir = '';
    best_score = [-inf, -inf, -inf, -inf];
    for i = 1:numel(infos)
        if strcmpi(lab_name, 'R6')
            if ~ismember(dm, infos(i).r6_modes), continue; end
            sc = [double(infos(i).r6_live_lpf), infos(i).r6_trials, 0, infos(i).datenum];
        else
            if ~ismember(dm, infos(i).r8_modes), continue; end
            sc = [double(infos(i).r8_prehold), double(infos(i).r8_live_lpf), infos(i).r8_trials, infos(i).datenum];
        end
        if is_score_better(sc, best_score)
            best_score = sc;
            best_dir = infos(i).dir;
        end
    end
    if ~isempty(best_dir)
        md(end+1) = struct('drive_mode', dm, 'dir', best_dir); %#ok<AGROW>
    end
end
end

function md = build_override_mode_dirs(dirs, lab_name)
md = struct('drive_mode', {}, 'dir', {});
for i = 1:numel(dirs)
    d = dirs{i};
    if ~isfolder(d), continue; end
    info = inspect_run_folder(d, 0);
    if strcmpi(lab_name, 'R6')
        modes = info.r6_modes;
    else
        modes = info.r8_modes;
    end
    if isempty(modes)
        % Still register dir as wildcard (drive_mode = 0) if table exists
        if strcmpi(lab_name, 'R6') && (isfile(fullfile(d,'tables','R6_pullin_steps.csv')) || isfile(fullfile(d,'tables','R6_pullin_summary.csv')))
            md(end+1) = struct('drive_mode', 0, 'dir', d); %#ok<AGROW>
        elseif strcmpi(lab_name, 'R8') && isfile(fullfile(d,'tables','R8_accel_pullout.csv'))
            md(end+1) = struct('drive_mode', 0, 'dir', d); %#ok<AGROW>
        end
    else
        for dm = sort(modes)
            if ~any([md.drive_mode] == dm)
                md(end+1) = struct('drive_mode', dm, 'dir', d); %#ok<AGROW>
            end
        end
    end
end
end

function tf = is_score_better(a, b)
tf = false;
for k = 1:numel(a)
    if a(k) > b(k)
        tf = true;
        return;
    elseif a(k) < b(k)
        tf = false;
        return;
    end
end
end

% =========================================================================
% Figure 1: R4 & R5 Frequency vs Speed across modes
% =========================================================================
function [ok, warn_msg] = make_fig1_freq_vs_speed(r4_dir, out_png, dpi)
ok = false;
warn_msg = '';
csv_path = fullfile(r4_dir, 'tables', 'R4_R5_freq_vs_speed.csv');
if ~isfile(csv_path)
    warn_msg = sprintf('Missing %s; skipped Fig1_R4_FreqVsSpeed.png.', csv_path);
    return;
end

T = readtable(csv_path, 'TextType', 'string');
if height(T) == 0
    warn_msg = sprintf('Empty table %s; skipped Fig1_R4_FreqVsSpeed.png.', csv_path);
    return;
end

M_col    = to_num_col(T.Microstep_M);
freq_col = to_num_col(T.Freq_Hz);
th_col   = to_num_col(T.Theory_RPM);
me_col   = to_num_col(T.Meas_Mean_RPM);
sd_col   = to_num_col(T.Meas_SD_RPM);

n_trials_str = '';
if ismember('N_Trials', T.Properties.VariableNames)
    nt = unique(to_num_col(T.N_Trials));
    nt = nt(isfinite(nt));
    if isscalar(nt)
        n_trials_str = sprintf('n = %d, ', round(nt));
    elseif ~isempty(nt)
        n_trials_str = sprintf('n = %d-%d, ', round(min(nt)), round(max(nt)));
    end
end

[M_list, mode_labels, cols, mkrs] = canonical_mode_style();

fh = figure('Visible', 'off', 'Color', [1 1 1], 'Position', [100 100 940 540]);
cleanup = onCleanup(@() close_if_valid(fh));
ax = axes(fh);
hold(ax, 'on');

plotted = false;
for dm = 1:numel(M_list)
    idx = (M_col == M_list(dm));
    if ~any(idx), continue; end
    fq = freq_col(idx);
    th = th_col(idx);
    me = me_col(idx);
    sd = sd_col(idx);
    [fq, ord] = sort(fq);
    th = th(ord); me = me(ord); sd = sd(ord);
    sd(~isfinite(sd)) = 0;

    plot(ax, fq, th, '--', 'Color', cols(dm,:), 'LineWidth', 1.15, 'HandleVisibility', 'off');
    errorbar(ax, fq, me, sd, ['-' mkrs{dm}], ...
        'Color', cols(dm,:), 'MarkerFaceColor', cols(dm,:), ...
        'LineWidth', 1.5, 'MarkerSize', 5.5, 'CapSize', 5, ...
        'DisplayName', mode_labels{dm});
    plotted = true;
end

if ~plotted
    warn_msg = sprintf('No recognized drive modes in %s; skipped Fig1.', csv_path);
    return;
end

plot(ax, NaN, NaN, 'k--', 'LineWidth', 1.2, 'DisplayName', 'Theory (f_{step} \cdot 60 / (M \cdot N_{full}))');

u_freqs = sort(unique(freq_col(isfinite(freq_col))));
if numel(u_freqs) >= 2
    df = min(diff(u_freqs));
    xlim(ax, [min(u_freqs) - 0.15*df, max(u_freqs) + 0.15*df]);
    if numel(u_freqs) <= 12
        xticks(ax, u_freqs);
    end
elseif isscalar(u_freqs)
    xlim(ax, [max(0, u_freqs - 100), u_freqs + 100]);
end

y_max = max([th_col; me_col + sd_col], [], 'omitnan');
if isfinite(y_max) && y_max > 0
    ylim(ax, [0, y_max * 1.08]);
end

grid(ax, 'on');
box(ax, 'on');
ax.FontSize = 10.5;
xlabel(ax, 'STEP Frequency (Hz)', 'FontSize', 11.5);
ylabel(ax, 'Motor Speed (RPM)', 'FontSize', 11.5);
title(ax, sprintf('R4 & R5: Motor Speed vs STEP Frequency (%sMean \\pm SD)', n_trials_str), ...
    'FontSize', 12, 'FontWeight', 'bold');
legend(ax, 'Location', 'northwest', 'FontSize', 9.5);

save_fig(fh, out_png, dpi);
clear cleanup;
ok = true;
end

% =========================================================================
% Figure 2, Figure 5 & Raw_vs_LPF_R3_metrics.csv
% =========================================================================
function [ok2, ok5, T_lpf, warn_msg] = make_fig2_fig5_r3_lpf(r3_dir, f2_png, f5_png, csv_path, dpi)
ok2 = false;
ok5 = false;
T_lpf = table();
warn_msg = '';

r3_runs = load_runs_for_lab(r3_dir, 'R3');
r3_csv  = fullfile(r3_dir, 'tables', 'R3_drive_modes_summary.csv');

% Build Raw_vs_LPF_R3_metrics.csv (preferring analyzer's multi-trial LPF summary if present)
if isfile(r3_csv)
    T_src = readtable(r3_csv, 'TextType', 'string');
    req_lpf = {'Mode','Microstep_M','Theory_RPM','Meas_Mean_RPM','Ripple_SD_RPM', ...
               'LPF_Mean_RPM','LPF_Ripple_SD_RPM','Ripple_Reduction_Pct'};
    if height(T_src) > 0 && all(ismember(req_lpf, T_src.Properties.VariableNames))
        lpf_shift = to_num_col(T_src.LPF_Mean_RPM) - to_num_col(T_src.Meas_Mean_RPM);
        if ismember('LPF_Mean_Shift_RPM', T_src.Properties.VariableNames)
            lpf_shift = to_num_col(T_src.LPF_Mean_Shift_RPM);
        end
        if ismember('LPF_Source', T_src.Properties.VariableNames)
            lpf_source = string(T_src.LPF_Source);
        else
            lpf_source = repmat("live", height(T_src), 1);
        end
        if ismember('N_Trials', T_src.Properties.VariableNames)
            n_tr = to_num_col(T_src.N_Trials);
        else
            n_tr = max(1, numel(r3_runs)) * ones(height(T_src), 1);
        end
        T_lpf = table(string(T_src.Mode), to_num_col(T_src.Microstep_M), to_num_col(T_src.Theory_RPM), ...
            to_num_col(T_src.Meas_Mean_RPM), to_num_col(T_src.Ripple_SD_RPM), ...
            to_num_col(T_src.LPF_Mean_RPM), to_num_col(T_src.LPF_Ripple_SD_RPM), ...
            to_num_col(T_src.Ripple_Reduction_Pct), lpf_shift, lpf_source, n_tr, ...
            'VariableNames', {'Mode','M','Theory_RPM','Raw_Mean_RPM','Raw_Ripple_SD', ...
            'LPF_Mean_RPM','LPF_Ripple_SD','Noise_Reduction_Pct','LPF_Mean_Shift_RPM','LPF_Source','N_Trials'});
    end
end

if isempty(T_lpf) && ~isempty(r3_runs)
    T_lpf = compute_r3_lpf_metrics(r3_runs);
end

if ~isempty(T_lpf)
    writetable(T_lpf, csv_path);
    fprintf('\n--- Raw vs 10 Hz LPF Ripple Reduction (R3) ---\n');
    disp(T_lpf);
end

if isempty(r3_runs)
    warn_msg = sprintf('No R3 .mat files found in %s; skipped Fig2 and Fig5.', r3_dir);
    return;
end

% Pick representative R3 run (prefer live LPF, then lowest trial number)
rep_idx = select_representative_r3(r3_runs);
D = extract_signals(r3_runs{rep_idx}.logsout);

act_std = (D.step_id >= 1 & D.step_id <= 6) & (D.is_steady > 0.5);
if any(act_std)
    f_r3 = round(median(D.target_freq(act_std)));
else
    f_r3 = 400;
end

if D.has_live_lpf
    lpf_leg = '10 Hz Butterworth LPF RPM (Live)';
    lpf_short = 'Live 10 Hz Butterworth LPF';
else
    lpf_leg = '10 Hz Butterworth LPF RPM (Offline)';
    lpf_short = '10 Hz Butterworth LPF (Offline)';
end

% ---- Fig 2: All 6 Drive Modes Time Series (Raw vs LPF vs Theory)
fh2 = figure('Visible', 'off', 'Color', [1 1 1], 'Position', [100 100 960 520]);
cleanup2 = onCleanup(@() close_if_valid(fh2));
ax2 = axes(fh2);
hold(ax2, 'on');

plot(ax2, D.t, D.rpm_meas, '-', 'Color', [0.72 0.84 0.98], 'LineWidth', 0.75, 'DisplayName', 'Raw Unfiltered RPM');
plot(ax2, D.t, D.rpm_meas_lpf, 'b-', 'LineWidth', 1.6, 'DisplayName', lpf_leg);
plot(ax2, D.t, D.rpm_theory, 'k--', 'LineWidth', 1.25, 'DisplayName', 'Theoretical RPM');

short_lbls = {'Full', '1/2', '1/4', '1/8', '1/16', '1/32'};
y_all_max = max([D.rpm_meas; D.rpm_meas_lpf; D.rpm_theory; 10], [], 'omitnan');
y_lbl_top = y_all_max;
for k = 1:6
    msk_std = (round(D.step_id) == k) & (D.is_steady > 0.5);
    msk_act = (round(D.step_id) == k);
    if any(msk_std)
        msk = msk_std;
    elseif any(msk_act)
        msk = msk_act;
    else
        continue;
    end
    x_mid = mean(D.t(msk));
    y_pk  = max([D.rpm_meas(msk); D.rpm_theory(msk)], [], 'omitnan');
    y_txt = y_pk + 0.03 * y_all_max;
    y_lbl_top = max(y_lbl_top, y_txt);
    text(ax2, x_mid, y_txt, short_lbls{k}, ...
        'HorizontalAlignment', 'center', 'VerticalAlignment', 'bottom', ...
        'FontWeight', 'bold', 'FontSize', 9.5, ...
        'BackgroundColor', [1 1 1], 'EdgeColor', 'none', 'Margin', 1.2);
end

xlim(ax2, [0, max(D.t)]);
ylim(ax2, [-0.04 * y_lbl_top, y_lbl_top * 1.15]);
grid(ax2, 'on');
box(ax2, 'on');
ax2.FontSize = 10.5;
xlabel(ax2, 'Time (s)', 'FontSize', 11.5);
ylabel(ax2, 'Motor Speed (RPM)', 'FontSize', 11.5);
title(ax2, sprintf('R3: All 6 DRV8825 Modes at %d Hz (Raw vs 10 Hz LPF)', f_r3), ...
    'FontSize', 12, 'FontWeight', 'bold');
legend(ax2, 'Location', 'northeast', 'FontSize', 9.5);

save_fig(fh2, f2_png, dpi);
clear cleanup2;
ok2 = true;

% ---- Fig 5: Zoomed Steady Window + Single-Sided FFT Spectrum
msk_fs = (round(D.step_id) == 1) & (D.is_steady > 0.5);
mode_fft_lbl = 'Full Step';
if ~any(msk_fs)
    for k = 2:6
        cand = (round(D.step_id) == k) & (D.is_steady > 0.5);
        if any(cand)
            msk_fs = cand;
            mode_fft_lbl = short_lbls{k};
            break;
        end
    end
end

if nnz(msk_fs) < 16
    warn_msg = 'R3 steady window too short for FFT; skipped Fig5_Raw_vs_LPF_FFT.png.';
    return;
end

t_fs  = D.t(msk_fs);
t_fs  = t_fs - t_fs(1);
rm_fs = D.rpm_meas(msk_fs);
rl_fs = D.rpm_meas_lpf(msk_fs);
rt_fs = D.rpm_theory(msk_fs);

dt_fs = median(diff(t_fs));
Fs    = 1.0 / max(dt_fs, 1e-6);
N     = numel(rm_fs);

Y_raw = abs(fft(rm_fs - mean(rm_fs)) / N);
P_raw = Y_raw(1:floor(N/2)+1);
if numel(P_raw) > 2, P_raw(2:end-1) = 2 * P_raw(2:end-1); end

Y_lpf = abs(fft(rl_fs - mean(rl_fs)) / N);
P_lpf = Y_lpf(1:floor(N/2)+1);
if numel(P_lpf) > 2, P_lpf(2:end-1) = 2 * P_lpf(2:end-1); end

fv = Fs * (0:floor(N/2))' / N;

sd_raw = std(rm_fs);
sd_lpf = std(rl_fs);
if sd_raw > 1e-9
    red_str = sprintf(', -%.1f%%', 100 * (1 - sd_lpf / sd_raw));
else
    red_str = '';
end

fh5 = figure('Visible', 'off', 'Color', [1 1 1], 'Position', [100 100 940 580]);
cleanup5 = onCleanup(@() close_if_valid(fh5));
tl5 = tiledlayout(fh5, 2, 1, 'TileSpacing', 'compact', 'Padding', 'compact');

% Top panel: Zoomed Time-Domain Steady Window
ax5a = nexttile(tl5, 1);
hold(ax5a, 'on');
plot(ax5a, t_fs, rm_fs, '-', 'Color', [0.68 0.82 0.98], 'LineWidth', 0.9, ...
    'DisplayName', sprintf('Raw Unfiltered (SD = %.2f RPM)', sd_raw));
plot(ax5a, t_fs, rl_fs, 'b-', 'LineWidth', 1.6, ...
    'DisplayName', sprintf('10 Hz LPF (SD = %.2f RPM%s)', sd_lpf, red_str));
plot(ax5a, t_fs, rt_fs, 'k--', 'LineWidth', 1.25, ...
    'DisplayName', sprintf('Theory (%.1f RPM)', mean(rt_fs)));

t_win = min(2.0, max(t_fs));
in_w  = t_fs <= t_win;
y_lo  = min([rm_fs(in_w); rl_fs(in_w); rt_fs(in_w)], [], 'omitnan');
y_hi  = max([rm_fs(in_w); rl_fs(in_w); rt_fs(in_w)], [], 'omitnan');
y_sp  = max(y_hi - y_lo, 10);
xlim(ax5a, [0, max(t_win, 0.1)]);
ylim(ax5a, [y_lo - 0.15 * y_sp, y_hi + 0.42 * y_sp]);
grid(ax5a, 'on');
box(ax5a, 'on');
ax5a.FontSize = 10.5;
xlabel(ax5a, 'Time in Steady Window (s)', 'FontSize', 11);
ylabel(ax5a, 'Speed (RPM)', 'FontSize', 11);
title(ax5a, sprintf('%s @ %d Hz: Raw Unfiltered vs %s', mode_fft_lbl, f_r3, lpf_short), ...
    'FontSize', 11.5, 'FontWeight', 'bold');
legend(ax5a, 'Location', 'northeast', 'FontSize', 9.5);

% Bottom panel: Single-Sided FFT Spectrum
ax5b = nexttile(tl5, 2);
hold(ax5b, 'on');
plot(ax5b, fv, P_raw, 'r-', 'LineWidth', 1.05, 'DisplayName', 'Raw Speed AC Spectrum');
plot(ax5b, fv, P_lpf, 'b-', 'LineWidth', 1.45, 'DisplayName', '10 Hz LPF AC Spectrum');

f_xmax = min(150, Fs / 2);
in_rng = (fv >= 2) & (fv <= f_xmax);
if any(in_rng)
    fv_r = fv(in_rng);
    pr_r = P_raw(in_rng);
    [pk_amp, pk_i] = max(pr_r);
    pk_f = fv_r(pk_i);
else
    pk_amp = max(P_raw);
    pk_f = 0;
end

y_fft_top = max(pk_amp * 1.28, 0.5);
xlim(ax5b, [0, f_xmax]);
ylim(ax5b, [0, y_fft_top]);

if 10 < f_xmax
    xline(ax5b, 10, 'k--', 'f_c = 10 Hz', 'LineWidth', 1.15, ...
        'LabelVerticalAlignment', 'top', 'LabelHorizontalAlignment', 'right', ...
        'HandleVisibility', 'off');
end

if pk_amp > 0.25 && pk_f > 0
    plot(ax5b, pk_f, pk_amp, 'ro', 'MarkerFaceColor', 'r', 'MarkerSize', 5, 'HandleVisibility', 'off');
    if abs(pk_f - f_r3 / 4) <= 3.0
        pk_lbl = sprintf('%.1f Hz (f_{step}/4)', pk_f);
    else
        pk_lbl = sprintf('Peak: %.1f Hz', pk_f);
    end
    if pk_f > 0.62 * f_xmax
        text(ax5b, pk_f - 0.02 * f_xmax, pk_amp * 1.03, pk_lbl, ...
            'HorizontalAlignment', 'right', 'VerticalAlignment', 'bottom', ...
            'FontSize', 9.5, 'FontWeight', 'bold', 'Color', [0.75 0.05 0.05]);
    else
        text(ax5b, pk_f + 0.02 * f_xmax, pk_amp * 1.03, pk_lbl, ...
            'HorizontalAlignment', 'left', 'VerticalAlignment', 'bottom', ...
            'FontSize', 9.5, 'FontWeight', 'bold', 'Color', [0.75 0.05 0.05]);
    end
end

grid(ax5b, 'on');
box(ax5b, 'on');
ax5b.FontSize = 10.5;
xlabel(ax5b, 'Frequency (Hz)', 'FontSize', 11);
ylabel(ax5b, 'Amplitude (RPM)', 'FontSize', 11);
title(ax5b, 'Single-Sided FFT Spectrum of Speed Ripple (DC Removed)', ...
    'FontSize', 11.5, 'FontWeight', 'bold');
legend(ax5b, 'Location', 'northeast', 'FontSize', 9.5);

save_fig(fh5, f5_png, dpi);
clear cleanup5;
ok5 = true;
end

function T = compute_r3_lpf_metrics(r3_runs)
mode_names = ["Full (1)"; "Half (1/2)"; "1/4"; "1/8"; "1/16"; "1/32"];
M_vals     = [1; 2; 4; 8; 16; 32];
nT = numel(r3_runs);

th_a  = nan(6, nT);
rm_a  = nan(6, nT);
rsd_a = nan(6, nT);
lm_a  = nan(6, nT);
lsd_a = nan(6, nT);
has_live = false(1, nT);

for tr = 1:nT
    D = extract_signals(r3_runs{tr}.logsout);
    has_live(tr) = D.has_live_lpf;
    for k = 1:6
        msk = (round(D.step_id) == k) & (D.is_steady > 0.5);
        if any(msk)
            th_a(k, tr)  = mean(D.rpm_theory(msk));
            rm_a(k, tr)  = mean(D.rpm_meas(msk));
            rsd_a(k, tr) = std(D.rpm_meas(msk));
            lm_a(k, tr)  = mean(D.rpm_meas_lpf(msk));
            lsd_a(k, tr) = std(D.rpm_meas_lpf(msk));
        end
    end
end

th_m   = mean(th_a, 2, 'omitnan');
raw_m  = mean(rm_a, 2, 'omitnan');
raw_sd = mean(rsd_a, 2, 'omitnan');
lpf_m  = mean(lm_a, 2, 'omitnan');
lpf_sd = mean(lsd_a, 2, 'omitnan');
red    = nan(6, 1);
valid  = raw_sd > 1e-9;
red(valid) = 100 * (1 - lpf_sd(valid) ./ raw_sd(valid));
shift  = lpf_m - raw_m;

if all(has_live)
    src_lbl = "live";
elseif ~any(has_live)
    src_lbl = "offline_fallback";
else
    src_lbl = "mixed";
end
n_tr_col = sum(~isnan(rm_a), 2);

T = table(mode_names, M_vals, th_m, raw_m, raw_sd, lpf_m, lpf_sd, red, shift, ...
    repmat(src_lbl, 6, 1), n_tr_col, ...
    'VariableNames', {'Mode','M','Theory_RPM','Raw_Mean_RPM','Raw_Ripple_SD', ...
    'LPF_Mean_RPM','LPF_Ripple_SD','Noise_Reduction_Pct','LPF_Mean_Shift_RPM','LPF_Source','N_Trials'});
end

function idx = select_representative_r3(r3_runs)
best_score = [-inf, -inf];
idx = 1;
for i = 1:numel(r3_runs)
    has_lpf = any(strcmp(r3_runs{i}.logsout.getElementNames, 'rpm_meas_lpf'));
    tr = 1;
    if isfield(r3_runs{i}.meta, 'trial') && ~isempty(r3_runs{i}.meta.trial)
        tr = double(r3_runs{i}.meta.trial);
    end
    sc = [double(has_lpf), -tr];
    if is_score_better(sc, best_score)
        best_score = sc;
        idx = i;
    end
end
end

% =========================================================================
% Figure 3: R8 Loss-Step / Speed Time Series (representative trial)
% =========================================================================
function [ok, warn_msg] = make_fig3_loss_step_timeseries(r8_mode_dirs, out_png, dpi)
ok = false;
warn_msg = '';

% Collect candidate R8 trials across mode_dirs (deduplicated by drive_mode + file)
cands = struct('drive_mode', {}, 'accel', {}, 'trial', {}, 'stalled', {}, ...
    'stall_time', {}, 'pullout_hz', {}, 'has_live_lpf', {}, 'filepath', {}, 'dir', {});
seen_fp = {};

for i = 1:numel(r8_mode_dirs)
    d = r8_mode_dirs(i).dir;
    dm_filter = r8_mode_dirs(i).drive_mode;
    trials_csv = fullfile(d, 'tables', 'R8_trials.csv');

    if isfile(trials_csv)
        T = readtable(trials_csv, 'TextType', 'string');
        for r = 1:height(T)
            dm = round(to_num_col(T.Drive_Mode(r)));
            if dm_filter > 0 && dm ~= dm_filter, continue; end
            sf = strtrim(char(T.Source_File(r)));
            fp = fullfile(d, sf);
            if ~isfile(fp), continue; end
            if any(strcmp(seen_fp, fp)), continue; end
            seen_fp{end+1} = fp; %#ok<AGROW>
            cands(end+1) = struct( ...
                'drive_mode',   dm, ...
                'accel',        round(to_num_col(T.Accel_Hz_s(r))), ...
                'trial',        round(to_num_col(T.Trial(r))), ...
                'stalled',      to_num_col(T.Stalled(r)) > 0.5, ...
                'stall_time',   to_num_col(T.Stall_Time_s(r)), ...
                'pullout_hz',   to_num_col(T.PullOut_Freq_Hz(r)), ...
                'has_live_lpf', mat_has_live_lpf(fp), ...
                'filepath',     fp, ...
                'dir',          d); %#ok<AGROW>
        end
    else
        % Legacy fallback: scan R8 .mat files directly
        runs = load_runs_for_lab(d, 'R8');
        for r = 1:numel(runs)
            dm = 1;
            if isfield(runs{r}.meta, 'drive_mode'), dm = round(double(runs{r}.meta.drive_mode)); end
            if dm_filter > 0 && dm ~= dm_filter, continue; end
            fp = fullfile(d, runs{r}.filename);
            if any(strcmp(seen_fp, fp)), continue; end
            seen_fp{end+1} = fp; %#ok<AGROW>
            D = extract_signals(runs{r}.logsout);
            [stalled, t_st, f_st] = detect_r8_stall(D);
            ac = 0;
            if isfield(runs{r}.meta, 'accel'), ac = round(double(runs{r}.meta.accel)); end
            tr = r;
            if isfield(runs{r}.meta, 'trial'), tr = round(double(runs{r}.meta.trial)); end
            cands(end+1) = struct( ...
                'drive_mode',   dm, ...
                'accel',        ac, ...
                'trial',        tr, ...
                'stalled',      stalled, ...
                'stall_time',   t_st, ...
                'pullout_hz',   f_st, ...
                'has_live_lpf', D.has_live_lpf, ...
                'filepath',     fp, ...
                'dir',          d); %#ok<AGROW>
        end
    end
end

if isempty(cands)
    warn_msg = 'No R8 .mat run files available; skipped Fig3_R6_R8_LossStep_TimeSeries.png.';
    return;
end

% Rank candidates dynamically:
% 1) Stalled trial preferred (clearly illustrates loss-step)
% 2) Full Step (drive_mode == 1) preferred
% 3) Accel == 2000 Hz/s preferred (representative mid-high ramp)
% 4) Live LPF preferred
% 5) Closest pull-out frequency to group median (avoids outlier trial)
% 6) Lower trial number as deterministic tie-breaker
best_i = 1;
best_score = -inf(1, 6);
for i = 1:numel(cands)
    c = cands(i);
    same_grp = ([cands.drive_mode] == c.drive_mode) & ([cands.accel] == c.accel) & ([cands.stalled] == c.stalled);
    grp_med = median([cands(same_grp).pullout_hz], 'omitnan');
    dist_med = abs(c.pullout_hz - grp_med);
    if ~isfinite(dist_med), dist_med = 0; end
    sc = [double(c.stalled), double(c.drive_mode == 1), double(c.accel == 2000), ...
          double(c.has_live_lpf), -dist_med, -c.trial];
    if is_score_better(sc, best_score)
        best_score = sc;
        best_i = i;
    end
end

chosen = cands(best_i);
S8 = load(chosen.filepath);
D  = extract_signals(S8.logsout);

% Ensure stall time & frequency are populated if trial stalled
if chosen.stalled && (~isfinite(chosen.stall_time) || ~isfinite(chosen.pullout_hz))
    [chosen.stalled, chosen.stall_time, chosen.pullout_hz] = detect_r8_stall(D);
end

act_idx = find((round(D.step_id) == 1) | (D.freq_cmd > 1));
if ~isempty(act_idx)
    x_max = min(max(D.t), D.t(act_idx(end)) + 1.0);
else
    x_max = max(D.t);
end
x_max = max(x_max, 1.0);

mode_str = mode_short_title(chosen.drive_mode);
if D.has_live_lpf
    lpf_leg = '10 Hz LPF RPM (Live)';
else
    lpf_leg = '10 Hz LPF RPM (Offline)';
end

fh = figure('Visible', 'off', 'Color', [1 1 1], 'Position', [100 100 940 660]);
cleanup = onCleanup(@() close_if_valid(fh));
tl = tiledlayout(fh, 3, 1, 'TileSpacing', 'compact', 'Padding', 'compact');

% Panel 1: Commanded vs Echo Frequency
ax1 = nexttile(tl, 1);
hold(ax1, 'on');
plot(ax1, D.t, D.freq_cmd, 'b-', 'LineWidth', 1.4, 'DisplayName', 'f_{cmd}');
plot(ax1, D.t, D.f_echo, 'r--', 'LineWidth', 1.1, 'DisplayName', 'f_{echo}');
if chosen.stalled && isfinite(chosen.stall_time)
    h_align = 'right';
    if chosen.stall_time > 0.72 * x_max
        h_align = 'left';
    end
    xline(ax1, chosen.stall_time, 'm--', ...
        sprintf('Pull-Out: %.0f Hz\n(t = %.2f s)', chosen.pullout_hz, chosen.stall_time), ...
        'LineWidth', 1.2, 'LabelOrientation', 'horizontal', ...
        'LabelVerticalAlignment', 'bottom', ...
        'LabelHorizontalAlignment', h_align, 'HandleVisibility', 'off');
end
xlim(ax1, [0, x_max]);
ylim(ax1, [0, max([D.freq_cmd; D.f_echo; 100], [], 'omitnan') * 1.18]);
grid(ax1, 'on'); box(ax1, 'on'); ax1.FontSize = 10;
ylabel(ax1, 'Frequency (Hz)', 'FontSize', 11);
if chosen.stalled
    t_suffix = '';
else
    t_suffix = ' — No Stall';
end
title(ax1, sprintf('R8: Loss-Step Time Series (%s, Accel = %d Hz/s, Trial %d%s)', ...
    mode_str, chosen.accel, chosen.trial, t_suffix), 'FontSize', 11.5, 'FontWeight', 'bold');
legend(ax1, 'Location', 'northwest', 'FontSize', 9.5);

% Panel 2: Raw, LPF, and Theory RPM
ax2 = nexttile(tl, 2);
hold(ax2, 'on');
plot(ax2, D.t, D.rpm_meas, '-', 'Color', [0.70 0.83 0.98], 'LineWidth', 0.8, 'DisplayName', 'Raw RPM');
plot(ax2, D.t, D.rpm_meas_lpf, 'b-', 'LineWidth', 1.55, 'DisplayName', lpf_leg);
plot(ax2, D.t, D.rpm_theory, 'k--', 'LineWidth', 1.25, 'DisplayName', 'Theory RPM');
if chosen.stalled && isfinite(chosen.stall_time)
    xline(ax2, chosen.stall_time, 'm--', 'LineWidth', 1.2, 'HandleVisibility', 'off');
end
xlim(ax2, [0, x_max]);
ylim(ax2, [0, max([D.rpm_theory; D.rpm_meas_lpf; 50], [], 'omitnan') * 1.15]);
grid(ax2, 'on'); box(ax2, 'on'); ax2.FontSize = 10;
ylabel(ax2, 'Speed (RPM)', 'FontSize', 11);
legend(ax2, 'Location', 'northwest', 'FontSize', 9.5);

% Panel 3: Lost Full Steps
ax3 = nexttile(tl, 3);
hold(ax3, 'on');
plot(ax3, D.t, D.lost_steps, 'r-', 'LineWidth', 1.45, 'DisplayName', 'Lost Full Steps');
if chosen.stalled && isfinite(chosen.stall_time)
    xline(ax3, chosen.stall_time, 'm--', 'LineWidth', 1.2, 'HandleVisibility', 'off');
end
xlim(ax3, [0, x_max]);
ls_max = max(D.lost_steps, [], 'omitnan');
ls_min = min(D.lost_steps, [], 'omitnan');
if isfinite(ls_max) && isfinite(ls_min) && ls_max > ls_min
    ylim(ax3, [min(0, ls_min * 1.08), ls_max * 1.12]);
end
grid(ax3, 'on'); box(ax3, 'on'); ax3.FontSize = 10;
xlabel(ax3, 'Time (s)', 'FontSize', 11);
ylabel(ax3, 'Lost Steps (full)', 'FontSize', 11);
legend(ax3, 'Location', 'northwest', 'FontSize', 9.5);

save_fig(fh, out_png, dpi);
clear cleanup;
ok = true;
end

function [stalled, t_stall, f_stall] = detect_r8_stall(D)
% Exact match to analyze_stepper_labs.m causal 80 ms + 20 ms backtrack onset detector
m = (round(D.step_id) == 1) & (D.is_steady > 0.5) & (D.freq_cmd > 250);
if ~any(m)
    stalled = false; t_stall = NaN; f_stall = max(D.f_echo);
    return;
end
dt_med = median(diff(D.t));
win_n  = max(1, round(0.08 / max(dt_med, 1e-4)));
rm_win = movmean(D.rpm_meas, [win_n-1, 0]);
rt_win = movmean(D.rpm_theory, [win_n-1, 0]);
bad    = m & (rt_win > 40) & (rm_win < 0.70 * rt_win);
idx    = find(bad, 1, 'first');
if ~isempty(idx)
    rm_s = movmean(D.rpm_meas, max(1, round(0.02 / max(dt_med, 1e-4))));
    j = idx;
    while j > 1 && m(j-1) && rm_s(j-1) < 0.9 * D.rpm_theory(j-1)
        j = j - 1;
    end
    stalled = true;
    t_stall = D.t(j);
    f_stall = D.f_echo(j);
else
    stalled = false;
    t_stall = NaN;
    f_stall = max(D.f_echo(m));
end
end

% =========================================================================
% Figure 4: R8 (+ R6 Pull-In) Acceleration Limit vs Pull-Out Frequency
% =========================================================================
function [ok, warn_msg] = make_fig4_accel_vs_pullout(r8_mode_dirs, r6_mode_dirs, out_png, dpi)
ok = false;
warn_msg = '';

T = load_canonical_r8_table(r8_mode_dirs, r6_mode_dirs);
if isempty(T) || height(T) == 0
    warn_msg = 'No R6/R8 pull-out summary data found; skipped Fig4_R8_Accel_vs_PullOut.png.';
    return;
end

modes_u = sort(unique(T.Drive_Mode));
nM = numel(modes_u);

% Order conditions: Step Input (Inf) first, then finite accels ascending (500, 1000, 2000, 4000)
has_step  = any(isinf(T.Accel_Hz_s));
fin_accs  = sort(unique(T.Accel_Hz_s(isfinite(T.Accel_Hz_s))), 'ascend');
cond_accs = fin_accs(:)';
if has_step
    cond_accs = [Inf, cond_accs];
end
nC = numel(cond_accs);

x_labels = cell(1, nC);
for ic = 1:nC
    if isinf(cond_accs(ic))
        x_labels{ic} = 'Step Input\newline(Pull-In)';
    else
        x_labels{ic} = sprintf('%d Hz/s', round(cond_accs(ic)));
    end
end

Y_mean = nan(nC, nM);
Y_sd   = nan(nC, nM);
Cens   = zeros(nC, nM);
N_tr   = zeros(nC, nM);
Ceil   = nan(nC, nM);

for m = 1:nM
    dm = modes_u(m);
    for ic = 1:nC
        if isinf(cond_accs(ic))
            idx = (T.Drive_Mode == dm) & isinf(T.Accel_Hz_s);
        else
            idx = (T.Drive_Mode == dm) & (abs(T.Accel_Hz_s - cond_accs(ic)) < 1e-3);
        end
        if any(idx)
            r = find(idx, 1, 'first');
            Y_mean(ic, m) = T.MaxFreq_Mean_Hz(r);
            Y_sd(ic, m)   = T.MaxFreq_SD_Hz(r);
            Cens(ic, m)   = T.N_Censored(r);
            N_tr(ic, m)   = T.N_Trials(r);
            Ceil(ic, m)   = T.Ceiling_Hz(r);
        end
    end
end
Y_sd(~isfinite(Y_sd)) = 0;

bar_colors = [0.18 0.45 0.76;   % Mode 1 Full: blue
              0.85 0.38 0.14;   % Mode 2 Half: orange-red
              0.16 0.58 0.24;   % Mode 3 1/4:  green
              0.49 0.22 0.58;   % Mode 4 1/8:  purple
              0.82 0.62 0.05;   % Mode 5 1/16: gold
              0.72 0.10 0.20];  % Mode 6 1/32: crimson

fh = figure('Visible', 'off', 'Color', [1 1 1], 'Position', [100 100 940 520]);
cleanup = onCleanup(@() close_if_valid(fh));
ax = axes(fh);

b = bar(ax, 1:nC, Y_mean, 'grouped');
hold(ax, 'on');

ramp_mask = isfinite(cond_accs(:));
mode_title_parts = cell(1, nM);
for m = 1:nM
    dm = modes_u(m);
    col = bar_colors(min(dm, size(bar_colors, 1)), :);
    b(m).FaceColor = col;
    b(m).EdgeColor = [0.2 0.2 0.2];
    b(m).LineWidth = 0.7;

    base_name = mode_long_label(dm);
    mode_title_parts{m} = mode_short_title(dm);

    % Dynamic legend note if ramps reached MaxFreq ceiling without stalling
    rm_valid = ramp_mask & (N_tr(:, m) > 0);
    if any(rm_valid) && all(Cens(rm_valid, m) == N_tr(rm_valid, m))
        c_max = max(Ceil(rm_valid, m), [], 'omitnan');
        if isfinite(c_max)
            b(m).DisplayName = sprintf('%s (no stall up to %.0f Hz ceiling)', base_name, c_max);
        else
            b(m).DisplayName = sprintf('%s (no stall up to MaxFreq)', base_name);
        end
    elseif any(rm_valid & (Cens(:, m) > 0))
        c_max = max(Ceil(rm_valid & (Cens(:, m) > 0), m), [], 'omitnan');
        if isfinite(c_max)
            b(m).DisplayName = sprintf('%s (\\geq%.0f Hz ceiling where marked)', base_name, c_max);
        else
            b(m).DisplayName = sprintf('%s (censored where marked)', base_name);
        end
    else
        b(m).DisplayName = base_name;
    end

    % Errorbars (skip fully censored bars with 0 SD to keep >= annotation crisp)
    xe = b(m).XEndPoints;
    ym = Y_mean(:, m);
    ys = Y_sd(:, m);
    eb_mask = isfinite(ym) & ~(Cens(:, m) > 0 & Cens(:, m) == N_tr(:, m) & ys == 0);
    if any(eb_mask)
        errorbar(ax, xe(eb_mask), ym(eb_mask), ys(eb_mask), 'k.', ...
            'LineWidth', 1.4, 'CapSize', 7, 'HandleVisibility', 'off');
    end
end

% Ceiling reference line(s) only when censoring occurs
cens_mask = (Cens > 0) & isfinite(Ceil);
y_top = max(Y_mean(:) + Y_sd(:), [], 'omitnan');
if any(cens_mask(:))
    u_ceils = unique(round(Ceil(cens_mask)));
    y_top = max(y_top, max(u_ceils));
    for k = 1:numel(u_ceils)
        c_hz = u_ceils(k);
        yline(ax, c_hz, 'k:', sprintf('Ramp Ceiling (%.0f Hz)', c_hz), ...
            'LineWidth', 1.2, 'LabelHorizontalAlignment', 'left', ...
            'LabelVerticalAlignment', 'bottom', 'HandleVisibility', 'off');
    end
end
if ~isfinite(y_top) || y_top <= 0, y_top = 1000; end

% Annotate bar values / censored flags cleanly without colliding with errorbar caps or ceiling lines
for m = 1:nM
    xe = b(m).XEndPoints;
    for ic = 1:nC
        ym = Y_mean(ic, m);
        ys = Y_sd(ic, m);
        if ~isfinite(ym), continue; end
        if Cens(ic, m) > 0 && isfinite(Ceil(ic, m))
            y_ann = ym + ys + 0.022 * y_top;
            if Cens(ic, m) == N_tr(ic, m)
                lbl = sprintf('\\geq%.0f', Ceil(ic, m));
            else
                lbl = sprintf('%.0f\n(%d/%d \\geq%.0f)', ym, Cens(ic, m), N_tr(ic, m), Ceil(ic, m));
            end
            text(ax, xe(ic), y_ann, lbl, 'HorizontalAlignment', 'center', ...
                'VerticalAlignment', 'bottom', 'FontSize', 8.5, 'FontWeight', 'bold', ...
                'Color', [0.55 0.18 0.0]);
        elseif (ym - ys) >= 0.24 * y_top
            % Place numeric label inside the lower body of tall bars, well below the lower errorbar cap
            y_in = 0.52 * (ym - ys);
            text(ax, xe(ic), y_in, sprintf('%.0f', ym), 'HorizontalAlignment', 'center', ...
                'VerticalAlignment', 'middle', 'FontSize', 8.5, 'FontWeight', 'bold', ...
                'Color', [1 1 1]);
        else
            y_ann = ym + ys + 0.025 * y_top;
            text(ax, xe(ic), y_ann, sprintf('%.0f', ym), 'HorizontalAlignment', 'center', ...
                'VerticalAlignment', 'bottom', 'FontSize', 8.5, 'FontWeight', 'bold', ...
                'Color', [0.15 0.15 0.15]);
        end
    end
end

set(ax, 'XTick', 1:nC, 'XTickLabel', x_labels, 'TickLabelInterpreter', 'tex');
ylim(ax, [0, y_top * 1.28]);
grid(ax, 'on');
box(ax, 'on');
ax.FontSize = 10.5;
ylabel(ax, 'Max Frequency Before Loss Step (Hz)', 'FontSize', 11.5);
title(ax, sprintf('R8: Acceleration Limit vs Pull-Out Frequency (%s, Mean \\pm SD)', ...
    strjoin(mode_title_parts, ' vs ')), 'FontSize', 11.5, 'FontWeight', 'bold');
legend(ax, 'Location', 'northwest', 'FontSize', 9.5);

save_fig(fh, out_png, dpi);
clear cleanup;
ok = true;
end

function T_all = load_canonical_r8_table(r8_mode_dirs, r6_mode_dirs)
rows = cell(0, 12);
seen_key = {};

% 1) Read finite-accel R8 rows from r8_mode_dirs (and R6 Step Input if unified same folder)
for i = 1:numel(r8_mode_dirs)
    d = r8_mode_dirs(i).dir;
    dm_filter = r8_mode_dirs(i).drive_mode;
    csv_path = fullfile(d, 'tables', 'R8_accel_pullout.csv');
    if ~isfile(csv_path), continue; end
    T = readtable(csv_path, 'TextType', 'string');
    if height(T) == 0, continue; end

    T_norm = normalize_r8_table(T, d, dm_filter);
    for r = 1:height(T_norm)
        dm = T_norm.Drive_Mode(r);
        ac = T_norm.Accel_Hz_s(r);
        if dm_filter > 0 && dm ~= dm_filter, continue; end
        % If Step Input (Inf) is also in a dedicated r6_mode_dirs entry for this mode,
        % only accept Inf here if this dir IS that r6 dir (or no r6 dir for this mode).
        if isinf(ac) && has_different_r6_dir(r6_mode_dirs, dm, d)
            continue;
        end
        key = sprintf('%d_%g', dm, ac);
        if any(strcmp(seen_key, key)), continue; end
        seen_key{end+1} = key; %#ok<AGROW>
        rows(end+1, :) = table2cell(T_norm(r, :)); %#ok<AGROW>
    end
end

% 2) Ensure R6 Step Input (Pull-In, Accel_Hz_s = Inf) is populated from r6_mode_dirs
T_r6 = load_canonical_r6_summary(r6_mode_dirs);
for r = 1:height(T_r6)
    dm = T_r6.Drive_Mode(r);
    key = sprintf('%d_Inf', dm);
    if any(strcmp(seen_key, key)), continue; end
    seen_key{end+1} = key; %#ok<AGROW>
    rows(end+1, :) = {dm, char(T_r6.Mode(r)), T_r6.Microstep_M(r), ...
        'Step Input (No Limit)', Inf, T_r6.PullIn_Mean_Hz(r), T_r6.PullIn_SD_Hz(r), ...
        T_r6.PullIn_Speed_RPM(r), T_r6.N_Trials(r), T_r6.N_Stalled_Trials(r), ...
        T_r6.N_Censored(r), T_r6.Max_Tested_Hz(r)}; %#ok<AGROW>
end

if isempty(rows)
    T_all = table();
    return;
end

T_all = cell2table(rows, 'VariableNames', { ...
    'Drive_Mode','Mode','Microstep_M','Condition','Accel_Hz_s', ...
    'MaxFreq_Mean_Hz','MaxFreq_SD_Hz','MaxSpeed_RPM', ...
    'N_Trials','N_Stalled','N_Censored','Ceiling_Hz'});
T_all.Mode      = string(T_all.Mode);
T_all.Condition = string(T_all.Condition);
end

function tf = has_different_r6_dir(r6_mode_dirs, dm, cur_dir)
tf = false;
for k = 1:numel(r6_mode_dirs)
    if (r6_mode_dirs(k).drive_mode == dm || r6_mode_dirs(k).drive_mode == 0) && ~strcmp(r6_mode_dirs(k).dir, cur_dir)
        tf = true;
        return;
    end
end
end

function Tn = normalize_r8_table(T, folder, dm_hint)
n = height(T);
vars = T.Properties.VariableNames;

if ismember('Drive_Mode', vars)
    dm_col = round(to_num_col(T.Drive_Mode));
else
    dm_guess = dm_hint;
    if dm_guess <= 0
        dm_guess = infer_mode_from_folder(folder, 'R8');
    end
    dm_col = dm_guess * ones(n, 1);
end

M_col = 2.^(dm_col - 1);
if ismember('Microstep_M', vars)
    M_col = round(to_num_col(T.Microstep_M));
end

mode_col = strings(n, 1);
if ismember('Mode', vars)
    mode_col = string(T.Mode);
else
    for k = 1:n
        mode_col(k) = string(canonical_mode_name(dm_col(k)));
    end
end

cond_col = string(T.Condition);
acc_col  = to_num_col(T.Accel_Hz_s);
fm_col   = to_num_col(T.MaxFreq_Mean_Hz);
fs_col   = to_num_col(T.MaxFreq_SD_Hz);
spd_col  = to_num_col(T.MaxSpeed_RPM);
nt_col   = to_num_col(T.N_Trials);

if ismember('Ceiling_Hz', vars)
    ceil_col = to_num_col(T.Ceiling_Hz);
else
    ceil_val = infer_r8_ceiling_from_folder(folder);
    ceil_col = ceil_val * ones(n, 1);
    ceil_col(isinf(acc_col)) = NaN;
end

if ismember('N_Censored', vars) && ismember('N_Stalled', vars)
    nc_col = to_num_col(T.N_Censored);
    ns_col = to_num_col(T.N_Stalled);
else
    nc_col = zeros(n, 1);
    ns_col = nt_col;
    for k = 1:n
        if isfinite(acc_col(k)) && isfinite(ceil_col(k)) && ...
           abs(fm_col(k) - ceil_col(k)) <= 10 && fs_col(k) <= 1
            nc_col(k) = nt_col(k);
            ns_col(k) = 0;
        end
    end
end

Tn = table(dm_col, mode_col, M_col, cond_col, acc_col, fm_col, fs_col, spd_col, ...
    nt_col, ns_col, nc_col, ceil_col, 'VariableNames', { ...
    'Drive_Mode','Mode','Microstep_M','Condition','Accel_Hz_s', ...
    'MaxFreq_Mean_Hz','MaxFreq_SD_Hz','MaxSpeed_RPM', ...
    'N_Trials','N_Stalled','N_Censored','Ceiling_Hz'});
end

function dm = infer_mode_from_folder(folder, lab_name)
dm = 1;
mats = list_run_mat_files(folder);
for i = 1:numel(mats)
    M = load_meta_only(fullfile(folder, mats(i).name));
    if ~isempty(M) && isfield(M, 'lab') && strcmpi(char(M.lab), lab_name) && isfield(M, 'drive_mode')
        dm = round(double(M.drive_mode));
        return;
    end
end
end

function fmax = infer_r8_ceiling_from_folder(folder)
fmax = NaN;
mats = list_run_mat_files(folder);
for i = 1:numel(mats)
    M = load_meta_only(fullfile(folder, mats(i).name));
    if ~isempty(M) && isfield(M, 'lab') && strcmpi(char(M.lab), 'R8') && isfield(M, 'max_freq')
        fmax = double(M.max_freq);
        return;
    end
end
end

% =========================================================================
% Figure 6: R6 Pull-In Comparison (Full Step vs Half Step)
% =========================================================================
function [ok, warn_msg] = make_fig6_r6_pullin(r6_mode_dirs, out_png, dpi)
ok = false;
warn_msg = '';

T_steps = load_canonical_r6_steps(r6_mode_dirs);
T_sum   = load_canonical_r6_summary(r6_mode_dirs);
T_tr    = load_canonical_r6_trials(r6_mode_dirs);

if isempty(T_steps) && isempty(T_sum)
    warn_msg = 'No R6 pull-in tables found; skipped Fig6_R6_PullIn_Full_vs_Half.png.';
    return;
end

modes_u = [];
if ~isempty(T_sum),   modes_u = unique([modes_u; T_sum.Drive_Mode]); end
if ~isempty(T_steps), modes_u = unique([modes_u; T_steps.Drive_Mode]); end
modes_u = sort(modes_u);
nM = numel(modes_u);

bar_colors = [0.18 0.45 0.76;
              0.85 0.38 0.14;
              0.16 0.58 0.24;
              0.49 0.22 0.58;
              0.82 0.62 0.05;
              0.72 0.10 0.20];
mkrs = {'o', 's', '^', 'd', 'v', 'p'};
mode_titles = arrayfun(@mode_short_title, modes_u, 'UniformOutput', false);

fh = figure('Visible', 'off', 'Color', [1 1 1], 'Position', [80 80 1060 470]);
cleanup = onCleanup(@() close_if_valid(fh));

if ~isempty(T_steps) && ~isempty(T_sum)
    tl = tiledlayout(fh, 1, 2, 'TileSpacing', 'compact', 'Padding', 'compact');
    ax1 = nexttile(tl, 1);
    ax2 = nexttile(tl, 2);
else
    tl = tiledlayout(fh, 1, 1, 'TileSpacing', 'compact', 'Padding', 'compact');
    if ~isempty(T_steps)
        ax1 = nexttile(tl, 1); ax2 = [];
    else
        ax1 = []; ax2 = nexttile(tl, 1);
    end
end

% ---- Left Panel: Normalized Speed Tracking vs Step-Input Frequency
if ~isempty(ax1)
    hold(ax1, 'on');
    max_ratio = 110;
    all_fq = [];
    for m = 1:nM
        dm = modes_u(m);
        sub = T_steps(T_steps.Drive_Mode == dm, :);
        if height(sub) == 0, continue; end
        fqs = sort(unique(sub.Freq_Hz));
        all_fq = unique([all_fq; fqs]);
        rm_pct = nan(size(fqs));
        rs_pct = nan(size(fqs));
        for k = 1:numel(fqs)
            s_f = sub(abs(sub.Freq_Hz - fqs(k)) < 1e-3, :);
            ratio = 100 * s_f.Meas_RPM ./ max(s_f.Theory_RPM, 1e-9);
            rm_pct(k) = mean(ratio, 'omitnan');
            rs_pct(k) = std(ratio, 0, 'omitnan');
        end
        rs_pct(~isfinite(rs_pct)) = 0;
        max_ratio = max(max_ratio, max(rm_pct + rs_pct, [], 'omitnan'));

        col = bar_colors(min(dm, size(bar_colors, 1)), :);
        mkr = mkrs{min(dm, numel(mkrs))};
        errorbar(ax1, fqs, rm_pct, rs_pct, ['-' mkr], ...
            'Color', col, 'MarkerFaceColor', col, ...
            'LineWidth', 1.55, 'MarkerSize', 5.5, 'CapSize', 5, ...
            'DisplayName', mode_long_label(dm));
    end

    yline(ax1, 100, 'k:', '100% Theory', 'LineWidth', 1.1, ...
        'LabelHorizontalAlignment', 'right', 'LabelVerticalAlignment', 'bottom', 'HandleVisibility', 'off');
    yline(ax1, 85, 'r--', '85% Stall Threshold', 'LineWidth', 1.2, ...
        'LabelHorizontalAlignment', 'right', 'LabelVerticalAlignment', 'bottom', 'HandleVisibility', 'off');

    if numel(all_fq) >= 2
        df = min(diff(all_fq));
        xlim(ax1, [min(all_fq) - 0.35*df, max(all_fq) + 0.35*df]);
    end
    ylim(ax1, [0, max(125, max_ratio * 1.12)]);
    grid(ax1, 'on'); box(ax1, 'on'); ax1.FontSize = 10;
    xlabel(ax1, 'Step-Input Frequency from Rest (Hz)', 'FontSize', 11);
    ylabel(ax1, 'Measured / Theoretical Speed (%)', 'FontSize', 11);
    title(ax1, 'Pull-In Ladder: Speed Tracking (Mean \pm SD)', 'FontSize', 11.5, 'FontWeight', 'bold');
    legend(ax1, 'Location', 'southwest', 'FontSize', 9.5);
end

% ---- Right Panel: Pull-In Frequency Bar Summary + Individual Trials
if ~isempty(ax2)
    hold(ax2, 'on');
    means = nan(1, nM);
    sds   = zeros(1, nM);
    rpms  = nan(1, nM);
    nts   = zeros(1, nM);
    cens  = zeros(1, nM);
    max_t = nan(1, nM);
    x_lbl = cell(1, nM);

    y_hi = 100;
    for m = 1:nM
        dm = modes_u(m);
        x_lbl{m} = mode_long_label(dm);
        idx = find(T_sum.Drive_Mode == dm, 1, 'first');
        if isempty(idx), continue; end
        means(m) = T_sum.PullIn_Mean_Hz(idx);
        sds(m)   = T_sum.PullIn_SD_Hz(idx);
        if ~isfinite(sds(m)), sds(m) = 0; end
        rpms(m)  = T_sum.PullIn_Speed_RPM(idx);
        nts(m)   = T_sum.N_Trials(idx);
        cens(m)  = T_sum.N_Censored(idx);
        max_t(m) = T_sum.Max_Tested_Hz(idx);

        col = bar_colors(min(dm, size(bar_colors, 1)), :);
        bar(ax2, m, means(m), 0.52, 'FaceColor', col, 'EdgeColor', [0.2 0.2 0.2], ...
            'LineWidth', 0.8, 'HandleVisibility', 'off');
        errorbar(ax2, m, means(m), sds(m), 'k.', 'LineWidth', 1.5, 'CapSize', 8, 'HandleVisibility', 'off');

        trial_max = means(m) + sds(m);
        if ~isempty(T_tr)
            tr_vals = T_tr.PullIn_Hz(T_tr.Drive_Mode == dm);
            tr_vals = tr_vals(isfinite(tr_vals));
            if ~isempty(tr_vals)
                if isscalar(tr_vals)
                    jit = 0;
                else
                    jit = linspace(-0.12, 0.12, numel(tr_vals));
                end
                plot(ax2, m + jit, tr_vals, 'ko', 'MarkerFaceColor', [0.15 0.15 0.15], ...
                    'MarkerSize', 5, 'HandleVisibility', 'off');
                trial_max = max(trial_max, max(tr_vals));
            end
        end
        y_hi = max(y_hi, trial_max);

        if cens(m) > 0 && isfinite(max_t(m))
            ann = sprintf('%.1f \\pm %.1f Hz\n(%.0f RPM, %d/%d \\geq%.0f)', ...
                means(m), sds(m), rpms(m), cens(m), nts(m), max_t(m));
        else
            ann = sprintf('%.1f \\pm %.1f Hz\n(%.0f RPM, n=%d)', ...
                means(m), sds(m), rpms(m), nts(m));
        end
        text(ax2, m, trial_max + 0.04 * max(y_hi, 100), ann, ...
            'HorizontalAlignment', 'center', 'VerticalAlignment', 'bottom', ...
            'FontSize', 9, 'FontWeight', 'bold', 'Color', [0.12 0.12 0.12]);
    end

    % Dummy marker for trial scatter legend if trials plotted
    if ~isempty(T_tr) && height(T_tr) > 0
        plot(ax2, NaN, NaN, 'ko', 'MarkerFaceColor', [0.15 0.15 0.15], ...
            'MarkerSize', 5, 'DisplayName', 'Individual Trials');
        legend(ax2, 'Location', 'northwest', 'FontSize', 9);
    end

    set(ax2, 'XTick', 1:nM, 'XTickLabel', x_lbl);
    xlim(ax2, [0.4, nM + 0.6]);
    ylim(ax2, [0, y_hi * 1.34]);
    grid(ax2, 'on'); box(ax2, 'on'); ax2.FontSize = 10;
    ylabel(ax2, 'Pull-In Frequency (Hz)', 'FontSize', 11);
    title(ax2, 'Pull-In Frequency Summary (Mean \pm SD)', 'FontSize', 11.5, 'FontWeight', 'bold');
end

title(tl, sprintf('R6: Step-Input Pull-In Performance (%s)', strjoin(mode_titles, ' vs ')), ...
    'FontSize', 12.5, 'FontWeight', 'bold');

save_fig(fh, out_png, dpi);
clear cleanup;
ok = true;
end

function T_all = load_canonical_r6_steps(r6_mode_dirs)
parts = {};
for i = 1:numel(r6_mode_dirs)
    d = r6_mode_dirs(i).dir;
    dm_filter = r6_mode_dirs(i).drive_mode;
    fp = fullfile(d, 'tables', 'R6_pullin_steps.csv');
    if ~isfile(fp), continue; end
    T = readtable(fp, 'TextType', 'string');
    if height(T) == 0, continue; end

    vars = T.Properties.VariableNames;
    n = height(T);
    if ismember('Drive_Mode', vars)
        dm_col = round(to_num_col(T.Drive_Mode));
    else
        dm_guess = dm_filter;
        if dm_guess <= 0
            dm_guess = infer_mode_from_folder(d, 'R6');
        end
        dm_col = dm_guess * ones(n, 1);
    end
    keep = (dm_filter <= 0) | (dm_col == dm_filter);
    if ~any(keep), continue; end

    T_sub = table(dm_col(keep), to_num_col(T.Trial(keep)), to_num_col(T.Freq_Hz(keep)), ...
        to_num_col(T.Theory_RPM(keep)), to_num_col(T.Meas_RPM(keep)), to_num_col(T.Stalled(keep)) > 0.5, ...
        'VariableNames', {'Drive_Mode','Trial','Freq_Hz','Theory_RPM','Meas_RPM','Stalled'});
    parts{end+1} = T_sub; %#ok<AGROW>
end

if isempty(parts)
    T_all = table();
else
    T_all = vertcat(parts{:});
end
end

function T_all = load_canonical_r6_trials(r6_mode_dirs)
parts = {};
for i = 1:numel(r6_mode_dirs)
    d = r6_mode_dirs(i).dir;
    dm_filter = r6_mode_dirs(i).drive_mode;
    fp = fullfile(d, 'tables', 'R6_pullin_trials.csv');
    if isfile(fp)
        T = readtable(fp, 'TextType', 'string');
        if height(T) == 0, continue; end
        dm_col = round(to_num_col(T.Drive_Mode));
        keep = (dm_filter <= 0) | (dm_col == dm_filter);
        if ~any(keep), continue; end
        parts{end+1} = table(dm_col(keep), to_num_col(T.Trial(keep)), ...
            to_num_col(T.PullIn_Hz(keep)), to_num_col(T.PullIn_Speed_RPM(keep)), ...
            to_num_col(T.Stalled_Any(keep)) > 0.5, to_num_col(T.Max_Tested_Hz(keep)), ...
            'VariableNames', {'Drive_Mode','Trial','PullIn_Hz','PullIn_Speed_RPM','Stalled_Any','Max_Tested_Hz'}); %#ok<AGROW>
    else
        % Derive per-trial pull-in from legacy R6_pullin_steps.csv
        T_st = load_canonical_r6_steps(r6_mode_dirs(i));
        if isempty(T_st), continue; end
        parts{end+1} = derive_r6_trials_from_steps(T_st); %#ok<AGROW>
    end
end

if isempty(parts)
    T_all = table();
else
    T_all = vertcat(parts{:});
    [~, ia] = unique(T_all(:, {'Drive_Mode','Trial'}), 'rows', 'stable');
    T_all = T_all(ia, :);
end
end

function T_tr = derive_r6_trials_from_steps(T_st)
modes = unique(T_st.Drive_Mode);
rows = cell(0, 6);
for m = 1:numel(modes)
    dm = modes(m);
    M  = 2^(dm - 1);
    sub_m = T_st(T_st.Drive_Mode == dm, :);
    trs = unique(sub_m.Trial);
    for k = 1:numel(trs)
        sub = sub_m(sub_m.Trial == trs(k), :);
        [~, ord] = sort(sub.Freq_Hz);
        sub = sub(ord, :);
        last_ok = 0;
        stalled_any = false;
        for r = 1:height(sub)
            if ~sub.Stalled(r)
                last_ok = sub.Freq_Hz(r);
            else
                stalled_any = true;
                break;
            end
        end
        rpm = last_ok * 60 / (M * 200);
        rows(end+1, :) = {dm, trs(k), last_ok, rpm, stalled_any, max(sub.Freq_Hz)}; %#ok<AGROW>
    end
end
T_tr = cell2table(rows, 'VariableNames', ...
    {'Drive_Mode','Trial','PullIn_Hz','PullIn_Speed_RPM','Stalled_Any','Max_Tested_Hz'});
end

function T_all = load_canonical_r6_summary(r6_mode_dirs)
parts = {};
for i = 1:numel(r6_mode_dirs)
    d = r6_mode_dirs(i).dir;
    dm_filter = r6_mode_dirs(i).drive_mode;
    fp = fullfile(d, 'tables', 'R6_pullin_summary.csv');
    if isfile(fp)
        T = readtable(fp, 'TextType', 'string');
        if height(T) == 0, continue; end
        dm_col = round(to_num_col(T.Drive_Mode));
        keep = (dm_filter <= 0) | (dm_col == dm_filter);
        if ~any(keep), continue; end
        parts{end+1} = table(dm_col(keep), string(T.Mode(keep)), round(to_num_col(T.Microstep_M(keep))), ...
            to_num_col(T.PullIn_Mean_Hz(keep)), to_num_col(T.PullIn_SD_Hz(keep)), ...
            to_num_col(T.PullIn_Speed_RPM(keep)), to_num_col(T.N_Trials(keep)), ...
            to_num_col(T.N_Stalled_Trials(keep)), to_num_col(T.N_Censored(keep)), ...
            to_num_col(T.Max_Tested_Hz(keep)), ...
            'VariableNames', {'Drive_Mode','Mode','Microstep_M','PullIn_Mean_Hz','PullIn_SD_Hz', ...
            'PullIn_Speed_RPM','N_Trials','N_Stalled_Trials','N_Censored','Max_Tested_Hz'}); %#ok<AGROW>
    else
        T_tr = load_canonical_r6_trials(r6_mode_dirs(i));
        if isempty(T_tr), continue; end
        modes = unique(T_tr.Drive_Mode);
        rows = cell(numel(modes), 10);
        for m = 1:numel(modes)
            dm = modes(m);
            M  = 2^(dm - 1);
            sub = T_tr(T_tr.Drive_Mode == dm, :);
            pm = mean(sub.PullIn_Hz, 'omitnan');
            ps = std(sub.PullIn_Hz, 0, 'omitnan');
            if ~isfinite(ps), ps = 0; end
            nt = height(sub);
            ns = sum(sub.Stalled_Any);
            nc = nt - ns;
            rows(m, :) = {dm, string(canonical_mode_name(dm)), M, pm, ps, ...
                pm * 60 / (M * 200), nt, ns, nc, max(sub.Max_Tested_Hz)};
        end
        parts{end+1} = cell2table(rows, 'VariableNames', ...
            {'Drive_Mode','Mode','Microstep_M','PullIn_Mean_Hz','PullIn_SD_Hz', ...
            'PullIn_Speed_RPM','N_Trials','N_Stalled_Trials','N_Censored','Max_Tested_Hz'}); %#ok<AGROW>
    end
end

if isempty(parts)
    T_all = table();
else
    T_all = vertcat(parts{:});
    [~, ia] = unique(T_all.Drive_Mode, 'stable');
    T_all = sortrows(T_all(ia, :), 'Drive_Mode');
end
end

% =========================================================================
% Signal Loading, Filtering & Formatting Helpers
% =========================================================================
function runs = load_runs_for_lab(folder, lab_name)
mats = list_run_mat_files(folder);
runs = {};
for i = 1:numel(mats)
    fp = fullfile(folder, mats(i).name);
    M = load_meta_only(fp);
    if isempty(M) || ~isfield(M, 'lab') || ~strcmpi(char(M.lab), lab_name)
        continue;
    end
    S = load(fp);
    if isfield(S, 'logsout') && isfield(S, 'meta')
        S.filename = mats(i).name;
        runs{end+1} = S; %#ok<AGROW>
    end
end
end

function D = extract_signals(logsout)
names = logsout.getElementNames;
ts_ref = logsout.get('freq_cmd').Values;
D.t           = double(ts_ref.Time(:));
D.freq_cmd    = get_vec(logsout, 'freq_cmd', D.t);
D.target_freq = get_vec_opt(logsout, names, 'target_freq', D.t, D.freq_cmd);
D.f_echo      = get_vec_opt(logsout, names, 'Stepper Frequency (echo)', D.t, D.freq_cmd);
D.is_steady   = get_vec_opt(logsout, names, 'is_steady', D.t, ones(size(D.t)));
D.step_id     = get_vec_opt(logsout, names, 'step_id', D.t, ones(size(D.t)));
D.rpm_theory  = get_vec(logsout, 'rpm_theory', D.t);
D.rpm_meas    = get_vec(logsout, 'rpm_meas', D.t);
D.lost_steps  = get_vec_opt(logsout, names, 'lost_steps', D.t, zeros(size(D.t)));

if any(strcmp(names, 'rpm_meas_lpf'))
    D.rpm_meas_lpf = get_vec(logsout, 'rpm_meas_lpf', D.t);
    D.has_live_lpf = true;
else
    dt = median(diff(D.t));
    D.rpm_meas_lpf = butter2_lpf(D.rpm_meas, dt, 10.0);
    D.has_live_lpf = false;
end
end

function y = butter2_lpf(x, dt, fc_hz)
% 2nd-order Butterworth LPF: uses exact Simulink coefficients at Ts=1 ms,
% or exact bilinear-transform coefficients for any other sampling interval.
if abs(dt - 0.001) < 2e-4 && abs(fc_hz - 10.0) < 1e-6
    b = [0.000944691843840, 0.001889383687680, 0.000944691843840];
    a = [1.0, -1.911197067426073, 0.914975834801434];
    y = filter(b, a, x);
    return;
end
fs = 1.0 / max(dt, 1e-6);
if fc_hz >= 0.49 * fs
    y = x;
    return;
end
K  = tan(pi * fc_hz / fs);
K2 = K * K;
sq = sqrt(2) * K;
dn = 1 + sq + K2;
b  = [K2, 2*K2, K2] / dn;
a  = [1, 2*(K2 - 1)/dn, (1 - sq + K2)/dn];
y  = filter(b, a, x);
end

function v = get_vec(logsout, name, t_ref)
ts = logsout.get(name).Values;
d  = double(squeeze(ts.Data));
t  = double(ts.Time(:));
if numel(t) == numel(t_ref) && max(abs(t - t_ref)) < 1e-9
    v = d(:);
else
    v = interp1(t, d(:), t_ref, 'previous', 'extrap');
end
end

function v = get_vec_opt(logsout, names, name, t_ref, fallback)
if any(strcmp(names, name))
    v = get_vec(logsout, name, t_ref);
else
    v = fallback;
end
end

function v = to_num_col(col)
if isnumeric(col)
    v = double(col(:));
elseif islogical(col)
    v = double(col(:));
else
    v = str2double(string(col(:)));
end
end

function [M_list, labels, cols, mkrs] = canonical_mode_style()
M_list = [1, 2, 4, 8, 16, 32];
labels = {'Full Step (M=1)', 'Half Step (M=2)', '1/4 Microstep (M=4)', ...
          '1/8 Microstep (M=8)', '1/16 Microstep (M=16)', '1/32 Microstep (M=32)'};
cols   = [0.00 0.45 0.74;
          0.85 0.33 0.10;
          0.13 0.55 0.13;
          0.49 0.18 0.56;
          0.85 0.62 0.00;
          0.75 0.05 0.18];
mkrs   = {'o', 's', '^', 'd', 'v', 'p'};
end

function s = canonical_mode_name(dm)
names = {'Full (1)', 'Half (1/2)', '1/4', '1/8', '1/16', '1/32'};
s = names{max(1, min(6, round(dm)))};
end

function s = mode_short_title(dm)
names = {'Full Step', 'Half Step', '1/4 Microstep', '1/8 Microstep', '1/16 Microstep', '1/32 Microstep'};
s = names{max(1, min(6, round(dm)))};
end

function s = mode_long_label(dm)
names = {'Full Step (M=1)', 'Half Step (M=2)', '1/4 (M=4)', '1/8 (M=8)', '1/16 (M=16)', '1/32 (M=32)'};
s = names{max(1, min(6, round(dm)))};
end

function save_fig(fh, out_png, dpi)
drawnow;
try
    exportgraphics(fh, out_png, 'Resolution', dpi);
catch
    print(fh, '-dpng', sprintf('-r%d', dpi), out_png);
end
close_if_valid(fh);
end

function close_if_valid(fh)
if ~isempty(fh) && isvalid(fh)
    close(fh);
end
end
