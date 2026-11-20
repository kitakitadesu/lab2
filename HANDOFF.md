# Lab 2.2 Stepper Motor — Handoff

Snapshot of where the work stands, how to run it, and what is left.
Board: NUCLEO-G474RE + DRV8825 + AMT103-V encoder, MotorXplorer firmware (`motorxplorer.bin`).

## Status

| Item | State |
|---|---|
| Per-rubric Simulink models (7 `.slx`, R2025b) | Done, verified in harness (T0a–T6 PASS) |
| Automated runner / analyzer / interactive launcher | Done (`checkcode` clean) |
| Hardware data, 3 trials (all labs) + LPF/fixed-R8 runs | Collected in `stepper_data/` |
| **Hardware data, 5 trials (all labs, Full+Half for R6/R8)** | **Not collected** — board was unplugged when the run started |
| Thai report | Draft only (`Lab2_2_Stepper_Motor_Report_Draft.docx`, placeholders for measured data) |

## Files

| Path | Purpose |
|---|---|
| `MotorXploer_Stepper.slx` | Master model, `Exp Mode` 0..5 (0 = manual, safe default `EN = 1`) |
| `stepper_motor/R0_…R14_*.slx` | One model per rubric item; `Exp Mode` preset per file |
| `start_stepper_labs.m` | Interactive launcher: asks port, labs, trials, modes, accels; prints ETA + safety checklist |
| `run_stepper_labs.m` | Non-interactive runner; saves one `.mat` (`logsout` + `meta`) per run, plus `queue.json` |
| `analyze_stepper_labs.m` | Tables (`tables/*.csv`), report figures (`figures/`), raw figures (`figures_raw/`), 1 kHz raw CSV per run (`raw_csv/`) |
| `stepper_data/<run>/` | Collected data (see below) |
| `Report+Format.docx` | Course template |
| `Lab2_2_Stepper_Motor_Report_Draft.docx` | Thai draft built from the template |

`tools/` (all paths repo-relative; scratch work goes to `tempdir`):

| Script | Purpose |
|---|---|
| `build_stepper_suite.m` | Regenerates the 7 `.slx` from the TA `MotorXploer.slx` (needs the TA repo cloned into the repo root). `build_stepper_suite()` overwrites the repo models; pass a folder to build elsewhere |
| `verify_stepper_suite.m` | Compile checks on all 7 models + harness sims (serial blocks commented out) T0a–T5 + synthetic-data test of the analyzer T6. `verify_stepper_suite(folder)` |
| `make_report_figures.m` | 300-dpi report figures (raw vs LPF, FFT, loss-step time series, Full vs Half pull-out) into `stepper_data/report_final` |
| `build_report_draft.py` | Builds the Thai draft `.docx` from `Report+Format.docx` (Python 3, stdlib only) |
| `progress_dashboard.ts` | Live progress page: `bun tools/progress_dashboard.ts stepper_data/<run> [matlab.log] [port]` → `http://127.0.0.1:8765` (reads `queue.json`, a run counts as done when its `.mat` exists) |

Model internals: clock-driven MATLAB Function `Experiment Scheduler` → TA Output area via Goto/From; `Stepper Kinematics & Loss Step` computes `rpm_theory`, `rpm_meas` (raw), `rpm_meas_lpf` (2nd-order 10 Hz Butterworth, Ts = 1 ms), `lost_steps` (integrators reset while `EN = 1`). `StopFcn` sends `Stepper Freq = 0, EN = 1` on stop.

## Setup on a new machine

1. Clone: `git clone git@github.com:kitakitadesu/lab2.git && cd lab2`
2. MATLAB **R2025b or newer** with Simulink. A C compiler must be set up (`mex -setup C`) because the models use MATLAB Function blocks (MinGW-w64 on Windows, Xcode CLT on macOS).
3. Waijung 18.11a (Host Serial blocks) is **not** in this repo. Get it from the TA repo and install it per its README:
   `git clone https://github.com/MINIFI2548/FRA271_LAB2_ACTUATOR_FRAB12` (also contains `motorxplorer.bin` and the original `MotorXploer.slx`). That folder is git-ignored if you clone it inside `lab2/`.
4. Flash `motorxplorer.bin` by dragging it onto the `NOD_G474RE` drive; LED blinks at ~1 Hz when running.
5. Find your ST-Link serial port: Windows `COMx` (Device Manager), macOS `/dev/cu.usbmodem…` (`serialportlist("available")`). The saved models carry the previous user's macOS port (`/dev/cu.usbmodem213403`); **always pass your own port** (the launcher asks for it).

## How to run

```matlab
cd lab2                                  % repo root
start_stepper_labs                       % interactive: port, labs, trials, modes, accels

% the pending 5-trial collection (86 runs, ~42 min) — replace the port:
run_stepper_labs({'R0','R3','R4_R5','R6','R8'}, 'Port','COM5', ...
    'Trials',5, 'Modes',1:6, 'R6Mode',[1 2], 'R8Mode',[1 2], ...
    'Accels',[4000 2000 1000 500], 'MaxFreq',8000, 'Cooldown',3, ...
    'OutDir','stepper_data/final_5trials', 'AutoAnalyze',false);
analyze_stepper_labs('stepper_data/final_5trials')   % only after the analyzer fixes in "Pending"
```

Before powering: `5V_SEL = E5V`, step-down outputs 3.3 V, DRV8825 current limit set, shaft clear. Keep `EN = 1` when idle (driver off, prevents heating); the models default to it and `StopFcn` re-sends it. If the board streams frames but echoes 0 for commands, press Reset (B2). The runner refuses `<auto>` / `debug-console` ports.

## Data collected so far

| Folder | Content |
|---|---|
| `stepper_data/20261120_200111` | Full suite, 3 trials: R0, R3, R4_R5 (6 modes), R6 Full, R8 Full (R8 ramped from 0 Hz — see caveat) |
| `stepper_data/hw_lpf_r8_full` | R8 Full, 3 trials, 200 Hz start, raw + live LPF |
| `stepper_data/hw_lpf_r6_r8_half` | R6 + R8 Half, 3 trials, raw + live LPF |
| `stepper_data/hw_lpf_compare` | R3 + R4_R5 (Full, Half), 1 trial, raw + live LPF |
| `stepper_data/report_final` | 300-dpi report figures built from the above + `Raw_vs_LPF_R3_metrics.csv` |
| `stepper_data/final_5trials` | Only `queue.json` / `run_config.mat` (run aborted, no data) |

## Findings so far (3-trial data)

- **Speed ∝ frequency / M** holds in every mode while in sync: errors mostly < 0.1 % (e.g. Half 400–1600 Hz, 1/4, 1/8). Larger errors only at the lowest speeds (1/16, 1/32 at 200 Hz) where encoder quantization dominates.
- **Encoder velocity quantization = 7.32 RPM** (1 count/ms at 8192 counts/rev). Raw ripple SD 5–17 RPM is mostly this; the 10 Hz LPF cuts ripple SD by 92.6–98.0 % with mean shift < 0.2 RPM. FFT of Full step @ 400 Hz shows a peak at 100 Hz = f_step/4 (electrical frequency).
- **Full step loses sync at ≥ 600 Hz in the R4_R5 staircase** (≈180 RPM) while Half step runs cleanly to 1600 Hz (240 RPM), including 1200 Hz (same 180 RPM). Points to full-step mid-band resonance, not a torque–speed limit (Full step reached 800–970 RPM on fast ramps).
- **Pull-in (step from rest, R6):** Full 466.7 ± 115.5 Hz, Half 933.3 ± 230.9 Hz.
- **Pull-out vs acceleration, Full step (R8, 200 Hz start, true speed-drop detector):** 500 Hz/s → ~656 Hz (trapped in the resonance band), 1000 → ~2676, 2000 → ~3246, 4000 → ~2908 Hz. Non-monotonic: too slow dwells in resonance, too fast hits the inertia-torque limit. Half step never lost steps up to the 4000 Hz ceiling (hence `MaxFreq = 8000` for the 5-trial run).
- **R8 from 0 Hz stalls at start for 1/f₁** (f₁ = first command, e.g. 0.5 Hz → 2 s at 500 Hz/s): firmware timer period preload. Fixed by holding 200 Hz for 0.5 s before the ramp.
- **PA1 current sensor does not see stepper current** (< 0.04 A change while stepping) — it sits on the DC-motor path. `Current_A` values are not stepper phase current.

## Pending

1. Reconnect the board, run the 86-run 5-trial collection above, commit + push `stepper_data/final_5trials`.
2. Analyzer updates before analysing the 5-trial data:
   - Group R6/R8 by drive mode (current code assumes one mode per folder; mixed Full+Half would be averaged together).
   - ~~R8 pull-out bias~~ done: reports `f_echo` at the stall onset (backtracked from the causal 80 ms detection), verified by `tools/verify_stepper_suite` T6.
   - R6 stall criterion: use speed (< 85 % theory) and end-of-step lost steps ≥ 4; the current peak-lost-steps > 5 rule flags transient start-up lag as a stall (seen at Half 1000 Hz with speed exactly on theory).
   - Raw figures for R6/R8 per mode; LPF columns in R3 summary; per-trial long CSVs for R4_R5 and R8.
3. Write the final report from the 5-trial CSVs/figures into a new `Lab2_2_Stepper_Motor_Report.docx` (keep the draft). Hypothesis 2 (lower accel → higher pull-out) is only partially supported by the data so far — discuss as such.

## Caveats

- 200 full steps/rev (1.8°) assumed — check the motor datasheet (`'StepsPerRev'` option).
- `.slx` files are R2025b exports, tested only in R2026a.
- Current gain 66.3185 counts/A is borrowed from the DC-motor board calibration.
- `tools/build_report_draft.py` regenerates the **draft** report (placeholders); its appendix text still describes the older per-area model, not the current scheduler-based models.
- `tools/make_report_figures.m` is tied to the 3-trial/LPF folders and their pull-out numbers; adapt it for the 5-trial data.
- The saved models carry the previous user's macOS port; regenerated models keep the TA reference port (`COM9`). Always pass `'Port'`.
