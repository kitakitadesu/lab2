function build_stepper_suite(out_root)
% Build the Lab 2.2 Stepper Motor Simulink suite inspired by MotorXploer_dcmotorlab.slx:
%   - <out_root>/MotorXploer_Stepper.slx (unified master, default Exp Mode = 0 Manual, EN = 1)
%   - <out_root>/stepper_motor/R0_Baseline_Calibration.slx
%   - <out_root>/stepper_motor/R3_DriveModes_RealOp.slx
%   - <out_root>/stepper_motor/R4_R5_FreqVsSpeed.slx
%   - <out_root>/stepper_motor/R6_LossStep_PullIn.slx
%   - <out_root>/stepper_motor/R8_Accel_PullOut.slx
%   - <out_root>/stepper_motor/R14_Control_PerMode.slx
repo = fileparts(fileparts(mfilename('fullpath')));
if nargin < 1, out_root = repo; end
bdclose('all');
% Base model = TA reference MotorXploer.slx (clone the TA repo into the repo root, it is git-ignored)
ref_slx = fullfile(repo, 'FRA271_LAB2_ACTUATOR_FRAB12', 'DC Motor and Stepper', 'MotorXploer.slx');
assert(isfile(ref_slx), ['Missing %s\nClone https://github.com/MINIFI2548/FRA271_LAB2_ACTUATOR_FRAB12 ' ...
    'into the repo root first.'], ref_slx);
work_dir = fullfile(tempdir, 'stepper_build');
sub_dir  = fullfile(out_root, 'stepper_motor');
if ~isfolder(work_dir), mkdir(work_dir); end
if ~isfolder(out_root), mkdir(out_root); end
if ~isfolder(sub_dir),  mkdir(sub_dir);  end

specs = {
  struct('name','MotorXploer_Stepper',      'dir',out_root, 'exp_mode','0', 'stop','inf', 'drv','1', 'accel','2000', 'fmax','3000', 'mfreq','400', 'title','Lab 2.2 Master — Exp Mode Guide (Modes 0..5)'), ...
  struct('name','R0_Baseline_Calibration',  'dir',sub_dir,  'exp_mode','1', 'stop','6',   'drv','1', 'accel','2000', 'fmax','3000', 'mfreq','400', 'title','R0 Baseline Calibration — 5 s Idle Zero-Offset (EN=1)'), ...
  struct('name','R3_DriveModes_RealOp',     'dir',sub_dir,  'exp_mode','2', 'stop','38',  'drv','1', 'accel','2000', 'fmax','3000', 'mfreq','400', 'title','R3 Drive Modes Real Operation — All 6 DRV8825 Modes'), ...
  struct('name','R4_R5_FreqVsSpeed',        'dir',sub_dir,  'exp_mode','3', 'stop','37',  'drv','1', 'accel','2000', 'fmax','3000', 'mfreq','400', 'title','R4 & R5 Frequency vs Speed Sweep (200..1600 Hz)'), ...
  struct('name','R6_LossStep_PullIn',       'dir',sub_dir,  'exp_mode','4', 'stop','44',  'drv','1', 'accel','2000', 'fmax','3000', 'mfreq','400', 'title','R6 Loss Step Pull-In Ladder (Step from Rest, No Ramp)'), ...
  struct('name','R8_Accel_PullOut',         'dir',sub_dir,  'exp_mode','5', 'stop','12',  'drv','1', 'accel','2000', 'fmax','3000', 'mfreq','400', 'title','R8 Acceleration Limit & Pull-Out Ramp (0 -> Max Freq)'), ...
  struct('name','R14_Control_PerMode',      'dir',sub_dir,  'exp_mode','0', 'stop','inf', 'drv','1', 'accel','2000', 'fmax','3000', 'mfreq','400', 'title','R14 Manual Control per Drive Mode (EN=1 Safe Default)') ...
};

for i = 1:numel(specs)
  build_one(ref_slx, work_dir, specs{i}, i == 1);
end
fprintf('SUITE BUILD DONE (%d models)\n', numel(specs));
end

function build_one(ref_slx, work_dir, sp, do_png)
bdclose('all');
load_system(ref_slx);
[~, ref_name] = fileparts(ref_slx);
m = ['bld_' sp.name];
save_system(ref_name, fullfile(work_dir, [m '.slx']));

% Serial port stays as in the TA reference; run_stepper_labs / start_stepper_labs set the
% user's port at run time (Waijung rejects a port that is not present when the model is built).

% ---- 1. Rewire TA Output stepper inputs: replace old constants with From tags so wires never cross the Slider
ta_swap = {'Stepper Frequency','Data Type Conversion8','f_cmd',false; ...
           'M0','Data Type Conversion1','M0',true; ...
           'M1','Data Type Conversion2','M1',true; ...
           'M2','Data Type Conversion3','M2',true; ...
           'DIR','Data Type Conversion4','DIR',true; ...
           'EN','Data Type Conversion5','EN',true};
for k = 1:size(ta_swap, 1)
  pos = get_param([m '/' ta_swap{k,1}], 'Position');
  delete_line(m, [ta_swap{k,1} '/1'], [ta_swap{k,2} '/1']);
  delete_block([m '/' ta_swap{k,1}]);
  yc = round((pos(2) + pos(4)) / 2);
  add_from(m, ['From ' ta_swap{k,3}], ta_swap{k,3}, [325 yc-10 405 yc+10]);
  h = wire(m, ['From ' ta_swap{k,3}], 1, ta_swap{k,2}, 1);
  if ta_swap{k,4}, set_param(h, 'Name', ta_swap{k,1}); end
end

% Log all 5 TA Rx outputs (exact names preserved)
rx_ph = get_param([m '/Host Serial Rx1'], 'PortHandles');
for p = 2:6
  set_param(rx_ph.Outport(p), 'DataLogging', 'on');
end

% Route Rx signals via Goto/From to keep center interface clean
add_goto(m, 'Goto omega',  'omega',  [490 296 555 312]); wire(m, 'Host Serial Rx1', 2, 'Goto omega',  1);
add_goto(m, 'Goto adc_i',  'adc_i',  [490 400 555 416]); wire(m, 'Host Serial Rx1', 4, 'Goto adc_i',  1);
add_goto(m, 'Goto f_echo', 'f_echo', [490 556 555 572]); wire(m, 'Host Serial Rx1', 6, 'Goto f_echo', 1);

% ---- 2. Left-Top Area: Guide (clear of lavender MotorXploler Interface which starts at x=5)
add_area(m, sp.title, [-940 168 -30 580], '[0.95 0.95 0.95]');
an = Simulink.Annotation(m, guide_text(sp));
an.Position = [-920 205 -50 565];
an.Interpreter = 'rich';
an.FontSize = 10;

% ---- 3. Left-Bottom Area: Experiment Scheduler (Clock)
add_area(m, 'Experiment Scheduler (Clock)', [-940 605 -30 1295], '[0.98 0.93 0.78]');

% Inputs to scheduler
add_block('simulink/Sources/Digital Clock', [m '/Exp Clock'], 'Position', [-905 660 -845 690], 'SampleTime', '0.001');
cfg_blks = {
  'Exp Mode',              sp.exp_mode, 735;
  'Drive Mode',            sp.drv,      800;
  'Accel Limit (Hz per s)',sp.accel,    865;
  'Max Freq (Hz)',         sp.fmax,     930;
  'Manual Freq (Hz)',      sp.mfreq,    995;
  'Manual DIR',            '0',        1060;
  'Manual EN',             '1',        1125
};
for k = 1:size(cfg_blks, 1)
  add_block('simulink/Sources/Constant', [m '/' cfg_blks{k,1}], ...
    'Position', [-910 cfg_blks{k,3} -830 cfg_blks{k,3}+28], ...
    'Value', cfg_blks{k,2}, 'SampleTime', '0.001');
end

% MATLAB Function block: Experiment Scheduler
sch = [m '/Experiment Scheduler'];
add_block('simulink/User-Defined Functions/MATLAB Function', sch, 'Position', [-700 650 -460 1245]);
rt = sfroot;
ch = rt.find('-isa', 'Stateflow.EMChart', 'Path', sch);
ch.Script = scheduler_script();

% Wire scheduler inputs (1..8)
wire(m, 'Exp Clock', 1, 'Experiment Scheduler', 1);
for k = 1:size(cfg_blks, 1)
  wire(m, cfg_blks{k,1}, 1, 'Experiment Scheduler', k + 1);
end

% Route scheduler command outputs (1..6) via Goto tags cleanly into TA Output area
sch_ph = get_param(sch, 'PortHandles');
cmd_tags = {'f_cmd', 'M0', 'M1', 'M2', 'DIR', 'EN'};
cmd_log  = {'freq_cmd', '', '', '', '', 'EN'};
for k = 1:numel(cmd_tags)
  py = get_param(sch_ph.Outport(k), 'Position');
  gname = ['Goto ' cmd_tags{k}];
  add_goto(m, gname, cmd_tags{k}, [-355 py(2)-9 -275 py(2)+9]);
  h = wire(m, 'Experiment Scheduler', k, gname, 1);
  if ~isempty(cmd_log{k})
    set_param(h, 'Name', cmd_log{k});
    set_param(sch_ph.Outport(k), 'DataLogging', 'on');
  end
end

% Also display freq_cmd and EN right inside the scheduler area
py1 = get_param(sch_ph.Outport(1), 'Position');
add_block('simulink/Sinks/Display', [m '/Disp Freq Cmd (Hz)'], 'Position', [-185 py1(2)-13 -60 py1(2)+13]);
wire(m, 'Experiment Scheduler', 1, 'Disp Freq Cmd (Hz)', 1);
py6 = get_param(sch_ph.Outport(6), 'Position');
add_block('simulink/Sinks/Display', [m '/Disp EN (0 on, 1 off)'], 'Position', [-185 py6(2)-13 -60 py6(2)+13]);
wire(m, 'Experiment Scheduler', 6, 'Disp EN (0 on, 1 off)', 1);

% Route en_cmd tag (alias of EN for kinematics reset)
add_goto(m, 'Goto en_cmd', 'en_cmd', [-355 py6(2)+16 -275 py6(2)+34]);
wire(m, 'Experiment Scheduler', 6, 'Goto en_cmd', 1);

meta_defs = {
  7,  'microstep_M', 'Disp Microstep (M)',    true;
  8,  'target_freq', 'Disp Target (Hz)',      false;
  9,  'accel_hz_s',  'Disp Accel (Hz per s)', false;
  10, 'is_steady',   'Disp Steady',           false;
  11, 'step_id',     'Disp Step ID',          false
};
for k = 1:size(meta_defs, 1)
  pidx = meta_defs{k,1}; nm = meta_defs{k,2}; dn = meta_defs{k,3};
  py = get_param(sch_ph.Outport(pidx), 'Position');
  add_block('simulink/Sinks/Display', [m '/' dn], 'Position', [-185 py(2)-13 -60 py(2)+13]);
  h = wire(m, 'Experiment Scheduler', pidx, dn, 1);
  set_param(h, 'Name', nm);
  set_param(sch_ph.Outport(pidx), 'DataLogging', 'on');
  if meta_defs{k,4}
    add_goto(m, 'Goto ustep', 'ustep', [-355 py(2)-9 -275 py(2)+9]);
    wire(m, 'Experiment Scheduler', pidx, 'Goto ustep', 1);
  end
end

% ---- 4. Right-Top Area: Current (ADC to A) — calibrated from MotorXploer_dcmotorlab.slx
add_area(m, 'Current (ADC to A) — PA1 (zero-offset refined by R0)', [1095 214 1660 430], '[0.95 0.85 0.82]');
add_from(m, 'From adc_i', 'adc_i', [1120 305 1195 325]);
cur = [m '/Current (ADC to A)'];
add_block('simulink/User-Defined Functions/MATLAB Function', cur, 'Position', [1240 285 1445 345]);
cch = rt.find('-isa', 'Stateflow.EMChart', 'Path', cur);
cch.Script = current_script();
add_block('simulink/Sinks/Display', [m '/Disp Current (A)'], 'Position', [1525 302 1630 328]);
wire(m, 'From adc_i', 1, 'Current (ADC to A)', 1);
hc = wire(m, 'Current (ADC to A)', 1, 'Disp Current (A)', 1);
set_param(hc, 'Name', 'Current (A)');
cph = get_param(cur, 'PortHandles');
set_param(cph.Outport(1), 'DataLogging', 'on');

% ---- 5. Right-Bottom Area: Stepper Kinematics & Loss Step (Raw + 10 Hz Butterworth LPF)
add_area(m, 'Stepper Kinematics & Loss Step (Raw + 10 Hz LPF; integrators reset when EN = 1)', [1095 460 1980 1055], '[0.86 0.94 0.90]');

add_block('simulink/Sources/Constant', [m '/Full steps per rev'], 'Position', [1120 520 1200 548], 'Value', '200', 'SampleTime', '0.001');
add_from(m, 'From f_echo', 'f_echo', [1120 590 1200 610]);
add_from(m, 'From ustep',  'ustep',  [1120 640 1200 660]);
add_from(m, 'From omega',  'omega',  [1120 755 1200 775]);
add_from(m, 'From en_cmd', 'en_cmd', [1120 865 1200 885]);

% Theory speed: rps_theory = f_echo / (ustep * spr); rpm_theory = rps_theory * 60
add_block('simulink/Math Operations/Product', [m '/rev per s (theory)'], ...
  'Position', [1285 575 1330 675], 'Inputs', '*//', 'OutDataTypeStr', 'double');
add_block('simulink/Math Operations/Gain', [m '/x60 (theory)'], 'Position', [1410 545 1475 575], 'Gain', '60');
add_block('simulink/Sinks/Display', [m '/Disp RPM Theory'], 'Position', [1830 547 1945 573]);
wire(m, 'From f_echo', 1, 'rev per s (theory)', 1);
wire(m, 'From ustep',  1, 'rev per s (theory)', 2);
wire(m, 'Full steps per rev', 1, 'rev per s (theory)', 3);
wire(m, 'rev per s (theory)', 1, 'x60 (theory)', 1);
h_rt = wire(m, 'x60 (theory)', 1, 'Disp RPM Theory', 1);
set_param(h_rt, 'Name', 'rpm_theory');
set_param(get_param([m '/x60 (theory)'], 'PortHandles').Outport(1), 'DataLogging', 'on');

% Measured speed: omega -> double -> 1/(2*pi) -> Abs -> x60 -> rpm_meas
add_block('simulink/Signal Attributes/Data Type Conversion', [m '/omega to double'], ...
  'Position', [1265 750 1330 780], 'OutDataTypeStr', 'double');
add_block('simulink/Math Operations/Gain', [m '/rad to rev'], 'Position', [1375 750 1455 780], 'Gain', '1/(2*pi)');
add_block('simulink/Math Operations/Abs',  [m '/abs speed'],  'Position', [1515 710 1555 740]);
add_block('simulink/Math Operations/Gain', [m '/x60 (meas)'], 'Position', [1610 710 1675 740], 'Gain', '60');
add_block('simulink/Sinks/Display', [m '/Disp RPM Meas'], 'Position', [1830 712 1945 738]);
wire(m, 'From omega', 1, 'omega to double', 1);
wire(m, 'omega to double', 1, 'rad to rev', 1);
wire(m, 'rad to rev', 1, 'abs speed', 1);
wire(m, 'abs speed', 1, 'x60 (meas)', 1);
wire(m, 'x60 (meas)', 1, 'Disp RPM Meas', 1);
h_rm = get_param(get_param([m '/x60 (meas)'], 'PortHandles').Outport(1), 'Line');
set_param(h_rm, 'Name', 'rpm_meas');
set_param(get_param([m '/x60 (meas)'], 'PortHandles').Outport(1), 'DataLogging', 'on');

% Parallel 10 Hz 2nd-order Butterworth discrete LPF (Ts=0.001 s, matching DC lab 10 Hz cutoff)
add_block('simulink/Discrete/Discrete Filter', [m '/LPF 10Hz (2nd-order)'], ...
  'Position', [1685 935 1785 975], ...
  'Numerator',   '[0.000944691843840 0.001889383687680 0.000944691843840]', ...
  'Denominator', '[1 -1.911197067426073 0.914975834801434]', ...
  'SampleTime',  '0.001');
add_block('simulink/Sinks/Display', [m '/Disp RPM (LPF)'], 'Position', [1835 942 1950 968]);
wire(m, 'x60 (meas)', 1, 'LPF 10Hz (2nd-order)', 1);
h_lpf = wire(m, 'LPF 10Hz (2nd-order)', 1, 'Disp RPM (LPF)', 1);
set_param(h_lpf, 'Name', 'rpm_meas_lpf');
set_param(get_param([m '/LPF 10Hz (2nd-order)'], 'PortHandles').Outport(1), 'DataLogging', 'on');

% Lost full steps: integrate rps_theory & rad_to_rev with ExternalReset='level' on en_cmd
add_block('simulink/Discrete/Discrete-Time Integrator', [m '/commanded rev'], ...
  'Position', [1455 620 1520 665], 'ExternalReset', 'level');
add_block('simulink/Discrete/Discrete-Time Integrator', [m '/shaft rev'], ...
  'Position', [1515 805 1580 850], 'ExternalReset', 'level');
add_block('simulink/Math Operations/Abs', [m '/abs rev'], 'Position', [1615 812 1655 842]);
add_block('simulink/Math Operations/Subtract', [m '/cmd - actual'], 'Position', [1695 775 1735 835]);
add_block('simulink/Math Operations/Product',  [m '/to full steps'], 'Position', [1770 800 1805 860]);
add_block('simulink/Sinks/Display', [m '/Disp Lost Steps'], 'Position', [1835 817 1950 843]);

wire(m, 'rev per s (theory)', 1, 'commanded rev', 1);
wire(m, 'From en_cmd',        1, 'commanded rev', 2);
wire(m, 'rad to rev',         1, 'shaft rev', 1);
wire(m, 'From en_cmd',        1, 'shaft rev', 2);
wire(m, 'shaft rev',          1, 'abs rev', 1);
wire(m, 'commanded rev',      1, 'cmd - actual', 1);
wire(m, 'abs rev',            1, 'cmd - actual', 2);
wire(m, 'cmd - actual',       1, 'to full steps', 1);
wire(m, 'Full steps per rev', 1, 'to full steps', 2);
h_ls = wire(m, 'to full steps', 1, 'Disp Lost Steps', 1);
set_param(h_ls, 'Name', 'lost_steps');
set_param(get_param([m '/to full steps'], 'PortHandles').Outport(1), 'DataLogging', 'on');

% ---- 6. Solver, Pacing, StopFcn safety callback (per model name!)
set_param(m, 'SolverType', 'Fixed-step', 'SolverName', 'FixedStepDiscrete', ...
  'FixedStep', '0.001', 'StopTime', sp.stop, 'EnablePacing', 'on', 'SignalLogging', 'on');
set_param(m, 'StopFcn', stop_fcn_script(sp.name));

save_system(m);
out_slx = fullfile(sp.dir, [sp.name '.slx']);
Simulink.exportToVersion(m, out_slx, 'R2025b');
if do_png
  try
    print(['-s' m], '-dpng', '-r110', fullfile(work_dir, 'master_layout.png'));
  catch e
    fprintf('PRINT ERR %s\n', e.message);
  end
end
close_system(m, 0);
fprintf('BUILT %s\n', out_slx);
end

function s = scheduler_script()
s = strjoin({
  'function [freq_cmd, m0_cmd, m1_cmd, m2_cmd, dir_cmd, en_cmd, microstep_M, target_freq, accel_hz_s, is_steady, step_id] = experiment_scheduler(t, exp_mode, drive_mode, accel_lim, max_freq, manual_freq, manual_dir, manual_en)'
  '% Clock-driven Stepper Experiment Scheduler for Lab 2.2 (inspired by MotorXploer_dcmotorlab)'
  '% Exp Mode:'
  '%   0 : Manual / R14 (safe default with Manual EN = 1)'
  '%   1 : R0 Baseline Calibration (5 s idle, EN = 1, f = 0 Hz; steady 0.5..5.0 s)'
  '%   2 : R3 All 6 DRV8825 Drive Modes Demo at Manual Freq (4 s on + 2 s EN=1 rest each)'
  '%   3 : R4/R5 Frequency vs Speed Staircase (200..1600 Hz in 200 Hz steps, 4 s each, ramped)'
  '%   4 : R6 Loss Step Pull-In Ladder (200..2400 Hz step from rest, 2.5 s on + 1.5 s EN=1 rest, no ramp)'
  '%   5 : R8 Acceleration Ramp Pull-Out (0 -> Max Freq at Accel Limit Hz/s + 1 s hold, then EN=1)'
  ''
  'EN_ENABLE  = 0.0;'
  'EN_DISABLE = 1.0;'
  'F_HARD_MAX = 20000.0;'
  ''
  'mode_int = round(double(exp_mode));'
  'drv_idx  = max(1, min(6, round(double(drive_mode))));'
  'acc      = max(50.0, double(accel_lim));'
  'f_max    = max(200.0, min(F_HARD_MAX, double(max_freq)));'
  'm_freq   = max(0.0, min(F_HARD_MAX, double(manual_freq)));'
  'm_dir    = double(round(double(manual_dir)) ~= 0);'
  'm_en     = double(round(double(manual_en)) ~= 0);'
  ''
  '% DRV8825 truth table (M0=LSB, M2=MSB): 1=Full, 2=1/2, 3=1/4, 4=1/8, 5=1/16, 6=1/32'
  'M0_TBL = [0.0, 1.0, 0.0, 1.0, 0.0, 1.0];'
  'M1_TBL = [0.0, 0.0, 1.0, 1.0, 0.0, 0.0];'
  'M2_TBL = [0.0, 0.0, 0.0, 0.0, 1.0, 1.0];'
  'MS_TBL = [1.0, 2.0, 4.0, 8.0, 16.0, 32.0];'
  ''
  'freq_cmd    = 0.0;'
  'dir_cmd     = m_dir;'
  'en_cmd      = EN_DISABLE;'
  'target_freq = 0.0;'
  'accel_hz_s  = 0.0;'
  'is_steady   = 0.0;'
  'step_id     = 0.0;'
  'active_drv  = drv_idx;'
  ''
  'switch mode_int'
  '    case 0  % Manual / R14'
  '        freq_cmd    = m_freq;'
  '        target_freq = m_freq;'
  '        en_cmd      = m_en;'
  '        step_id     = 0.0;'
  '        if t >= 0.5 && en_cmd == EN_ENABLE'
  '            is_steady = 1.0;'
  '        end'
  ''
  '    case 1  % R0: 5 s Idle Baseline Calibration (EN=1, f=0)'
  '        freq_cmd    = 0.0;'
  '        target_freq = 0.0;'
  '        en_cmd      = EN_DISABLE;'
  '        if t <= 5.0'
  '            step_id = 1.0;'
  '            if t >= 0.5'
  '                is_steady = 1.0;'
  '            end'
  '        else'
  '            step_id = 99.0;'
  '        end'
  ''
  '    case 2  % R3: All 6 DRV8825 Modes Demo at m_freq (default 400 Hz)'
  '        t_boot = 1.5;'
  '        t_on   = 4.0;'
  '        t_off  = 2.0;'
  '        t_slot = t_on + t_off;'
  '        f_demo = max(50.0, min(5000.0, m_freq));'
  '        accel_hz_s = acc;'
  '        if t < t_boot'
  '            step_id = 0.0; en_cmd = EN_DISABLE;'
  '        else'
  '            idx = floor((t - t_boot) / t_slot) + 1;'
  '            if idx <= 6'
  '                active_drv = idx;'
  '                t_in = (t - t_boot) - (idx - 1) * t_slot;'
  '                if t_in < t_on'
  '                    step_id     = double(idx);'
  '                    en_cmd      = EN_ENABLE;'
  '                    target_freq = f_demo;'
  '                    freq_cmd    = min(f_demo, acc * t_in);'
  '                    if t_in >= 1.2 && t_in <= (t_on - 0.1)'
  '                        is_steady = 1.0;'
  '                    end'
  '                else'
  '                    step_id = 0.0; en_cmd = EN_DISABLE;'
  '                end'
  '            else'
  '                step_id = 99.0; en_cmd = EN_DISABLE;'
  '            end'
  '        end'
  ''
  '    case 3  % R4/R5: Frequency vs Speed Staircase (200..1600 Hz, 4 s dwell, ramped)'
  '        freqs  = [200.0, 400.0, 600.0, 800.0, 1000.0, 1200.0, 1400.0, 1600.0];'
  '        t_boot = 1.5;'
  '        t_step = 4.0;'
  '        accel_hz_s = acc;'
  '        if t < t_boot'
  '            step_id = 0.0; en_cmd = EN_DISABLE;'
  '        else'
  '            idx = floor((t - t_boot) / t_step) + 1;'
  '            if idx <= numel(freqs)'
  '                step_id     = double(idx);'
  '                en_cmd      = EN_ENABLE;'
  '                t_in        = (t - t_boot) - (idx - 1) * t_step;'
  '                f_targ      = freqs(idx);'
  '                if idx == 1'
  '                    f_prev = 0.0;'
  '                else'
  '                    f_prev = freqs(idx - 1);'
  '                end'
  '                target_freq = f_targ;'
  '                freq_cmd    = min(f_targ, f_prev + acc * t_in);'
  '                if t_in >= 1.5 && t_in <= (t_step - 0.1)'
  '                    is_steady = 1.0;'
  '                end'
  '            else'
  '                step_id = 99.0; en_cmd = EN_DISABLE;'
  '            end'
  '        end'
  ''
  '    case 4  % R6: Pull-In Loss Step Ladder (step from rest, NO accel limit)'
  '        freqs  = [200.0, 400.0, 600.0, 800.0, 1000.0, 1200.0, 1400.0, 1600.0, 2000.0, 2400.0];'
  '        t_boot = 1.5;'
  '        t_on   = 2.5;'
  '        t_off  = 1.5;'
  '        t_slot = t_on + t_off;'
  '        accel_hz_s = 0.0;'
  '        if t < t_boot'
  '            step_id = 0.0; en_cmd = EN_DISABLE;'
  '        else'
  '            idx = floor((t - t_boot) / t_slot) + 1;'
  '            if idx <= numel(freqs)'
  '                t_in = (t - t_boot) - (idx - 1) * t_slot;'
  '                if t_in < t_on'
  '                    step_id     = double(idx);'
  '                    en_cmd      = EN_ENABLE;'
  '                    target_freq = freqs(idx);'
  '                    freq_cmd    = freqs(idx);'
  '                    if t_in >= 0.8 && t_in <= (t_on - 0.1)'
  '                        is_steady = 1.0;'
  '                    end'
  '                else'
  '                    step_id = 0.0; en_cmd = EN_DISABLE;'
  '                end'
  '            else'
  '                step_id = 99.0; en_cmd = EN_DISABLE;'
  '            end'
  '        end'
  ''
  '    case 5  % R8: Linear Acceleration Ramp Pull-Out Test (lock at 200 Hz 0.5 s, then ramp 200 -> f_max at acc Hz/s)'
  '        % Starting from 200 Hz (5 ms period) avoids STM32 TIM20 preload stalling on sub-10 Hz periods.'
  '        t_boot  = 1.5;'
  '        f_start = min(200.0, f_max);'
  '        t_lock  = 0.5;'
  '        t_ramp  = max(0.0, (f_max - f_start) / acc);'
  '        t_hold  = 1.0;'
  '        accel_hz_s = acc;'
  '        if t < t_boot'
  '            step_id = 0.0; en_cmd = EN_DISABLE;'
  '        else'
  '            t_in = t - t_boot;'
  '            if t_in < (t_lock + t_ramp + t_hold)'
  '                step_id = 1.0;'
  '                en_cmd  = EN_ENABLE;'
  '                if t_in < t_lock'
  '                    freq_cmd = f_start;'
  '                else'
  '                    freq_cmd = min(f_max, f_start + acc * (t_in - t_lock));'
  '                end'
  '                target_freq = freq_cmd;'
  '                if t_in >= t_lock && t_in <= (t_lock + t_ramp + t_hold - 0.05)'
  '                    is_steady = 1.0;'
  '                end'
  '            else'
  '                step_id = 99.0; en_cmd = EN_DISABLE;'
  '            end'
  '        end'
  ''
  '    otherwise'
  '        freq_cmd = 0.0; en_cmd = EN_DISABLE; step_id = 0.0;'
  'end'
  ''
  'freq_cmd    = max(0.0, min(F_HARD_MAX, freq_cmd));'
  'm0_cmd      = M0_TBL(active_drv);'
  'm1_cmd      = M1_TBL(active_drv);'
  'm2_cmd      = M2_TBL(active_drv);'
  'microstep_M = MS_TBL(active_drv);'
  'end'
}, newline);
end

function s = current_script()
s = strjoin({
  'function I_A = current_adc_to_amps(adc_raw)'
  '% Convert raw 12-bit ADC (PA1) to Current (A).'
  '% Slope borrowed from MotorXploer_dcmotorlab calibration (unverified for stepper path);'
  '% analyze_stepper_labs.m subtracts the per-session R0 zero-offset automatically.'
  'ADC_0     = 2137.5638;  % counts at 0 A (nominal)'
  'ADC_per_A = 66.3185;    % counts per A (DC-path calibration)'
  'I_A = (double(adc_raw) - ADC_0) / ADC_per_A;'
  'end'
}, newline);
end

function s = stop_fcn_script(mdl_name)
s = strjoin({
  '% --- Safe StopFcn: stop motors & disable stepper driver (EN=1) on sim end ---'
  'try'
  sprintf('    mxs_mdl = ''%s'';', mdl_name)
  '    if ~bdIsLoaded(mxs_mdl), return; end'
  '    mxs_tx = [mxs_mdl ''/Host Serial Tx''];'
  '    if ~strcmp(get_param(mxs_tx, ''Commented''), ''off''), return; end'
  '    mxs_port = get_param(mxs_tx, ''port'');'
  '    if strcmp(mxs_port, ''<auto>''), mxs_port = strrep(get_param(mxs_tx, ''autoport''), '''''''', ''''); end'
  '    mxs_hex = @(p) uint8(sscanf(strrep(get_param(mxs_tx, p), '''''''', ''''), ''%x''))'';'
  '    mxs_mf  = min(max(double(slResolve(get_param([mxs_mdl ''/Motor Frequency''], ''Value''), [mxs_mdl ''/Motor Frequency''])), 0), 20000);'
  '    % Frame: header, single([PWM=0, MotorFreq, StepperFreq=0]), int16([M0=0, M1=0, M2=0, DIR=0, EN=1]), terminator'
  '    mxs_frame = [mxs_hex(''binheader''), ...'
  '        typecast(single([0, mxs_mf, 0]), ''uint8''), ...'
  '        typecast(int16([0, 0, 0, 0, 1]), ''uint8''), ...'
  '        mxs_hex(''binterminator'')];'
  '    mxs_s = serialport(mxs_port, str2double(get_param(mxs_tx, ''baudrate'')));'
  '    for mxs_k = 1:3'
  '        write(mxs_s, mxs_frame, ''uint8''); pause(0.02);'
  '    end'
  '    clear mxs_s'
  '    disp([mxs_mdl '': stop command sent (Stepper Freq = 0, EN = 1 disabled).'']);'
  'catch mxs_err'
  '    warning(''MotorXploer:stopFailed'', ''Could not send stop command (%s): %s'', mxs_mdl, mxs_err.message);'
  'end'
  'clear mxs_*'
}, newline);
end

function html = guide_text(sp)
html = [ ...
  '<p style="margin:0 0 8px 0"><b>' sp.title '</b><br/>' ...
  'Default <b>Exp Mode = ' sp.exp_mode '</b>, <b>StopTime = ' sp.stop ' s</b>.<br/>' ...
  'On stop, <b>StopFcn</b> sends Stepper Freq = 0 Hz and <b>EN = 1</b> (driver disabled).</p>' ...
  '<p style="margin:0 0 6px 0"><b>Drive Mode (1..6, DRV8825, no wave drive) [M0 M1 M2]:</b><br/>' ...
  '1=Full (000) | 2=1/2 (100) | 3=1/4 (010) | 4=1/8 (110) | 5=1/16 (001) | 6=1/32 (101)</p>' ...
  '<p style="margin:0 0 6px 0"><b>Exp Mode map:</b><br/>' ...
  '<b>0</b> Manual / R14 (passes Manual Freq, DIR, EN=1 safe)<br/>' ...
  '<b>1</b> R0 Baseline: 5 s idle (EN=1, f=0) for PA0/PA1 zero offset<br/>' ...
  '<b>2</b> R3 Real Op: all 6 modes at Manual Freq (4 s on + 2 s EN=1 rest)<br/>' ...
  '<b>3</b> R4/R5 Freq Sweep: 200..1600 Hz (4 s each, ramped at Accel Limit)<br/>' ...
  '<b>4</b> R6 Pull-In: 200..2400 Hz step-from-rest (2.5 s on + 1.5 s EN=1 rest)<br/>' ...
  '<b>5</b> R8 Accel Ramp: 0 to Max Freq at Accel Limit Hz/s + 1 s hold, then EN=1</p>' ...
  '<p style="margin:0"><b>Outputs:</b> <b>step_id</b> (0=idle, 1..N=step, 99=done), ' ...
  '<b>is_steady</b> (1=settled), <b>lost_steps</b> (resets when EN=1).<br/>' ...
  'Run <b>run_stepper_labs</b> in MATLAB to automate all rubric experiments.</p>' ...
];
end

function add_area(m, title, rect, color)
h = add_block('built-in/Area', [m '/' title], 'Position', rect);
set_param(h, 'BackgroundColor', color);
end

function add_goto(m, n, tag, pos)
add_block('simulink/Signal Routing/Goto', [m '/' n], 'Position', pos, 'GotoTag', tag, 'ShowName', 'off');
end

function add_from(m, n, tag, pos)
add_block('simulink/Signal Routing/From', [m '/' n], 'Position', pos, 'GotoTag', tag, 'ShowName', 'off');
end

function h = wire(m, sb, sp, db, dp)
ps = get_param([m '/' sb], 'PortHandles');
pd = get_param([m '/' db], 'PortHandles');
h = add_line(m, ps.Outport(sp), pd.Inport(dp), 'autorouting', 'smart');
end
