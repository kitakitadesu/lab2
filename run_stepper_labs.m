function out_dir = run_stepper_labs(labs, varargin)
% RUN_STEPPER_LABS  Automate all Lab 2.2 Stepper Motor Simulink experiments.
%
% Usage:
%   run_stepper_labs()                                % run all labs (R0,R3,R4_R5,R6,R8), 3 trials
%   run_stepper_labs({'R0','R6','R8'})                % run a subset of rubric labs
%   run_stepper_labs('all', 'Port', 'COM5')           % override serial port for all models
%   run_stepper_labs({'R4_R5'}, 'Trials', 1, 'Modes', [1 2 6])
%
% Models live in ./stepper_motor/ (one self-contained .slx per rubric item).
% Raw SimulationOutput logsout + metadata are saved to ./stepper_data/<timestamp>/
% and analyzed automatically via analyze_stepper_labs().

if nargin < 1 || isempty(labs) || (ischar(labs) && strcmpi(labs, 'all')) || (isstring(labs) && strcmpi(labs, "all"))
    labs = {'R0', 'R3', 'R4_R5', 'R6', 'R8'};
elseif ischar(labs) || isstring(labs)
    labs = {char(labs)};
end

p = inputParser;
addParameter(p, 'Port',        '',                    @(x) ischar(x) || isstring(x));
addParameter(p, 'Trials',      3,                     @(x) isnumeric(x) && isscalar(x) && x >= 1);
addParameter(p, 'Modes',       [1 2 3 4 5 6],         @(x) isnumeric(x) && all(x >= 1 & x <= 6));
addParameter(p, 'Accels',      [4000 2000 1000 500],  @(x) isnumeric(x) && all(x >= 50));
addParameter(p, 'R3Freq',      400,                   @(x) isnumeric(x) && isscalar(x) && x > 0);
addParameter(p, 'R4Accel',     2000,                  @(x) isnumeric(x) && isscalar(x) && x >= 50);
addParameter(p, 'R6Mode',      1,                     @(x) isnumeric(x) && all(x >= 1 & x <= 6));
addParameter(p, 'R8Mode',      1,                     @(x) isnumeric(x) && all(x >= 1 & x <= 6));
addParameter(p, 'MaxFreq',     3000,                  @(x) isnumeric(x) && isscalar(x) && x >= 200);
addParameter(p, 'StepsPerRev', 200,                   @(x) isnumeric(x) && isscalar(x) && x > 0);
addParameter(p, 'Cooldown',    3,                     @(x) isnumeric(x) && isscalar(x) && x >= 0);
addParameter(p, 'OutDir',      '',                    @(x) ischar(x) || isstring(x));
addParameter(p, 'AutoAnalyze', true,                  @(x) islogical(x) && isscalar(x));
parse(p, varargin{:});
cfg = p.Results;
cfg.Port = char(cfg.Port);

base_dir = fileparts(mfilename('fullpath'));
slx_dir  = fullfile(base_dir, 'stepper_motor');
if isempty(cfg.OutDir)
    stamp   = char(datetime('now', 'Format', 'yyyyMMdd_HHmmss'));
    out_dir = fullfile(base_dir, 'stepper_data', stamp);
else
    out_dir = char(cfg.OutDir);
end
if ~isfolder(out_dir), mkdir(out_dir); end

% Build run queue first so we can report total runs and wall-clock estimate upfront
queue = build_queue(labs, slx_dir, cfg);
assert(~isempty(queue), 'No valid lab names in input. Valid: R0, R3, R4_R5, R6, R8.');

est_s = sum([queue.stop_time]) + max(0, numel(queue) - 1) * cfg.Cooldown;
fprintf('\n=== Lab 2.2 Stepper Motor Automated Runner ===\n');
fprintf('Output folder : %s\n', out_dir);
fprintf('Serial port   : %s\n', tern(isempty(cfg.Port), '<model default>', cfg.Port));
fprintf('Queued runs   : %d (estimated wall-clock ~%.1f min with pacing on)\n', numel(queue), est_s / 60);
fprintf('Safety check  : verify 5V_SEL=E5V, 3.3V step-down, DRV8825 current limit, and motor clear.\n\n');

save(fullfile(out_dir, 'run_config.mat'), 'cfg', 'labs', 'queue');
fid = fopen(fullfile(out_dir, 'queue.json'), 'w');
fwrite(fid, jsonencode(queue));
fclose(fid);

for i = 1:numel(queue)
    job = queue(i);
    fprintf('[%2d/%2d] %-34s (StopTime=%gs) ... ', i, numel(queue), job.tag, job.stop_time);
    t0 = tic;
    sim_out = execute_job(job, cfg);
    elapsed = toc(t0);
    logsout = sim_out.logsout;
    meta = job;
    meta.steps_per_rev = cfg.StepsPerRev;
    meta.timestamp = char(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss'));
    meta.elapsed_s = elapsed;
    save(fullfile(out_dir, [job.tag '.mat']), 'logsout', 'meta');
    fprintf('done (%.1f s)\n', elapsed);
    if i < numel(queue) && cfg.Cooldown > 0
        fprintf('        cooling down %g s (EN=1)...\n', cfg.Cooldown);
        pause(cfg.Cooldown);
    end
end

fprintf('\nAll %d runs saved in %s\n', numel(queue), out_dir);
if cfg.AutoAnalyze
    analyze_stepper_labs(out_dir);
end
end

function queue = build_queue(labs, slx_dir, cfg)
mode_names = {'Full', 'Half', '1_4', '1_8', '1_16', '1_32'};
queue = struct('lab', {}, 'slx', {}, 'model', {}, 'tag', {}, 'exp_mode', {}, ...
    'drive_mode', {}, 'drive_label', {}, 'accel', {}, 'max_freq', {}, 'manual_freq', {}, ...
    'trial', {}, 'stop_time', {});

for k = 1:numel(labs)
    L = upper(strtrim(labs{k}));
    switch L
        case 'R0'
            queue(end+1) = mk_job('R0', slx_dir, 'R0_Baseline_Calibration', 'R0_baseline', ...
                1, 1, 'Idle', cfg.R4Accel, cfg.MaxFreq, 0, 1, 6); %#ok<AGROW>
        case 'R3'
            for tr = 1:cfg.Trials
                queue(end+1) = mk_job('R3', slx_dir, 'R3_DriveModes_RealOp', ...
                    sprintf('R3_allmodes_T%d', tr), 2, 1, 'All6', cfg.R4Accel, cfg.MaxFreq, cfg.R3Freq, tr, 38); %#ok<AGROW>
            end
        case {'R4_R5', 'R4', 'R5'}
            for dm = cfg.Modes
                for tr = 1:cfg.Trials
                    queue(end+1) = mk_job('R4_R5', slx_dir, 'R4_R5_FreqVsSpeed', ...
                        sprintf('R4R5_M%d_%s_T%d', dm, mode_names{dm}, tr), ...
                        3, dm, mode_names{dm}, cfg.R4Accel, cfg.MaxFreq, cfg.R3Freq, tr, 37); %#ok<AGROW>
                end
            end
        case 'R6'
            for dm = cfg.R6Mode
                for tr = 1:cfg.Trials
                    queue(end+1) = mk_job('R6', slx_dir, 'R6_LossStep_PullIn', ...
                        sprintf('R6_pullin_M%d_%s_T%d', dm, mode_names{dm}, tr), ...
                        4, dm, mode_names{dm}, 0, cfg.MaxFreq, cfg.R3Freq, tr, 44); %#ok<AGROW>
                end
            end
        case 'R8'
            for dm = cfg.R8Mode
                for ac = cfg.Accels
                    stop_t = ceil(1.5 + 0.5 + max(0, cfg.MaxFreq - 200) / ac + 3.0);
                    for tr = 1:cfg.Trials
                        queue(end+1) = mk_job('R8', slx_dir, 'R8_Accel_PullOut', ...
                            sprintf('R8_accel%d_M%d_%s_T%d', round(ac), dm, mode_names{dm}, tr), ...
                            5, dm, mode_names{dm}, ac, cfg.MaxFreq, cfg.R3Freq, tr, stop_t); %#ok<AGROW>
                    end
                end
            end
        otherwise
            error('run_stepper_labs:unknownLab', 'Unknown lab "%s". Expected R0, R3, R4_R5, R6, or R8.', L);
    end
end
end

function j = mk_job(lab, slx_dir, model, tag, em, dm, dlabel, acc, fmax, mf, tr, st)
j = struct('lab', lab, 'slx', fullfile(slx_dir, [model '.slx']), 'model', model, 'tag', tag, ...
    'exp_mode', em, 'drive_mode', dm, 'drive_label', dlabel, 'accel', acc, ...
    'max_freq', fmax, 'manual_freq', mf, 'trial', tr, 'stop_time', st);
end

function sim_out = execute_job(job, cfg)
assert(isfile(job.slx), 'Model not found: %s', job.slx);
if ~bdIsLoaded(job.model)
    load_system(job.slx);
end
cleanup = onCleanup(@() close_if_loaded(job.model));
m = job.model;

if ~isempty(cfg.Port)
    for blk = {'Host Serial Setup', 'Host Serial Rx1', 'Host Serial Tx'}
        set_param([m '/' blk{1}], 'port', cfg.Port);
    end
else
    txp = get_param([m '/Host Serial Tx'], 'port');
    ap  = strrep(get_param([m '/Host Serial Tx'], 'autoport'), '''', '');
    eff = tern(strcmp(txp, '<auto>'), ap, txp);
    assert(~isempty(eff) && ~contains(eff, 'debug-console') && ~strcmp(eff, '<auto>'), ...
        ['Serial port is not configured (resolved to "%s"). ' ...
         'Pass ''Port'', ''COMx'' (Windows) or ''/dev/cu.usbmodem...'' (macOS), ' ...
         'or set the port in the Host Serial Setup/Rx1/Tx blocks first.'], eff);
end

set_param([m '/Exp Mode'],           'Value', num2str(job.exp_mode));
set_param([m '/Drive Mode'],         'Value', num2str(job.drive_mode));
set_param([m '/Accel Limit (Hz per s)'], 'Value', num2str(max(50, job.accel)));
set_param([m '/Max Freq (Hz)'],      'Value', num2str(job.max_freq));
set_param([m '/Manual Freq (Hz)'],   'Value', num2str(job.manual_freq));
set_param([m '/Full steps per rev'], 'Value', num2str(cfg.StepsPerRev));

sim_out = sim(m, 'StopTime', num2str(job.stop_time));
clear cleanup
end

function close_if_loaded(m)
if bdIsLoaded(m)
    close_system(m, 0);
end
end

function s = tern(cond, a, b)
if cond, s = a; else, s = b; end
end
