function verify_stepper_suite(out_root)
repo = fileparts(fileparts(mfilename('fullpath')));
if nargin < 1, out_root = repo; end
bdclose('all');
models = {
  fullfile(out_root, 'MotorXploer_Stepper.slx'), ...
  fullfile(out_root, 'stepper_motor', 'R0_Baseline_Calibration.slx'), ...
  fullfile(out_root, 'stepper_motor', 'R3_DriveModes_RealOp.slx'), ...
  fullfile(out_root, 'stepper_motor', 'R4_R5_FreqVsSpeed.slx'), ...
  fullfile(out_root, 'stepper_motor', 'R6_LossStep_PullIn.slx'), ...
  fullfile(out_root, 'stepper_motor', 'R8_Accel_PullOut.slx'), ...
  fullfile(out_root, 'stepper_motor', 'R14_Control_PerMode.slx') ...
};

fprintf('=== PART 1: Static & Real-Model Compile Checks (%d models) ===\n', numel(models));
for i = 1:numel(models)
  f = models{i};
  [~, m] = fileparts(f);
  info = Simulink.MDLInfo(f);
  txt = evalc('load_system(f)');
  inv_src = numel(strfind(txt, 'invalid Source'));
  slv = get_param(m, 'SolverName');
  stp = get_param(m, 'FixedStep');
  pac = get_param(m, 'EnablePacing');
  b = get_param([m '/Slider'], 'Binding');
  sb = b.BlockPath.getBlock(1);
  sf = get_param(m, 'StopFcn');
  sf_ok = contains(sf, ['''' m '''']) && contains(sf, 'int16([0, 0, 0, 0, 1])') && contains(sf, 'Commented');
  % Clear StopFcn in memory before compile/term so offline verification never touches serial hardware
  set_param(m, 'StopFcn', '');

  ctxt = evalc('feval(m,[],[],[],''compile'')');
  plw = numel(strfind(lower(ctxt), 'precision loss'));
  dt = get_param([m '/Host Serial Tx'], 'CompiledPortDataTypes');
  dts = strjoin(dt.Inport, ' ');
  feval(m, [], [], [], 'term');
  close_system(m, 0);

  ok = strcmp(info.ReleaseName, 'R2025b') && inv_src == 0 && strcmp(slv, 'FixedStepDiscrete') ...
       && strcmp(stp, '0.001') && strcmp(pac, 'on') && strcmp(sb, [m '/PWM Range']) ...
       && sf_ok && plw == 0 && strcmp(dts, 'single single single int16 int16 int16 int16 int16');
  fprintf('V MODEL %-28s rel=%s inv=%d plw=%d sf=%d tx=[%s] -> %s\n', m, info.ReleaseName, inv_src, plw, sf_ok, dts, pf(ok));
  assert(ok, 'Static/compile check failed for %s', m);
end

fprintf('\n=== PART 2: Functional Harness Simulation Checks (Exp Modes 0..5) ===\n');
hd = fullfile(tempdir, 'stepper_harness');
if ~isfolder(hd), mkdir(hd); end
hfile = fullfile(hd, 'step_h.slx');
copyfile(models{1}, hfile);
h = 'step_h';
load_system(hfile);
set_param(h, 'StopFcn', '');
for n = {'Host Serial Setup', 'Host Serial Rx1', 'Host Serial Tx'}
  set_param([h '/' n{1}], 'Commented', 'on');
end
rx_ph = get_param([h '/Host Serial Rx1'], 'PortHandles');
for p = 2:6, set_param(rx_ph.Outport(p), 'DataLogging', 'off'); end
for gn = {'Goto omega', 'Goto adc_i', 'Goto f_echo'}
  lh = get_param([h '/' gn{1}], 'LineHandles'); delete_line(lh.Inport(1));
end
add_block('simulink/Sources/Constant', [h '/w_test'], 'Position', [400 1300 450 1320], 'OutDataTypeStr', 'single', 'SampleTime', '0.001', 'Value', 'single(0.9*2*2*pi)');
add_block('simulink/Sources/Constant', [h '/i_test'], 'Position', [400 1340 450 1360], 'OutDataTypeStr', 'single', 'SampleTime', '0.001', 'Value', 'single(2137.5638 + 2*66.3185)');
add_block('simulink/Sources/Constant', [h '/f_test'], 'Position', [400 1380 450 1400], 'OutDataTypeStr', 'single', 'SampleTime', '0.001', 'Value', 'single(400)');
add_line(h, 'w_test/1', 'Goto omega/1');
add_line(h, 'i_test/1', 'Goto adc_i/1');
add_line(h, 'f_test/1', 'Goto f_echo/1');
set_param(h, 'EnablePacing', 'off');

% T0: Manual / R14 safe default EN=1, then EN=0 across all 6 DRV8825 modes
set_param([h '/Exp Mode'], 'Value', '0'); set_param([h '/Manual EN'], 'Value', '1');
o = sim(h, 'StopTime', '1');
en0 = lastv(o.logsout, 'EN'); ls0 = lastv(o.logsout, 'lost_steps'); cur0 = lastv(o.logsout, 'Current (A)');
ok0a = (en0 == 1) && (abs(ls0) < 1e-9) && (abs(cur0 - 2.0) < 1e-3);
fprintf('V T0a Manual safe default EN=%g lost=%g current=%.4f A -> %s\n', en0, ls0, cur0, pf(ok0a));
assert(ok0a);

set_param([h '/Manual EN'], 'Value', '0');
exp_ms = [1 2 4 8 16 32]; got_ms = zeros(1,6); got_rt = zeros(1,6);
for dm = 1:6
  set_param([h '/Drive Mode'], 'Value', num2str(dm));
  o = sim(h, 'StopTime', '0.1');
  got_ms(dm) = lastv(o.logsout, 'microstep_M');
  got_rt(dm) = lastv(o.logsout, 'rpm_theory');
end
ok0b = all(got_ms == exp_ms) && all(abs(got_rt - 120./exp_ms) < 1e-4);
fprintf('V T0b DRV8825 6 modes M=%s rpm_theory=%s -> %s\n', mat2str(got_ms), mat2str(got_rt,5), pf(ok0b));
assert(ok0b);

% T1: R0 Baseline
set_param([h '/Exp Mode'], 'Value', '1');
o = sim(h, 'StopTime', '6');
ok1 = (atv(o.logsout,'EN',2) == 1) && (atv(o.logsout,'freq_cmd',2) == 0) && (atv(o.logsout,'is_steady',2) == 1) && (atv(o.logsout,'step_id',5.5) == 99);
fprintf('V T1 R0 Baseline EN(2)=%g steady(2)=%g step_id(5.5)=%g -> %s\n', atv(o.logsout,'EN',2), atv(o.logsout,'is_steady',2), atv(o.logsout,'step_id',5.5), pf(ok1));
assert(ok1);

% T2: R3 All 6 Modes Demo
set_param([h '/Exp Mode'], 'Value', '2'); set_param([h '/Manual Freq (Hz)'], 'Value', '400');
o = sim(h, 'StopTime', '38');
ms_seen = arrayfun(@(k) atv(o.logsout, 'microstep_M', 1.5 + (k-1)*6 + 2.5), 1:6);
en_rest = arrayfun(@(k) atv(o.logsout, 'EN',          1.5 + (k-1)*6 + 5.0), 1:6);
ok2 = all(ms_seen == exp_ms) && all(en_rest == 1) && (atv(o.logsout,'step_id',37.8) == 99);
fprintf('V T2 R3 All 6 Modes M=%s rest_EN=%s -> %s\n', mat2str(ms_seen), mat2str(en_rest), pf(ok2));
assert(ok2);

% T3: R4/R5 Frequency Staircase
set_param([h '/Exp Mode'], 'Value', '3'); set_param([h '/Drive Mode'], 'Value', '1'); set_param([h '/Accel Limit (Hz per s)'], 'Value', '2000');
o = sim(h, 'StopTime', '36');
tq = 1.5 + (0:7)*4 + 2.5;
fq = arrayfun(@(t) atv(o.logsout, 'freq_cmd', t), tq);
st = arrayfun(@(t) atv(o.logsout, 'is_steady', t), tq);
ok3 = all(abs(fq - (200:200:1600)) < 1e-3) && all(st == 1) && (atv(o.logsout,'EN',35) == 1) && (atv(o.logsout,'step_id',35) == 99);
fprintf('V T3 R4/R5 Staircase f=%s steady=%s end_EN=%g -> %s\n', mat2str(fq), mat2str(st), atv(o.logsout,'EN',35), pf(ok3));
assert(ok3);

% T4: R6 Pull-In Ladder + Integrator Reset Verification!
set_param([h '/Exp Mode'], 'Value', '4'); set_param([h '/Drive Mode'], 'Value', '1');
o = sim(h, 'StopTime', '10');
% Step 1 active: 1.5..4.0 s -> at t=2.5 s (1.0 s into step 1), lost_steps should be 40.0
% Rest 1: 4.0..5.5 s (EN=1) -> at t=4.8 s, lost_steps MUST reset to 0!
% Step 2 active: 5.5..8.0 s -> at t=6.5 s (1.0 s into step 2), lost_steps MUST be 40.0 again (not 140!)
ls_s1 = atv(o.logsout, 'lost_steps', 2.5);
ls_r1 = atv(o.logsout, 'lost_steps', 4.8);
ls_s2 = atv(o.logsout, 'lost_steps', 6.5);
f_s1  = atv(o.logsout, 'freq_cmd',   1.51);
f_s2  = atv(o.logsout, 'freq_cmd',   5.51);
ok4 = abs(ls_s1 - 40) < 0.2 && abs(ls_r1) < 1e-6 && abs(ls_s2 - 40) < 0.2 && abs(f_s1 - 200) < 1e-3 && abs(f_s2 - 400) < 1e-3;
fprintf('V T4 R6 Pull-In & Reset: lost(s1+1s)=%.2f rest=%.2f lost(s2+1s)=%.2f f=[%g %g] -> %s\n', ls_s1, ls_r1, ls_s2, f_s1, f_s2, pf(ok4));
assert(ok4);

% T5: R8 Linear Acceleration Ramp (0.5 s lock at 200 Hz -> ramp 200..3000 Hz at 2000 Hz/s -> 1 s hold -> EN=1)
set_param([h '/Exp Mode'], 'Value', '5'); set_param([h '/Accel Limit (Hz per s)'], 'Value', '2000'); set_param([h '/Max Freq (Hz)'], 'Value', '3000');
o = sim(h, 'StopTime', '6');
% t_boot=1.5, t_lock=0.5 (1.5..2.0 at 200 Hz), t_ramp=1.4 s (2.0..3.4), t_hold=1.0 s (3.4..4.4), EN=1 after 4.4
fr = [atv(o.logsout,'freq_cmd',1.8) atv(o.logsout,'freq_cmd',2.5) atv(o.logsout,'freq_cmd',3.0) atv(o.logsout,'freq_cmd',3.6) atv(o.logsout,'EN',4.8) lastv(o.logsout,'rpm_meas_lpf')];
ok5 = all(abs(fr(1:5) - [200 1200 2200 3000 1]) < 3) && abs(fr(6) - 108) < 1;
fprintf('V T5 R8 Accel Ramp f(1.8,2.5,3,3.6)=[%g %g %g %g] EN(4.8)=%g lpf=%.2f -> %s\n', fr(1), fr(2), fr(3), fr(4), fr(5), fr(6), pf(ok5));
assert(ok5);
close_system(h, 0);

fprintf('\n=== PART 3: analyze_stepper_labs.m End-to-End Synthetic Dataset Test ===\n');
syn_dir = fullfile(tempdir, 'stepper_syn_data');
if isfolder(syn_dir), rmdir(syn_dir, 's'); end
mkdir(syn_dir);
make_synthetic_dataset(syn_dir);
addpath(repo);
S = analyze_stepper_labs(syn_dir);

% 1) R0 baseline check
ok_r0 = S.calibration.from_r0 && abs(S.calibration.adc_i_zero - 2140.0) < 0.1 && ...
        height(S.R0) == 1 && S.R0.From_R0 == 1 && abs(S.R0.PA1_Zero_Counts - 2140.0) < 0.1;

% 2) R3 LPF summary columns check (live LPF)
r3t = S.R3;
req_r3_cols = {'Mode','Microstep_M','Theory_RPM','Meas_Mean_RPM','Trial_SD_RPM','Ripple_SD_RPM', ...
               'Current_A','LPF_Mean_RPM','LPF_Trial_SD_RPM','LPF_Ripple_SD_RPM', ...
               'Ripple_Reduction_Pct','LPF_Mean_Shift_RPM','LPF_Source','N_Trials'};
ok_r3 = all(ismember(req_r3_cols, r3t.Properties.VariableNames)) && ...
        height(r3t) == 6 && all(strcmp(r3t.LPF_Source, 'live')) && ...
        all(r3t.Ripple_Reduction_Pct > 85) && all(r3t.LPF_Mean_Shift_RPM < 0.5) && ...
        all(r3t.N_Trials == 2);

% 3) R4_R5 summary & per-trial long CSV check
r4_sum = S.R4_R5;
r4_tr  = S.R4_R5_trials;
req_r4_tr_cols = {'Drive_Mode','Mode','Microstep_M','Trial','Step_ID','Freq_Hz','Theory_RPM', ...
                  'Meas_RPM','Ripple_SD_RPM','LPF_RPM','LPF_Ripple_SD_RPM','Error_Pct','Current_A','Source_File'};
ok_r4 = height(r4_sum) == 48 && height(r4_tr) == 96 && ...
        all(ismember(req_r4_tr_cols, r4_tr.Properties.VariableNames));

% 4) R6 mixed Full + Half grouping & transient startup-lag non-stall vs true stall check
r6_sum   = S.R6.summary_table;
r6_steps = S.R6.steps_table;
r6_tr    = S.R6.trials_table;
% Full (Drive_Mode=1): pull-in must be 800 Hz (step 4 @ 800 Hz has Peak_Lost_Steps=9.2>5 but End_Lost_Steps=1.8<4 & speed=100% -> Stalled=0; step 5 @ 1000 Hz has speed<85% & End_Lost_Steps=50>=4 -> Stalled=1)
% Half (Drive_Mode=2): pull-in must be 1200 Hz (step 5 @ 1000 Hz has End_Lost_Steps=7.5>=4 but speed=100% -> Stalled=0; step 6 @ 1200 Hz has Peak_Lost_Steps=8.4>5 & End_Lost_Steps=2.1<4 -> Stalled=0; step 7 @ 1400 Hz -> Stalled=1)
m_f800  = (r6_steps.Drive_Mode == 1) & (r6_steps.Freq_Hz == 800);
m_f1000 = (r6_steps.Drive_Mode == 1) & (r6_steps.Freq_Hz == 1000);
m_h1000 = (r6_steps.Drive_Mode == 2) & (r6_steps.Freq_Hz == 1000);
m_h1200 = (r6_steps.Drive_Mode == 2) & (r6_steps.Freq_Hz == 1200);
m_h1400 = (r6_steps.Drive_Mode == 2) & (r6_steps.Freq_Hz == 1400);
ok_r6_grouping = height(r6_sum) == 2 && height(r6_tr) == 4 && ...
                 all(r6_sum.Drive_Mode == [1; 2]) && ...
                 all(abs(r6_sum.PullIn_Mean_Hz - [800; 1200]) < 1e-3);
ok_r6_stall = all(r6_steps.Peak_Lost_Steps(m_f800) > 5.0) && ...
              all(r6_steps.End_Lost_Steps(m_f800) < 4.0) && ...
              all(r6_steps.Stalled(m_f800) == 0) && ...
              all(r6_steps.Stalled(m_f1000) == 1) && ...
              all(r6_steps.End_Lost_Steps(m_h1000) >= 4.0) && ...
              all(r6_steps.Stalled(m_h1000) == 0) && ...
              all(r6_steps.Peak_Lost_Steps(m_h1200) > 5.0) && ...
              all(r6_steps.End_Lost_Steps(m_h1200) < 4.0) && ...
              all(r6_steps.Stalled(m_h1200) == 0) && ...
              all(r6_steps.Stalled(m_h1400) == 1);
ok_r6 = ok_r6_grouping && ok_r6_stall;

% 5) R8 mixed Full + Half grouping, pull-out onset backtracking, censored ceiling & per-trial long CSV check
r8t    = S.R8;
r8_tr  = S.R8_trials;
req_r8_tr_cols = {'Drive_Mode','Mode','Microstep_M','Condition','Accel_Hz_s','Trial', ...
                  'PullOut_Freq_Hz','PullOut_Speed_RPM','Stalled','Reached_Ceiling', ...
                  'Stall_Time_s','Max_Cmd_Freq_Hz','Peak_Lost_Steps','Source_File'};
r8_full = r8t(r8t.Drive_Mode == 1, :);
r8_half = r8t(r8t.Drive_Mode == 2, :);
ok_r8_full = height(r8_full) == 5 && ...
             all(abs(r8_full.MaxFreq_Mean_Hz' - [800 1200 1600 2000 2200]) < 25) && ...
             all(r8_full.N_Censored == 0);
ok_r8_half = height(r8_half) == 5 && ...
             all(abs(r8_half.MaxFreq_Mean_Hz' - [1200 3200 3600 4000 4000]) < 25) && ...
             all(r8_half.N_Censored' == [0 0 0 2 2]);
ok_r8_tr   = height(r8_tr) == 16 && ...
             all(ismember(req_r8_tr_cols, r8_tr.Properties.VariableNames)) && ...
             sum(r8_tr.Stalled == 1) == 12 && sum(r8_tr.Reached_Ceiling == 1) == 4;
ok_r8 = height(r8t) == 10 && ok_r8_full && ok_r8_half && ok_r8_tr;

% 6) Expected CSV tables, report figures, and per-mode raw figures check
figs = {'Fig1_R4_FreqVsSpeed.png', 'Fig2_R3_DriveModes_Waveforms.png', ...
        'Fig3_R6_R8_LossStep_TimeSeries.png', 'Fig3_R6_R8_LossStep_TimeSeries_M1_Full.png', ...
        'Fig3_R6_R8_LossStep_TimeSeries_M2_Half.png', 'Fig4_R8_Accel_vs_PullOut.png'};
raw_figs = {'Raw_R0_Baseline.png', 'Raw_R3_AllModes_Unfiltered.png', ...
            'Raw_R4_R5_AllModes_TimeSeries.png', 'Raw_R6_PullIn_M1_Full.png', ...
            'Raw_R6_PullIn_M2_Half.png', 'Raw_R8_Accel_M1_Full.png', ...
            'Raw_R8_Accel_M2_Half.png'};
tbls = {'R0_baseline_calibration.csv', 'R3_drive_modes_summary.csv', ...
        'R4_R5_freq_vs_speed.csv', 'R4_R5_trials.csv', ...
        'R6_pullin_steps.csv', 'R6_pullin_trials.csv', 'R6_pullin_summary.csv', ...
        'R8_accel_pullout.csv', 'R8_trials.csv'};
ok_files = all(cellfun(@(fn) isfile(fullfile(syn_dir, 'figures', fn)), figs)) && ...
           all(cellfun(@(fn) isfile(fullfile(syn_dir, 'figures_raw', fn)), raw_figs)) && ...
           all(cellfun(@(fn) isfile(fullfile(syn_dir, 'tables', fn)), tbls));

ok_t6 = ok_r0 && ok_r3 && ok_r4 && ok_r6 && ok_r8 && ok_files;
fprintf('V T6 analyze_stepper_labs: R0=%d R3_lpf=%d R4_long=%d R6_modes=[%.0f %.0f](stall=%d) R8_full=%s R8_half=%s files=%d -> %s\n', ...
  ok_r0, ok_r3, ok_r4, r6_sum.PullIn_Mean_Hz(1), r6_sum.PullIn_Mean_Hz(2), ok_r6_stall, ...
  mat2str(round(r8_full.MaxFreq_Mean_Hz')), mat2str(round(r8_half.MaxFreq_Mean_Hz')), ok_files, pf(ok_t6));
assert(ok_t6, 'T6 synthetic dataset verification failed');
fprintf('ALL SUITE VERIFICATIONS PASSED\n');
end

function make_synthetic_dataset(d)
% Create synthetic logsout files with known exact answers to test analyze_stepper_labs.m
% R0
t = (0:0.01:6)';
save_run(d, 'R0_baseline.mat', struct('lab','R0','drive_mode',1,'accel',0,'trial',1,'steps_per_rev',200), ...
  t, zeros(size(t)), zeros(size(t)), ones(size(t)), double(t>=0.5 & t<=5.0), double(t<=5.0) + 99*double(t>5.0), ...
  zeros(size(t)), zeros(size(t)), zeros(size(t)), 2140*ones(size(t)), 100*ones(size(t)));

% R3 (2 trials with 100 Hz ripple + live 10 Hz 2nd-order Butterworth LPF at dt = 0.002 s)
dt3 = 0.002;
t = (0:dt3:38)';
ms_tbl = [1 2 4 8 16 32];
f_cmd = zeros(size(t)); sid = zeros(size(t)); stdy = zeros(size(t)); ms = ones(size(t));
for k = 1:6
  m = (t >= 1.5+(k-1)*6) & (t < 1.5+(k-1)*6+4);
  f_cmd(m) = 400; sid(m) = k; ms(m) = ms_tbl(k);
  stdy(t >= 2.7+(k-1)*6 & t <= 5.4+(k-1)*6) = 1;
end
rt = f_cmd .* 60 ./ (ms .* 200);
K = tan(pi * 10.0 * dt3);
norm_d = 1 + sqrt(2) * K + K^2;
b_lpf = [K^2, 2*K^2, K^2] / norm_d;
a_lpf = [1, 2*(K^2 - 1)/norm_d, (1 - sqrt(2)*K + K^2)/norm_d];
for tr = 1:2
  rip = min(10.0, 0.8 * rt) .* sin(2 * pi * 100 * t) .* double(sid > 0);
  rm  = rt * (0.995 + 0.002 * (tr - 1)) + rip;
  rl  = filter(b_lpf, a_lpf, rm);
  save_run(d, sprintf('R3_allmodes_T%d.mat', tr), ...
    struct('lab','R3','drive_mode',1,'accel',2000,'trial',tr,'steps_per_rev',200), ...
    t, f_cmd, f_cmd, ms, stdy, sid, rt, rm, zeros(size(t)), ...
    2140 + 66.3185*0.8*double(sid>0), 100*ones(size(t)), rl);
end

% R4_R5 (6 modes x 2 trials)
freqs = 200:200:1600;
t = (0:0.05:36)';
for dm = 1:6
  M = ms_tbl(dm);
  for tr = 1:2
    f_cmd = zeros(size(t)); sid = zeros(size(t)); stdy = zeros(size(t));
    for k = 1:8
      m = (t >= 1.5+(k-1)*4) & (t < 1.5+k*4);
      f_cmd(m) = freqs(k); sid(m) = k;
      stdy(t >= 3.0+(k-1)*4 & t <= 5.4+(k-1)*4) = 1;
    end
    rt = f_cmd * 60 / (M * 200);
    rm = rt * (0.99 + 0.005*tr);
    save_run(d, sprintf('R4R5_M%d_T%d.mat',dm,tr), struct('lab','R4_R5','drive_mode',dm,'accel',2000,'trial',tr,'steps_per_rev',200), ...
      t, f_cmd, f_cmd, M*ones(size(t)), stdy, sid, rt, rm, zeros(size(t)), 2140 + 66.3185*0.9*double(sid>0), 100*ones(size(t)));
  end
end

% R6: Mixed Full (dm=1, pull-in = 800 Hz) + Half (dm=2, pull-in = 1200 Hz), 2 trials each
freqs6 = [200 400 600 800 1000 1200 1400 1600 2000 2400];
t = (0:0.05:44)';
for dm = [1 2]
  M = ms_tbl(dm);
  if dm == 1
    pullin_lim = 800;
    tag = 'Full';
  else
    pullin_lim = 1200;
    tag = 'Half';
  end
  for tr = 1:2
    f_cmd = zeros(size(t)); sid = zeros(size(t)); stdy = zeros(size(t)); ls = zeros(size(t)); rm = zeros(size(t));
    for k = 1:numel(freqs6)
      t0 = 1.5 + (k - 1) * 4;
      m  = (t >= t0) & (t < t0 + 2.5);
      m_tr = (t >= t0) & (t < t0 + 0.7);
      m_st = (t >= t0 + 0.7) & (t < t0 + 2.5);
      f_cmd(m) = freqs6(k); sid(m) = k;
      stdy(t >= t0 + 0.8 & t <= t0 + 2.4) = 1;
      rt_step = freqs6(k) * 60 / (M * 200);
      if freqs6(k) < pullin_lim
        rm(m) = rt_step;
        if dm == 2 && freqs6(k) == 1000
          % Mimic Half 1000 Hz startup slip that stays integrated >= 4 while steady speed == 100% theory
          ls(m) = 7.5;
        else
          ls(m) = 1.5;
        end
      elseif freqs6(k) == pullin_lim
        % Transient startup-lag non-stall test: peak lost steps > 5 during startup, < 4 at end of step, speed == 100% theory
        rm(m) = rt_step;
        ls(m_tr) = 9.2;
        ls(m_st) = 1.8;
      else
        % True stall: speed < 85% theory AND end-of-step lost steps >= 4
        rm(m) = 0.15 * rt_step;
        ls(m) = 50;
      end
    end
    rt = f_cmd * 60 / (M * 200);
    save_run(d, sprintf('R6_pullin_M%d_%s_T%d.mat', dm, tag, tr), ...
      struct('lab','R6','drive_mode',dm,'accel',0,'trial',tr,'steps_per_rev',200), ...
      t, f_cmd, f_cmd, M*ones(size(t)), stdy, sid, rt, rm, ls, 2140*ones(size(t)), 100*ones(size(t)));
  end
end

% R8: Mixed Full (dm=1, pull-out: 4000->1200, 2000->1600, 1000->2000, 500->2200)
% and Half (dm=2, pull-out: 4000->3200, 2000->3600, 1000->censored@4000, 500->censored@4000)
acc_list   = [4000 2000 1000 500];
crit_full  = [1200 1600 2000 2200];
crit_half  = [3200 3600 Inf  Inf];
for dm = [1 2]
  M = ms_tbl(dm);
  if dm == 1
    f_ceil = 3000;
    crit_list = crit_full;
    tag = 'Full';
  else
    f_ceil = 4000;
    crit_list = crit_half;
    tag = 'Half';
  end
  for ia = 1:numel(acc_list)
    ac = acc_list(ia); fc_true = crit_list(ia);
    t_end = ceil(1.5 + f_ceil / ac + 2.5);
    t = (0:0.01:t_end)';
    for tr = 1:2
      t_in = t - 1.5;
      act = (t_in >= 0) & (t_in < f_ceil / ac + 1.0);
      f_cmd = zeros(size(t)); f_cmd(act) = min(f_ceil, ac * t_in(act));
      sid = double(act); stdy = double(t_in >= 0.25 & t_in <= f_ceil / ac + 0.95);
      rt = f_cmd * 60 / (M * 200);
      stalled = act & (f_cmd >= fc_true);
      rm = rt; rm(stalled) = 0.2 * rt(stalled);
      ls = zeros(size(t)); ls(stalled) = 20;
      save_run(d, sprintf('R8_accel%d_M%d_%s_T%d.mat', ac, dm, tag, tr), ...
        struct('lab','R8','drive_mode',dm,'accel',ac,'trial',tr,'steps_per_rev',200), ...
        t, f_cmd, f_cmd, M*ones(size(t)), stdy, sid, rt, rm, ls, 2140*ones(size(t)), 100*ones(size(t)));
    end
  end
end
end

function save_run(d, fname, meta, t, f_cmd, f_targ, ms, stdy, sid, rt, rm, ls, pa1, pa0, rl)
ds = Simulink.SimulationData.Dataset;
ds = add_sig(ds, 'freq_cmd', f_cmd, t);
ds = add_sig(ds, 'target_freq', f_targ, t);
ds = add_sig(ds, 'microstep_M', ms, t);
ds = add_sig(ds, 'is_steady', stdy, t);
ds = add_sig(ds, 'step_id', sid, t);
ds = add_sig(ds, 'rpm_theory', rt, t);
ds = add_sig(ds, 'rpm_meas', rm, t);
if nargin >= 15 && ~isempty(rl)
  ds = add_sig(ds, 'rpm_meas_lpf', rl, t);
end
ds = add_sig(ds, 'lost_steps', ls, t);
ds = add_sig(ds, 'Motor Angular Velocity', rm * 2 * pi / 60, t);
ds = add_sig(ds, 'Stepper Frequency (echo)', f_cmd, t);
ds = add_sig(ds, 'Current (PA1)', pa1, t);
ds = add_sig(ds, 'Load Cell (PA0)', pa0, t);
logsout = ds;
save(fullfile(d, fname), 'logsout', 'meta');
end

function ds = add_sig(ds, name, vals, t)
sig = Simulink.SimulationData.Signal;
sig.Name = name;
sig.Values = timeseries(vals, t);
ds = ds.addElement(sig, name);
end

function v = atv(lo, name, t)
ts = lo.get(name).Values;
v = interp1(double(ts.Time(:)), double(squeeze(ts.Data)), t, 'previous', 'extrap');
end

function v = lastv(lo, name)
d = double(squeeze(lo.get(name).Values.Data)); v = d(end);
end

function s = pf(ok)
if ok, s = 'PASS'; else, s = 'FAIL'; end
end
