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
    if ismember(files(i).name, {'run_config.mat', 'analysis_summary.mat'}), continue; end
    S = load(fullfile(data_dir, files(i).name));
    if isfield(S, 'logsout') && isfield(S, 'meta')
        S.filename = files(i).name;
        runs{end+1} = S; %#ok<AGROW>
    end
end
assert(~isempty(runs), 'No .mat run files with logsout + meta found in %s', data_dir);

summary = struct();

% ---- R0: Baseline Calibration (session zero offsets)
cal = struct('adc_i_zero', 2137.5638, 'adc_i_sd', NaN, 'adc_per_A', 66.3185, ...
    'pa0_zero', 0, 'pa0_sd', NaN, 'omega_zero', 0, 'omega_sd', NaN, ...
    'n_samples', 0, 'from_r0', false);
r0_runs = filter_lab(runs, 'R0');
if ~isempty(r0_runs)
    pa1_all = []; pa0_all = []; om_all = [];
    for i = 1:numel(r0_runs)
        D = extract_signals(r0_runs{i}.logsout);
        mask = (round(D.step_id) == 1) & (D.is_steady > 0.5);
        if any(mask)
            pa1_all = [pa1_all; D.current_pa1(mask)]; %#ok<AGROW>
            pa0_all = [pa0_all; D.load_pa0(mask)]; %#ok<AGROW>
            om_all  = [om_all;  D.omega(mask)]; %#ok<AGROW>
        end
    end
    assert(~isempty(pa1_all), 'R0 run has no steady baseline samples.');
    cal.adc_i_zero = mean(pa1_all);
    cal.adc_i_sd   = std(pa1_all);
    cal.pa0_zero   = mean(pa0_all);
    cal.pa0_sd     = std(pa0_all);
    cal.omega_zero = mean(om_all);
    cal.omega_sd   = std(om_all);
    cal.n_samples  = numel(pa1_all);
    cal.from_r0    = true;
    fprintf('R0 Baseline: PA1 zero = %.2f +/- %.2f counts, PA0 zero = %.2f counts, omega zero = %.4f rad/s (N=%d)\n', ...
        cal.adc_i_zero, cal.adc_i_sd, cal.pa0_zero, cal.omega_zero, cal.n_samples);
else
    fprintf('R0 Baseline: not found (using nominal PA1 zero = %.2f counts)\n', cal.adc_i_zero);
end
T_r0 = table(double(cal.from_r0), cal.adc_i_zero, cal.adc_i_sd, cal.pa0_zero, cal.pa0_sd, ...
    cal.omega_zero, cal.omega_sd, cal.adc_per_A, cal.n_samples, ...
    'VariableNames', {'From_R0','PA1_Zero_Counts','PA1_SD_Counts','PA0_Zero_Counts','PA0_SD_Counts', ...
    'Omega_Zero_rad_s','Omega_SD_rad_s','ADC_Per_A','N_Samples'});
writetable(T_r0, fullfile(tbl_dir, 'R0_baseline_calibration.csv'));
summary.calibration = cal;
summary.R0 = T_r0;

% ---- R3: All 6 Drive Modes Real Operation
r3_runs = filter_lab(runs, 'R3');
if ~isempty(r3_runs)
    summary.R3 = analyze_r3(r3_runs, cal, tbl_dir, fig_dir);
end

% ---- R4 & R5: Frequency vs Speed per Drive Mode
r4_runs = filter_lab(runs, 'R4_R5');
if ~isempty(r4_runs)
    [summary.R4_R5, summary.R4_R5_trials] = analyze_r4_r5(r4_runs, cal, tbl_dir, fig_dir);
end

% ---- R6: Pull-In Loss Step Ladder (Step Input, No Accel Limit, grouped by Drive Mode)
r6_runs = filter_lab(runs, 'R6');
r6_res = [];
if ~isempty(r6_runs)
    r6_res = analyze_r6(r6_runs, cal, tbl_dir);
    summary.R6 = r6_res;
end

% ---- R8: Linear Acceleration Ramp Pull-Out (+ per-mode Table 5 & Fig 3/4 with R6)
r8_runs = filter_lab(runs, 'R8');
if ~isempty(r8_runs) || ~isempty(r6_runs)
    [summary.R8, summary.R8_trials] = analyze_r8(r6_runs, r6_res, r8_runs, cal, tbl_dir, fig_dir);
end

% ---- Export 100% raw unfiltered 1 kHz CSV for every saved run (portable for Excel/Python/MATLAB)
export_raw_csvs(runs, raw_csv_dir);

% ---- Export dedicated raw unfiltered time-series figures for every lab (R6/R8 separated per mode)
plot_raw_unfiltered(r0_runs, r3_runs, r4_runs, r6_runs, r8_runs, raw_fig_dir);

fprintf('Note: Current_A uses DC-board gain (66.3185 counts/A, unverified for stepper path); R0 corrects zero-offset only.\n');
save(fullfile(data_dir, 'analysis_summary.mat'), 'summary');
fprintf('Analysis complete.\n  Tables      -> %s\n  Figures     -> %s\n  Raw CSVs    -> %s\n  Raw Figures -> %s\n', ...
    tbl_dir, fig_dir, raw_csv_dir, raw_fig_dir);
end

% =========================================================================
function T = analyze_r3(r3_runs, cal, tbl_dir, fig_dir)
[mode_names, M_vals] = mode_catalog();
r3_runs = sort_by_trial(r3_runs);
nT = numel(r3_runs);
rpm_th   = nan(6, nT);
rpm_m    = nan(6, nT);
rpm_sd   = nan(6, nT);
lpf_m    = nan(6, nT);
lpf_sd   = nan(6, nT);
cur_m    = nan(6, nT);
live_lpf = false(1, nT);

for tr = 1:nT
    D = extract_signals(r3_runs{tr}.logsout);
    live_lpf(tr) = D.has_live_lpf;
    I_corr = (D.current_pa1 - cal.adc_i_zero) / cal.adc_per_A;
    for k = 1:6
        m = (round(D.step_id) == k) & (D.is_steady > 0.5);
        if any(m)
            rpm_th(k, tr) = mean(D.rpm_theory(m));
            rpm_m(k, tr)  = mean(D.rpm_meas(m));
            rpm_sd(k, tr) = std(D.rpm_meas(m));
            lpf_m(k, tr)  = mean(D.rpm_meas_lpf(m));
            lpf_sd(k, tr) = std(D.rpm_meas_lpf(m));
            cur_m(k, tr)  = mean(I_corr(m));
        end
    end
end

th_mean      = mean(rpm_th, 2, 'omitnan');
raw_mean     = mean(rpm_m, 2, 'omitnan');
raw_trial_sd = std(rpm_m, 0, 2, 'omitnan');
raw_rip_sd   = mean(rpm_sd, 2, 'omitnan');
cur_mean     = mean(cur_m, 2, 'omitnan');
lpf_mean     = mean(lpf_m, 2, 'omitnan');
lpf_trial_sd = std(lpf_m, 0, 2, 'omitnan');
lpf_rip_sd   = mean(lpf_sd, 2, 'omitnan');
red_pct      = nan(6, 1);
for k = 1:6
    if isfinite(raw_rip_sd(k)) && raw_rip_sd(k) > 1e-12 && isfinite(lpf_rip_sd(k))
        red_pct(k) = 100 * (1 - lpf_rip_sd(k) / raw_rip_sd(k));
    end
end
mean_shift = abs(lpf_mean - raw_mean);
n_valid    = sum(~isnan(rpm_m), 2);
if all(live_lpf)
    src_str = 'live';
elseif ~any(live_lpf)
    src_str = 'offline_fallback';
else
    src_str = 'mixed';
end
lpf_src = repmat({src_str}, 6, 1);

T = table(mode_names(:), M_vals(:), th_mean, raw_mean, raw_trial_sd, raw_rip_sd, cur_mean, ...
    lpf_mean, lpf_trial_sd, lpf_rip_sd, red_pct, mean_shift, lpf_src, n_valid, ...
    'VariableNames', {'Mode','Microstep_M','Theory_RPM','Meas_Mean_RPM','Trial_SD_RPM', ...
    'Ripple_SD_RPM','Current_A','LPF_Mean_RPM','LPF_Trial_SD_RPM','LPF_Ripple_SD_RPM', ...
    'Ripple_Reduction_Pct','LPF_Mean_Shift_RPM','LPF_Source','N_Trials'});
writetable(T, fullfile(tbl_dir, 'R3_drive_modes_summary.csv'));
fprintf('\n--- R3 All 6 Drive Modes Summary (LPF source: %s) ---\n', src_str); disp(T);

% Figure 2: Real-Op speed waveforms across the 6 modes (Trial 1, Raw vs 10 Hz LPF vs Theory)
D1 = extract_signals(r3_runs{1}.logsout);
f = figure('Visible', 'off', 'Color', 'w', 'Position', [100 100 920 460]);
plot(D1.t, D1.rpm_meas, '-', 'Color', [0.72 0.84 0.98], 'LineWidth', 0.8, 'DisplayName', 'Measured RPM (Raw)'); hold on;
plot(D1.t, D1.rpm_meas_lpf, 'b-', 'LineWidth', 1.5, 'DisplayName', 'Measured RPM (10 Hz LPF)');
plot(D1.t, D1.rpm_theory, 'k--', 'LineWidth', 1.2, 'DisplayName', 'Theory RPM');
grid on; xlim([0 max(D1.t)]);
xlabel('Time (s)'); ylabel('Speed (RPM)');
title('R3: Measured (Raw & 10 Hz LPF) vs Theoretical Speed Across All 6 DRV8825 Modes');
legend('Location', 'northeast');
save_fig(f, fullfile(fig_dir, 'Fig2_R3_DriveModes_Waveforms.png'));
end

% =========================================================================
function [T, T_trials] = analyze_r4_r5(r4_runs, cal, tbl_dir, fig_dir)
[mode_names, M_vals] = mode_catalog();
rows = {};
trial_rows = {};

for dm = 1:6
    sub = {};
    for i = 1:numel(r4_runs)
        if get_drive_mode(r4_runs{i}) == dm
            sub{end+1} = r4_runs{i}; %#ok<AGROW>
        end
    end
    if isempty(sub), continue; end
    sub = sort_by_trial(sub);
    nTr = numel(sub);

    D_list = cell(1, nTr);
    sids_all = [];
    for tr = 1:nTr
        D_list{tr} = extract_signals(sub{tr}.logsout);
        s_tr = unique(round(D_list{tr}.step_id(D_list{tr}.step_id >= 1 & D_list{tr}.step_id < 99)));
        sids_all = union(sids_all, s_tr(:)');
    end
    if isempty(sids_all), continue; end
    nS = numel(sids_all);

    f_mat      = nan(nTr, nS);
    th_mat     = nan(nTr, nS);
    m_mat      = nan(nTr, nS);
    sd_mat     = nan(nTr, nS);
    lpf_mat    = nan(nTr, nS);
    lpf_sd_mat = nan(nTr, nS);
    i_mat      = nan(nTr, nS);

    for tr = 1:nTr
        D = D_list{tr};
        tr_num = get_trial_num(sub{tr}, tr);
        src_fn = sub{tr}.filename;
        I_corr = (D.current_pa1 - cal.adc_i_zero) / cal.adc_per_A;
        for si = 1:nS
            s = sids_all(si);
            msk = (round(D.step_id) == s) & (D.is_steady > 0.5);
            if any(msk)
                fv   = mean(D.target_freq(msk));
                thv  = mean(D.rpm_theory(msk));
                mv   = mean(D.rpm_meas(msk));
                sdv  = std(D.rpm_meas(msk));
                lv   = mean(D.rpm_meas_lpf(msk));
                lsdv = std(D.rpm_meas_lpf(msk));
                iv   = mean(I_corr(msk));
                epct = 100 * abs(mv - thv) / max(thv, 1e-9);

                f_mat(tr, si)      = fv;
                th_mat(tr, si)     = thv;
                m_mat(tr, si)      = mv;
                sd_mat(tr, si)     = sdv;
                lpf_mat(tr, si)    = lv;
                lpf_sd_mat(tr, si) = lsdv;
                i_mat(tr, si)      = iv;

                trial_rows(end+1, :) = {dm, mode_names{dm}, M_vals(dm), tr_num, s, round(fv), ...
                    thv, mv, sdv, lv, lsdv, epct, iv, src_fn}; %#ok<AGROW>
            end
        end
    end

    for si = 1:nS
        n_valid = sum(~isnan(m_mat(:, si)));
        if n_valid == 0, continue; end
        th_m      = mean(th_mat(:, si), 'omitnan');
        me_m      = mean(m_mat(:, si), 'omitnan');
        me_s      = std(m_mat(:, si), 0, 'omitnan');
        rip_m     = mean(sd_mat(:, si), 'omitnan');
        lpf_m     = mean(lpf_mat(:, si), 'omitnan');
        lpf_rip_m = mean(lpf_sd_mat(:, si), 'omitnan');
        cur_m     = mean(i_mat(:, si), 'omitnan');
        err_pct   = 100 * abs(me_m - th_m) / max(th_m, 1e-9);
        fq_m      = round(mean(f_mat(:, si), 'omitnan'));

        rows(end+1, :) = {mode_names{dm}, M_vals(dm), fq_m, th_m, me_m, me_s, err_pct, ...
            cur_m, n_valid, rip_m, lpf_m, lpf_rip_m}; %#ok<AGROW>
    end
end

T = cell2table(rows, 'VariableNames', {'Mode','Microstep_M','Freq_Hz','Theory_RPM', ...
    'Meas_Mean_RPM','Meas_SD_RPM','Error_Pct','Current_A','N_Trials', ...
    'Ripple_SD_RPM','LPF_Mean_RPM','LPF_Ripple_SD_RPM'});
writetable(T, fullfile(tbl_dir, 'R4_R5_freq_vs_speed.csv'));

T_trials = cell2table(trial_rows, 'VariableNames', {'Drive_Mode','Mode','Microstep_M', ...
    'Trial','Step_ID','Freq_Hz','Theory_RPM','Meas_RPM','Ripple_SD_RPM','LPF_RPM', ...
    'LPF_Ripple_SD_RPM','Error_Pct','Current_A','Source_File'});
writetable(T_trials, fullfile(tbl_dir, 'R4_R5_trials.csv'));

fprintf('\n--- R4 & R5 Frequency vs Speed (first 12 rows; %d trial rows exported) ---\n', height(T_trials));
disp(T(1:min(12, height(T)), :));

% Figure 1: Frequency vs Speed (6 modes, distinct high-contrast colors + markers)
f = figure('Visible', 'off', 'Color', 'w', 'Position', [100 100 920 520]);
cols = mode_colors();
mkrs = {'o', 's', '^', 'd', 'v', 'p'};
hold on;
for dm = 1:6
    idx = (T.Microstep_M == M_vals(dm));
    if ~any(idx), continue; end
    fq = T.Freq_Hz(idx);
    plot(fq, T.Theory_RPM(idx), '--', 'Color', cols(dm,:), 'LineWidth', 1.1, 'HandleVisibility', 'off');
    errorbar(fq, T.Meas_Mean_RPM(idx), T.Meas_SD_RPM(idx), ['-' mkrs{dm}], 'Color', cols(dm,:), ...
        'MarkerFaceColor', cols(dm,:), 'LineWidth', 1.4, 'MarkerSize', 5, ...
        'DisplayName', sprintf('%s (M=%d)', mode_names{dm}, M_vals(dm)));
end
grid on; xlabel('STEP Frequency (Hz)'); ylabel('Motor Speed (RPM)');
title('R4 & R5: Speed vs STEP Frequency (Dashed = Theory, Mean \pm SD)');
legend('Location', 'northwest');
save_fig(f, fullfile(fig_dir, 'Fig1_R4_FreqVsSpeed.png'));
end

% =========================================================================
function out = analyze_r6(r6_runs, ~, tbl_dir)
[mode_names, M_vals] = mode_catalog();
dm_all = cellfun(@get_drive_mode, r6_runs);
dm_u   = sort(unique(dm_all), 'ascend');

step_rows  = {};
trial_rows = {};
sum_rows   = {};
by_mode = struct('drive_mode', {}, 'mode', {}, 'microstep_M', {}, 'steps_per_rev', {}, ...
    'pullin_trials_hz', {}, 'pullin_mean_hz', {}, 'pullin_sd_hz', {}, 'pullin_speed_rpm', {}, ...
    'n_trials', {}, 'n_stalled', {}, 'n_censored', {}, 'max_tested_hz', {});

for im = 1:numel(dm_u)
    dm  = dm_u(im);
    M   = M_vals(dm);
    sub = sort_by_trial(r6_runs(dm_all == dm));
    nT  = numel(sub);
    spr = get_steps_per_rev(sub{1});

    pullin_hz      = nan(nT, 1);
    stalled_any    = zeros(nT, 1);
    first_stall_hz = nan(nT, 1);
    max_tested_hz  = nan(nT, 1);

    for tr_idx = 1:nT
        tr_num = get_trial_num(sub{tr_idx}, tr_idx);
        src_fn = sub{tr_idx}.filename;
        D = extract_signals(sub{tr_idx}.logsout);
        sids = unique(round(D.step_id(D.step_id >= 1 & D.step_id < 99)));
        last_ok  = 0;
        max_f_tr = 0;

        for s = sids(:)'
            m_act = (round(D.step_id) == s);
            m_std = m_act & (D.is_steady > 0.5);
            if ~any(m_std), m_std = m_act; end

            fq    = mean(D.target_freq(m_act));
            fq_r  = round(fq);
            max_f_tr = max(max_f_tr, fq_r);
            th    = mean(D.rpm_theory(m_std));
            me    = mean(D.rpm_meas(m_std));
            ls_pk = max(D.lost_steps(m_act));

            % End-of-step lost steps: mean over the final 0.2 s of the steady window
            % (fallback: final 15% of steady samples if sample period is coarse).
            idx_std   = find(m_std);
            t_std_end = D.t(idx_std(end));
            m_end     = m_std & (D.t >= t_std_end - 0.2);
            if sum(m_end) < 2 && numel(idx_std) >= 2
                n_tail = max(2, ceil(0.15 * numel(idx_std)));
                m_end  = false(size(D.t));
                m_end(idx_std(end - n_tail + 1 : end)) = true;
            end
            ls_end = mean(D.lost_steps(m_end));

            % Stall criterion: steady speed < 85% of theory AND end-of-step lost steps >= 4
            % (avoids false-triggering on transient start-up lag when motor locks into sync).
            stalled = (me < 0.85 * th) && (ls_end >= 4.0);

            step_rows(end+1, :) = {dm, mode_names{dm}, M, tr_num, s, fq_r, th, me, ...
                ls_pk, ls_end, double(stalled), src_fn}; %#ok<AGROW>

            if ~stalled && isnan(pullin_hz(tr_idx))
                last_ok = fq_r;
            elseif stalled && isnan(pullin_hz(tr_idx))
                pullin_hz(tr_idx)      = last_ok;
                stalled_any(tr_idx)    = 1;
                first_stall_hz(tr_idx) = fq_r;
            end
        end

        if isnan(pullin_hz(tr_idx))
            pullin_hz(tr_idx) = last_ok;
        end
        max_tested_hz(tr_idx) = max_f_tr;

        trial_rows(end+1, :) = {dm, mode_names{dm}, M, tr_num, pullin_hz(tr_idx), ...
            pullin_hz(tr_idx) * 60 / (M * spr), stalled_any(tr_idx), ...
            first_stall_hz(tr_idx), max_f_tr, src_fn}; %#ok<AGROW>
    end

    pm    = mean(pullin_hz, 'omitnan');
    ps    = std(pullin_hz, 0, 'omitnan');
    p_rpm = pm * 60 / (M * spr);
    n_st  = sum(stalled_any > 0.5);
    n_cen = nT - n_st;
    max_h = max(max_tested_hz);

    sum_rows(end+1, :) = {dm, mode_names{dm}, M, pm, ps, p_rpm, nT, n_st, n_cen, max_h}; %#ok<AGROW>

    by_mode(im) = struct('drive_mode', dm, 'mode', mode_names{dm}, 'microstep_M', M, ...
        'steps_per_rev', spr, 'pullin_trials_hz', pullin_hz, 'pullin_mean_hz', pm, ...
        'pullin_sd_hz', ps, 'pullin_speed_rpm', p_rpm, 'n_trials', nT, ...
        'n_stalled', n_st, 'n_censored', n_cen, 'max_tested_hz', max_h);
end

T_steps = cell2table(step_rows, 'VariableNames', {'Drive_Mode','Mode','Microstep_M', ...
    'Trial','Step_ID','Freq_Hz','Theory_RPM','Meas_RPM','Peak_Lost_Steps', ...
    'End_Lost_Steps','Stalled','Source_File'});
writetable(T_steps, fullfile(tbl_dir, 'R6_pullin_steps.csv'));

T_trials = cell2table(trial_rows, 'VariableNames', {'Drive_Mode','Mode','Microstep_M', ...
    'Trial','PullIn_Hz','PullIn_Speed_RPM','Stalled_Any','First_Stall_Hz', ...
    'Max_Tested_Hz','Source_File'});
writetable(T_trials, fullfile(tbl_dir, 'R6_pullin_trials.csv'));

T_sum = cell2table(sum_rows, 'VariableNames', {'Drive_Mode','Mode','Microstep_M', ...
    'PullIn_Mean_Hz','PullIn_SD_Hz','PullIn_Speed_RPM','N_Trials', ...
    'N_Stalled_Trials','N_Censored','Max_Tested_Hz'});
writetable(T_sum, fullfile(tbl_dir, 'R6_pullin_summary.csv'));

out = struct('by_mode', by_mode, 'summary_table', T_sum, 'trials_table', T_trials, ...
    'steps_table', T_steps);
if isscalar(by_mode)
    out.pullin_trials_hz = by_mode(1).pullin_trials_hz;
    out.pullin_mean_hz   = by_mode(1).pullin_mean_hz;
    out.pullin_sd_hz     = by_mode(1).pullin_sd_hz;
else
    out.pullin_mean_hz = [by_mode.pullin_mean_hz];
    out.pullin_sd_hz   = [by_mode.pullin_sd_hz];
end

fprintf('\n--- R6 Pull-In Frequency by Drive Mode (Step from Rest) ---\n');
disp(T_sum);
end

% =========================================================================
function [T, T_trials] = analyze_r8(~, r6_res, r8_runs, ~, tbl_dir, fig_dir)
[mode_names, M_vals, mode_tags] = mode_catalog();
dm_list = [];
if ~isempty(r6_res) && isfield(r6_res, 'by_mode') && ~isempty(r6_res.by_mode)
    dm_list = [dm_list, [r6_res.by_mode.drive_mode]];
end
if ~isempty(r8_runs)
    r8_dm_all = cellfun(@get_drive_mode, r8_runs);
    dm_list = [dm_list, r8_dm_all];
else
    r8_dm_all = [];
end
dm_u = sort(unique(dm_list), 'ascend');

rows       = {};
trial_rows = {};
rep_runs   = struct('dm', {}, 'run', {}, 'stall_t', {}, 'stall_f', {}, 'stalled', {});

for im = 1:numel(dm_u)
    dm = dm_u(im);
    M  = M_vals(dm);

    % Include R6 (Step Input / unlimited accel) as first row for this drive mode
    if ~isempty(r6_res) && isfield(r6_res, 'by_mode') && ~isempty(r6_res.by_mode)
        k6 = find([r6_res.by_mode.drive_mode] == dm, 1);
        if ~isempty(k6)
            bm = r6_res.by_mode(k6);
            rows(end+1, :) = {dm, mode_names{dm}, M, 'Step Input (No Limit)', Inf, ...
                bm.pullin_mean_hz, bm.pullin_sd_hz, bm.pullin_speed_rpm, ...
                bm.n_trials, bm.n_stalled, bm.n_censored, bm.max_tested_hz}; %#ok<AGROW>
        end
    end

    % Group R8 runs for this drive mode by acceleration value (descending: 4000, 2000, 1000, 500)
    r8_mode = r8_runs(r8_dm_all == dm);
    if isempty(r8_mode), continue; end

    acc_all = cellfun(@(r) round(double(r.meta.accel)), r8_mode);
    acc_u   = sort(unique(acc_all), 'descend');
    sample_run = []; sample_t = NaN; sample_f = NaN; sample_st = false;

    for a = acc_u(:)'
        sub = sort_by_trial(r8_mode(acc_all == a));
        nT  = numel(sub);
        spr = get_steps_per_rev(sub{1});

        f_crit      = nan(nT, 1);
        stalled_vec = zeros(nT, 1);
        max_cmd_vec = nan(nT, 1);

        for tr_idx = 1:nT
            tr_num = get_trial_num(sub{tr_idx}, tr_idx);
            src_fn = sub{tr_idx}.filename;
            D = extract_signals(sub{tr_idx}.logsout);
            m = (round(D.step_id) == 1) & (D.is_steady > 0.5) & (D.freq_cmd > 250);
            if ~any(m), m = (round(D.step_id) == 1) & (D.is_steady > 0.5); end
            if ~any(m), m = (round(D.step_id) == 1); end

            % Causal 80 ms speed-drop detector: immune to 1 ms raw encoder jitter and
            % UART transport-lag drift in lost_steps during rapid acceleration ramps.
            dt_med = median(diff(D.t));
            win_n  = max(1, round(0.08 / max(dt_med, 1e-4)));
            rm_win = movmean(D.rpm_meas, [win_n-1 0]);
            rt_win = movmean(D.rpm_theory, [win_n-1 0]);
            bad = m & (rt_win > 40) & (rm_win < 0.70 * rt_win);
            idx = find(bad, 1, 'first');

            if ~isempty(idx)
                % The causal window fires ~30 ms after the drop; walk back to the onset
                % (last contiguous samples below 90 % of theory, 20 ms smoothing).
                % f_echo, not freq_cmd: it arrives in the same Rx frame as the encoder speed.
                rm_s = movmean(D.rpm_meas, max(1, round(0.02 / max(dt_med, 1e-4))));
                j = idx;
                while j > 1 && m(j-1) && rm_s(j-1) < 0.9 * D.rpm_theory(j-1)
                    j = j - 1;
                end
                f_crit(tr_idx)      = D.f_echo(j);
                stalled_vec(tr_idx) = 1;
                t_st                = D.t(j);
                if isempty(sample_run)
                    sample_run = sub{tr_idx};
                    sample_t   = t_st;
                    sample_f   = f_crit(tr_idx);
                    sample_st  = true;
                end
            else
                f_crit(tr_idx)      = max(D.f_echo(m));
                stalled_vec(tr_idx) = 0;
                t_st                = NaN;
            end

            f_cmd_max           = max(D.freq_cmd(m));
            max_cmd_vec(tr_idx) = f_cmd_max;
            ls_pk               = max(D.lost_steps(m));
            spd_rpm             = f_crit(tr_idx) * 60 / (M * spr);

            trial_rows(end+1, :) = {dm, mode_names{dm}, M, sprintf('%d Hz/s', a), a, ...
                tr_num, f_crit(tr_idx), spd_rpm, stalled_vec(tr_idx), ...
                1 - stalled_vec(tr_idx), t_st, round(f_cmd_max), ls_pk, src_fn}; %#ok<AGROW>
        end

        fm      = mean(f_crit, 'omitnan');
        fs      = std(f_crit, 0, 'omitnan');
        n_st    = sum(stalled_vec > 0.5);
        n_cen   = nT - n_st;
        ceil_hz = round(max(max_cmd_vec));

        rows(end+1, :) = {dm, mode_names{dm}, M, sprintf('%d Hz/s', a), a, ...
            fm, fs, fm * 60 / (M * spr), nT, n_st, n_cen, ceil_hz}; %#ok<AGROW>
    end

    if isempty(sample_run)
        sample_run = r8_mode{1};
    end
    rep_runs(end+1) = struct('dm', dm, 'run', sample_run, 'stall_t', sample_t, ...
        'stall_f', sample_f, 'stalled', sample_st); %#ok<AGROW>
end

T = cell2table(rows, 'VariableNames', {'Drive_Mode','Mode','Microstep_M','Condition', ...
    'Accel_Hz_s','MaxFreq_Mean_Hz','MaxFreq_SD_Hz','MaxSpeed_RPM', ...
    'N_Trials','N_Stalled','N_Censored','Ceiling_Hz'});
writetable(T, fullfile(tbl_dir, 'R8_accel_pullout.csv'));
fprintf('\n--- R6 & R8 Acceleration vs Max Frequency Before Loss Step (Per Mode) ---\n'); disp(T);

if ~isempty(trial_rows)
    T_trials = cell2table(trial_rows, 'VariableNames', {'Drive_Mode','Mode','Microstep_M', ...
        'Condition','Accel_Hz_s','Trial','PullOut_Freq_Hz','PullOut_Speed_RPM', ...
        'Stalled','Reached_Ceiling','Stall_Time_s','Max_Cmd_Freq_Hz', ...
        'Peak_Lost_Steps','Source_File'});
    writetable(T_trials, fullfile(tbl_dir, 'R8_trials.csv'));
else
    T_trials = table();
end

% Figure 3: Loss Step Time Series (per mode + primary representative for backwards compatibility)
if ~isempty(rep_runs)
    for ir = 1:numel(rep_runs)
        dm = rep_runs(ir).dm;
        plot_fig3_r8(rep_runs(ir), mode_names{dm}, ...
            fullfile(fig_dir, sprintf('Fig3_R6_R8_LossStep_TimeSeries_%s.png', mode_tags{dm})));
    end
    stalled_idx = find([rep_runs.stalled], 1, 'first');
    if isempty(stalled_idx), stalled_idx = 1; end
    dm_rep = rep_runs(stalled_idx).dm;
    plot_fig3_r8(rep_runs(stalled_idx), mode_names{dm_rep}, ...
        fullfile(fig_dir, 'Fig3_R6_R8_LossStep_TimeSeries.png'));
end

% Figure 4: Accel vs Max Frequency bar chart with +/- SD (grouped cleanly by drive mode)
plot_fig4_r8(T, mode_names, fullfile(fig_dir, 'Fig4_R8_Accel_vs_PullOut.png'));
end

% =========================================================================
function plot_fig3_r8(rep, mode_label, out_png)
D = extract_signals(rep.run.logsout);
f3 = figure('Visible', 'off', 'Color', 'w', 'Position', [100 100 920 600]);

subplot(3,1,1);
plot(D.t, D.freq_cmd, 'b-', 'LineWidth', 1.3, 'DisplayName', 'f_{cmd}'); hold on;
plot(D.t, D.f_echo, 'r--', 'LineWidth', 1.0, 'DisplayName', 'f_{echo}');
if rep.stalled && isfinite(rep.stall_t)
    xline(rep.stall_t, 'm--', sprintf('Pull-Out (%.0f Hz)', rep.stall_f), ...
        'LineWidth', 1.1, 'LabelVerticalAlignment', 'middle', 'HandleVisibility', 'off');
end
grid on; xlim([0 max(D.t)]); ylabel('Freq (Hz)');
title(sprintf('R6 & R8: Loss Step Time Series — %s (Accel = %d Hz/s)', ...
    mode_label, round(double(rep.run.meta.accel))));
legend('Location', 'northwest');

subplot(3,1,2);
plot(D.t, D.rpm_meas, '-', 'Color', [0.72 0.84 0.98], 'LineWidth', 0.8, 'DisplayName', 'Measured RPM (Raw)'); hold on;
plot(D.t, D.rpm_meas_lpf, 'b-', 'LineWidth', 1.5, 'DisplayName', 'Measured RPM (10 Hz LPF)');
plot(D.t, D.rpm_theory, 'k--', 'LineWidth', 1.2, 'DisplayName', 'Theory RPM');
if rep.stalled && isfinite(rep.stall_t)
    xline(rep.stall_t, 'm--', 'LineWidth', 1.1, 'HandleVisibility', 'off');
end
grid on; xlim([0 max(D.t)]); ylabel('Speed (RPM)');
legend('Location', 'northwest');

subplot(3,1,3);
plot(D.t, D.lost_steps, 'r-', 'LineWidth', 1.3, 'DisplayName', 'Lost Steps (full)');
if rep.stalled && isfinite(rep.stall_t)
    hold on;
    xline(rep.stall_t, 'm--', 'LineWidth', 1.1, 'HandleVisibility', 'off');
end
grid on; xlim([0 max(D.t)]); xlabel('Time (s)'); ylabel('Lost Steps (full)');
save_fig(f3, out_png);
end

% =========================================================================
function plot_fig4_r8(T, mode_names, out_png)
has_inf = any(isinf(T.Accel_Hz_s));
fin_acc = sort(unique(T.Accel_Hz_s(isfinite(T.Accel_Hz_s))), 'descend');
cond_acc = fin_acc(:)';
cond_labels = arrayfun(@(a) sprintf('%d Hz/s', round(a)), fin_acc(:)', 'UniformOutput', false);
if has_inf
    cond_acc    = [Inf, cond_acc];
    cond_labels = [{'Step Input (No Limit)'}, cond_labels];
end

dm_u   = unique(T.Drive_Mode, 'stable');
nCond  = numel(cond_acc);
nModes = numel(dm_u);
Y_mean = nan(nCond, nModes);
Y_sd   = nan(nCond, nModes);
Y_cen  = false(nCond, nModes);

for im = 1:nModes
    dm = dm_u(im);
    for ic = 1:nCond
        if isinf(cond_acc(ic))
            idx = find((T.Drive_Mode == dm) & isinf(T.Accel_Hz_s), 1);
        else
            idx = find((T.Drive_Mode == dm) & (T.Accel_Hz_s == cond_acc(ic)), 1);
        end
        if ~isempty(idx)
            Y_mean(ic, im) = T.MaxFreq_Mean_Hz(idx);
            Y_sd(ic, im)   = T.MaxFreq_SD_Hz(idx);
            Y_cen(ic, im)  = (T.N_Censored(idx) > 0) && (T.N_Stalled(idx) == 0);
        end
    end
end

cols = mode_colors();
f4 = figure('Visible', 'off', 'Color', 'w', 'Position', [100 100 880 480]);
hold on;

if nModes == 1
    dm = dm_u(1);
    x = 1:nCond;
    bar(x, Y_mean(:, 1), 0.55, 'FaceColor', cols(dm,:), 'DisplayName', mode_names{dm});
    errorbar(x, Y_mean(:, 1), Y_sd(:, 1), 'k.', 'LineWidth', 1.5, 'CapSize', 10, 'HandleVisibility', 'off');
    for ic = 1:nCond
        if Y_cen(ic, 1) && isfinite(Y_mean(ic, 1))
            text(x(ic), Y_mean(ic, 1) + 0.03 * max(Y_mean(:,1), [], 'omitnan'), ...
                sprintf('>=%.0f', Y_mean(ic, 1)), 'HorizontalAlignment', 'center', ...
                'FontSize', 8, 'FontWeight', 'bold');
        end
    end
    set(gca, 'XTick', x, 'XTickLabel', cond_labels);
    title(sprintf('R8: Acceleration Limit vs Pull-Out Frequency — %s (Mean \\pm SD)', mode_names{dm}));
elseif nCond == 1
    x = 1:nModes;
    b = bar(x, Y_mean(1, :), 0.55);
    b.FaceColor = 'flat';
    for im = 1:nModes
        b.CData(im, :) = cols(dm_u(im), :);
    end
    errorbar(x, Y_mean(1, :), Y_sd(1, :), 'k.', 'LineWidth', 1.5, 'CapSize', 10, 'HandleVisibility', 'off');
    set(gca, 'XTick', x, 'XTickLabel', mode_names(dm_u));
    title(sprintf('R6/R8: %s Max Frequency by Drive Mode (Mean \\pm SD)', cond_labels{1}));
else
    b = bar(1:nCond, Y_mean, 'grouped');
    for im = 1:nModes
        dm = dm_u(im);
        b(im).FaceColor   = cols(dm, :);
        b(im).DisplayName = mode_names{dm};
        xe = b(im).XEndPoints;
        errorbar(xe, Y_mean(:, im), Y_sd(:, im), 'k.', 'LineWidth', 1.4, 'CapSize', 8, 'HandleVisibility', 'off');
        for ic = 1:nCond
            if Y_cen(ic, im) && isfinite(Y_mean(ic, im))
                text(xe(ic), Y_mean(ic, im) + 0.03 * max(Y_mean(:), [], 'omitnan'), ...
                    sprintf('>=%.0f', Y_mean(ic, im)), 'HorizontalAlignment', 'center', ...
                    'FontSize', 8, 'FontWeight', 'bold');
            end
        end
    end
    set(gca, 'XTick', 1:nCond, 'XTickLabel', cond_labels);
    legend('Location', 'northwest');
    title('R8: Acceleration Limit vs Pull-Out Frequency by Drive Mode (Mean \pm SD)');
end

sd_zero = Y_sd;
sd_zero(isnan(sd_zero)) = 0;
y_top = max(Y_mean(:) + sd_zero(:), [], 'omitnan');
if isfinite(y_top) && y_top > 0
    ylim([0, 1.18 * y_top]);
end
grid on;
ylabel('Max Frequency Before Loss Step (Hz)');
save_fig(f4, out_png);
end

% =========================================================================
function [mode_names, M_vals, mode_tags] = mode_catalog()
mode_names = {'Full (1)', 'Half (1/2)', '1/4', '1/8', '1/16', '1/32'};
M_vals     = [1, 2, 4, 8, 16, 32];
mode_tags  = {'M1_Full', 'M2_Half', 'M3_1_4', 'M4_1_8', 'M5_1_16', 'M6_1_32'};
end

function cols = mode_colors()
cols = [0.00 0.45 0.74;   % Full: blue
        0.85 0.33 0.10;   % Half: orange
        0.13 0.55 0.13;   % 1/4:  green
        0.49 0.18 0.56;   % 1/8:  purple
        0.85 0.65 0.05;   % 1/16: gold
        0.75 0.05 0.18];  % 1/32: crimson
end

function dm = get_drive_mode(run)
if isfield(run, 'meta') && isfield(run.meta, 'drive_mode') && ~isempty(run.meta.drive_mode)
    dm = round(double(run.meta.drive_mode));
else
    D = extract_signals(run.logsout);
    ms = D.microstep_M(D.microstep_M > 0);
    if isempty(ms)
        dm = 1;
    else
        dm = round(log2(median(ms))) + 1;
    end
end
dm = max(1, min(6, dm));
end

function tr = get_trial_num(run, fallback_idx)
if isfield(run, 'meta') && isfield(run.meta, 'trial') && ~isempty(run.meta.trial)
    tr = round(double(run.meta.trial));
else
    tr = fallback_idx;
end
end

function spr = get_steps_per_rev(run)
if isfield(run, 'meta') && isfield(run.meta, 'steps_per_rev') && ~isempty(run.meta.steps_per_rev)
    spr = double(run.meta.steps_per_rev);
else
    spr = 200;
end
end

function sorted_runs = sort_by_trial(sub_runs)
if numel(sub_runs) <= 1
    sorted_runs = sub_runs;
    return;
end
tr_nums = zeros(numel(sub_runs), 1);
fnames  = strings(numel(sub_runs), 1);
for i = 1:numel(sub_runs)
    tr_nums(i) = get_trial_num(sub_runs{i}, i);
    if isfield(sub_runs{i}, 'filename')
        fnames(i) = string(sub_runs{i}.filename);
    end
end
[~, ord] = sortrows(table(tr_nums, fnames));
sorted_runs = sub_runs(ord);
end

function sub = filter_lab(runs, lab_name)
sub = {};
for i = 1:numel(runs)
    if strcmpi(runs{i}.meta.lab, lab_name)
        sub{end+1} = runs{i}; %#ok<AGROW>
    end
end
end

% =========================================================================
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
    % Exact 10 Hz 2nd-order Butterworth discrete LPF at Ts=0.001 s (matches Simulink block),
    % with exact bilinear transform at actual sample period when dt ~= 0.001 s.
    dt_med = median(diff(D.t));
    if abs(dt_med - 0.001) <= 1e-4
        b = [0.000944691843840 0.001889383687680 0.000944691843840];
        a = [1 -1.911197067426073 0.914975834801434];
        D.rpm_meas_lpf = filter(b, a, D.rpm_meas);
    elseif dt_med > 0 && (10.0 < 0.45 / dt_med)
        K = tan(pi * 10.0 * dt_med);
        norm_d = 1 + sqrt(2) * K + K^2;
        b = [K^2, 2*K^2, K^2] / norm_d;
        a = [1, 2*(K^2 - 1)/norm_d, (1 - sqrt(2)*K + K^2)/norm_d];
        D.rpm_meas_lpf = filter(b, a, D.rpm_meas);
    else
        D.rpm_meas_lpf = D.rpm_meas;
    end
    D.has_live_lpf = false;
end
end

% =========================================================================
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

% =========================================================================
function plot_raw_unfiltered(r0_runs, r3_runs, r4_runs, r6_runs, r8_runs, raw_fig_dir)
[mode_names, M_vals, mode_tags] = mode_catalog();

% 1) R0 Raw Baseline Noise Floor
if ~isempty(r0_runs)
    D = extract_signals(r0_runs{1}.logsout);
    f = figure('Visible', 'off', 'Color', 'w', 'Position', [100 100 900 560]);
    subplot(3,1,1); plot(D.t, D.current_pa1, 'b', 'LineWidth', 0.8); grid on;
    xlim([0 max(D.t)]); ylabel('PA1 (counts)'); title('R0 Raw Unfiltered Baseline (EN = 1, f = 0 Hz)');
    subplot(3,1,2); plot(D.t, D.load_pa0, 'r', 'LineWidth', 0.8); grid on;
    xlim([0 max(D.t)]); ylabel('PA0 (counts)');
    subplot(3,1,3); plot(D.t, D.omega, 'k', 'LineWidth', 0.8); grid on;
    xlim([0 max(D.t)]); xlabel('Time (s)'); ylabel('\omega (rad/s)');
    save_fig(f, fullfile(raw_fig_dir, 'Raw_R0_Baseline.png'));
end

% 2) R3 Raw Unfiltered 6-Mode Waveforms (all trials overlaid)
if ~isempty(r3_runs)
    r3_s = sort_by_trial(r3_runs);
    D_ref = extract_signals(r3_s{1}.logsout);
    f = figure('Visible', 'off', 'Color', 'w', 'Position', [100 100 960 540]);
    cols = lines(numel(r3_s));
    subplot(2,1,1); hold on;
    for tr = 1:numel(r3_s)
        D = extract_signals(r3_s{tr}.logsout);
        plot(D.t, D.rpm_meas, 'Color', cols(tr,:), 'LineWidth', 0.8, ...
            'DisplayName', sprintf('Trial %d raw', get_trial_num(r3_s{tr}, tr)));
    end
    plot(D_ref.t, D_ref.rpm_theory, '--k', 'LineWidth', 1.2, 'DisplayName', 'Theory RPM');
    grid on; xlim([0 max(D_ref.t)]); ylabel('Speed (RPM)');
    title('R3 Raw Unfiltered Speed Across All 6 DRV8825 Modes');
    legend('Location', 'northeast');
    subplot(2,1,2); hold on;
    for tr = 1:numel(r3_s)
        D = extract_signals(r3_s{tr}.logsout);
        plot(D.t, D.omega, 'Color', cols(tr,:), 'LineWidth', 0.8, ...
            'DisplayName', sprintf('Trial %d raw', get_trial_num(r3_s{tr}, tr)));
    end
    grid on; xlim([0 max(D_ref.t)]); xlabel('Time (s)'); ylabel('Raw \omega (rad/s)');
    save_fig(f, fullfile(raw_fig_dir, 'Raw_R3_AllModes_Unfiltered.png'));
end

% 3) R4/R5 Raw Unfiltered Time Series per Drive Mode (6 panels)
if ~isempty(r4_runs)
    panel_titles = {'Full (M=1)', 'Half (M=2)', '1/4 (M=4)', '1/8 (M=8)', '1/16 (M=16)', '1/32 (M=32)'};
    f = figure('Visible', 'off', 'Color', 'w', 'Position', [60 60 1120 720]);
    for dm = 1:6
        subplot(3,2,dm); hold on;
        sub = {};
        for i = 1:numel(r4_runs)
            if get_drive_mode(r4_runs{i}) == dm
                sub{end+1} = r4_runs{i}; %#ok<AGROW>
            end
        end
        if isempty(sub), title([panel_titles{dm} ' (no data)']); continue; end
        sub = sort_by_trial(sub);
        cols = lines(numel(sub));
        D_ref = extract_signals(sub{1}.logsout);
        for tr = 1:numel(sub)
            D = extract_signals(sub{tr}.logsout);
            plot(D.t, D.rpm_meas, 'Color', cols(tr,:), 'LineWidth', 0.7);
        end
        plot(D_ref.t, D_ref.rpm_theory, '--k', 'LineWidth', 1.1);
        grid on; xlim([0 max(D_ref.t)]); title(panel_titles{dm}); ylabel('RPM');
        if dm >= 5, xlabel('Time (s)'); end
    end
    sgtitle('R4 & R5 Raw Unfiltered Speed Time Series (All Modes & Trials, Dashed = Theory)');
    save_fig(f, fullfile(raw_fig_dir, 'Raw_R4_R5_AllModes_TimeSeries.png'));
end

% 4) R6 Raw Unfiltered Pull-In Ladder (separate figure per drive mode)
if ~isempty(r6_runs)
    dm_all = cellfun(@get_drive_mode, r6_runs);
    dm_u   = sort(unique(dm_all), 'ascend');
    for im = 1:numel(dm_u)
        dm  = dm_u(im);
        sub = sort_by_trial(r6_runs(dm_all == dm));
        D1  = extract_signals(sub{1}.logsout);
        f = figure('Visible', 'off', 'Color', 'w', 'Position', [100 100 960 620]);
        cols = lines(numel(sub));

        subplot(3,1,1); hold on;
        plot(D1.t, D1.freq_cmd, 'b', 'LineWidth', 1.1, 'DisplayName', 'f_{cmd}');
        plot(D1.t, D1.f_echo, '--r', 'LineWidth', 0.9, 'DisplayName', 'f_{echo}');
        grid on; xlim([0 max(D1.t)]); ylabel('Freq (Hz)');
        title(sprintf('R6 Raw Unfiltered Pull-In Ladder — %s (M=%d, Step from Rest)', ...
            mode_names{dm}, M_vals(dm)));
        legend('Location', 'northwest');

        subplot(3,1,2); hold on;
        for tr = 1:numel(sub)
            D = extract_signals(sub{tr}.logsout);
            plot(D.t, D.rpm_meas, 'Color', cols(tr,:), 'LineWidth', 0.8, ...
                'DisplayName', sprintf('Trial %d raw', get_trial_num(sub{tr}, tr)));
        end
        plot(D1.t, D1.rpm_theory, '--k', 'LineWidth', 1.0, 'DisplayName', 'Theory');
        grid on; xlim([0 max(D1.t)]); ylabel('Speed (RPM)'); legend('Location', 'northwest');

        subplot(3,1,3); hold on;
        for tr = 1:numel(sub)
            D = extract_signals(sub{tr}.logsout);
            plot(D.t, D.lost_steps, 'Color', cols(tr,:), 'LineWidth', 0.9, ...
                'DisplayName', sprintf('Trial %d', get_trial_num(sub{tr}, tr)));
        end
        grid on; xlim([0 max(D1.t)]); xlabel('Time (s)'); ylabel('Lost Steps (full)');
        legend('Location', 'northwest');
        save_fig(f, fullfile(raw_fig_dir, sprintf('Raw_R6_PullIn_%s.png', mode_tags{dm})));
    end
end

% 5) R8 Raw Unfiltered Acceleration Ramps (separate figure per drive mode, one panel per accel)
if ~isempty(r8_runs)
    dm_all = cellfun(@get_drive_mode, r8_runs);
    dm_u   = sort(unique(dm_all), 'ascend');
    for im = 1:numel(dm_u)
        dm   = dm_u(im);
        r8_m = r8_runs(dm_all == dm);
        acc_all = cellfun(@(r) round(double(r.meta.accel)), r8_m);
        acc_u   = sort(unique(acc_all), 'descend');
        nA = numel(acc_u);
        f = figure('Visible', 'off', 'Color', 'w', 'Position', [60 60 1120 max(460, 260*ceil(nA/2))]);
        for ia = 1:nA
            a   = acc_u(ia);
            sub = sort_by_trial(r8_m(acc_all == a));
            subplot(ceil(nA/2), min(2, nA), ia); hold on;
            cols = lines(numel(sub));
            D_ref = extract_signals(sub{1}.logsout);
            for tr = 1:numel(sub)
                D = extract_signals(sub{tr}.logsout);
                plot(D.t, D.rpm_meas, 'Color', cols(tr,:), 'LineWidth', 0.8, ...
                    'DisplayName', sprintf('Trial %d', get_trial_num(sub{tr}, tr)));
            end
            plot(D_ref.t, D_ref.rpm_theory, '--k', 'LineWidth', 1.1, 'DisplayName', 'Theory');
            grid on; xlim([0 max(D_ref.t)]);
            title(sprintf('Accel = %d Hz/s (raw)', a));
            xlabel('Time (s)'); ylabel('Speed (RPM)');
            legend('Location', 'northwest');
        end
        sgtitle(sprintf('R8 Raw Unfiltered Acceleration Ramps — %s (M=%d, All Trials Overlaid)', ...
            mode_names{dm}, M_vals(dm)));
        save_fig(f, fullfile(raw_fig_dir, sprintf('Raw_R8_Accel_%s.png', mode_tags{dm})));
    end
end
end

% =========================================================================
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
