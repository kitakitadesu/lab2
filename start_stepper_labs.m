function out_dir = start_stepper_labs()
% START_STEPPER_LABS  Interactive launcher for Lab 2.2 Stepper Motor experiments.
%
% Prompts for serial port (auto-discovered via serialportlist), rubric labs to
% run, repeat trials, modes/accelerations, and safety confirmation, then calls
% run_stepper_labs() -> analyze_stepper_labs().
%
% Usage:
%   start_stepper_labs

out_dir = '';
base_dir = fileparts(mfilename('fullpath'));
addpath(base_dir);

fprintf('\n====================================================\n');
fprintf('   Lab 2.2 Stepper Motor — Interactive Lab Runner\n');
fprintf('====================================================\n');
fprintf('  1) Run automated hardware experiments\n');
fprintf('  2) Open R14_Control_PerMode.slx (manual control)\n');
fprintf('  3) Re-analyze existing stepper_data folder\n');
fprintf('  0) Quit\n');
action = ask_int('Select action [1]: ', 1, 0, 3);

if action == 0
    fprintf('Cancelled.\n');
    return;
elseif action == 3
    out_dir = pick_and_analyze(fullfile(base_dir, 'stepper_data'));
    return;
end

% ---- 1. Serial port selection
port = pick_serial_port();
if isempty(port)
    fprintf('No serial port selected. Cancelled.\n');
    return;
end

if action == 2
    slx = fullfile(base_dir, 'stepper_motor', 'R14_Control_PerMode.slx');
    assert(isfile(slx), 'Model not found: %s', slx);
    open_system(slx);
    for blk = {'Host Serial Setup', 'Host Serial Rx1', 'Host Serial Tx'}
        set_param(['R14_Control_PerMode/' blk{1}], 'port', port);
    end
    fprintf('Opened R14_Control_PerMode with port = %s (Manual EN = 1 safe default).\n', port);
    return;
end

% ---- 2. Labs to run
fprintf('\n--- Step 2: Select Rubric Labs to Run ---\n');
lab_keys = {'R0', 'R3', 'R4_R5', 'R6', 'R8'};
lab_desc = { ...
    'R0    Baseline Calibration (5 s idle PA0/PA1 zero offset)', ...
    'R3    Real Operation Demo (all 6 DRV8825 modes in one run)', ...
    'R4_R5 Frequency vs Speed Sweep (200..1600 Hz per drive mode)', ...
    'R6    Loss Step Pull-In Ladder (step from rest, no ramp)', ...
    'R8    Acceleration Ramp Pull-Out (0 -> Max Freq per accel)'};
for k = 1:numel(lab_keys)
    fprintf('  %d) %s\n', k, lab_desc{k});
end
fprintf('  a) ALL labs (R0, R3, R4_R5, R6, R8)\n');
raw_labs = strtrim(input('Enter numbers (e.g. "1 3 4") or "a" [a]: ', 's'));
labs = parse_lab_selection(raw_labs, lab_keys);
if isempty(labs)
    fprintf('No valid labs selected. Cancelled.\n');
    return;
end

% ---- 3. Experiment parameters (only ask what applies)
fprintf('\n--- Step 3: Experiment Parameters (Enter = default) ---\n');
has_r3  = any(strcmp(labs, 'R3'));
has_r45 = any(strcmp(labs, 'R4_R5'));
has_r6  = any(strcmp(labs, 'R6'));
has_r8  = any(strcmp(labs, 'R8'));

if has_r3 || has_r45 || has_r6 || has_r8
    trials = ask_int('Repeat trials per condition for R9 [3]: ', 3, 1, 20);
else
    trials = 1;
end

r3_freq = 400;
if has_r3
    r3_freq = ask_num('R3 demo STEP frequency in Hz [400]: ', 400, 50, 5000);
end

modes = [1 2 3 4 5 6];
r4_accel = 2000;
if has_r45
    fprintf('  Drive modes: 1=Full, 2=1/2, 3=1/4, 4=1/8, 5=1/16, 6=1/32\n');
    modes = ask_vec('R4/R5 drive modes to sweep [1 2 3 4 5 6]: ', [1 2 3 4 5 6], 1, 6, true);
    r4_accel = ask_num('R4/R5 transition accel limit in Hz/s [2000]: ', 2000, 50, 20000);
end

r6_mode = 1;
if has_r6
    r6_mode = ask_int('R6 Pull-In drive mode (1=Full..6=1/32) [1]: ', 1, 1, 6);
end

r8_mode = 1;
accels = [4000 2000 1000 500];
max_freq = 3000;
if has_r8
    r8_mode  = ask_int('R8 Accel Ramp drive mode (1=Full..6=1/32) [1]: ', 1, 1, 6);
    accels   = ask_vec('R8 accel limits in Hz/s [4000 2000 1000 500]: ', [4000 2000 1000 500], 50, 20000, false);
    max_freq = ask_num('R8 max ramp frequency in Hz [3000]: ', 3000, 200, 20000);
end

spr      = ask_num('Motor full steps per rev (1.8 deg = 200) [200]: ', 200, 1, 10000);
cooldown = ask_num('Cool-down pause between runs in s [3]: ', 3, 0, 120);
auto_ana = ask_yesno('Auto-generate CSV tables & PNG figures after runs? [Y/n]: ', true);

% ---- 4. Review & safety confirmation
est_runs = (any(strcmp(labs,'R0'))) + has_r3*trials + has_r45*numel(modes)*trials ...
         + has_r6*trials + has_r8*numel(accels)*trials;
est_s = (any(strcmp(labs,'R0')))*6 + has_r3*trials*38 + has_r45*numel(modes)*trials*37 ...
      + has_r6*trials*44 + has_r8*sum(ceil(1.5 + max_freq./accels + 3.0))*trials ...
      + max(0, est_runs - 1)*cooldown;

fprintf('\n--- Review & Safety Checklist ---\n');
fprintf('  Serial port : %s\n', port);
fprintf('  Labs        : %s\n', strjoin(labs, ', '));
fprintf('  Trials      : %d | Steps/rev: %g | Cooldown: %g s\n', trials, spr, cooldown);
if has_r45, fprintf('  R4/R5 modes : %s (accel %g Hz/s)\n', mat2str(modes), r4_accel); end
if has_r6,  fprintf('  R6 mode     : %d\n', r6_mode); end
if has_r8,  fprintf('  R8 accels   : %s Hz/s (mode %d, max %g Hz)\n', mat2str(accels), r8_mode, max_freq); end
fprintf('  Total runs  : %d (~%.1f min wall-clock with pacing on)\n', est_runs, est_s / 60);
fprintf('  [!] Check hardware: 5V_SEL=E5V, 3.3V step-down OK, DRV8825 current limit set, shaft clear.\n');

if ~ask_yesno('Start automated runs now? [Y/n]: ', true)
    fprintf('Cancelled.\n');
    return;
end

out_dir = run_stepper_labs(labs, ...
    'Port',        port, ...
    'Trials',      trials, ...
    'Modes',       modes, ...
    'Accels',      accels, ...
    'R3Freq',      r3_freq, ...
    'R4Accel',     r4_accel, ...
    'R6Mode',      r6_mode, ...
    'R8Mode',      r8_mode, ...
    'MaxFreq',     max_freq, ...
    'StepsPerRev', spr, ...
    'Cooldown',    cooldown, ...
    'AutoAnalyze', auto_ana);
end

% =========================================================================
function port = pick_serial_port()
fprintf('\n--- Step 1: Select ST-Link Serial Port ---\n');
try
    ports = cellstr(serialportlist('available'));
catch
    ports = {};
end
% Hide macOS system noise and rank USB/COM ports (preferring /dev/cu.usbmodem*) first
good = ports(~contains(ports, 'debug-console', 'IgnoreCase', true) & ...
             ~contains(ports, 'Bluetooth-Incoming-Port', 'IgnoreCase', true));
if ~isempty(good), ports = good; end
score = zeros(size(ports));
for k = 1:numel(ports)
    if contains(ports{k}, '/dev/cu.usbmodem', 'IgnoreCase', true), score(k) = 4;
    elseif contains(ports{k}, 'usbmodem', 'IgnoreCase', true) || contains(ports{k}, 'usbserial', 'IgnoreCase', true), score(k) = 3;
    elseif startsWith(upper(ports{k}), 'COM'), score(k) = 3;
    elseif contains(ports{k}, '/dev/cu.', 'IgnoreCase', true), score(k) = 1;
    end
end
[~, ord] = sort(score, 'descend');
ports = ports(ord);

if isempty(ports)
    fprintf('  No USB/COM serial ports detected automatically.\n');
    port = strtrim(input('Enter port manually (e.g. COM5 or /dev/cu.usbmodemXXXX, blank to cancel): ', 's'));
    return;
end

for k = 1:numel(ports)
    fprintf('  %d) %s\n', k, ports{k});
end
fprintf('  m) Type port name manually\n');
raw = strtrim(input(sprintf('Select port [1]: '), 's'));
if isempty(raw)
    port = ports{1};
elseif strcmpi(raw, 'm')
    port = strtrim(input('Enter port name: ', 's'));
else
    idx = str2double(raw);
    if ~isnan(idx) && idx == round(idx) && idx >= 1 && idx <= numel(ports)
        port = ports{idx};
    else
        port = raw;  % allow typing COM5 directly at the prompt
    end
end
if contains(port, 'debug-console', 'IgnoreCase', true)
    warning('start_stepper_labs:debugConsole', 'Refusing macOS debug-console port "%s".', port);
    port = '';
end
end

function out_dir = pick_and_analyze(data_root)
out_dir = '';
if ~isfolder(data_root)
    fprintf('No stepper_data directory found yet at %s\n', data_root);
    return;
end
d = dir(data_root);
d = d([d.isdir] & ~ismember({d.name}, {'.', '..'}));
if isempty(d)
    fprintf('No saved run folders inside %s\n', data_root);
    return;
end
[~, ord] = sort([d.datenum], 'descend');
d = d(ord);
fprintf('\nSaved run folders (newest first):\n');
for k = 1:numel(d)
    fprintf('  %d) %s\n', k, d(k).name);
end
idx = ask_int('Select folder to analyze [1]: ', 1, 1, numel(d));
out_dir = fullfile(data_root, d(idx).name);
analyze_stepper_labs(out_dir);
end

function labs = parse_lab_selection(raw, lab_keys)
if isempty(raw) || strcmpi(raw, 'a') || strcmpi(raw, 'all')
    labs = lab_keys;
    return;
end
toks = regexp(raw, '[\s,;]+', 'split');
labs = {};
for i = 1:numel(toks)
    tk = strtrim(toks{i});
    if isempty(tk), continue; end
    n = str2double(tk);
    if ~isnan(n) && n == round(n) && n >= 1 && n <= numel(lab_keys)
        k = lab_keys{n};
    else
        m = find(strcmpi(lab_keys, tk), 1);
        if isempty(m) && (strcmpi(tk, 'R4') || strcmpi(tk, 'R5')), m = 3; end
        if isempty(m), continue; end
        k = lab_keys{m};
    end
    if ~any(strcmp(labs, k)), labs{end+1} = k; end %#ok<AGROW>
end
end

function v = ask_int(prompt, def, lo, hi)
for tries = 1:20
    raw = strtrim(input(prompt, 's'));
    if isempty(raw), v = def; return; end
    x = str2double(raw);
    if ~isnan(x) && isfinite(x) && x == round(x) && x >= lo && x <= hi
        v = x; return;
    end
    fprintf('  Please enter an integer between %d and %d.\n', lo, hi);
end
error('start_stepper_labs:inputLimit', 'Too many invalid inputs.');
end

function v = ask_num(prompt, def, lo, hi)
for tries = 1:20
    raw = strtrim(input(prompt, 's'));
    if isempty(raw), v = def; return; end
    x = str2double(raw);
    if ~isnan(x) && isfinite(x) && x >= lo && x <= hi
        v = x; return;
    end
    fprintf('  Please enter a number between %g and %g.\n', lo, hi);
end
error('start_stepper_labs:inputLimit', 'Too many invalid inputs.');
end

function v = ask_vec(prompt, def, lo, hi, int_only)
for tries = 1:20
    raw = strtrim(input(prompt, 's'));
    if isempty(raw), v = def; return; end
    toks = regexp(strrep(strrep(raw, '[', ''), ']', ''), '[\s,;]+', 'split');
    toks = toks(~cellfun('isempty', toks));
    x = str2double(toks);
    ok = ~isempty(x) && all(~isnan(x)) && all(isfinite(x)) && all(x >= lo & x <= hi);
    if ok && int_only, ok = all(x == round(x)); end
    if ok
        v = unique(x(:)', 'stable'); return;
    end
    fprintf('  Please enter space-separated values in [%g, %g].\n', lo, hi);
end
error('start_stepper_labs:inputLimit', 'Too many invalid inputs.');
end

function tf = ask_yesno(prompt, def)
raw = strtrim(input(prompt, 's'));
if isempty(raw), tf = def; return; end
tf = startsWith(lower(raw), 'y');
end
