# Lab 2.2 Stepper Motor — Handoff

Snapshot of where the work stands, how to run it, and what is left.
Board: NUCLEO-G474RE + DRV8825 + AMT103-V encoder, MotorXplorer firmware (`motorxplorer.bin`).

## Status

| Item | State |
|---|---|
| Per-rubric Simulink models (7 `.slx`, R2025b) | Done, verified in harness (T0a–T6 PASS) |
| Automated runner / analyzer / interactive launcher | Done (`checkcode` clean; per-mode R6/R8, speed+lost-steps R6 stall rule, R3 LPF metrics, per-trial long CSVs) |
| Hardware data, 3 trials (all labs) + LPF/fixed-R8 runs | Collected in `stepper_data/` |
| **Hardware data, 5 trials (all labs, Full+Half for R6/R8)** | **Done** — 86/86 runs collected and analyzed in `stepper_data/final_5trials/` |
| Thai report | **Done** (`Lab2_2_Stepper_Motor_Report.docx` built from 5-trial data via `tools/build_report_final.py`; `Lab2_2_Stepper_Motor_Report_Draft.docx` preserved) |

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
| `Lab2_2_Stepper_Motor_Report.docx` | Final Thai report populated with 5-trial tables, 300-dpi figures, and updated Appendices |
| `Lab2_2_Stepper_Motor_Report_Draft.docx` | Initial Thai draft built from the template |

`tools/` (all paths repo-relative; scratch work goes to `tempdir`):

| Script | Purpose |
|---|---|
| `build_stepper_suite.m` | Regenerates the 7 `.slx` from the TA `MotorXploer.slx` (needs the TA repo cloned into the repo root). `build_stepper_suite()` overwrites the repo models; pass a folder to build elsewhere |
| `verify_stepper_suite.m` | Compile checks on all 7 models (clearing `StopFcn` in memory for zero serial I/O) + harness sims (serial blocks commented out) T0a–T5 + synthetic-data test of the analyzer T6. `verify_stepper_suite(folder)` |
| `make_report_figures.m` | Dynamic 300-dpi report figures (`Fig1`–`Fig6`) + `Raw_vs_LPF_R3_metrics.csv` into `<dataDir>/report_final` (and `stepper_data/report_final`) |
| `build_report_final.py` | Builds the final Thai report `Lab2_2_Stepper_Motor_Report.docx` dynamically from `<dataDir>/tables/*.csv` and `<dataDir>/report_final/*.png` (Python 3, stdlib only) |
| `build_report_draft.py` | Builds the initial Thai draft `.docx` from `Report+Format.docx` (Python 3, stdlib only) |
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

% 5-trial collection (86 runs, ~42 min) — replace the port:
run_stepper_labs({'R0','R3','R4_R5','R6','R8'}, 'Port','COM5', ...
    'Trials',5, 'Modes',1:6, 'R6Mode',[1 2], 'R8Mode',[1 2], ...
    'Accels',[4000 2000 1000 500], 'MaxFreq',8000, 'Cooldown',3, ...
    'OutDir','stepper_data/final_5trials', 'AutoAnalyze',true);

% Regenerate analysis tables, 300-dpi report figures, and final .docx report offline:
analyze_stepper_labs('stepper_data/final_5trials');
run('tools/make_report_figures.m');      % or make_report_figures('stepper_data/final_5trials')
```
```bash
python3 tools/build_report_final.py stepper_data/final_5trials
```

Before powering: `5V_SEL = E5V`, step-down outputs 3.3 V, DRV8825 current limit set, shaft clear. Keep `EN = 1` when idle (driver off, prevents heating); the models default to it and `StopFcn` re-sends it. If the board streams frames but echoes 0 for commands, press Reset (B2). The runner refuses `<auto>` / `debug-console` ports.

## Data collected

| Folder | Content |
|---|---|
| `stepper_data/final_5trials` | **Complete 5-trial suite (86 runs):** R0 (1), R3 (5), R4_R5 across 6 modes (30), R6 Full+Half (10), R8 Full+Half across 4 accels at `MaxFreq = 8000 Hz` (40), plus `tables/`, `figures/`, `figures_raw/`, `raw_csv/`, and `report_final/` |
| `stepper_data/report_final` | 300-dpi report figures (`Fig1`–`Fig6`, `Simulink_MotorXploer_Stepper.png`) + `Raw_vs_LPF_R3_metrics.csv` built from `stepper_data/final_5trials` |
| `stepper_data/20261120_200111` | Initial 3-trial suite: R0, R3, R4_R5 (6 modes), R6 Full, R8 Full (R8 ramped from 0 Hz — see caveat) |
| `stepper_data/hw_lpf_r8_full` | R8 Full, 3 trials, 200 Hz start, raw + live LPF |
| `stepper_data/hw_lpf_r6_r8_half` | R6 + R8 Half, 3 trials, raw + live LPF |
| `stepper_data/hw_lpf_compare` | R3 + R4_R5 (Full, Half), 1 trial, raw + live LPF |

## Findings (5-trial data, `stepper_data/final_5trials`)

- **Speed ∝ frequency / M** holds across all 6 DRV8825 drive modes (`Full`, `Half`, `1/4`, `1/8`, `1/16`, `1/32`) while in sync: at R3 (`f_step = 400 Hz`, `n = 5`), `Full` (`120.00 ± 0.02 RPM`), `Half` (`60.00 ± 0.01 RPM`), `1/4` (`30.00 ± 0.01 RPM`), and `1/8` (`15.00 ± 0.01 RPM`) match theory within `< 0.01 %`. Larger percentage offsets appear only at the lowest speeds (`1/16` → `8.00 RPM` vs `7.50 RPM`; `1/32` → `4.11 RPM` vs `3.75 RPM`) where 1 kHz encoder quantization dominates.
- **Encoder velocity quantization = 7.32 RPM** (`1 count/ms` at `8192 counts/rev`). In R3 (`n = 5`), raw ripple SD is `5.11–16.21 RPM`; the 2nd-order 10 Hz Butterworth LPF cuts ripple SD to `0.19–0.40 RPM` (`92.2–97.9 %` reduction) with mean shift `≤ 0.005 RPM`. Single-sided FFT of Full step @ 400 Hz shows the dominant AC ripple peak at `100.0 Hz = f_step/4` (electrical cycle frequency).
- **Full step mid-band resonance in R4_R5 staircase (`n = 5`):** 2 of 5 Full-step trials lost synchronism at `600 Hz` (`180 RPM`, pulling the 5-trial mean to `129.46 ± 69.21 RPM` at `600 Hz` and `299.92 ± 246.59 RPM` at `1600 Hz`), whereas the other 3/5 Full-step trials and all `5/5` trials in `Half`, `1/4`, `1/8`, `1/16`, and `1/32` tracked cleanly up to `1600 Hz` (`240.00 ± 0.02 RPM` in Half step, including `1200 Hz = 180.00 ± 0.01 RPM`). Confirms full-step mid-band structural resonance rather than a torque–speed ceiling.
- **Pull-in (step from rest, R6, `n = 5`):** Full step `480 ± 110 Hz` (`144.0 RPM`, range `400–600 Hz`) vs Half step `1000 ± 200 Hz` (`150.0 RPM`, range `800–1200 Hz`) — Half step achieves `2.08×` higher pull-in frequency.
- **Pull-out vs acceleration (R8, 200 Hz start, `MaxFreq = 8000 Hz`, `n = 5`):**
  - **Full step (`M = 1`):** `500 Hz/s` → `1003.7 ± 890.7 Hz` (`301.1 RPM`, 4/5 trials trapped near `600–614 Hz` resonance, 1/5 reached `2597 Hz`); `1000 Hz/s` → `2204.6 ± 880.2 Hz` (`661.4 RPM`); `2000 Hz/s` → peak `3444.0 ± 775.1 Hz` (`1033.2 RPM`, `7.18×` above pull-in); `4000 Hz/s` → `2919.2 ± 698.1 Hz` (`875.8 RPM`). Partially supports Hypothesis 2: ramping vastly exceeds step-input pull-in and `4000 Hz/s` drops below `2000 Hz/s` due to inertia torque (`T_accel = J·α`), while slow ramps (`500–1000 Hz/s`) dwell too long in the `~600 Hz` resonance zone.
  - **Half step (`M = 2`):** `15/20` runs reached the `8000 Hz` (`1200.0 RPM`) ceiling without stalling (`5/5` @ `4000 Hz/s` → `≥ 8000.0 Hz`; `3/5` @ `2000 Hz/s` → `≥ 7753.2 ± 349.0 Hz`; `4/5` @ `1000 Hz/s` → `≥ 7757.0 ± 543.4 Hz`; `3/5` @ `500 Hz/s` → `≥ 7913.8 ± 126.0 Hz`), while `5/20` runs stalled near the ceiling (`6785–7847 Hz`), yielding `7.8–8.0×` over Half-step pull-in.
- **R8 from 0 Hz stalls at start for 1/f₁** (f₁ = first command, e.g. 0.5 Hz → 2 s at 500 Hz/s): firmware timer period preload. Fixed by holding 200 Hz for 0.5 s before the ramp.
- **PA1 current sensor does not see stepper current** (`< 0.04 A` change while stepping; R0 zero `2139.37 ± 0.70 counts`, PA0 zero `1218.02 ± 1.50 counts`, `N = 4501`) — it sits on the DC-motor path. `Current_A` values are not stepper phase current.

## Completed Milestones (formerly Pending)

1. **86-run 5-trial hardware collection (`stepper_data/final_5trials`):** Done (`R0`, `R3`, `R4_R5`, `R6` Full+Half, `R8` Full+Half up to `8000 Hz`).
2. **Analyzer & Verifier (`analyze_stepper_labs.m`, `tools/verify_stepper_suite.m`):** Done (per-mode R6/R8 grouping, backtracked R8 stall onset `f_echo`, R6 speed `< 85 %` + end-of-step lost steps `≥ 4` stall rule, R3 LPF summary columns, per-trial long CSVs `R4_R5_trials.csv` / `R6_pullin_trials.csv` / `R8_trials.csv`, and zero-serial-I/O `StopFcn` clearing during offline compile verification).
3. **Final figures & Thai report (`tools/make_report_figures.m`, `tools/build_report_final.py`, `Lab2_2_Stepper_Motor_Report.docx`):** Done (dynamic 5-trial `Fig1`–`Fig6` at 300 dpi, all 10 tables populated from `stepper_data/final_5trials/tables/*.csv`, Hypothesis 2 partial-support discussion, updated Appendices ก and ข, draft `.docx` preserved).

## Caveats

- 200 full steps/rev (1.8°) assumed — check the motor datasheet (`'StepsPerRev'` option).
- `.slx` files are R2025b exports, tested only in R2026a.
- Current gain 66.3185 counts/A is borrowed from the DC-motor board calibration.
- `tools/build_report_draft.py` regenerates the initial **draft** report (`Lab2_2_Stepper_Motor_Report_Draft.docx`); use `tools/build_report_final.py` to build the final data-backed report (`Lab2_2_Stepper_Motor_Report.docx`).
- The saved models carry the previous user's macOS port; regenerated models keep the TA reference port (`COM9`). Always pass `'Port'`.
