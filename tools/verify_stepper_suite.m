function verify_stepper_suite(out_root)
if nargin < 1, out_root = '/tmp/mlwork/step_auto/out'; end
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
hd = '/tmp/mlwork/step_auto/harness';
if ~isfolder(hd), mkdir(hd); end
hfile = fullfile(hd, 'step_h.slx');
copyfile(models{1}, hfile);
h = 'step_h';
load_system(hfile);
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
syn_dir = '/tmp/mlwork/step_auto/syn_data';
if isfolder(syn_dir), rmdir(syn_dir, 's'); end
mkdir(syn_dir);
make_synthetic_dataset(syn_dir);
addpath('/Users/bocchichan/Documents/lab2');
S = analyze_stepper_labs(syn_dir);
ok_r0 = S.calibration.from_r0 && abs(S.calibration.adc_i_zero - 2140.0) < 0.1;
ok_r6 = abs(S.R6.pullin_mean_hz - 800) < 1e-3;
r8t   = S.R8;
ok_r8 = height(r8t) == 5 && all(abs(r8t.MaxFreq_Mean_Hz' - [800 1200 1600 2000 2200]) < 25);
figs  = {'Fig1_R4_FreqVsSpeed.png','Fig2_R3_DriveModes_Waveforms.png','Fig3_R6_R8_LossStep_TimeSeries.png','Fig4_R8_Accel_vs_PullOut.png'};
tbls  = {'R3_drive_modes_summary.csv','R4_R5_freq_vs_speed.csv','R6_pullin_steps.csv','R8_accel_pullout.csv'};
ok_files = all(cellfun(@(fn) isfile(fullfile(syn_dir,'figures',fn)), figs)) && ...
           all(cellfun(@(fn) isfile(fullfile(syn_dir,'tables',fn)), tbls));
fprintf('V T6 analyze_stepper_labs: R0_cal=%d R6_pullin=%.1f R8_crit=%s files=%d -> %s\n', ...
  ok_r0, S.R6.pullin_mean_hz, mat2str(round(r8t.MaxFreq_Mean_Hz')), ok_files, pf(ok_r0 && ok_r6 && ok_r8 && ok_files));
assert(ok_r0 && ok_r6 && ok_r8 && ok_files);
fprintf('ALL SUITE VERIFICATIONS PASSED\n');
end

function make_synthetic_dataset(d)
% Create minimal synthetic logsout files with known exact answers to test analyze_stepper_labs.m
% R0
t = (0:0.01:6)';
save_run(d, 'R0_baseline.mat', struct('lab','R0','drive_mode',1,'accel',0,'trial',1,'steps_per_rev',200), ...
  t, zeros(size(t)), zeros(size(t)), ones(size(t)), double(t>=0.5 & t<=5.0), double(t<=5.0) + 99*double(t>5.0), ...
  zeros(size(t)), zeros(size(t)), zeros(size(t)), 2140*ones(size(t)), 100*ones(size(t)));
% R3
t = (0:0.02:38)';
ms_tbl = [1 2 4 8 16 32];
f_cmd = zeros(size(t)); sid = zeros(size(t)); stdy = zeros(size(t)); ms = ones(size(t));
for k = 1:6
  m = (t >= 1.5+(k-1)*6) & (t < 1.5+(k-1)*6+4);
  f_cmd(m) = 400; sid(m) = k; ms(m) = ms_tbl(k);
  stdy(t >= 2.7+(k-1)*6 & t <= 5.4+(k-1)*6) = 1;
end
rt = f_cmd .* 60 ./ (ms .* 200);
rm = rt * 0.995;
save_run(d, 'R3_allmodes_T1.mat', struct('lab','R3','drive_mode',1,'accel',2000,'trial',1,'steps_per_rev',200), ...
  t, f_cmd, f_cmd, ms, stdy, sid, rt, rm, zeros(size(t)), 2140 + 66.3185*0.8*double(sid>0), 100*ones(size(t)));
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
% R6 (2 trials, pull-in = 800 Hz -> steps > 800 Hz stall!)
freqs6 = [200 400 600 800 1000 1200 1400 1600 2000 2400];
t = (0:0.05:44)';
for tr = 1:2
  f_cmd = zeros(size(t)); sid = zeros(size(t)); stdy = zeros(size(t)); ls = zeros(size(t)); rm = zeros(size(t));
  for k = 1:numel(freqs6)
    m = (t >= 1.5+(k-1)*4) & (t < 1.5+(k-1)*4+2.5);
    f_cmd(m) = freqs6(k); sid(m) = k;
    stdy(t >= 2.3+(k-1)*4 & t <= 3.9+(k-1)*4) = 1;
    if freqs6(k) <= 800
      rm(m) = freqs6(k) * 60 / 200;
    else
      rm(m) = 0; ls(m) = 50;
    end
  end
  rt = f_cmd * 60 / 200;
  save_run(d, sprintf('R6_pullin_T%d.mat',tr), struct('lab','R6','drive_mode',1,'accel',0,'trial',tr,'steps_per_rev',200), ...
    t, f_cmd, f_cmd, ones(size(t)), stdy, sid, rt, rm, ls, 2140*ones(size(t)), 100*ones(size(t)));
end
% R8 (4 accels x 2 trials with known pull-out: 4000->1200, 2000->1600, 1000->2000, 500->2200)
acc_list = [4000 2000 1000 500];
crit_list = [1200 1600 2000 2200];
for ia = 1:numel(acc_list)
  ac = acc_list(ia); fc_true = crit_list(ia);
  t_end = ceil(1.5 + 3000/ac + 2.5);
  t = (0:0.01:t_end)';
  for tr = 1:2
    t_in = t - 1.5;
    act = (t_in >= 0) & (t_in < 3000/ac + 1.0);
    f_cmd = zeros(size(t)); f_cmd(act) = min(3000, ac * t_in(act));
    sid = double(act); stdy = double(t_in >= 0.25 & t_in <= 3000/ac + 0.95);
    rt = f_cmd * 60 / 200;
    stalled = act & (f_cmd >= fc_true);
    rm = rt; rm(stalled) = 0.2 * rt(stalled);
    ls = zeros(size(t)); ls(stalled) = 20;
    save_run(d, sprintf('R8_accel%d_T%d.mat',ac,tr), struct('lab','R8','drive_mode',1,'accel',ac,'trial',tr,'steps_per_rev',200), ...
      t, f_cmd, f_cmd, ones(size(t)), stdy, sid, rt, rm, ls, 2140*ones(size(t)), 100*ones(size(t)));
  end
end
end

function save_run(d, fname, meta, t, f_cmd, f_targ, ms, stdy, sid, rt, rm, ls, pa1, pa0) %#ok<INUSL>
ds = Simulink.SimulationData.Dataset;
ds = add_sig(ds, 'freq_cmd', f_cmd, t);
ds = add_sig(ds, 'target_freq', f_targ, t);
ds = add_sig(ds, 'microstep_M', ms, t);
ds = add_sig(ds, 'is_steady', stdy, t);
ds = add_sig(ds, 'step_id', sid, t);
ds = add_sig(ds, 'rpm_theory', rt, t);
ds = add_sig(ds, 'rpm_meas', rm, t);
ds = add_sig(ds, 'lost_steps', ls, t);
ds = add_sig(ds, 'Motor Angular Velocity', rm * 2 * pi / 60, t);
ds = add_sig(ds, 'Stepper Frequency (echo)', f_cmd, t);
ds = add_sig(ds, 'Current (PA1)', pa1, t);
ds = add_sig(ds, 'Load Cell (PA0)', pa0, t);
logsout = ds; %#ok<NASGU>
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
