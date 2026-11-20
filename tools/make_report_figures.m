function make_report_figures()
% 300-dpi report figures + Raw-vs-LPF metrics from the 3-trial / LPF datasets
% (20261120_200111, hw_lpf_*) into stepper_data/report_final. Dataset folders and
% the Fig3/Fig4 pull-out values are specific to those runs; adapt for new data.
root = fullfile(fileparts(fileparts(mfilename('fullpath'))), 'stepper_data');
d_raw  = fullfile(root, '20261120_200111');
d_r8f  = fullfile(root, 'hw_lpf_r8_full');
d_cmp  = fullfile(root, 'hw_lpf_compare');
out    = fullfile(root, 'report_final');
if ~isfolder(out), mkdir(out); end

% Copy verified Fig1 (6-mode Freq vs Speed from 18 live trials)
copyfile(fullfile(d_raw, 'figures', 'Fig1_R4_FreqVsSpeed.png'), fullfile(out, 'Fig1_R4_FreqVsSpeed.png'));

% ---- Fig 2: R3 All 6 Drive Modes (Raw Unfiltered vs Live 10 Hz Butterworth LPF vs Theory)
S3 = load(fullfile(d_cmp, 'R3_allmodes_T1.mat'));
lo = S3.logsout;
t  = double(lo.get('freq_cmd').Values.Time(:));
rm = double(squeeze(lo.get('rpm_meas').Values.Data));
rl = double(squeeze(lo.get('rpm_meas_lpf').Values.Data));
rt = double(squeeze(lo.get('rpm_theory').Values.Data));
sid= double(squeeze(lo.get('step_id').Values.Data));
stdy=double(squeeze(lo.get('is_steady').Values.Data));

mode_names = {'Full (1)', 'Half (1/2)', '1/4', '1/8', '1/16', '1/32'};
M_vals = [1; 2; 4; 8; 16; 32];
raw_m = zeros(6,1); raw_sd = zeros(6,1); lpf_m = zeros(6,1); lpf_sd = zeros(6,1); th_m = zeros(6,1);
for k = 1:6
    msk = (round(sid) == k) & (stdy > 0.5);
    th_m(k)   = mean(rt(msk));
    raw_m(k)  = mean(rm(msk));
    raw_sd(k) = std(rm(msk));
    lpf_m(k)  = mean(rl(msk));
    lpf_sd(k) = std(rl(msk));
end
red_pct = 100 * (1 - lpf_sd ./ raw_sd);
T_lpf = table(mode_names', M_vals, th_m, raw_m, raw_sd, lpf_m, lpf_sd, red_pct, ...
    'VariableNames', {'Mode','M','Theory_RPM','Raw_Mean_RPM','Raw_Ripple_SD','LPF_Mean_RPM','LPF_Ripple_SD','Noise_Reduction_Pct'});
writetable(T_lpf, fullfile(out, 'Raw_vs_LPF_R3_metrics.csv'));
fprintf('\n=== Raw vs 10 Hz LPF Ripple Reduction (Live R3, 400 Hz) ===\n');
disp(T_lpf);

f2 = figure('Visible', 'off', 'Color', 'w', 'Position', [100 100 940 500]);
plot(t, rm, '-', 'Color', [0.75 0.85 0.98], 'LineWidth', 0.7, 'DisplayName', 'Raw Unfiltered RPM'); hold on;
plot(t, rl, 'b-', 'LineWidth', 1.5, 'DisplayName', '10 Hz Butterworth LPF RPM');
plot(t, rt, 'k--', 'LineWidth', 1.2, 'DisplayName', 'Theoretical RPM');
grid on; xlim([0 max(t)]); ylim([-5 160]);
xlabel('Time (s)'); ylabel('Motor Speed (RPM)');
title('R3: Real Operation Across All 6 DRV8825 Modes at 400 Hz (Raw vs 10 Hz LPF)');
legend('Location', 'northeast');
lbls = {'Full','1/2','1/4','1/8','1/16','1/32'};
for k = 1:6
    text(1.5 + (k-1)*6 + 2.0, th_m(k) + 12, lbls{k}, 'HorizontalAlignment', 'center', 'FontWeight', 'bold', 'FontSize', 9);
end
save_fig(f2, fullfile(out, 'Fig2_R3_DriveModes_Raw_vs_LPF.png'));

% ---- Fig 5: Zoomed Raw vs 10 Hz LPF + FFT Spectrum (Full Step 400 Hz steady plateau)
msk_fs = (round(sid) == 1) & (stdy > 0.5);
t_fs = t(msk_fs); t_fs = t_fs - t_fs(1);
rm_fs = rm(msk_fs); rl_fs = rl(msk_fs); rt_fs = rt(msk_fs);
Fs = 1000; N = numel(rm_fs);
Y_raw = abs(fft(rm_fs - mean(rm_fs)) / N); P_raw = Y_raw(1:floor(N/2)+1); P_raw(2:end-1) = 2*P_raw(2:end-1);
Y_lpf = abs(fft(rl_fs - mean(rl_fs)) / N); P_lpf = Y_lpf(1:floor(N/2)+1); P_lpf(2:end-1) = 2*P_lpf(2:end-1);
fv = Fs * (0:floor(N/2)) / N;

f5 = figure('Visible', 'off', 'Color', 'w', 'Position', [100 100 940 560]);
subplot(2,1,1);
plot(t_fs, rm_fs, 'Color', [0.70 0.82 0.98], 'LineWidth', 0.9, 'DisplayName', sprintf('Raw (SD = %.2f RPM)', std(rm_fs))); hold on;
plot(t_fs, rl_fs, 'b-', 'LineWidth', 1.6, 'DisplayName', sprintf('10 Hz LPF (SD = %.2f RPM)', std(rl_fs)));
plot(t_fs, rt_fs, 'k--', 'LineWidth', 1.2, 'DisplayName', 'Theory (120.0 RPM)');
grid on; xlim([0 min(2.0, max(t_fs))]);
xlabel('Time in Steady Window (s)'); ylabel('Speed (RPM)');
title('Full Step @ 400 Hz: Raw Unfiltered vs Live 10 Hz Butterworth LPF');
legend('Location', 'northeast');

subplot(2,1,2);
plot(fv, P_raw, 'r-', 'LineWidth', 1.0, 'DisplayName', 'Raw Speed AC Spectrum'); hold on;
plot(fv, P_lpf, 'b-', 'LineWidth', 1.4, 'DisplayName', '10 Hz LPF AC Spectrum');
xline(10, 'k--', 'f_c = 10 Hz', 'LineWidth', 1.1, 'LabelVerticalAlignment', 'middle', 'HandleVisibility', 'off');
grid on; xlim([0 150]);
xlabel('Frequency (Hz)'); ylabel('Amplitude (RPM)');
title('Single-Sided FFT Spectrum of Speed Ripple (DC Removed)');
legend('Location', 'northeast');
save_fig(f5, fullfile(out, 'Fig5_Raw_vs_LPF_FFT.png'));

% ---- Fig 3: Loss Step Time Series (Full Step Accel = 2000 Hz/s, Trial 2: clean ramp -> stall at 2856 Hz)
S8 = load(fullfile(d_r8f, 'R8_accel2000_M1_Full_T2.mat'));
lo8 = S8.logsout;
t8  = double(lo8.get('freq_cmd').Values.Time(:));
fc8 = double(squeeze(lo8.get('freq_cmd').Values.Data));
fe8 = double(squeeze(lo8.get('Stepper Frequency (echo)').Values.Data));
rt8 = double(squeeze(lo8.get('rpm_theory').Values.Data));
rm8 = double(squeeze(lo8.get('rpm_meas').Values.Data));
rl8 = double(squeeze(lo8.get('rpm_meas_lpf').Values.Data));
ls8 = double(squeeze(lo8.get('lost_steps').Values.Data));

f3 = figure('Visible', 'off', 'Color', 'w', 'Position', [100 100 940 620]);
subplot(3,1,1);
plot(t8, fc8, 'b-', 'LineWidth', 1.3, 'DisplayName', 'f_{cmd}'); hold on;
plot(t8, fe8, 'r--', 'LineWidth', 1.0, 'DisplayName', 'f_{echo}');
xline(3.33, 'm--', 'Pull-Out (2856 Hz)', 'LineWidth', 1.1, 'HandleVisibility', 'off');
grid on; xlim([0 6]); ylabel('Freq (Hz)');
title('R6 & R8: Loss Step Time Series (Full Step, Accel = 2000 Hz/s, Trial 2)');
legend('Location', 'northwest');

subplot(3,1,2);
plot(t8, rm8, '-', 'Color', [0.72 0.84 0.98], 'LineWidth', 0.8, 'DisplayName', 'Raw RPM'); hold on;
plot(t8, rl8, 'b-', 'LineWidth', 1.5, 'DisplayName', '10 Hz LPF RPM');
plot(t8, rt8, 'k--', 'LineWidth', 1.2, 'DisplayName', 'Theory RPM');
xline(3.33, 'm--', 'LineWidth', 1.1, 'HandleVisibility', 'off');
grid on; xlim([0 6]); ylabel('Speed (RPM)');
legend('Location', 'northwest');

subplot(3,1,3);
plot(t8, ls8, 'r-', 'LineWidth', 1.4, 'DisplayName', 'Lost Full Steps');
xline(3.33, 'm--', 'LineWidth', 1.1, 'HandleVisibility', 'off');
grid on; xlim([0 6]); xlabel('Time (s)'); ylabel('Lost Steps (full)');
save_fig(f3, fullfile(out, 'Fig3_R6_R8_LossStep_TimeSeries.png'));

% ---- Fig 4: Grouped Bar Chart — Full Step vs Half Step (Pull-In vs Accel Ramp Pull-Out)
full_m  = [466.7, 656.3, 2676.0, 3246.0, 2908.0];
full_sd = [115.5,   7.4,  120.3,  653.1,  128.0];
half_m  = [933.3, 4000.0, 4000.0, 4000.0, 4000.0];
half_sd = [230.9,    0.0,    0.0,    0.0,    0.0];

f4 = figure('Visible', 'off', 'Color', 'w', 'Position', [100 100 900 480]);
b = bar(1:5, [full_m(:), half_m(:)], 'grouped');
b(1).FaceColor = [0.18 0.45 0.76]; b(1).DisplayName = 'Full Step (M=1)';
b(2).FaceColor = [0.85 0.38 0.14]; b(2).DisplayName = 'Half Step (M=2, >=4000 Hz ceiling on ramps)';
hold on;
x1 = b(1).XEndPoints; x2 = b(2).XEndPoints;
errorbar(x1, full_m, full_sd, 'k.', 'LineWidth', 1.4, 'CapSize', 8, 'HandleVisibility', 'off');
errorbar(x2, half_m, half_sd, 'k.', 'LineWidth', 1.4, 'CapSize', 8, 'HandleVisibility', 'off');
yline(4000, 'k:', 'Ramp Ceiling (4000 Hz)', 'LineWidth', 1.1, 'HandleVisibility', 'off');
set(gca, 'XTick', 1:5, 'XTickLabel', {'Step Input (Pull-In)', '500 Hz/s', '1000 Hz/s', '2000 Hz/s', '4000 Hz/s'});
ylim([0 5100]); grid on;
ylabel('Max Frequency Before Loss Step (Hz)');
title('R8: Acceleration Limit vs Pull-Out Frequency (Full Step vs Half Step, Mean \pm SD)');
legend('Location', 'northwest');
save_fig(f4, fullfile(out, 'Fig4_R8_Accel_vs_PullOut.png'));

fprintf('FINAL REPORT ASSETS WRITTEN -> %s\n', out);
end

function save_fig(fh, out_png)
try
    exportgraphics(fh, out_png, 'Resolution', 300);
catch
    print(fh, '-dpng', '-r300', out_png);
end
close(fh);
end
