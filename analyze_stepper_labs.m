function summary = analyze_stepper_labs(data_dir)
% ANALYZE_STEPPER_LABS  Post-process saved Lab 2.2 Stepper Motor runs into CSV tables & report PNG figures.
%
% Usage:
%   analyze_stepper_labs('stepper_data/20261120_180000')
%   analyze_stepper_labs()   % automatically picks the newest folder under ./stepper_data/

if nargin < 1 || isempty(data_dir)
    base_dir = fullfile(fileparts(mfilename('fullpath')), 'stepper_data');
    d = dir(base_dir);
    d = d([d.isdir] & ~ismember({d.name}, {'.', '..'}));
    assert(~isempty(d), 'No run folders found in %s', base_dir);
    [~, idx] = sort([d.datenum], 'descend');
    data_dir = fullfile(base_dir, d(idx(1)).name);
end
assert(isfolder(data_dir), 'Data directory not found: %s', data_dir);

fig_dir     = fullfile(data_dir, 'figures');
raw_fig_dir = fullfile(data_dir, 'figures_raw');
tbl_dir     = fullfile(data_dir, 'tables');
raw_csv_dir = fullfile(data_dir, 'raw_csv');
for dpath = {fig_dir, raw_fig_dir, tbl_dir, raw_csv_dir}
    if ~isfolder(dpath{1}), mkdir(dpath{1}); end
end

fprintf('\n=== Analyzing Stepper Data: %s ===\n', data_dir);
files = dir(fullfile(data_dir, '*.mat'));
runs = {};
for i = 1:numel(files)
    if strcmp(files(i).name, 'run_config.mat'), continue; end
    S = load(fullfile(data_dir, files(i).name));
    if isfield(S, 'logsout') && isfield(S, 'meta')
        S.filename = files(i).name;
        runs{end+1} = S; %#ok<AGROW>
    end
end
assert(~isempty(runs), 'No .mat run files with logsout + meta found in %s', data_dir);

summary = struct();

% ---- R0: Baseline Calibration (session zero offsets)
cal = struct('adc_i_zero', 2137.5638, 'adc_per_A', 66.3185, 'pa0_zero', 0, 'omega_zero', 0, 'from_r0', false);
r0_runs = filter_lab(runs, 'R0');
if ~isempty(r0_runs)
    D = extract_signals(r0_runs{1}.logsout);
    mask = (D.step_id == 1) & (D.is_steady > 0.5);
    assert(any(mask), 'R0 run has no steady baseline samples.');
    cal.adc_i_zero = mean(D.current_pa1(mask));
    cal.pa0_zero   = mean(D.load_pa0(mask));
    cal.omega_zero = mean(D.omega(mask));
    cal.from_r0    = true;
    fprintf('R0 Baseline: PA1 zero = %.2f counts, PA0 zero = %.2f counts, omega zero = %.4f rad/s\n', ...
        cal.adc_i_zero, cal.pa0_zero, cal.omega_zero);
else
    fprintf('R0 Baseline: not found (using nominal PA1 zero = %.2f counts)\n', cal.adc_i_zero);
end
summary.calibration = cal;

% ---- R3: All 6 Drive Modes Real Operation
r3_runs = filter_lab(runs, 'R3');
if ~isempty(r3_runs)
    summary.R3 = analyze_r3(r3_runs, cal, tbl_dir, fig_dir);
end

% ---- R4 & R5: Frequency vs Speed per Drive Mode
r4_runs = filter_lab(runs, 'R4_R5');
if ~isempty(r4_runs)
    summary.R4_R5 = analyze_r4_r5(r4_runs, cal, tbl_dir, fig_dir);
end

% ---- R6: Pull-In Loss Step Ladder (Step Input, No Accel Limit)
r6_runs = filter_lab(runs, 'R6');
r6_res = [];
if ~isempty(r6_runs)
    r6_res = analyze_r6(r6_runs, cal, tbl_dir);
    summary.R6 = r6_res;
end

% ---- R8: Linear Acceleration Ramp Pull-Out (+ combined Table 5 & Fig 3/4 with R6)
r8_runs = filter_lab(runs, 'R8');
if ~isempty(r8_runs) || ~isempty(r6_runs)
    summary.R8 = analyze_r8(r6_runs, r6_res, r8_runs, cal, tbl_dir, fig_dir);
end

% ---- Export 100% raw unfiltered 1 kHz CSV for every saved run (portable for Excel/Python/MATLAB)
export_raw_csvs(runs, raw_csv_dir);

% ---- Export dedicated raw unfiltered time-series figures for every lab
plot_raw_unfiltered(r0_runs, r3_runs, r4_runs, r6_runs, r8_runs, raw_fig_dir);

fprintf('Note: Current_A uses DC-board gain (66.3185 counts/A, unverified for stepper path); R0 corrects zero-offset only.\n');
save(fullfile(data_dir, 'analysis_summary.mat'), 'summary');
fprintf('Analysis complete.\n  Tables      -> %s\n  Figures     -> %s\n  Raw CSVs    -> %s\n  Raw Figures -> %s\n', ...
    tbl_dir, fig_dir, raw_csv_dir, raw_fig_dir);
end

% =========================================================================
function T = analyze_r3(r3_runs, cal, tbl_dir, fig_dir)
mode_names = {'Full (1)', 'Half (1/2)', '1/4', '1/8', '1/16', '1/32'};
nT = numel(r3_runs);
rpm_th = nan(6, nT); rpm_m = nan(6, nT); rpm_sd = nan(6, nT); cur_m = nan(6, nT);
for tr = 1:nT
    D = extract_signals(r3_runs{tr}.logsout);
    I_corr = (D.current_pa1 - cal.adc_i_zero) / cal.adc_per_A;
    for k = 1:6
        m = (round(D.step_id) == k) & (D.is_steady > 0.5);
        if any(m)
            rpm_th(k, tr) = mean(D.rpm_theory(m));
            rpm_m(k, tr)  = mean(D.rpm_meas(m));
            rpm_sd(k, tr) = std(D.rpm_meas(m));
            cur_m(k, tr)  = mean(I_corr(m));
        end
    end
end
T = table(mode_names', [1;2;4;8;16;32], mean(rpm_th,2,'omitnan'), mean(rpm_m,2,'omitnan'), ...
    std(rpm_m,0,2,'omitnan'), mean(rpm_sd,2,'omitnan'), mean(cur_m,2,'omitnan'), ...
    'VariableNames', {'Mode','Microstep_M','Theory_RPM','Meas_Mean_RPM','Trial_SD_RPM','Ripple_SD_RPM','Current_A'});
writetable(T, fullfile(tbl_dir, 'R3_drive_modes_summary.csv'));
fprintf('\n--- R3 All 6 Drive Modes Summary ---\n'); disp(T);

% Figure 2: Real-Op speed waveforms across the 6 modes (Trial 1)
D1 = extract_signals(r3_runs{1}.logsout);
f = figure('Visible', 'off', 'Color', 'w', 'Position', [100 100 900 450]);
plot(D1.t, D1.rpm_theory, '--k', 'LineWidth', 1.2); hold on;
plot(D1.t, D1.rpm_meas, 'b', 'LineWidth', 1.3);
grid on; xlabel('Time (s)'); ylabel('Speed (RPM)');
title('R3: Measured vs Theoretical Speed Across All 6 DRV8825 Drive Modes');
legend({'Theory RPM', 'Measured RPM'}, 'Location', 'northeast');
save_fig(f, fullfile(fig_dir, 'Fig2_R3_DriveModes_Waveforms.png'));
end

% =========================================================================
function T = analyze_r4_r5(r4_runs, cal, tbl_dir, fig_dir)
mode_names = {'Full (1)', 'Half (1/2)', '1/4', '1/8', '1/16', '1/32'};
M_vals = [1 2 4 8 16 32];
rows = {};
for dm = 1:6
    sub = {};
    for i = 1:numel(r4_runs)
        if r4_runs{i}.meta.drive_mode == dm, sub{end+1} = r4_runs{i}; end %#ok<AGROW>
    end
    if isempty(sub), continue; end
    % Collect unique active step_ids
    D0 = extract_signals(sub{1}.logsout);
    sids = unique(round(D0.step_id(D0.step_id >= 1 & D0.step_id < 99)));
    for s = sids(:)'
        f_vals = nan(1, numel(sub)); th_vals = nan(1, numel(sub));
        m_vals = nan(1, numel(sub)); i_vals  = nan(1, numel(sub));
        for tr = 1:numel(sub)
            D = extract_signals(sub{tr}.logsout);
            I_corr = (D.current_pa1 - cal.adc_i_zero) / cal.adc_per_A;
            msk = (round(D.step_id) == s) & (D.is_steady > 0.5);
            if any(msk)
                f_vals(tr)  = mean(D.target_freq(msk));
                th_vals(tr) = mean(D.rpm_theory(msk));
                m_vals(tr)  = mean(D.rpm_meas(msk));
                i_vals(tr)  = mean(I_corr(msk));
            end
        end
        th_m = mean(th_vals, 'omitnan');
        me_m = mean(m_vals, 'omitnan');
        me_s = std(m_vals, 0, 'omitnan');
        err_pct = 100 * abs(me_m - th_m) / max(th_m, 1e-9);
        rows(end+1, :) = {mode_names{dm}, M_vals(dm), round(mean(f_vals,'omitnan')), th_m, me_m, me_s, err_pct, mean(i_vals,'omitnan'), numel(sub)}; %#ok<AGROW>
    end
end
T = cell2table(rows, 'VariableNames', {'Mode','Microstep_M','Freq_Hz','Theory_RPM','Meas_Mean_RPM','Meas_SD_RPM','Error_Pct','Current_A','N_Trials'});
writetable(T, fullfile(tbl_dir, 'R4_R5_freq_vs_speed.csv'));
fprintf('\n--- R4 & R5 Frequency vs Speed (first 12 rows) ---\n');
disp(T(1:min(12, height(T)), :));

% Figure 1: Frequency vs Speed (6 modes, distinct high-contrast colors + markers)
f = figure('Visible', 'off', 'Color', 'w', 'Position', [100 100 920 520]);
cols = [0.00 0.45 0.74;   % Full: blue
        0.85 0.33 0.10;   % Half: orange
        0.13 0.55 0.13;   % 1/4:  green
        0.49 0.18 0.56;   % 1/8:  purple
        0.85 0.65 0.05;   % 1/16: gold
        0.75 0.05 0.18];  % 1/32: crimson
mkrs = {'o', 's', '^', 'd', 'v', 'p'};
hold on;
leg = {};
for dm = 1:6
    idx = (T.Microstep_M == M_vals(dm));
    if ~any(idx), continue; end
    fq = T.Freq_Hz(idx);
    plot(fq, T.Theory_RPM(idx), '--', 'Color', cols(dm,:), 'LineWidth', 1.1, 'HandleVisibility', 'off');
    errorbar(fq, T.Meas_Mean_RPM(idx), T.Meas_SD_RPM(idx), ['-' mkrs{dm}], 'Color', cols(dm,:), ...
        'MarkerFaceColor', cols(dm,:), 'LineWidth', 1.4, 'MarkerSize', 5);
    leg{end+1} = sprintf('%s (M=%d)', mode_names{dm}, M_vals(dm)); %#ok<AGROW>
end
grid on; xlabel('STEP Frequency (Hz)'); ylabel('Motor Speed (RPM)');
title('R4 & R5: Speed vs STEP Frequency (Dashed = Theory, Mean \pm SD)');
legend(leg, 'Location', 'northwest');
save_fig(f, fullfile(fig_dir, 'Fig1_R4_FreqVsSpeed.png'));
end

% =========================================================================
function out = analyze_r6(r6_runs, ~, tbl_dir)
nT = numel(r6_runs);
pullin_hz = nan(nT, 1);
step_rows = {};
for tr = 1:nT
    D = extract_signals(r6_runs{tr}.logsout);
    sids = unique(round(D.step_id(D.step_id >= 1 & D.step_id < 99)));
    last_ok = 0;
    for s = sids(:)'
        m_act = (round(D.step_id) == s);
        m_std = m_act & (D.is_steady > 0.5);
        fq    = mean(D.target_freq(m_act));
        th    = mean(D.rpm_theory(m_std));
        me    = mean(D.rpm_meas(m_std));
        ls_pk = max(D.lost_steps(m_act));
        stalled = (me < 0.85 * th) || (ls_pk > 5.0);
        step_rows(end+1, :) = {tr, s, round(fq), th, me, ls_pk, stalled}; %#ok<AGROW>
        if ~stalled && isnan(pullin_hz(tr))
            last_ok = fq;
        elseif stalled && isnan(pullin_hz(tr))
            pullin_hz(tr) = last_ok;
        end
    end
    if isnan(pullin_hz(tr)), pullin_hz(tr) = last_ok; end
end
T_steps = cell2table(step_rows, 'VariableNames', {'Trial','Step_ID','Freq_Hz','Theory_RPM','Meas_RPM','Peak_Lost_Steps','Stalled'});
writetable(T_steps, fullfile(tbl_dir, 'R6_pullin_steps.csv'));
out = struct('pullin_trials_hz', pullin_hz, 'pullin_mean_hz', mean(pullin_hz,'omitnan'), ...
    'pullin_sd_hz', std(pullin_hz,0,'omitnan'), 'steps_table', T_steps);
fprintf('\n--- R6 Pull-In Frequency (Step from Rest): %.1f +/- %.1f Hz ---\n', out.pullin_mean_hz, out.pullin_sd_hz);
end

% =========================================================================
function T = analyze_r8(r6_runs, r6_res, r8_runs, ~, tbl_dir, fig_dir)
rows = {};
% Include R6 (Step Input / unlimited accel) as first row to match Report Table 5
if ~isempty(r6_runs) && ~isempty(r6_res)
    spr = r6_runs{1}.meta.steps_per_rev;
    M   = 2^(r6_runs{1}.meta.drive_mode - 1);
    rows(end+1, :) = {'Step Input (No Limit)', Inf, r6_res.pullin_mean_hz, r6_res.pullin_sd_hz, ...
        r6_res.pullin_mean_hz * 60 / (M * spr), numel(r6_runs)};
end

% Group R8 runs by acceleration value (descending: 4000, 2000, 1000, 500)
if ~isempty(r8_runs)
    acc_all = cellfun(@(r) round(r.meta.accel), r8_runs);
    acc_u   = sort(unique(acc_all), 'descend');
    sample_r8 = [];
    for a = acc_u(:)'
        sub = r8_runs(acc_all == a);
        f_crit = nan(numel(sub), 1);
        for tr = 1:numel(sub)
            D = extract_signals(sub{tr}.logsout);
            m = (round(D.step_id) == 1) & (D.is_steady > 0.5) & (D.freq_cmd > 250);
            % Causal 80 ms speed-drop detector: immune to 1 ms raw encoder jitter and
            % UART transport-lag drift in lost_steps during rapid acceleration ramps.
            dt_med = median(diff(D.t));
            win_n  = max(1, round(0.08 / max(dt_med, 1e-4)));
            rm_win = movmean(D.rpm_meas, [win_n-1 0]);
            rt_win = movmean(D.rpm_theory, [win_n-1 0]);
            bad = m & (rt_win > 40) & (rm_win < 0.70 * rt_win);
            idx = find(bad, 1, 'first');
            if ~isempty(idx)
                f_crit(tr) = D.freq_cmd(idx);
                if isempty(sample_r8), sample_r8 = sub{tr}; end
            else
                f_crit(tr) = max(D.freq_cmd(m));
            end
        end
        spr = sub{1}.meta.steps_per_rev;
        M   = 2^(sub{1}.meta.drive_mode - 1);
        fm  = mean(f_crit, 'omitnan');
        fs  = std(f_crit, 0, 'omitnan');
        rows(end+1, :) = {sprintf('%d Hz/s', a), a, fm, fs, fm * 60 / (M * spr), numel(sub)}; %#ok<AGROW>
    end

    % Figure 3: Loss Step Time Series (from a representative R8 run)
    if isempty(sample_r8), sample_r8 = r8_runs{1}; end
    D = extract_signals(sample_r8.logsout);
    f3 = figure('Visible', 'off', 'Color', 'w', 'Position', [100 100 900 580]);
    subplot(3,1,1); plot(D.t, D.freq_cmd, 'b', 'LineWidth', 1.3); hold on;
    plot(D.t, D.f_echo, '--r', 'LineWidth', 1.0); grid on; ylabel('Freq (Hz)');
    title(sprintf('R6 & R8: Loss Step Time Series (Accel = %d Hz/s)', round(sample_r8.meta.accel)));
    legend({'f_{cmd}', 'f_{echo}'}, 'Location', 'northwest');
    subplot(3,1,2); plot(D.t, D.rpm_theory, '--k', 'LineWidth', 1.2); hold on;
    plot(D.t, D.rpm_meas, 'b', 'LineWidth', 1.3); grid on; ylabel('Speed (RPM)');
    legend({'Theory RPM', 'Measured RPM'}, 'Location', 'northwest');
    subplot(3,1,3); plot(D.t, D.lost_steps, 'r', 'LineWidth', 1.3); grid on;
    xlabel('Time (s)'); ylabel('Lost Steps (full)');
    save_fig(f3, fullfile(fig_dir, 'Fig3_R6_R8_LossStep_TimeSeries.png'));
end

T = cell2table(rows, 'VariableNames', {'Condition','Accel_Hz_s','MaxFreq_Mean_Hz','MaxFreq_SD_Hz','MaxSpeed_RPM','N_Trials'});
writetable(T, fullfile(tbl_dir, 'R8_accel_pullout.csv'));
fprintf('\n--- R6 & R8 Acceleration vs Max Frequency Before Loss Step ---\n'); disp(T);

% Figure 4: Accel vs Max Frequency bar chart with +/- SD
f4 = figure('Visible', 'off', 'Color', 'w', 'Position', [100 100 820 460]);
x = 1:height(T);
bar(x, T.MaxFreq_Mean_Hz, 0.55, 'FaceColor', [0.22 0.48 0.76]); hold on;
errorbar(x, T.MaxFreq_Mean_Hz, T.MaxFreq_SD_Hz, 'k.', 'LineWidth', 1.5, 'CapSize', 10);
set(gca, 'XTick', x, 'XTickLabel', T.Condition);
grid on; ylabel('Max Frequency Before Loss Step (Hz)');
title('R8: Acceleration Limit vs Pull-Out Frequency (Mean \pm SD)');
save_fig(f4, fullfile(fig_dir, 'Fig4_R8_Accel_vs_PullOut.png'));
end

% =========================================================================
function sub = filter_lab(runs, lab_name)
sub = {};
for i = 1:numel(runs)
    if strcmpi(runs{i}.meta.lab, lab_name)
        sub{end+1} = runs{i}; %#ok<AGROW>
    end
end
end

function D = extract_signals(logsout)
req = {'freq_cmd', 'target_freq', 'microstep_M', 'is_steady', 'step_id', ...
       'rpm_theory', 'rpm_meas', 'lost_steps', 'Motor Angular Velocity', ...
       'Stepper Frequency (echo)', 'Current (PA1)', 'Load Cell (PA0)'};
names = logsout.getElementNames;
for i = 1:numel(req)
    assert(any(strcmp(names, req{i})), 'Missing required logged signal "%s" in logsout.', req{i});
end
ts_ref = logsout.get('freq_cmd').Values;
D.t          = double(ts_ref.Time(:));
D.freq_cmd   = get_vec(logsout, 'freq_cmd', D.t);
D.target_freq= get_vec(logsout, 'target_freq', D.t);
D.microstep_M= get_vec(logsout, 'microstep_M', D.t);
D.is_steady  = get_vec(logsout, 'is_steady', D.t);
D.step_id    = get_vec(logsout, 'step_id', D.t);
D.rpm_theory = get_vec(logsout, 'rpm_theory', D.t);
D.rpm_meas   = get_vec(logsout, 'rpm_meas', D.t);
D.lost_steps = get_vec(logsout, 'lost_steps', D.t);
D.omega      = get_vec(logsout, 'Motor Angular Velocity', D.t);
D.f_echo     = get_vec(logsout, 'Stepper Frequency (echo)', D.t);
D.current_pa1= get_vec(logsout, 'Current (PA1)', D.t);
D.load_pa0   = get_vec(logsout, 'Load Cell (PA0)', D.t);
if any(strcmp(names, 'EN'))
    D.en_cmd = get_vec(logsout, 'EN', D.t);
else
    D.en_cmd = double(D.step_id == 0 | D.step_id == 99);
end
if any(strcmp(names, 'accel_hz_s'))
    D.accel_hz_s = get_vec(logsout, 'accel_hz_s', D.t);
else
    D.accel_hz_s = zeros(size(D.t));
end
if any(strcmp(names, 'rpm_meas_lpf'))
    D.rpm_meas_lpf = get_vec(logsout, 'rpm_meas_lpf', D.t);
    D.has_live_lpf = true;
else
    % Exact 10 Hz 2nd-order Butterworth discrete LPF at Ts=0.001 s (matches Simulink block)
    b = [0.000944691843840 0.001889383687680 0.000944691843840];
    a = [1 -1.911197067426073 0.914975834801434];
    D.rpm_meas_lpf = filter(b, a, D.rpm_meas);
    D.has_live_lpf = false;
end
end

function export_raw_csvs(runs, raw_csv_dir)
for i = 1:numel(runs)
    D = extract_signals(runs{i}.logsout);
    [~, stem] = fileparts(runs{i}.filename);
    T = table(D.t, D.freq_cmd, D.f_echo, D.target_freq, D.microstep_M, D.accel_hz_s, ...
        D.en_cmd, D.is_steady, D.step_id, D.omega, D.rpm_meas, D.rpm_meas_lpf, D.rpm_theory, ...
        D.lost_steps, D.current_pa1, D.load_pa0, ...
        'VariableNames', {'time_s','freq_cmd_hz','f_echo_hz','target_freq_hz','microstep_M', ...
        'accel_hz_s','en_cmd','is_steady','step_id','omega_rad_s','rpm_meas_raw','rpm_meas_lpf', ...
        'rpm_theory','lost_steps_full','current_pa1_raw','load_pa0_raw'});
    writetable(T, fullfile(raw_csv_dir, [stem '.csv']));
end
fprintf('Exported %d raw unfiltered CSV files -> %s\n', numel(runs), raw_csv_dir);
end

function plot_raw_unfiltered(r0_runs, r3_runs, r4_runs, r6_runs, r8_runs, raw_fig_dir)
% 1) R0 Raw Baseline Noise Floor
if ~isempty(r0_runs)
    D = extract_signals(r0_runs{1}.logsout);
    f = figure('Visible', 'off', 'Color', 'w', 'Position', [100 100 900 560]);
    subplot(3,1,1); plot(D.t, D.current_pa1, 'b', 'LineWidth', 0.8); grid on;
    ylabel('PA1 (counts)'); title('R0 Raw Unfiltered Baseline (EN = 1, f = 0 Hz)');
    subplot(3,1,2); plot(D.t, D.load_pa0, 'r', 'LineWidth', 0.8); grid on;
    ylabel('PA0 (counts)');
    subplot(3,1,3); plot(D.t, D.omega, 'k', 'LineWidth', 0.8); grid on;
    xlabel('Time (s)'); ylabel('\omega (rad/s)');
    save_fig(f, fullfile(raw_fig_dir, 'Raw_R0_Baseline.png'));
end

% 2) R3 Raw Unfiltered 6-Mode Waveforms (all trials overlaid)
if ~isempty(r3_runs)
    f = figure('Visible', 'off', 'Color', 'w', 'Position', [100 100 960 540]);
    cols = lines(numel(r3_runs));
    subplot(2,1,1); hold on;
    for tr = 1:numel(r3_runs)
        D = extract_signals(r3_runs{tr}.logsout);
        plot(D.t, D.rpm_meas, 'Color', cols(tr,:), 'LineWidth', 0.8, 'DisplayName', sprintf('Trial %d raw', tr));
    end
    plot(D.t, D.rpm_theory, '--k', 'LineWidth', 1.2, 'DisplayName', 'Theory RPM');
    grid on; ylabel('Speed (RPM)'); title('R3 Raw Unfiltered Speed Across All 6 DRV8825 Modes');
    legend('Location', 'northeast');
    subplot(2,1,2); hold on;
    for tr = 1:numel(r3_runs)
        D = extract_signals(r3_runs{tr}.logsout);
        plot(D.t, D.omega, 'Color', cols(tr,:), 'LineWidth', 0.8, 'DisplayName', sprintf('Trial %d raw', tr));
    end
    grid on; xlabel('Time (s)'); ylabel('Raw \omega (rad/s)');
    save_fig(f, fullfile(raw_fig_dir, 'Raw_R3_AllModes_Unfiltered.png'));
end

% 3) R4/R5 Raw Unfiltered Time Series per Drive Mode (6 panels)
if ~isempty(r4_runs)
    mode_names = {'Full (M=1)', 'Half (M=2)', '1/4 (M=4)', '1/8 (M=8)', '1/16 (M=16)', '1/32 (M=32)'};
    f = figure('Visible', 'off', 'Color', 'w', 'Position', [60 60 1120 720]);
    for dm = 1:6
        subplot(3,2,dm); hold on;
        sub = {};
        for i = 1:numel(r4_runs)
            if r4_runs{i}.meta.drive_mode == dm, sub{end+1} = r4_runs{i}; end %#ok<AGROW>
        end
        if isempty(sub), title([mode_names{dm} ' (no data)']); continue; end
        cols = lines(numel(sub));
        for tr = 1:numel(sub)
            D = extract_signals(sub{tr}.logsout);
            plot(D.t, D.rpm_meas, 'Color', cols(tr,:), 'LineWidth', 0.7);
        end
        plot(D.t, D.rpm_theory, '--k', 'LineWidth', 1.1);
        grid on; title(mode_names{dm}); ylabel('RPM');
        if dm >= 5, xlabel('Time (s)'); end
    end
    sgtitle('R4 & R5 Raw Unfiltered Speed Time Series (All Modes & Trials, Dashed = Theory)');
    save_fig(f, fullfile(raw_fig_dir, 'Raw_R4_R5_AllModes_TimeSeries.png'));
end

% 4) R6 Raw Unfiltered Pull-In Ladder (all trials overlaid)
if ~isempty(r6_runs)
    f = figure('Visible', 'off', 'Color', 'w', 'Position', [100 100 960 620]);
    cols = lines(numel(r6_runs));
    subplot(3,1,1); hold on;
    D1 = extract_signals(r6_runs{1}.logsout);
    plot(D1.t, D1.freq_cmd, 'b', 'LineWidth', 1.1, 'DisplayName', 'f_{cmd}');
    plot(D1.t, D1.f_echo, '--r', 'LineWidth', 0.9, 'DisplayName', 'f_{echo}');
    grid on; ylabel('Freq (Hz)'); title('R6 Raw Unfiltered Pull-In Ladder (Step from Rest, No Ramp)');
    legend('Location', 'northwest');
    subplot(3,1,2); hold on;
    for tr = 1:numel(r6_runs)
        D = extract_signals(r6_runs{tr}.logsout);
        plot(D.t, D.rpm_meas, 'Color', cols(tr,:), 'LineWidth', 0.8, 'DisplayName', sprintf('Trial %d raw', tr));
    end
    plot(D1.t, D1.rpm_theory, '--k', 'LineWidth', 1.0, 'DisplayName', 'Theory');
    grid on; ylabel('Speed (RPM)'); legend('Location', 'northwest');
    subplot(3,1,3); hold on;
    for tr = 1:numel(r6_runs)
        D = extract_signals(r6_runs{tr}.logsout);
        plot(D.t, D.lost_steps, 'Color', cols(tr,:), 'LineWidth', 0.9, 'DisplayName', sprintf('Trial %d', tr));
    end
    grid on; xlabel('Time (s)'); ylabel('Lost Steps (full)');
    save_fig(f, fullfile(raw_fig_dir, 'Raw_R6_PullIn_Unfiltered.png'));
end

% 5) R8 Raw Unfiltered Acceleration Ramps (one panel per accel limit)
if ~isempty(r8_runs)
    acc_all = cellfun(@(r) round(r.meta.accel), r8_runs);
    acc_u   = sort(unique(acc_all), 'descend');
    nA = numel(acc_u);
    f = figure('Visible', 'off', 'Color', 'w', 'Position', [60 60 1120 max(460, 260*ceil(nA/2))]);
    for ia = 1:nA
        a = acc_u(ia);
        sub = r8_runs(acc_all == a);
        subplot(ceil(nA/2), min(2, nA), ia); hold on;
        cols = lines(numel(sub));
        for tr = 1:numel(sub)
            D = extract_signals(sub{tr}.logsout);
            plot(D.t, D.rpm_meas, 'Color', cols(tr,:), 'LineWidth', 0.8);
        end
        plot(D.t, D.rpm_theory, '--k', 'LineWidth', 1.1);
        grid on; title(sprintf('Accel = %d Hz/s (raw)', a)); xlabel('Time (s)'); ylabel('Speed (RPM)');
    end
    sgtitle('R8 Raw Unfiltered Acceleration Ramps (All Trials Overlaid, Dashed = Theory)');
    save_fig(f, fullfile(raw_fig_dir, 'Raw_R8_Accel_AllRamps_Unfiltered.png'));
end
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

function save_fig(fh, out_png)
try
    exportgraphics(fh, out_png, 'Resolution', 300);
catch
    print(fh, '-dpng', '-r300', out_png);
end
close(fh);
end
