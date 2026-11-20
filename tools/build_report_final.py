#!/usr/bin/env python3
"""Build the FINAL Lab 2.2 Stepper Motor Thai report (Lab2_2_Stepper_Motor_Report.docx).

Python 3 standard library only.  Every measured number, table row and figure in the report
is read from the analyzed output of ``analyze_stepper_labs.m`` (``<data-dir>/tables/*.csv``)
and the 300-dpi figures of ``tools/make_report_figures.m`` (``<fig-dir>/*.png`` +
``Raw_vs_LPF_R3_metrics.csv``).  The course template ``Report+Format.docx`` provides the page
setup, header/footer, logo and numbering definitions.  The draft
(``Lab2_2_Stepper_Motor_Report_Draft.docx`` / ``tools/build_report_draft.py``) is never touched.

Usage (from the repo root):
    # 5-trial dataset (default paths)
    python3 tools/build_report_final.py

    # explicit paths
    python3 tools/build_report_final.py --data-dir stepper_data/final_5trials \
        --fig-dir stepper_data/final_5trials/report_final --out /tmp/report.docx

    # existing 3-trial + LPF folders combined (later folders override earlier ones
    # for R6/R8 of the same drive mode; R3/R4_R5 keep the row with the most trials)
    python3 tools/build_report_final.py --legacy --fig-dir stepper_data/report_final \
        --out /tmp/report_legacy.docx

Both the new analyzer schema (Drive_Mode / N_Censored / Ceiling_Hz columns, R8_trials.csv,
R6_pullin_trials.csv ...) and the older 3-trial schema are accepted.  Pull-out runs that reach
the ramp ceiling without stalling are reported as censored (">= ceiling"), never as a stall.
"""
import argparse
import csv
import glob
import json
import math
import os
import re
import shutil
import statistics
import struct
import sys
import tempfile
import zipfile
from xml.etree import ElementTree as ET
from xml.sax.saxutils import escape

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DRAFT_DOCX = os.path.join(REPO, "Lab2_2_Stepper_Motor_Report_Draft.docx")
LEGACY_DIRS = [
    "stepper_data/20261120_200111",   # R0, R3, R4_R5 (3 trials), R6 Full, R8 Full (0 Hz start, superseded)
    "stepper_data/hw_lpf_compare",    # R3 + R4_R5 Full/Half, 1 trial, live LPF
    "stepper_data/hw_lpf_r6_r8_half", # R6 + R8 Half, 3 trials, live LPF
    "stepper_data/hw_lpf_r8_full",    # R8 Full, 3 trials, 200 Hz pre-hold (fixed)
]

FONT = "TH Sarabun New"
PRINTABLE_W = 9746  # A4 (11906) - left(1080) - right(1080) twips
EMU_PER_IN = 914400
ENC_CPR = 8192      # AMT103-V counts/rev (X4) used by the firmware
TS = 0.001          # Simulink fixed step (s)
LPF_B = [0.000944691843840, 0.001889383687680, 0.000944691843840]
LPF_A = [1.0, -1.911197067426073, 0.914975834801434]

MODE_BY_M = {
    1: ("Full (1)", "Full Step"),
    2: ("Half (1/2)", "Half Step"),
    4: ("1/4", "1/4 Microstep"),
    8: ("1/8", "1/8 Microstep"),
    16: ("1/16", "1/16 Microstep"),
    32: ("1/32", "1/32 Microstep"),
}
LABEL_TO_M = {"full (1)": 1, "half (1/2)": 2, "1/4": 4, "1/8": 8, "1/16": 16, "1/32": 32,
              "full": 1, "half": 2}

# Figure slots: glob candidates are tried in order inside every figure directory.
FIG_SLOTS = {
    "freq_speed": ["Fig1_R4_FreqVsSpeed.png", "Fig1*.png", "*R4*Freq*Speed*.png"],
    "r3_lpf": ["Fig2_R3_DriveModes_Raw_vs_LPF.png", "Fig2_R3_DriveModes_Waveforms.png", "Fig2*.png", "*R3*Raw*LPF*.png", "*R3*DriveModes*.png"],
    "fft": ["Fig5_Raw_vs_LPF_FFT.png", "Fig5*.png", "*FFT*.png"],
    "pullin": ["Fig6_R6_PullIn_Full_vs_Half.png", "Fig6*.png", "*R6*PullIn*.png", "*R6*Pull_In*.png"],
    "lossstep": ["Fig3_R6_R8_LossStep_TimeSeries.png", "Fig3_R6_R8_LossStep_TimeSeries*.png", "Fig3*.png", "*LossStep*TimeSeries*.png", "*LossStep*.png"],
    "pullout": ["Fig4_R8_Accel_vs_PullOut.png", "Fig4*.png", "*Accel*PullOut*.png", "*PullOut*.png"],
    "simulink": ["Simulink_MotorXploer_Stepper.png", "Simulink_*.png"],
}
MULTI_SLOTS = set()


# =============================================================================
# Generic helpers
# =============================================================================
def warn(msg):
    print("WARNING:", msg, file=sys.stderr)


def num(v):
    """CSV cell -> float (None for empty / NaN / non-numeric). 'Inf' stays inf."""
    if v is None:
        return None
    s = str(v).strip()
    if not s:
        return None
    if s.lower() in ("true", "false"):
        return 1.0 if s.lower() == "true" else 0.0
    try:
        x = float(s)
    except ValueError:
        return None
    return None if math.isnan(x) else x


def fin(x):
    return x is not None and not math.isnan(x) and not math.isinf(x)


def fmt(x, nd=1, comma=True):
    if x is None or (isinstance(x, float) and math.isnan(x)):
        return "-"
    if math.isinf(x):
        return "∞"
    return f"{x:,.{nd}f}" if comma else f"{x:.{nd}f}"


def fhz(x):
    return fmt(x, 0) if fin(x) and abs(x) >= 100 else fmt(x, 1)


def frpm(x):
    return fmt(x, 2) if fin(x) and abs(x) < 100 else fmt(x, 1)


def ferr(x):
    if not fin(x):
        return "-"
    return "< 0.01" if abs(x) < 0.01 else (fmt(x, 2) if x < 10 else fmt(x, 1))


def mean(xs):
    xs = [x for x in xs if fin(x)]
    return sum(xs) / len(xs) if xs else None


def sd(xs):
    xs = [x for x in xs if fin(x)]
    return statistics.stdev(xs) if len(xs) > 1 else (0.0 if xs else None)


def m_to_drive(m):
    return int(round(math.log2(m))) + 1


def snap_m(x):
    if not fin(x) or x <= 0:
        return None
    m = 2 ** int(round(math.log2(x)))
    return m if m in MODE_BY_M and abs(x / m - 1) < 0.2 else None


def row_m(row, spr):
    """Microstep factor of a CSV row (new schema columns first, then inference)."""
    for key in ("Microstep_M", "M"):
        m = snap_m(num(row.get(key)))
        if m:
            return m
    dm = num(row.get("Drive_Mode"))
    if fin(dm) and 1 <= dm <= 6:
        return 2 ** (int(dm) - 1)
    lab = str(row.get("Mode", "")).strip().lower()
    if lab in LABEL_TO_M:
        return LABEL_TO_M[lab]
    # legacy rows: theory RPM = f * 60 / (M * spr)  ->  M = 60 f / (spr * RPM)
    for fk, rk in (("Freq_Hz", "Theory_RPM"), ("MaxFreq_Mean_Hz", "MaxSpeed_RPM")):
        f, r = num(row.get(fk)), num(row.get(rk))
        if fin(f) and fin(r) and r > 0:
            m = snap_m(60.0 * f / (spr * r))
            if m:
                return m
    return None


def read_csv(path):
    with open(path, newline="", encoding="utf-8-sig") as fh:
        return [dict(r) for r in csv.DictReader(fh)]


def png_size(path):
    with open(path, "rb") as fh:
        head = fh.read(24)
    if head[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError(f"not a PNG file: {path}")
    return struct.unpack(">II", head[16:24])


# =============================================================================
# Data loading
# =============================================================================
TABLE_FILES = [
    "R0_baseline_calibration.csv", "R3_drive_modes_summary.csv", "R4_R5_freq_vs_speed.csv",
    "R4_R5_trials.csv", "R6_pullin_steps.csv", "R6_pullin_trials.csv", "R6_pullin_summary.csv",
    "R8_accel_pullout.csv", "R8_trials.csv",
]


def detect_ceiling(d):
    """Ramp ceiling (MaxFreq) per microstep factor M for one run folder."""
    out = {}
    qj = os.path.join(d, "queue.json")
    if os.path.isfile(qj):
        try:
            with open(qj, encoding="utf-8") as fh:
                q = json.load(fh)
            if isinstance(q, dict):
                q = [q]
            for j in q:
                if str(j.get("lab", "")).upper() == "R8":
                    m = 2 ** (int(j.get("drive_mode", 1)) - 1)
                    out[m] = max(out.get(m, 0.0), float(j.get("max_freq", 0)))
        except (OSError, ValueError, TypeError):
            pass
    if out:
        return out
    for f in sorted(glob.glob(os.path.join(d, "raw_csv", "R8_*.csv"))):
        mm = re.search(r"_M(\d)_", os.path.basename(f))
        if not mm:
            continue
        m = 2 ** (int(mm.group(1)) - 1)
        try:
            with open(f, newline="", encoding="utf-8-sig") as fh:
                rd = csv.reader(fh)
                hdr = next(rd)
                ci = hdr.index("freq_cmd_hz")
                mx = max(float(r[ci]) for r in rd if len(r) > ci and r[ci])
            out[m] = max(out.get(m, 0.0), mx)
        except (OSError, ValueError, StopIteration):
            continue
    return out


class Data:
    def __init__(self, data_dirs, fig_dirs, spr, ceiling_override):
        self.spr = spr
        self.data_dirs = data_dirs
        self.fig_dirs = fig_dirs
        self.raw = {name: [] for name in TABLE_FILES}   # list of (dir, rows)
        self.files_used = []
        for d in data_dirs:
            tdir = os.path.join(d, "tables")
            for name in TABLE_FILES:
                p = os.path.join(tdir, name)
                if os.path.isfile(p):
                    rows = read_csv(p)
                    if rows:
                        self.raw[name].append((d, rows))
                        self.files_used.append(p)
        self.ceiling = {}
        for d in data_dirs:
            self.ceiling[d] = detect_ceiling(d)
        self.ceiling_override = ceiling_override
        self.lpf_metrics = None
        for fd in fig_dirs:
            p = os.path.join(fd, "Raw_vs_LPF_R3_metrics.csv")
            if os.path.isfile(p):
                self.lpf_metrics = read_csv(p)
                self.files_used.append(p)
                break
        self._build()

    # ---- merge helpers -------------------------------------------------------
    def _best_by(self, name, keyfn, scorefn):
        best = {}
        for d, rows in self.raw[name]:
            for r in rows:
                k = keyfn(r)
                if k is None:
                    continue
                s = scorefn(r)
                if k not in best or s > best[k][0]:
                    best[k] = (s, r, d)
        return best

    def _build(self):
        spr = self.spr

        # ---- R0
        self.r0 = None
        if self.raw["R0_baseline_calibration.csv"]:
            self.r0 = self.raw["R0_baseline_calibration.csv"][0][1][0]

        # ---- R3 (keep the summary with most trials, LPF columns preferred)
        def r3score(r):
            return (num(r.get("N_Trials")) or 0, 1 if fin(num(r.get("LPF_Ripple_SD_RPM"))) else 0)
        b = self._best_by("R3_drive_modes_summary.csv", lambda r: row_m(r, spr), r3score)
        self.r3 = {}
        for m, (_, r, d) in b.items():
            self.r3[m] = {
                "theory": num(r.get("Theory_RPM")), "mean": num(r.get("Meas_Mean_RPM")),
                "trial_sd": num(r.get("Trial_SD_RPM")), "ripple": num(r.get("Ripple_SD_RPM")),
                "current": num(r.get("Current_A")), "lpf_mean": num(r.get("LPF_Mean_RPM")),
                "lpf_ripple": num(r.get("LPF_Ripple_SD_RPM")), "red": num(r.get("Ripple_Reduction_Pct")),
                "shift": num(r.get("LPF_Mean_Shift_RPM")), "src_lpf": r.get("LPF_Source", ""),
                "n": num(r.get("N_Trials")), "dir": d,
            }
        # Fill LPF columns from the figure script metrics when the analyzer table lacks them
        if self.lpf_metrics:
            for r in self.lpf_metrics:
                m = row_m(r, spr)
                if not m:
                    continue
                e = self.r3.setdefault(m, {"theory": num(r.get("Theory_RPM")), "mean": None, "trial_sd": None,
                                           "ripple": None, "current": None, "n": None, "dir": ""})
                rm, lm = num(r.get("Raw_Mean_RPM")), num(r.get("LPF_Mean_RPM"))
                if not fin(e.get("lpf_ripple")):
                    e["lpf_ripple"] = num(r.get("LPF_Ripple_SD"))
                    e["lpf_mean"] = lm
                    e["raw_ripple_fig"] = num(r.get("Raw_Ripple_SD"))
                    e["red"] = num(r.get("Noise_Reduction_Pct"))
                    e["shift"] = (lm - rm) if fin(lm) and fin(rm) else None
                    e["src_lpf"] = "figure_metrics"
                if not fin(e.get("ripple")):
                    e["ripple"] = num(r.get("Raw_Ripple_SD"))
        for e in self.r3.values():
            if fin(e.get("ripple")) and fin(e.get("lpf_ripple")) and not fin(e.get("red")):
                e["red"] = 100.0 * (1.0 - e["lpf_ripple"] / e["ripple"])

        # ---- R4/R5 summary (most trials wins, ties keep the first folder)
        def r4key(r):
            m, f = row_m(r, spr), num(r.get("Freq_Hz"))
            return (m, int(round(f))) if m and fin(f) else None
        b = self._best_by("R4_R5_freq_vs_speed.csv", r4key,
                          lambda r: (num(r.get("N_Trials")) or 0, 1 if fin(num(r.get("LPF_Ripple_SD_RPM"))) else 0))
        self.r4 = {}
        for (m, f), (_, r, d) in sorted(b.items()):
            th, me = num(r.get("Theory_RPM")), num(r.get("Meas_Mean_RPM"))
            err = num(r.get("Error_Pct"))
            if not fin(err) and fin(th) and fin(me) and th > 0:
                err = 100.0 * abs(me - th) / th
            self.r4[(m, f)] = {"theory": th, "mean": me, "sd": num(r.get("Meas_SD_RPM")), "err": err,
                               "current": num(r.get("Current_A")), "n": num(r.get("N_Trials")),
                               "ripple": num(r.get("Ripple_SD_RPM")), "lpf_ripple": num(r.get("LPF_Ripple_SD_RPM")),
                               "dir": d, "n_lost": None}
        for d, rows in self.raw["R4_R5_trials.csv"]:
            counts = {}
            for r in rows:
                k = r4key(r)
                th, me = num(r.get("Theory_RPM")), num(r.get("Meas_RPM"))
                if k and k in self.r4 and self.r4[k]["dir"] == d and fin(th) and fin(me):
                    c = counts.setdefault(k, [0, 0])
                    c[0] += 1
                    if me < 0.85 * th:
                        c[1] += 1
            for k, (nt, nl) in counts.items():
                self.r4[k]["n_lost"] = nl
                if not fin(self.r4[k].get("n")):
                    self.r4[k]["n"] = nt
        self.r4_modes = sorted({m for m, _ in self.r4})

        # ---- R6 per mode (later folder wins for the same mode)
        self.r6 = {}
        for d, rows in self.raw["R6_pullin_steps.csv"]:
            by_m = {}
            for r in rows:
                m = row_m(r, spr)
                if m:
                    by_m.setdefault(m, []).append(r)
            for m, rs in by_m.items():
                self.r6[m] = self._r6_from_steps(rs, d)
        for d, rows in self.raw["R6_pullin_trials.csv"]:
            by_m = {}
            for r in rows:
                m = row_m(r, spr)
                if m:
                    by_m.setdefault(m, []).append(r)
            for m, rs in by_m.items():
                e = self.r6.get(m)
                if e is None or e["dir"] != d:
                    e = {"dir": d, "resync": [], "steps": [], "first_stall": []}
                    self.r6[m] = e
                rs.sort(key=lambda r: num(r.get("Trial")) or 0)
                e["trials"] = [num(r.get("PullIn_Hz")) for r in rs]
                e["censored"] = [num(r.get("Stalled_Any")) == 0 for r in rs]
                e["first_stall"] = [num(r.get("First_Stall_Hz")) for r in rs]
                e["max_tested"] = max([num(r.get("Max_Tested_Hz")) or 0 for r in rs] or [0])
        for d, rows in self.raw["R6_pullin_summary.csv"]:
            for r in rows:
                m = row_m(r, spr)
                if m and m in self.r6 and self.r6[m]["dir"] == d:
                    e = self.r6[m]
                    e["mean"] = num(r.get("PullIn_Mean_Hz"))
                    e["sd"] = num(r.get("PullIn_SD_Hz"))
                    e["n_cens"] = int(num(r.get("N_Censored")) or 0)
                    mt = num(r.get("Max_Tested_Hz"))
                    if fin(mt):
                        e["max_tested"] = mt
        for m, e in self.r6.items():
            if not fin(e.get("mean")):
                e["mean"] = mean(e.get("trials", []))
                e["sd"] = sd(e.get("trials", []))
            if "n_cens" not in e:
                e["n_cens"] = sum(1 for c in e.get("censored", []) if c)
            e["rpm"] = e["mean"] * 60.0 / (m * spr) if fin(e.get("mean")) else None

        # ---- R8 per (mode, accel); later folder wins
        self.r8 = {}
        for d, rows in self.raw["R8_accel_pullout.csv"]:
            for r in rows:
                m = row_m(r, spr)
                a = num(r.get("Accel_Hz_s"))
                if not m or a is None:
                    cond = str(r.get("Condition", ""))
                    if "Step" in cond:
                        a = math.inf
                    else:
                        mm = re.match(r"\s*(\d+)", cond)
                        a = float(mm.group(1)) if mm else None
                if not m or a is None:
                    continue
                ceil = num(r.get("Ceiling_Hz"))
                if not fin(ceil):
                    ceil = self.ceiling_override or self.ceiling.get(d, {}).get(m)
                fm = num(r.get("MaxFreq_Mean_Hz"))
                n = int(num(r.get("N_Trials")) or 0)
                ncens = num(r.get("N_Censored"))
                if ncens is None:
                    ncens = n if (fin(ceil) and fin(fm) and not math.isinf(a) and fm >= ceil - max(1.0, 0.002 * ceil)) else 0
                self.r8[(m, a)] = {"mean": fm, "sd": num(r.get("MaxFreq_SD_Hz")), "rpm": num(r.get("MaxSpeed_RPM")),
                                   "n": n, "n_cens": int(ncens), "n_stall": num(r.get("N_Stalled")),
                                   "ceiling": ceil, "dir": d, "trials": None}
        for d, rows in self.raw["R8_trials.csv"]:
            grp = {}
            for r in rows:
                m, a = row_m(r, spr), num(r.get("Accel_Hz_s"))
                if m and fin(a):
                    grp.setdefault((m, a), []).append(r)
            for k, rs in grp.items():
                if k in self.r8 and self.r8[k]["dir"] == d:
                    rs.sort(key=lambda r: num(r.get("Trial")) or 0)
                    self.r8[k]["trials"] = [(num(r.get("PullOut_Freq_Hz")), num(r.get("Reached_Ceiling")) == 1)
                                            for r in rs]
        self.r8_modes = sorted({m for m, _ in self.r8} | set(self.r6))
        self.accels = sorted({a for _, a in self.r8 if fin(a)}, reverse=True)

    def _r6_from_steps(self, rows, d):
        trials = {}
        for r in rows:
            trials.setdefault(int(num(r.get("Trial")) or 1), []).append(r)
        new_schema = any("End_Lost_Steps" in r for r in rows)
        out = {"dir": d, "trials": [], "censored": [], "first_stall": [], "resync": [], "steps": rows,
               "max_tested": 0.0, "new_schema": new_schema}
        for t in sorted(trials):
            rs = sorted(trials[t], key=lambda r: num(r.get("Step_ID")) or 0)
            last_ok, first_bad, seen_bad = 0.0, None, False
            for r in rs:
                f, th, me = num(r.get("Freq_Hz")), num(r.get("Theory_RPM")), num(r.get("Meas_RPM"))
                out["max_tested"] = max(out["max_tested"], f or 0)
                if new_schema and num(r.get("Stalled")) is not None:
                    st = num(r.get("Stalled")) == 1
                else:  # legacy table: speed criterion only (end-of-step lost steps unavailable)
                    st = fin(me) and fin(th) and me < 0.85 * th
                if st and first_bad is None:
                    first_bad = f
                elif not st and first_bad is None:
                    last_ok = f
                elif not st and first_bad is not None and not seen_bad:
                    out["resync"].append((t, f))
                    seen_bad = True
            out["trials"].append(last_ok)
            out["censored"].append(first_bad is None)
            out["first_stall"].append(first_bad)
        return out

    # ---- figures -------------------------------------------------------------
    def find_fig(self, slot, extra_dirs=()):
        dirs = list(self.fig_dirs) + list(extra_dirs)
        found = []
        for pat in FIG_SLOTS[slot]:
            for d in dirs:
                hits = sorted(glob.glob(os.path.join(d, pat)))
                if hits:
                    if slot in MULTI_SLOTS:
                        found.extend(h for h in hits if h not in found)
                    else:
                        return [hits[0]]
            if found and slot in MULTI_SLOTS:
                return found
        return found


# =============================================================================
# WordprocessingML builders (same formatting as tools/build_report_draft.py)
# =============================================================================
def rpr(sz=32, bold=False, italic=False, color=None, font=FONT):
    parts = [f'<w:rFonts w:ascii="{font}" w:eastAsia="{font}" w:hAnsi="{font}" w:cs="{font}"/>']
    if bold:
        parts.append("<w:b/><w:bCs/>")
    if italic:
        parts.append("<w:i/><w:iCs/>")
    if color:
        parts.append(f'<w:color w:val="{color}"/>')
    parts.append(f'<w:sz w:val="{sz}"/><w:szCs w:val="{sz}"/>')
    return "<w:rPr>" + "".join(parts) + "</w:rPr>"


def run(text, sz=32, bold=False, italic=False, color=None):
    return f'<w:r>{rpr(sz, bold, italic, color)}<w:t xml:space="preserve">{escape(text)}</w:t></w:r>'


def p(runs_xml, before=0, after=0, jc="thaiDistribute", first_line=0, left=0, num_id=None,
      style=None, keep_next=False, tabs_xml="", page_break_before=False):
    ppr = []
    if style:
        ppr.append(f'<w:pStyle w:val="{style}"/>')
    if keep_next:
        ppr.append("<w:keepNext/>")
    if page_break_before:
        ppr.append("<w:pageBreakBefore/>")
    if num_id is not None:
        ppr.append(f'<w:numPr><w:ilvl w:val="0"/><w:numId w:val="{num_id}"/></w:numPr>')
    if tabs_xml:
        ppr.append(f"<w:tabs>{tabs_xml}</w:tabs>")
    ppr.append(f'<w:spacing w:before="{before}" w:after="{after}" w:line="240" w:lineRule="auto"/>')
    if first_line or left:
        attrs = []
        if left:
            attrs.append(f'w:left="{left}"')
        if first_line:
            attrs.append(f'w:firstLine="{first_line}"')
        ppr.append(f'<w:ind {" ".join(attrs)}/>')
    if jc:
        ppr.append(f'<w:jc w:val="{jc}"/>')
    return f"<w:p><w:pPr>{''.join(ppr)}</w:pPr>{runs_xml}</w:p>"


def h_lab(text, page_break=False):
    return p(run(text, sz=36, bold=True), after=120, jc="center", keep_next=True, page_break_before=page_break)


def h_exp(text, page_break=False):
    return p(run(text, sz=32, bold=True), before=240, keep_next=True, page_break_before=page_break)


def h_sec(text):
    return p(run(text, sz=32, bold=True), before=240, keep_next=True)


def h_sub(text):
    return p(run(text, sz=32, bold=True), before=120, keep_next=True)


def body(text, first=False):
    return p(run(text), before=0 if first else 240, first_line=720)


def bullet(text, num_id=1, left=360, bold_prefix=None):
    rx = (run(bold_prefix, bold=True) if bold_prefix else "") + run(text)
    return p(rx, num_id=num_id, left=left)


def var_head(text, num_id):
    return p(run(text, bold=True), style="ListParagraph", num_id=num_id)


def var_item(text):
    return p(run(text), style="ListParagraph", num_id=49)


def blank(after=60):
    return p("", after=after, jc="left")


def caption_xml(label, text, before=60, after=120):
    return p(run(label + " ", sz=28, bold=True) + run(text, sz=28), before=before, after=after, jc="center")


# ---- OMML equations (12 pt) ----
def mr(text, roman=False):
    rp = f'<w:rPr><w:rFonts w:ascii="Cambria Math" w:hAnsi="Cambria Math" w:cs="{FONT}"/><w:sz w:val="24"/><w:szCs w:val="24"/></w:rPr>'
    mpr = "<m:rPr><m:nor/></m:rPr>" if roman else ""
    return f"<m:r>{mpr}{rp}<m:t>{escape(text)}</m:t></m:r>"


def msub(b, s):
    return f"<m:sSub><m:e>{b}</m:e><m:sub>{s}</m:sub></m:sSub>"


def mfrac(n, d):
    return f"<m:f><m:num>{n}</m:num><m:den>{d}</m:den></m:f>"


def mdel(inner, beg="(", end=")"):
    return f'<m:d><m:dPr><m:begChr m:val="{escape(beg)}"/><m:endChr m:val="{escape(end)}"/></m:dPr><m:e>{inner}</m:e></m:d>'


def mnary(chr_val, sub, sup, expr):
    return (f'<m:nary><m:naryPr><m:chr m:val="{chr_val}"/><m:limLoc m:val="subSup"/></m:naryPr>'
            f"<m:sub>{sub}</m:sub><m:sup>{sup}</m:sup><m:e>{expr}</m:e></m:nary>")


def msup(b, s):
    return f"<m:sSup><m:e>{b}</m:e><m:sup>{s}</m:sup></m:sSup>"


def S(base, sub):
    return msub(mr(base), mr(sub, roman=True))


# ---- tables ----
def make_table(headers, rows, widths, aligns=None, sz=28):
    widths = list(widths)
    total = sum(widths)
    if total != PRINTABLE_W:  # normalise to the printable width
        widths = [int(round(w * PRINTABLE_W / total)) for w in widths]
        widths[-1] += PRINTABLE_W - sum(widths)
    aligns = aligns or ["center"] * len(headers)
    grid = "".join(f'<w:gridCol w:w="{w}"/>' for w in widths)
    tbl_pr = ('<w:tblPr><w:tblStyle w:val="TableGrid"/>'
              f'<w:tblW w:w="{sum(widths)}" w:type="dxa"/><w:jc w:val="center"/>'
              '<w:tblCellMar><w:top w:w="60" w:type="dxa"/><w:bottom w:w="60" w:type="dxa"/>'
              '<w:left w:w="100" w:type="dxa"/><w:right w:w="100" w:type="dxa"/></w:tblCellMar></w:tblPr>')

    def cell(text, w, al, bold=False, shade=None):
        shd = f'<w:shd w:val="clear" w:color="auto" w:fill="{shade}"/>' if shade else ""
        ps = "".join(p(run(ln, sz=sz, bold=bold), jc=al) for ln in str(text).split("\n"))
        return f'<w:tc><w:tcPr><w:tcW w:w="{w}" w:type="dxa"/>{shd}<w:vAlign w:val="center"/></w:tcPr>{ps}</w:tc>'

    hdr = "".join(cell(h, w, "center", True, "E8EEF5") for h, w in zip(headers, widths))
    trs = [f"<w:tr><w:trPr><w:tblHeader/><w:cantSplit/></w:trPr>{hdr}</w:tr>"]
    for r in rows:
        trs.append("<w:tr><w:trPr><w:cantSplit/></w:trPr>" +
                   "".join(cell(v, w, a) for v, w, a in zip(r, widths, aligns)) + "</w:tr>")
    return f"<w:tbl>{tbl_pr}<w:tblGrid>{grid}</w:tblGrid>{''.join(trs)}</w:tbl>"


def image_xml(rid, cx, cy, docpr_id, name):
    return (
        '<w:p><w:pPr><w:keepNext/><w:spacing w:before="120" w:after="60" w:line="240" w:lineRule="auto"/>'
        '<w:jc w:val="center"/></w:pPr><w:r><w:rPr><w:noProof/></w:rPr><w:drawing>'
        f'<wp:inline distT="0" distB="0" distL="0" distR="0"><wp:extent cx="{cx}" cy="{cy}"/>'
        f'<wp:effectExtent l="0" t="0" r="0" b="0"/><wp:docPr id="{docpr_id}" name="{escape(name)}"/>'
        '<wp:cNvGraphicFramePr><a:graphicFrameLocks xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" noChangeAspect="1"/></wp:cNvGraphicFramePr>'
        '<a:graphic xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">'
        '<a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">'
        '<pic:pic xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">'
        f'<pic:nvPicPr><pic:cNvPr id="{docpr_id}" name="{escape(name)}"/><pic:cNvPicPr><a:picLocks noChangeAspect="1"/></pic:cNvPicPr></pic:nvPicPr>'
        f'<pic:blipFill><a:blip r:embed="{rid}"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>'
        f'<pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="{cx}" cy="{cy}"/></a:xfrm>'
        '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr></pic:pic></a:graphicData></a:graphic>'
        '</wp:inline></w:drawing></w:r></w:p>'
    )


class Doc:
    """Collects body XML, numbers tables/figures and registers embedded images."""

    def __init__(self, strict):
        self.el = []
        self.tab_n = 0
        self.fig_n = 0
        self.images = []  # (rid, src_path, media_name)
        self.strict = strict
        self.missing = []

    def add(self, xml):
        self.el.append(xml)

    def table(self, title, headers, rows, widths, aligns=None, label=None, sz=28):
        if label is None:
            self.tab_n += 1
            label = f"ตารางที่ {self.tab_n}"
        self.add(caption_xml(label, title, before=120, after=60))
        self.add(make_table(headers, rows, widths, aligns, sz))
        self.add(blank())
        return label

    def figure(self, path, title, label=None, max_w_in=6.5, max_h_in=8.3):
        if not path or not os.path.isfile(path):
            self.missing.append(title)
            return None
        w, h = png_size(path)
        cx = int(max_w_in * EMU_PER_IN)
        cy = int(round(cx * h / w))
        if cy > max_h_in * EMU_PER_IN:
            cy = int(max_h_in * EMU_PER_IN)
            cx = int(round(cy * w / h))
        idx = len(self.images) + 1
        rid = f"rIdFig{idx}"
        media = f"final_fig{idx}.png"
        self.images.append((rid, path, media))
        if label is None:
            self.fig_n += 1
            label = f"ภาพที่ {self.fig_n}"
        self.add(image_xml(rid, cx, cy, 300 + idx, os.path.basename(path)))
        self.add(caption_xml(label, title))
        return label

    def xml(self):
        return "".join(self.el)


def eq_xml(omath, n):
    tabs = f'<w:tab w:val="center" w:pos="{PRINTABLE_W // 2}"/><w:tab w:val="right" w:pos="{PRINTABLE_W}"/>'
    tab_r = f"<w:r>{rpr(sz=24)}<w:tab/></w:r>"
    return p(f"{tab_r}<m:oMath>{omath}</m:oMath>{tab_r}{run(f'({n})', sz=24)}",
             before=120, after=120, jc="left", tabs_xml=tabs)


# =============================================================================
# Analysis helpers used by the prose
# =============================================================================
def mode_short(m):
    return MODE_BY_M[m][0]


def mode_long(m):
    return MODE_BY_M[m][1]


def r8_cell(e):
    """Display text for a pull-out summary entry (handles censored ceilings)."""
    if e is None or not fin(e.get("mean")):
        return "-"
    n, nc = e.get("n") or 0, e.get("n_cens") or 0
    if nc and n and nc >= n and fin(e.get("ceiling")):
        return f"≥ {fhz(e['ceiling'])}"
    s = f"{fhz(e['mean'])} ± {fhz(e['sd'] or 0.0)}"
    if nc:
        s = "≥ " + s
    return s


def is_censored_all(e):
    return e is not None and (e.get("n") or 0) > 0 and (e.get("n_cens") or 0) >= (e.get("n") or 0)


def is_r4_lost(e):
    me, th = e.get("mean"), e.get("theory")
    return fin(me) and fin(th) and th > 0 and me < 0.85 * th


def r4_status(e):
    err, esd = e.get("err"), e.get("sd")
    if not fin(err):
        return "-"
    if is_r4_lost(e):
        nl, nt = e.get("n_lost"), e.get("n")
        if nl is not None and nt and 0 < nl < int(nt):
            return f"หลุดก้าวบางรอบ ({nl}/{int(nt)})"
        return "หลุดก้าวบางรอบ" if fin(esd) and esd > 30 else "หลุดก้าว"
    if err > 1:
        return "ซิงก์ (คลาดเคลื่อนช่วงความเร็วต่ำ/การแกว่ง |ω|)"
    return "ซิงก์ตามทฤษฎี"


def lost_freqs(data, m):
    return [f for (mm, f), e in sorted(data.r4.items()) if mm == m and is_r4_lost(e)]


def h2_mode(data, m):
    """Hypothesis-2 analysis for one drive mode. Returns dict or None."""
    rows = [(a, data.r8[(m, a)]) for a in sorted(data.accels) if (m, a) in data.r8 and fin(data.r8[(m, a)]["mean"])]
    if len(rows) < 2:
        return None
    total_n = sum(int(e.get("n") or 0) for _, e in rows)
    total_cens = sum(int(e.get("n_cens") or 0) for _, e in rows)
    res = {"rows": rows, "all_cens": all(is_censored_all(e) for _, e in rows),
           "total_n": total_n, "total_cens": total_cens}
    step = data.r6.get(m, {}).get("mean")
    if not fin(step):
        e = data.r8.get((m, math.inf))
        step = e["mean"] if e else None
    res["step"] = step
    res["ramp_beats_step"] = fin(step) and all(e["mean"] > step for _, e in rows)
    if res["all_cens"]:
        res["verdict"] = "censored"
        return res
    supports, violations = [], []
    for (a1, e1), (a2, e2) in zip(rows, rows[1:]):  # a1 < a2
        tol = max(e1.get("sd") or 0.0, e2.get("sd") or 0.0, 0.05 * max(e1["mean"], e2["mean"]))
        if e1["mean"] > e2["mean"] + tol or (is_censored_all(e1) and not is_censored_all(e2)):
            supports.append((a1, a2))
        elif e2["mean"] > e1["mean"] + tol and not is_censored_all(e1):
            violations.append((a1, a2))
    best_a, best_e = max(rows, key=lambda t: (is_censored_all(t[1]), t[1]["mean"]))
    res.update(supports=supports, violations=violations, best_a=best_a, best_e=best_e,
               low_a=rows[0][0], low_e=rows[0][1], high_a=rows[-1][0], high_e=rows[-1][1])
    is_interior_peak = (rows[0][0] < best_a < rows[-1][0]
                        and best_e["mean"] > rows[0][1]["mean"]
                        and best_e["mean"] > rows[-1][1]["mean"])
    if (supports and violations) or is_interior_peak:
        res["verdict"] = "partial"
    elif violations:
        res["verdict"] = "contradicted"
    elif supports:
        res["verdict"] = "supported"
    else:
        res["verdict"] = "flat"
    return res


def alpha(m, spr, a):
    return 2 * math.pi / (m * spr) * a


# =============================================================================
# Report content
# =============================================================================
def build_body(doc, data, cover_p0, authors, args):
    spr = data.spr
    q_rpm = 60.0 / (ENC_CPR * TS)
    n_trials_r4 = int(max([e["n"] or 0 for e in data.r4.values()] or [0]))
    n_trials_r3 = int(max([e.get("n") or 0 for e in data.r3.values()] or [0]))
    n_trials_r6 = max([len(e.get("trials", [])) for e in data.r6.values()] or [0])
    n_trials_r8 = max([e["n"] or 0 for e in data.r8.values()] or [0])
    n_trials_txt = lambda n: f"{n} ครั้ง" if n else "หลายครั้ง"
    r4_freqs = sorted({f for _, f in data.r4})
    r3_f = None
    if 1 in data.r3 and fin(data.r3[1].get("theory")):
        r3_f = data.r3[1]["theory"] * spr / 60.0

    # ===================== COVER =====================
    doc.add(cover_p0)
    doc.add(blank(0))
    doc.add(p(run("LAB 2: Actuators (Lab 2.2: Stepper Motor)", bold=True), jc="left"))
    doc.add(p(run("Name", bold=True), before=240, jc="left"))
    for a in authors:
        doc.add(p(run(a), jc="left", num_id=1, tabs_xml='<w:tab w:val="left" w:pos="2268"/>'))
    doc.add(p(run("Objectives", bold=True), before=240, jc="left"))
    for o in [
        "เพื่อศึกษาหลักการทำงาน โครงสร้าง ชนิดของโรเตอร์ และโหมดการขับเคลื่อนของ Stepper Motor ร่วมกับไดรเวอร์ DRV8825",
        "เพื่อวิเคราะห์ความสัมพันธ์ระหว่างความถี่สัญญาณขับ (STEP Frequency) กับความเร็วรอบของมอเตอร์ในแต่ละโหมดการขับเคลื่อน",
        "เพื่อศึกษาปรากฏการณ์ Loss Step เงื่อนไขที่ก่อให้เกิดการสูญเสียก้าว และผลของความเร่ง (Acceleration) ต่อความถี่สูงสุดก่อนเกิด Loss Step",
        "เพื่อเปรียบเทียบข้อดี ข้อเสีย และความเหมาะสมของการเลือกใช้โหมดการขับเคลื่อนแต่ละแบบในงานจริง",
        "เพื่อประยุกต์ใช้ MATLAB และ Simulink ในการส่งคำสั่ง ควบคุมโหมด บันทึกข้อมูล และตรวจสอบความสอดคล้องระหว่างผลวัดจริงกับทฤษฎี",
    ]:
        doc.add(p(run(o), num_id=1))

    doc.add(h_lab("2. Lab 2.2: Stepper Motor", page_break=True))

    # =========================================================================
    # EXPERIMENT 1
    # =========================================================================
    doc.add(h_exp("การทดลองที่ 1 การศึกษาโหมดการขับเคลื่อนและความสัมพันธ์ระหว่างความถี่สัญญาณขับกับความเร็วรอบของ Stepper Motor"))
    doc.add(h_sec("จุดประสงค์"))
    for t in [
        "เพื่อสังเกตการทำงานจริงและเปรียบเทียบลักษณะการเคลื่อนที่ของ Stepper Motor ในแต่ละโหมดที่ไดรเวอร์ DRV8825 รองรับ ได้แก่ Full Step, Half Step และ Microstep (1/4, 1/8, 1/16, 1/32)",
        "เพื่อวัดและวิเคราะห์ความสัมพันธ์ระหว่างความถี่ของสัญญาณพัลส์ขับ (STEP Frequency) กับความเร็วรอบของมอเตอร์ในแต่ละโหมดการขับเคลื่อน",
        "เพื่อตรวจสอบความสอดคล้องระหว่างความเร็วรอบที่วัดได้จาก Incremental Encoder (AMT103-V) กับความเร็วรอบตามสมการทฤษฎี รวมถึงประเมินความซ้ำได้ของการวัดและผลของตัวกรองความถี่ต่ำต่อสัญญาณความเร็ว",
    ]:
        doc.add(bullet(t, num_id=52))

    doc.add(h_sec("สมมติฐาน"))
    doc.add(body("เมื่อมอเตอร์หมุนโดยยังไม่เกิดการสูญเสียก้าว (Loss Step) ความเร็วรอบของ Stepper Motor จะแปรผันตรงกับความถี่ของสัญญาณ STEP ที่ป้อนให้ไดรเวอร์ และแปรผกผันกับตัวคูณไมโครสเต็ป (Microstep Factor, M) ของโหมดที่เลือกใช้งาน หากคงความถี่สัญญาณ STEP ไว้เท่าเดิม การเปลี่ยนจากโหมด Full Step ไปเป็น Half Step หรือ Microstep ที่ละเอียดขึ้นจะทำให้มุมหมุนต่อหนึ่งพัลส์เล็กลง ความเร็วรอบจึงลดลงตามสัดส่วน 1/M ในขณะเดียวกันการเคลื่อนที่จะนุ่มนวลและสั่นสะเทือนน้อยลง", True))

    doc.add(h_sec("ตัวแปร"))
    doc.add(var_head("ตัวแปรต้น:", 56))
    doc.add(var_item("โหมดการขับเคลื่อนของไดรเวอร์ DRV8825 กำหนดผ่านขา M0, M1, M2 จำนวน 6 โหมด ได้แก่ Full Step (1), Half Step (1/2), 1/4, 1/8, 1/16 และ 1/32"))
    if r4_freqs:
        doc.add(var_item(f"ความถี่สัญญาณขับ STEP ในช่วง {fhz(r4_freqs[0])} ถึง {fhz(r4_freqs[-1])} Hz ({len(r4_freqs)} ระดับ ค้างระดับละ 4 วินาที) โดยเปลี่ยนระดับผ่านอัตราเร่งจำกัด 2,000 Hz/s"))
    doc.add(var_head("ตัวแปรตาม:", 56))
    doc.add(var_item("ความเร็วรอบที่วัดได้จาก Encoder ทั้งสัญญาณดิบ (rpm_meas) และสัญญาณหลังกรองความถี่ต่ำ 10 Hz (rpm_meas_lpf) หน่วย RPM"))
    doc.add(var_item("ร้อยละความคลาดเคลื่อนเทียบความเร็วรอบทฤษฎี ส่วนเบี่ยงเบนมาตรฐานระหว่างการทดลองซ้ำ และขนาดการกระเพื่อมของความเร็ว (Ripple SD)"))
    doc.add(var_head("ตัวแปรควบคุม:", 56))
    doc.add(var_item("ชุดมอเตอร์และบอร์ดทดลอง MotorXplorer เดิม แรงดันแหล่งจ่าย 24 V และค่าจำกัดกระแส (Current Limit) ของ DRV8825 คงที่ตลอดการทดลอง"))
    doc.add(var_item(f"สภาวะโหลดเปล่า ทิศทางการหมุน DIR = 0 จำนวนก้าวเต็มต่อรอบ {spr} ก้าว และคาบการทำงานของ Simulink แบบ Fixed-step 0.001 s"))

    # ---- Literature
    doc.add(h_sec("เอกสารและงานวิจัยที่เกี่ยวข้อง"))
    doc.add(h_sub("1. หลักการทำงานและประเภทของ Stepper Motor"))
    doc.add(body("Stepper Motor เป็นมอเตอร์ไฟฟ้ากระแสตรงแบบไร้แปรงถ่านที่แบ่งการหมุนหนึ่งรอบเต็มออกเป็นขั้นมุมย่อยเท่าๆ กัน เรียกว่ามุมก้าว (Step Angle) โครงสร้างหลักประกอบด้วยสเตเตอร์ (Stator) ที่มีชุดขดลวดแม่เหล็กไฟฟ้าวางเรียงเป็นเฟส และโรเตอร์ (Rotor) ที่หมุนตามแนวแรงแม่เหล็ก เมื่อจ่ายกระแสให้ขดลวดสเตเตอร์ตามลำดับเวลา ขั้วแม่เหล็กของโรเตอร์จะจัดแนวเข้าหาขั้วสเตเตอร์ที่กำลังมีกระแสไหล ส่งผลให้เพลาหมุนไปทีละก้าวตามจำนวนพัลส์ที่ป้อนเข้าโดยไม่จำเป็นต้องใช้วงจรป้อนกลับตำแหน่งในสภาวะที่โหลดไม่เกินพิกัด", True))
    doc.add(body("ในเชิงโครงสร้างของโรเตอร์ Stepper Motor แบ่งออกเป็น 3 ชนิดหลัก ชนิดแรกคือ Variable Reluctance (VR) โรเตอร์เป็นเหล็กอ่อนที่มีซี่ฟันโดยไม่มีแม่เหล็กถาวร อาศัยหลักการลดความต้านทานแม่เหล็กจึงไม่มี Detent Torque ชนิดที่สองคือ Permanent Magnet (PM) โรเตอร์เป็นแม่เหล็กถาวรสลับขั้วเหนือ-ใต้ ให้แรงบิดค่อนข้างสูงที่ความเร็วต่ำแต่มุมก้าวค่อนข้างกว้างราว 7.5 ถึง 15 องศา ชนิดที่สามคือ Hybrid Stepper Motor ซึ่งรวมข้อดีของทั้งสองแบบ โรเตอร์มีแกนแม่เหล็กถาวรประกบด้วยฝาครอบเหล็กอ่อนที่มีซี่ฟันละเอียด ทำให้ได้มุมก้าวเล็กมาตรฐานที่ 1.8 องศาต่อก้าว (200 ก้าวเต็มต่อรอบ) และให้แรงบิดยึดสูง มอเตอร์บนบอร์ด MotorXplorer เป็นชนิด Hybrid 2 เฟสแบบ Bipolar (สาย 4 เส้น แยกเป็นเฟส A และเฟส B) ในรายงานนี้ใช้ค่า " + f"{spr} ก้าวเต็มต่อรอบ ({360.0 / spr:.2f} องศาต่อก้าว) ในการคำนวณทั้งหมด ซึ่งเป็นค่ามาตรฐานของมอเตอร์ Hybrid ขนาดนี้ และสอดคล้องกับผลวัดที่ความเร็วจริงตรงกับค่าทฤษฎีในทุกโหมดขณะไม่หลุดก้าว"))
    doc.add(body("หากจำแนกตามลักษณะการพันขดลวดและวงจรขับ Stepper Motor แบ่งเป็นแบบ Unipolar ที่มีจุดต่อกึ่งกลาง (Center Tap) ทำให้จ่ายกระแสทิศทางเดียวผ่านสวิตช์อย่างง่ายได้แต่ใช้ขดลวดเพียงครึ่งหนึ่งต่อขณะ และแบบ Bipolar ที่ไม่มีจุดต่อกึ่งกลาง ต้องขับผ่านวงจร H-Bridge เพื่อกลับทิศกระแสในแต่ละเฟส ข้อได้เปรียบของแบบ Bipolar คือใช้ขดลวดเต็มทั้งเฟสจึงให้แรงบิดสูงกว่าในขนาดตัวถังเท่ากัน ส่วนพารามิเตอร์แรงบิดสถิตสำคัญมีสองค่าคือ Holding Torque แรงบิดสูงสุดที่โรเตอร์ต้านแรงภายนอกได้ขณะจ่ายกระแสพิกัดค้างไว้ และ Detent Torque แรงบิดต้านการหมุนขณะไม่จ่ายไฟซึ่งเกิดจากแรงดึงดูดระหว่างแม่เหล็กถาวรของโรเตอร์กับฟันเหล็กสเตเตอร์"))
    doc.add(eq_xml(S("N", "full") + mr("=") + mfrac(mr("360°", True), S("θ", "step")), 1))
    doc.add(body(f"โดย N_full คือจำนวนก้าวเต็มต่อรอบ และ θ_step คือมุมก้าวเต็มของมอเตอร์ (องศา) สำหรับมอเตอร์มุมก้าว {360.0 / spr:.2f} องศา จะได้ N_full = {spr} ก้าวต่อรอบ", True))

    doc.add(h_sub("2. หลักการขับเคลื่อนในแต่ละโหมด (Drive Modes) และตารางความจริงของ DRV8825"))
    doc.add(body("รูปแบบการจ่ายกระแสเข้าขดลวดเฟส A และเฟส B กำหนดความละเอียดของมุมหมุน แรงบิด และความนุ่มนวลของการเคลื่อนที่ โหมดมาตรฐานของ Stepper Motor มี 4 รูปแบบ ได้แก่ Wave Drive (One-Phase On) จ่ายกระแสทีละเฟสเดียวสลับไปมา (A+ → B+ → A- → B-) ใช้พลังงานต่ำแต่ได้แรงบิดราวร้อยละ 70 ของโหมด Full Step โหมด Full Step (Two-Phase On) จ่ายกระแสพร้อมกันทั้งสองเฟสทุกจังหวะ โรเตอร์จึงจัดแนวอยู่กึ่งกลางระหว่างขั้วทั้งสองและให้ Holding Torque สูงสุด โหมด Half Step สลับระหว่างการจ่าย 1 เฟสกับ 2 เฟส (8 จังหวะต่อรอบไฟฟ้า) ทำให้ความละเอียดเพิ่มเป็น 2 เท่า แต่แรงบิดในจังหวะ 1 เฟสต่ำกว่าจังหวะ 2 เฟสราวร้อยละ 29 และโหมด Microstepping ใช้การควบคุมกระแสแบบ PWM ในสัดส่วนไซน์และโคไซน์ (I_A = I_max cos φ, I_B = I_max sin φ) เพื่อแบ่งหนึ่งก้าวเต็มออกเป็นก้าวย่อย 1/4, 1/8, 1/16 จนถึง 1/32 ทำให้การเคลื่อนที่ต่อเนื่องและลดการสั่นสะเทือนช่วงเรโซแนนซ์ได้อย่างชัดเจน", True))
    doc.add(body("ชิปขับ DRV8825 ควบคุมด้วยสัญญาณ STEP, DIR, EN และขากำหนดโหมด M0, M1, M2 โดยรองรับตั้งแต่ Full Step (Two-Phase On) ไปจนถึง 1/32 Microstep ตามตารางที่ 1 ทั้งนี้ DRV8825 ไม่รองรับโหมด Wave Drive เนื่องจากวงจร Indexer ภายในจ่ายกระแสแบบสองเฟสพร้อมกันตั้งแต่โหมดเริ่มต้น (M2 M1 M0 = 000)"))
    t1_rows = [["Wave Drive (1-Phase On)", "-", "-", "-", "1", fmt(spr, 0), f"{360.0 / spr:.4f}", "ไม่รองรับ"]]
    for m, (m2, m1, m0) in zip([1, 2, 4, 8, 16, 32], ["000", "001", "010", "011", "100", "101"]):
        t1_rows.append([mode_long(m) if m > 2 else f"{mode_long(m)} ({'2-Phase On' if m == 1 else '1/2'})",
                        m2, m1, m0, str(m), fmt(m * spr, 0), f"{360.0 / (m * spr):.5g}",
                        "รองรับ (110, 111 = 1/32)" if m == 32 else "รองรับ"])
    doc.table(f"เปรียบเทียบโหมดการขับเคลื่อนและการกำหนดขา M0, M1, M2 ของไดรเวอร์ DRV8825 (กรณีมอเตอร์ {spr} ก้าว/รอบ)",
              ["โหมดการขับเคลื่อน", "M2", "M1", "M0", "ตัวคูณไมโครสเต็ป (M)", "พัลส์ต่อรอบ", "มุมต่อพัลส์ (°)", "การรองรับบน DRV8825"],
              t1_rows, [1950, 620, 620, 620, 1280, 1360, 1250, 2046],
              ["left"] + ["center"] * 7)

    doc.add(h_sub("3. ความสัมพันธ์ระหว่างความถี่สัญญาณขับกับความเร็วรอบ"))
    doc.add(body("ทุกขอบขาขึ้นของสัญญาณ STEP หนึ่งพัลส์ทำให้สนามแม่เหล็กสเตเตอร์เลื่อนไปข้างหน้าหนึ่งก้าวย่อยเป็นมุม θ_pulse = θ_step / M ดังนั้นจำนวนพัลส์ที่ต้องใช้ในการหมุนครบหนึ่งรอบคือ N_pulse = M · N_full เมื่อป้อนพัลส์ต่อเนื่องด้วยความถี่ f_step และโรเตอร์หมุนตามสนามแม่เหล็กได้โดยไม่หลุดซิงโครไนซ์ ความเร็วรอบตามทฤษฎีคำนวณได้จากสมการที่ (2) และ (3) ส่วนความเร็วรอบจริงคำนวณจากความเร็วเชิงมุมที่บอร์ดวัดจาก Encoder ตามสมการที่ (4)", True))
    doc.add(eq_xml(S("N", "pulse") + mr("=") + mr("M") + mr("⋅") + S("N", "full") + mr(",   ", True) + S("θ", "pulse") + mr("=") + mfrac(S("θ", "step"), mr("M")), 2))
    doc.add(eq_xml(S("ω", "theory") + mr("=") + mfrac(S("f", "step") + mr("×") + mr("60", True), mr("M") + mr("⋅") + S("N", "full")) + mr("  (RPM)", True), 3))
    doc.add(eq_xml(S("ω", "meas") + mr("=") + mfrac(mdel(S("ω", "enc"), "|", "|") + mr("×") + mr("60", True), mr("2π", True)) + mr("  (RPM)", True), 4))
    doc.add(body("สมการที่ (3) อธิบายว่าเหตุใดความเร็วรอบจึงเปลี่ยนตามความถี่ของสัญญาณขับ ความถี่ f_step คืออัตราการสับเปลี่ยนสถานะสนามแม่เหล็กสเตเตอร์ต่อวินาที โรเตอร์ซึ่งยึดแนวตามแรงแม่เหล็กจะก้าวตามทุกพัลส์ เมื่อความถี่เพิ่มขึ้นสองเท่า เวลาต่อหนึ่งก้าวลดลงครึ่งหนึ่ง ความเร็วรอบจึงเพิ่มขึ้นสองเท่า ในทางกลับกันเมื่อเพิ่มตัวคูณ M เป็นสองเท่า มุมต่อพัลส์ลดลงครึ่งหนึ่ง ความเร็วรอบที่ความถี่เดียวกันจึงลดลงครึ่งหนึ่ง", True))

    doc.add(h_sub("4. ความละเอียดของการวัดความเร็วด้วย Encoder และตัวกรองความถี่ต่ำ"))
    doc.add(body(f"บอร์ดคำนวณความเร็วเชิงมุมจากจำนวนพัลส์ของ Encoder AMT103-V ({ENC_CPR:,} counts ต่อรอบหลังถอดรหัส X4) ที่นับได้ในแต่ละคาบ 1 ms ความเร็วที่วัดได้จึงเป็นค่าไม่ต่อเนื่อง (Quantized) ขั้นละหนึ่ง count ต่อคาบ ตามสมการที่ (5) ได้ความละเอียด Δω ≈ {q_rpm:.2f} RPM ซึ่งหยาบเมื่อเทียบกับความเร็วในโหมดไมโครสเต็ปละเอียด (เช่น 3.75 RPM ที่ 1/32, 200 Hz) สัญญาณความเร็วดิบจึงกระโดดระหว่างระดับที่อยู่ติดกันตลอดเวลา เพื่อให้อ่านค่าได้ง่ายขึ้นโมเดลจึงกรองความเร็วด้วยตัวกรอง Butterworth อันดับ 2 ความถี่ตัด 10 Hz แบบดิสครีต (Ts = 1 ms) ตามสมการที่ (6) ควบคู่กับสัญญาณดิบ ตัวกรองนี้มีอัตราขยายที่ DC เท่ากับ 1 จึงไม่เปลี่ยนค่าเฉลี่ยของความเร็ว แต่ลดทอนองค์ประกอบกระเพื่อมความถี่สูงอย่างมาก", True))
    doc.add(eq_xml(mr("Δ") + S("ω", "q") + mr("=") + mfrac(mr("60", True), S("N", "enc") + mr("⋅") + S("T", "s")) + mr("=") + mfrac(mr("60", True), mr(f"{ENC_CPR}", True) + mr("×") + mr("0.001", True)) + mr(f" ≈ {q_rpm:.2f} RPM", True), 5))
    hz = mfrac(mr(f"{LPF_B[0]:.6f}", True) + mdel(mr("1", True) + mr("+") + mr("2", True) + msup(mr("z"), mr("−1", True)) + mr("+") + msup(mr("z"), mr("−2", True))),
               mr("1", True) + mr("−") + mr(f"{-LPF_A[1]:.6f}", True) + msup(mr("z"), mr("−1", True)) + mr("+") + mr(f"{LPF_A[2]:.6f}", True) + msup(mr("z"), mr("−2", True)))
    doc.add(eq_xml(S("H", "LPF") + mdel(mr("z")) + mr("=") + hz, 6))

    # ---- Procedure
    doc.add(h_sec("ขั้นตอนการดำเนินงาน"))
    for t in [
        "ติดตั้งโมดูล Stepper Motor เข้ากับฐานบอร์ด MotorXplorer ยึด Coupling ระหว่างเพลามอเตอร์กับเพลา Encoder AMT103-V ให้แน่น ตรวจคู่สายเฟส A และเฟส B ด้วยมัลติมิเตอร์โหมด Continuity แล้วต่อเข้าขั้ว Stepper บนบอร์ด และต่อสัญญาณ Encoder (A → PA7, B → PA6) กับ DRV8825 (M0 → PB15, M1 → PB14, M2 → PB13, EN → PB1, DIR → PB2, STEP → PC8) เข้ากับบอร์ด Nucleo STM32G474RE",
        "ตรวจความปลอดภัยก่อนจ่ายไฟ ได้แก่ จัมเปอร์ 5V_SEL อยู่ที่ E5V แรงดันขาออก Step Down เท่ากับ 3.3 V ตั้งค่า Current Limit ของ DRV8825 ให้อยู่ในพิกัดมอเตอร์ และเพลาหมุนได้อิสระ จากนั้นต่อ Adapter 24 V และสาย USB แล้วแฟลชเฟิร์มแวร์ motorxplorer.bin (LED กระพริบประมาณ 1 Hz)",
        "เปิด MATLAB (R2025b ขึ้นไป พร้อม Waijung 18.11a) ที่โฟลเดอร์โปรเจกต์ แล้วเรียก start_stepper_labs (โหมดโต้ตอบ) หรือ run_stepper_labs พร้อมระบุพอร์ต ST-Link ของเครื่องตนเองผ่านพารามิเตอร์ 'Port' สคริปต์จะเปิดโมเดลประจำหัวข้อในโฟลเดอร์ stepper_motor/ ตั้งค่า Exp Mode, Drive Mode, Accel Limit, Max Freq และ Full steps per rev แล้วสั่งจำลองแบบ Real-time (Pacing) ทีละรายการ พร้อมบันทึก logsout และข้อมูลกำกับ (meta) ลงไฟล์ .mat หนึ่งไฟล์ต่อหนึ่งรอบ และพักมอเตอร์ด้วย EN = 1 ระหว่างรอบ",
        "R0 (R0_Baseline_Calibration.slx): บันทึกสัญญาณขณะมอเตอร์หยุดนิ่ง (EN = 1, f = 0 Hz) 5 วินาที เพื่อหาค่าศูนย์ของ PA1, PA0 และความเร็วเชิงมุมของแต่ละรอบการทดลอง",
        f"R3 (R3_DriveModes_RealOp.slx): บล็อก Experiment Scheduler ขับมอเตอร์ทีละโหมดครบทั้ง 6 โหมดที่ความถี่ {fhz(r3_f) if fin(r3_f) else '400'} Hz โหมดละ 4 วินาที (เร่งด้วย 2,000 Hz/s) สลับกับพัก EN = 1 อีก 2 วินาที ทำซ้ำ {n_trials_txt(n_trials_r3)} เพื่อเปรียบเทียบลักษณะการเคลื่อนที่ ความเร็วดิบ และความเร็วหลังกรอง",
        f"R4/R5 (R4_R5_FreqVsSpeed.slx): สำหรับแต่ละโหมด สั่งความถี่แบบขั้นบันได {fhz(r4_freqs[0]) if r4_freqs else '200'} ถึง {fhz(r4_freqs[-1]) if r4_freqs else '1,600'} Hz ระดับละ 4 วินาที โดยใช้เฉพาะช่วงที่สัญญาณ is_steady = 1 (1.5 ถึง 3.9 วินาทีของแต่ละระดับ) ในการเฉลี่ยความเร็ว ทำซ้ำโหมดละ {n_trials_txt(n_trials_r4)}",
        "ประมวลผลข้อมูลด้วย analyze_stepper_labs ซึ่งคำนวณค่าเฉลี่ย ส่วนเบี่ยงเบนมาตรฐานระหว่างการทดลองซ้ำ ร้อยละความคลาดเคลื่อน และ Ripple SD ของทั้งสัญญาณดิบและสัญญาณ LPF ส่งออกเป็นตาราง CSV แล้วสร้างกราฟรายงานความละเอียด 300 dpi ด้วย tools/make_report_figures.m และรวมผลเป็นรายงานด้วย tools/build_report_final.py",
    ]:
        doc.add(bullet(t, num_id=53))

    # ---- Results
    doc.add(h_sec("ผลการทดลอง"))
    t_r4 = doc.tab_n + 1
    doc.add(body(f"ผลการวัดความเร็วรอบในแต่ละโหมดที่ความถี่ต่างๆ เปรียบเทียบกับค่าทฤษฎีจากสมการที่ (3) จากการทดลองซ้ำ {n_trials_txt(n_trials_r4)} แสดงในตารางที่ {t_r4} และภาพที่ {doc.fig_n + 1} ส่วนผลการขับมอเตอร์ครบ 6 โหมดในการทดลองเดียว (R3) พร้อมการเปรียบเทียบสัญญาณดิบกับสัญญาณหลังกรองแสดงในตารางที่ {t_r4 + 1} และภาพถัดไป", True))
    has_lpf_r4 = any(fin(e.get("lpf_ripple")) for e in data.r4.values())
    rows = []
    for m in data.r4_modes:
        first = True
        for (mm, f), e in sorted(data.r4.items()):
            if mm != m:
                continue
            r = [f"{mode_short(m)}" if first else "", fhz(f), frpm(e["theory"]),
                 f"{frpm(e['mean'])} ± {frpm(e['sd'] or 0.0)}", ferr(e["err"])]
            if has_lpf_r4:
                r.append(f"{fmt(e['ripple'], 2)} / {fmt(e['lpf_ripple'], 2)}")
            r.append(r4_status(e))
            rows.append(r)
            first = False
    hdr = ["โหมด", "ความถี่\n(Hz)", "ทฤษฎี\n(RPM)", "วัดได้ เฉลี่ย ± SD\n(RPM)", "Error\n(%)"]
    widths = [1150, 950, 1150, 2000, 1000]
    if has_lpf_r4:
        hdr.append("Ripple SD ดิบ / LPF\n(RPM)")
        widths.append(1700)
    hdr.append("สถานะ")
    widths.append(1796)
    doc.table(f"ผลการวัดความเร็วรอบเทียบค่าทฤษฎีในแต่ละโหมดการขับเคลื่อน (ค่าเฉลี่ย ± SD จากการทดลองซ้ำ {n_trials_txt(n_trials_r4)}, {spr} ก้าว/รอบ)",
              hdr, rows, widths, sz=26)
    doc.figure(data.find_fig("freq_speed")[:1] and data.find_fig("freq_speed")[0],
               "ความเร็วรอบที่วัดได้จริง (ค่าเฉลี่ย ± SD) เทียบกับความเร็วรอบตามทฤษฎี (เส้นประ) ตามความถี่สัญญาณขับในแต่ละโหมดการขับเคลื่อน")

    # R3 table
    r3_rows = []
    for m in sorted(data.r3):
        e = data.r3[m]
        r3_rows.append([mode_short(m), frpm(e.get("theory")),
                        f"{frpm(e.get('mean'))} ± {fmt(e.get('trial_sd'), 3)}" if fin(e.get("mean")) else frpm(e.get("lpf_mean")),
                        fmt(e.get("ripple"), 2), fmt(e.get("lpf_ripple"), 2), fmt(e.get("red"), 1),
                        fmt(e.get("shift"), 3)])
    if r3_rows:
        doc.table(f"ความเร็วเฉลี่ยในสภาวะคงตัวและขนาดการกระเพื่อมของความเร็วก่อนและหลังตัวกรอง LPF 10 Hz เมื่อขับครบ 6 โหมดที่ความถี่ {fhz(r3_f) if fin(r3_f) else '-'} Hz (R3)",
                  ["โหมด", "ทฤษฎี\n(RPM)", "วัดได้ ± SD ระหว่างครั้ง\n(RPM)", "Ripple SD ดิบ\n(RPM)", "Ripple SD LPF\n(RPM)", "ลด Ripple\n(%)", "ค่าเฉลี่ยเลื่อน\nLPF − ดิบ (RPM)"],
                  r3_rows, [1300, 1100, 2000, 1300, 1300, 1150, 1596], sz=26)
    doc.figure(next(iter(data.find_fig("r3_lpf")), None),
               f"สัญญาณความเร็วดิบ (Raw) เทียบกับสัญญาณหลังกรอง Butterworth 10 Hz และค่าทฤษฎี เมื่อขับครบทั้ง 6 โหมดที่ {fhz(r3_f) if fin(r3_f) else '400'} Hz")
    f_e = r3_f / 4.0 if fin(r3_f) else None
    doc.figure(next(iter(data.find_fig("fft")), None),
               f"สัญญาณความเร็วโหมด Full Step ที่ {fhz(r3_f) if fin(r3_f) else '400'} Hz ในสภาวะคงตัว (บน) และสเปกตรัม FFT ของการกระเพื่อมความเร็วก่อนและหลังกรอง (ล่าง)")

    # ---- statistics for prose
    in_sync = [(k, e) for k, e in data.r4.items() if fin(e["err"]) and not is_r4_lost(e)]
    lost = [(k, e) for k, e in data.r4.items() if is_r4_lost(e)]
    n_lt01 = sum(1 for _, e in in_sync if e["err"] < 0.1)
    n_lt1 = sum(1 for _, e in in_sync if e["err"] < 1.0)
    med_err = statistics.median([e["err"] for _, e in in_sync]) if in_sync else None
    lowspeed = sorted([(k, e) for k, e in in_sync if e["err"] >= 1.0], key=lambda t: -t[1]["err"])
    sd_max = max([e["sd"] for _, e in in_sync if fin(e["sd"])] or [0.0])
    full_lost, half_lost = lost_freqs(data, 1), lost_freqs(data, 2)
    full_partial_lost = any((data.r4[(1, f)].get("sd") or 0.0) > 30 for f in full_lost)
    full_res = full_lost[0] if full_lost else None
    rip = [e["ripple"] for e in data.r3.values() if fin(e.get("ripple"))]
    lrip = [e["lpf_ripple"] for e in data.r3.values() if fin(e.get("lpf_ripple"))]
    red = [e["red"] for e in data.r3.values() if fin(e.get("red"))]
    shift = [abs(e["shift"]) for e in data.r3.values() if fin(e.get("shift"))]
    cur_vals = [abs(e["current"]) for e in list(data.r3.values()) + list(data.r4.values()) if fin(e.get("current"))]
    cur_max = max(cur_vals) if cur_vals else None
    modes_all_ok = [m for m in data.r4_modes if not lost_freqs(data, m)]

    # ---- Conclusion 1
    doc.add(h_sec("สรุปผลการทดลอง"))
    c = []
    if data.r4:
        c.append(f"จากการขับ Stepper Motor ผ่าน DRV8825 ทั้ง {len(data.r4_modes)} โหมดในช่วง {fhz(r4_freqs[0])} ถึง {fhz(r4_freqs[-1])} Hz รวม {len(data.r4)} จุดทดสอบ พบว่าในจุดที่มอเตอร์ยังไม่หลุดก้าวจำนวน {len(in_sync)} จุด ความเร็วรอบที่วัดได้สอดคล้องกับสมการที่ (3) อย่างใกล้ชิด โดยมีความคลาดเคลื่อนต่ำกว่าร้อยละ 0.1 ถึง {n_lt01} จุด ต่ำกว่าร้อยละ 1 รวม {n_lt1} จุด และค่ามัธยฐานของความคลาดเคลื่อนเท่ากับร้อยละ {ferr(med_err)} ความเร็วรอบลดลงตามสัดส่วน 1/M เมื่อเปลี่ยนเป็นโหมดที่ละเอียดขึ้นที่ความถี่เดียวกัน ส่วนเบี่ยงเบนมาตรฐานระหว่างการทดลองซ้ำในช่วงที่ซิงก์สูงสุดเพียง {fmt(sd_max, 2)} RPM ยืนยันสมมติฐานว่าความเร็วแปรผันตรงกับ f_step และแปรผกผันกับ M")
    if lowspeed:
        ex = ", ".join(f"{mode_short(k[0])} ที่ {fhz(k[1])} Hz (ร้อยละ {ferr(e['err'])})" for k, e in lowspeed[:4])
        c.append(f"ความคลาดเคลื่อนที่เกินร้อยละ 1 ในจุดที่ไม่หลุดก้าวเกิดเฉพาะที่ความเร็วต่ำ ได้แก่ {ex} ซึ่งเป็นผลจากการ Quantize ความเร็วของ Encoder และการแกว่งเกิน (Overshoot) ของก้าวที่ถูกหาค่าสัมบูรณ์ |ω_enc|")
    if full_lost:
        tail = (f" ขณะที่โหมด Half Step และ Microstep (1/4 ถึง 1/32) หมุนตามได้ครบทุกความถี่จนถึง {fhz(max(f for m, f in data.r4 if m == 2))} Hz" if 2 in data.r4_modes and not half_lost else "")
        e0 = data.r4[(1, full_lost[0])]
        nl, nt = e0.get("n_lost"), int(e0.get("n") or 0)
        if nl is not None and nt and 0 < nl < nt:
            part_txt = f" (หลุดก้าว {nl} ใน {nt} รอบการทดลอง ขณะที่อีก {nt - nl} รอบหมุนตามได้ถึง {fhz(full_lost[-1])} Hz จึงมีค่า SD ระหว่างรอบสูง)"
        elif full_partial_lost:
            part_txt = " (หลุดก้าวบางรอบการทดลอง ทำให้ค่าเฉลี่ยต่ำกว่าทฤษฎีและมี SD ระหว่างรอบสูง)"
        else:
            part_txt = ""
        c.append(f"ข้อยกเว้นสำคัญคือโหมด Full Step ซึ่งเกิดการหลุดก้าวตั้งแต่ {fhz(full_lost[0])} Hz ขึ้นไป ({len(full_lost)} ระดับความถี่ในช่วงขั้นบันได){part_txt}{tail}")
    if rip and lrip:
        c.append(f"ด้านคุณภาพสัญญาณ ความเร็วดิบมี Ripple SD {fmt(min(rip), 1)} ถึง {fmt(max(rip), 1)} RPM ซึ่งส่วนใหญ่มาจากการ Quantize ขั้นละ {q_rpm:.2f} RPM เมื่อผ่านตัวกรอง LPF 10 Hz Ripple SD ลดลงเหลือ {fmt(min(lrip), 2)} ถึง {fmt(max(lrip), 2)} RPM (ลดลงร้อยละ {fmt(min(red), 1)} ถึง {fmt(max(red), 1)}) โดยค่าเฉลี่ยเปลี่ยนไปไม่เกิน {fmt(max(shift) if shift else None, 2)} RPM")
    doc.add(body(" ".join(c) if c else "ไม่พบตารางผลการวัดของการทดลองที่ 1 ในโฟลเดอร์ข้อมูลที่ระบุ", True))

    # ---- Discussion 1
    doc.add(h_sec("อภิปรายผล"))
    doc.add(body("พฤติกรรมที่ความเร็วรอบเพิ่มขึ้นเป็นเส้นตรงตามความถี่สัญญาณ STEP เกิดจากธรรมชาติการทำงานแบบซิงโครนัสของ Stepper Motor ทุกหนึ่งพัลส์บังคับให้เวกเตอร์สนามแม่เหล็กสเตเตอร์หมุนไปหนึ่งก้าวย่อยคงที่ โรเตอร์จึงต้องหมุนด้วยอัตราเร็วเชิงมุมเท่ากับอัตราป้อนพัลส์หารด้วยจำนวนพัลส์ต่อรอบ เส้นกราฟของโหมดที่มีตัวคูณ M สูงกว่าจึงชันน้อยกว่าเป็นสัดส่วน 1/M พอดี ตราบใดที่โรเตอร์ยังไม่หลุดซิงก์ ความเร็วเฉลี่ยจะถูกกำหนดโดยความถี่ของพัลส์เพียงอย่างเดียว ความคลาดเคลื่อนที่ต่ำมากในตารางจึงสะท้อนความแม่นยำของ Timer ที่สร้างสัญญาณ STEP มากกว่าความแม่นยำของตัวมอเตอร์", True))
    doc.add(body(f"ความคลาดเคลื่อนที่สูงขึ้นที่ความเร็วต่ำอธิบายได้จากสมการที่ (5) ความเร็วที่วัดได้มีความละเอียดเพียง {q_rpm:.2f} RPM ต่อหนึ่ง count ต่อมิลลิวินาที ขณะที่ความเร็วจริงในโหมด 1/16 และ 1/32 ที่ 200 Hz มีค่าเพียง 3.75 ถึง 7.5 RPM สัญญาณดิบจึงกระโดดระหว่าง 0 กับ ±{q_rpm:.2f} RPM และเนื่องจากสมการที่ (4) ใช้ค่าสัมบูรณ์ |ω_enc| ตัวอย่างที่ติดลบจากการสั่นของเพลาจะถูกพลิกเป็นค่าบวก ค่าเฉลี่ยจึงเอนสูงกว่าค่าทฤษฎีเมื่อขนาดการกระเพื่อมใกล้เคียงกับความเร็วเฉลี่ย ในโหมด Full Step, Half Step (ที่ 200 Hz) และ 1/4 Microstep (ที่ 600 Hz) การเคลื่อนที่แบบก้าวที่มีการแกว่งเกิน (Underdamped Step Ringing) รอบตำแหน่งสมดุลในแต่ละก้าวทำให้ค่าสัมบูรณ์ |ω_enc| สูงกว่าความเร็วเฉลี่ยเชิงเส้นแม้โรเตอร์ยังคงซิงก์ครบทุกก้าวและกลับเข้าสู่ความคลาดเคลื่อนต่ำกว่าร้อยละ 0.01 ที่ความถี่สูงขึ้น"))
    if rip and lrip:
        fe_txt = (f" สเปกตรัม FFT ของสัญญาณ Full Step ที่ {fhz(r3_f)} Hz แสดงยอดเด่นที่ประมาณ {fhz(f_e)} Hz ซึ่งเท่ากับ f_step/4 หรือความถี่ไฟฟ้าของขดลวด (หนึ่งรอบไฟฟ้ามี 4 ก้าวเต็ม) ห่างจากความถี่ตัด 10 Hz มากกว่าหนึ่งดีเคด จึงถูกลดทอนได้เกือบทั้งหมด" if fin(f_e) else "")
        doc.add(body(f"Ripple SD ของสัญญาณดิบ ({fmt(min(rip), 1)} ถึง {fmt(max(rip), 1)} RPM) อยู่ในระดับเดียวกับขั้น Quantize {q_rpm:.2f} RPM แสดงว่าการกระเพื่อมส่วนใหญ่เป็นสัญญาณรบกวนจากการวัด ไม่ใช่ความเร็วจริงของเพลา ตัวกรอง Butterworth อันดับ 2 ที่ 10 Hz ลด Ripple SD ลงร้อยละ {fmt(min(red), 1)} ถึง {fmt(max(red), 1)} โดยค่าเฉลี่ยเปลี่ยนไปไม่เกิน {fmt(max(shift) if shift else None, 2)} RPM เนื่องจากอัตราขยายที่ DC เท่ากับ 1{fe_txt} ดังนั้นสัญญาณ rpm_meas_lpf เหมาะสำหรับแสดงผลและตรวจสอบความเร็วเฉลี่ย แต่การตรวจจับ Loss Step แบบทันทีควรใช้สัญญาณดิบหรือค่าเฉลี่ยเคลื่อนที่ช่วงสั้น เพราะตัวกรองมีความหน่วงเวลาราว 20 ถึง 30 ms"))
    if full_lost:
        half_txt = ""
        if 2 in data.r4_modes:
            same = [(f, data.r4.get((2, 2 * f))) for f in full_lost if (2, 2 * f) in data.r4]
            ok_same = [f for f, e in same if e and not is_r4_lost(e)]
            if ok_same:
                f0 = ok_same[0]
                half_txt = f" ในขณะที่โหมด Half Step ที่ {fhz(2 * f0)} Hz ซึ่งให้ความเร็วรอบเท่ากัน ({frpm(data.r4[(2, 2 * f0)]['theory'])} RPM) หมุนตามได้ปกติ"
        fast = [e["rpm"] for (m, a), e in data.r8.items() if m == 1 and fin(a) and fin(e.get("rpm"))]
        fast_txt = (f" นอกจากนี้ในการทดลองที่ 2 โหมด Full Step เดียวกันสามารถเร่งแบบ Ramp ขึ้นไปถึงประมาณ {fmt(max(fast), 0)} RPM ได้ จึงยืนยันว่าการหลุดก้าวที่ {fhz(full_lost[0])} Hz ไม่ได้เกิดจากขีดจำกัดแรงบิด-ความเร็ว" if fast and max(fast) > (data.r4[(1, full_lost[0])]["theory"] or 0) else "")
        doc.add(body(f"การที่โหมด Full Step หลุดก้าวตั้งแต่ {fhz(full_lost[0])} Hz ({frpm(data.r4[(1, full_lost[0])]['theory'])} RPM) ในการทดสอบแบบขั้นบันได{half_txt} ชี้ว่าสาเหตุคือการสั่นพ้องช่วงกลาง (Mid-band Resonance) ของโหมด Full Step ซึ่งแรงบิดเป็นแบบขั้นและมีพลังงานกระตุ้นการแกว่งของโรเตอร์สูง เมื่อมอเตอร์ค้างอยู่ในย่านนี้นานหลายวินาที การแกว่งจะขยายตัวจนหลุดซิงก์ ส่วน Half Step และ Microstep ที่กระแสเปลี่ยนเป็นขั้นเล็กกว่ากระตุ้นการสั่นพ้องน้อยกว่ามาก{fast_txt}"))
    if fin(cur_max):
        doc.add(body(f"ข้อควรระวังในการตีความข้อมูลกระแส ค่า Current_A ในตารางผลมาจากเซนเซอร์ PA1 ซึ่งต่ออยู่บนเส้นทางกระแสของ DC Motor ไม่ใช่กระแสเฟสของ Stepper Motor ขณะสั่งขับ Stepper ค่าที่อ่านได้เปลี่ยนแปลงไม่เกิน {fmt(cur_max, 3)} A (หลังหักค่าศูนย์จาก R0) และใช้อัตราขยาย 66.3185 counts/A ที่ยืมมาจากการสอบเทียบของ DC Motor จึงไม่สามารถนำค่านี้ไปวิเคราะห์กระแสหรือแรงบิดของ Stepper Motor ได้ หากต้องการวัดกระแสเฟสต้องติดตั้งเซนเซอร์เพิ่มบนสายเฟส A หรือ B"))
    doc.add(body(f"การทำซ้ำ {n_trials_txt(n_trials_r4)} ในแต่ละโหมดให้ส่วนเบี่ยงเบนมาตรฐานต่ำมาก แสดงให้เห็นความเที่ยงตรงของการควบคุมแบบวงเปิดตราบเท่าที่มอเตอร์ยังทำงานต่ำกว่าขีดจำกัดแรงบิดและอยู่นอกย่านเรโซแนนซ์ เมื่อพิจารณาการเลือกใช้งานจริง แต่ละโหมดมีจุดเด่นและข้อจำกัดต่างกันดังสรุปในตารางที่ {doc.tab_n + 1} ซึ่งรวมโหมด Wave Drive ไว้ในเชิงทฤษฎีแม้ DRV8825 จะไม่รองรับก็ตาม"))
    doc.table("เปรียบเทียบข้อดี ข้อเสีย และความเหมาะสมในการใช้งานจริงของแต่ละโหมดการขับเคลื่อน Stepper Motor",
              ["โหมดการขับเคลื่อน", "ข้อดี", "ข้อเสีย", "ลักษณะงานที่เหมาะสม"],
              [["Wave Drive\n(1-Phase On)", "จ่ายกระแสทีละเฟสจึงกินไฟและความร้อนต่ำกว่า Full Step วงจรควบคุมพื้นฐานไม่ซับซ้อน",
                "แรงบิดลดลงเหลือราวร้อยละ 70 ของ Full Step มุมก้าวหยาบ สั่นสะเทือนสูง และ DRV8825 ไม่รองรับ",
                "งานโหลดเบามากที่จำกัดกำลังไฟฟ้าและไม่ต้องการความละเอียดสูง"],
               ["Full Step\n(2-Phase On)", "ให้ Holding Torque สูงสุด ได้ความเร็วรอบสูงที่สุดที่ความถี่พัลส์เท่ากัน และใช้ความถี่สัญญาณ STEP ต่ำที่สุด",
                "เคลื่อนที่เป็นจังหวะกระตุก สั่นสะเทือนสูง เกิดเรโซแนนซ์ช่วงกลางจนหลุดก้าวได้ง่าย" + (f" (ในการทดลองนี้หลุดก้าวที่ {fhz(full_lost[0])} Hz)" if full_lost else "") + " ความละเอียดตำแหน่งหยาบ",
                "งานที่เน้นแรงบิดและความเร็วสูงที่เร่งผ่านย่านเรโซแนนซ์ได้รวดเร็ว และไม่เข้มงวดเรื่องเสียงหรือความละเอียดมุม"],
               ["Half Step\n(1/2)", "ความละเอียดเพิ่มเป็น 2 เท่าของ Full Step ลดการสั่นและเรโซแนนซ์ได้ชัดเจน" + (" (หมุนได้ครบทุกความถี่ในการทดลองนี้)" if 2 in modes_all_ok else ""),
                "แรงบิดสลับไม่สม่ำเสมอระหว่างจังหวะ 1 เฟสกับ 2 เฟส ทำให้ยังมีแรงกระเพื่อม (Torque Ripple)",
                "งานวางตำแหน่งทั่วไปที่ต้องการจุดสมดุลระหว่างแรงบิด ความเร็ว และความนุ่มนวล"],
               ["Microstep\n(1/4 ถึง 1/32)", "เคลื่อนที่นุ่มนวลมาก เสียงเบา ลดการสั่นและเรโซแนนซ์ช่วงความถี่ต่ำ-กลางได้ดี ความละเอียดสูงถึง " + f"{360.0 / (32 * spr):.5f}°/พัลส์",
                "แรงบิดต่อหนึ่งก้าวย่อยลดลงตาม M ต้องใช้ความถี่ STEP สูงมากเพื่อให้ได้ความเร็วเท่าเดิม และวัดความเร็วต่ำได้ยากเพราะความละเอียดของ Encoder",
                "เครื่องพิมพ์ 3 มิติ เครื่อง CNC แขนกลขนาดเล็ก และระบบจัดตำแหน่งที่ต้องการความนุ่มนวลและความละเอียดสูง"]],
              [1600, 2750, 2900, 2496], ["left"] * 4)

    # =========================================================================
    # EXPERIMENT 2
    # =========================================================================
    acc_txt = ", ".join(fmt(a, 0) for a in data.accels) if data.accels else "4,000, 2,000, 1,000 และ 500"
    r8_ceils = sorted({e["ceiling"] for e in data.r8.values() if fin(e.get("ceiling"))})
    ceil_txt = " / ".join(fhz(c) for c in r8_ceils) if r8_ceils else None
    modes2 = [m for m in data.r8_modes]
    modes2_txt = " และ ".join(mode_long(m) for m in modes2) if modes2 else "Full Step"
    doc.add(h_exp("การทดลองที่ 2 การศึกษาการเกิด Loss Step และผลของความเร่งต่อความถี่ที่เกิด Loss Step", page_break=True))
    doc.add(h_sec("จุดประสงค์"))
    for t in [
        "เพื่อศึกษาหลักการ เงื่อนไข และลักษณะพฤติกรรมของ Stepper Motor เมื่อเกิดการสูญเสียก้าว (Loss Step) ทั้งในกรณีออกตัวแบบก้าวกระโดด (Step Input) และกรณีเพิ่มความถี่แบบ Ramp",
        "เพื่อวิเคราะห์ผลของอัตราเร่งเชิงเส้น (Linear Acceleration) ต่อความถี่สูงสุดที่มอเตอร์หมุนตามได้ก่อนเกิด Loss Step (Pull-out Frequency) และเปรียบเทียบระหว่างโหมด Full Step กับ Half Step",
        "เพื่อวัดจำนวนก้าวที่สูญหาย (Lost Full Steps) จากความแตกต่างระหว่างจำนวนรอบที่สั่งกับจำนวนรอบจริงที่วัดได้จาก Encoder",
    ]:
        doc.add(bullet(t, num_id=54))
    doc.add(h_sec("สมมติฐาน"))
    doc.add(body("สมมติฐานที่ 1: หากสั่งความถี่สัญญาณ STEP แบบก้าวกระโดดจากหยุดนิ่งโดยไม่จำกัดความเร่ง มอเตอร์จะเกิด Loss Step ตั้งแต่ความถี่ค่อนข้างต่ำ (Pull-in Frequency) เนื่องจากแรงบิดไม่พอเร่งความเฉื่อยของโรเตอร์ในเสี้ยววินาทีแรก และโหมดที่ละเอียดกว่าจะออกตัวได้ที่ความถี่สูงกว่าเพราะแต่ละพัลส์ขยับมุมน้อยกว่า", True))
    doc.add(body("สมมติฐานที่ 2: เมื่อเพิ่มความถี่แบบ Ramp ด้วยอัตราเร่งเชิงเส้น ความต้องการแรงบิดเร่งความเฉื่อย (J · α) จะลดลง มอเตอร์จึงไต่ความถี่ขึ้นสู่ย่าน Slew Range ได้สูงกว่ากรณี Step Input และยิ่งกำหนดอัตราเร่ง (Hz/s) ให้ต่ำลง ความถี่สูงสุดก่อนเกิด Loss Step (Pull-out Frequency) จะยิ่งสูงขึ้น"))
    doc.add(h_sec("ตัวแปร"))
    doc.add(var_head("ตัวแปรต้น:", 57))
    doc.add(var_item(f"รูปแบบและขนาดของความเร่งสัญญาณ STEP ได้แก่ Step Input จากหยุดนิ่ง (R6 ไล่ความถี่ 200 ถึง 2,400 Hz) และ Ramp เชิงเส้นที่อัตรา {acc_txt} Hz/s (R8)"))
    doc.add(var_item(f"โหมดการขับเคลื่อน ได้แก่ {modes2_txt}"))
    doc.add(var_head("ตัวแปรตาม:", 57))
    doc.add(var_item("ความถี่สูงสุดก่อนเกิด Loss Step (Pull-in Frequency สำหรับ Step Input และ Pull-out Frequency สำหรับ Ramp) และความเร็วรอบที่จุดนั้น"))
    doc.add(var_item("จำนวนก้าวเต็มที่สูญหาย (lost_steps) และความเร็วรอบจริงจาก Encoder"))
    doc.add(var_head("ตัวแปรควบคุม:", 57))
    doc.add(var_item("ชุดฮาร์ดแวร์เดิม แรงดัน 24 V ค่า Current Limit ของ DRV8825 สภาวะโหลดเปล่า ทิศทาง DIR = 0 และเวลาสุ่มตัวอย่าง 0.001 s"))
    doc.add(var_item("ความถี่เริ่มต้นของ Ramp (คงที่ 200 Hz เป็นเวลา 0.5 s ก่อนเริ่มเร่ง)" + (f" และเพดานความถี่ของ Ramp {ceil_txt} Hz" if ceil_txt else "")))

    doc.add(h_sec("เอกสารและงานวิจัยที่เกี่ยวข้อง"))
    doc.add(h_sub("1. หลักการของ Loss Step และเงื่อนไขที่ทำให้เกิด Loss Step"))
    doc.add(body("Loss Step หรือการหลุดซิงโครไนซ์เกิดขึ้นเมื่อมุมตำแหน่งจริงของโรเตอร์ตามมุมสนามแม่เหล็กสเตเตอร์ไม่ทันเกินขอบเขตที่แรงดึงแม่เหล็กจะดึงกลับได้ (มากกว่า ±2 ก้าวเต็ม หรือ ±90 องศาไฟฟ้า) โรเตอร์จะกระตุก ชะงัก หรือสั่นอยู่กับที่แม้ไดรเวอร์ยังส่งพัลส์ STEP ต่อไป เนื่องจากระบบขับพื้นฐานทำงานแบบวงเปิด ไดรเวอร์จึงไม่รับรู้ว่าตำแหน่งคลาดเคลื่อน การทดลองนี้จึงใช้ Encoder เปรียบเทียบกับจำนวนรอบที่สั่งจริงจากสัญญาณ f_echo เพื่อคำนวณจำนวนก้าวเต็มที่สูญหายตามสมการที่ (7)", True))
    int1 = mnary("∫", mr("0", True), mr("t"), mfrac(S("f", "echo") + mdel(mr("τ")), mr("M") + mr("⋅") + S("N", "full")) + mr(" dτ"))
    int2 = mdel(mnary("∫", mr("0", True), mr("t"), mfrac(S("ω", "enc") + mdel(mr("τ")), mr("2π", True)) + mr(" dτ")), "|", "|")
    doc.add(eq_xml(S("S", "lost") + mdel(mr("t")) + mr("=") + mdel(int1 + mr("−") + int2) + mr("⋅") + S("N", "full"), 7))
    doc.add(body("เงื่อนไขทางฟิสิกส์ที่นำไปสู่ Loss Step อธิบายได้จากสมดุลแรงบิดในสมการที่ (8) มอเตอร์จะหมุนตามคำสั่งได้ก็ต่อเมื่อแรงบิดที่สร้างได้ ณ ความถี่นั้นไม่น้อยกว่าผลรวมของแรงบิดโหลดกับแรงบิดที่ใช้เร่งความเฉื่อยของโรเตอร์และเพลาต่อพ่วง", True))
    doc.add(eq_xml(S("T", "motor") + mdel(mr("f")) + mr("≥") + S("T", "load") + mr("+") + S("J", "total") + mr("⋅") + mr("α") + mr(",   ", True) + mr("α") + mr("=") + mfrac(mr("2π", True), mr("M") + mr("⋅") + S("N", "full")) + mr("⋅") + mfrac(mr("d") + S("f", "step"), mr("dt")), 8))
    doc.add(body("จากสมการที่ (8) ปัจจัยที่ทำให้เกิด Loss Step มี 5 ประการหลัก ได้แก่ (1) ความถี่ขับสูงเกินไป ทำให้แรงดันต้านกลับ (Back-EMF) สูงขึ้นและเวลาชาร์จกระแสผ่านความเหนี่ยวนำขดลวดสั้นลง กระแสจริงจึงขึ้นไม่ถึงพิกัดและแรงบิดตก (2) อัตราเร่งสูงเกินไปหรือออกตัวแบบก้าวกระโดด ทำให้พจน์ J_total · α เกินแรงบิดที่มี (3) แรงบิดโหลดหรือความเฉื่อยต่อพ่วงสูงเกินเส้นโค้ง Torque-Speed (4) ค่า Current Limit ต่ำเกินไปหรือแรงดันแหล่งจ่ายไม่พอ และ (5) การสั่นพ้องเชิงกล (Mid-band Resonance) เมื่อความถี่พัลส์ตรงกับย่านที่โรเตอร์แกว่งขยายตัวจนหลุดก้าว ซึ่งขึ้นกับระยะเวลาที่มอเตอร์ค้างอยู่ในย่านนั้นด้วย"))
    doc.add(h_sub("2. Start/Stop Frequency, Slew Range และ Linear Acceleration"))
    doc.add(body("เส้นโค้งแรงบิด-ความเร็วของ Stepper Motor แบ่งย่านการทำงานเป็นสองขอบเขต ขอบเขตแรกคือ Pull-in Torque (Start/Stop Region) ซึ่งเป็นความถี่สูงสุดที่ออกตัวหรือหยุดได้ทันทีโดยไม่หลุดก้าว ขอบเขตที่สองคือ Pull-out Torque (Slew Region) ซึ่งสูงกว่ามาก มอเตอร์ไม่สามารถออกตัวตรงเข้าย่าน Slew ได้ แต่ไต่ขึ้นไปได้หากเพิ่มความถี่ด้วยโปรไฟล์ Ramp ให้พจน์ J_total · α พอเหมาะกับแรงบิดคงเหลือในแต่ละความถี่ ทั้งนี้ Ramp ที่ช้ามากจะทำให้มอเตอร์ใช้เวลาอยู่ในย่านเรโซแนนซ์นานขึ้น อัตราเร่งที่เหมาะสมจึงต้องสมดุลระหว่างแรงบิดเร่งความเฉื่อยกับเวลาที่ผ่านย่านเรโซแนนซ์", True))

    doc.add(h_sec("ขั้นตอนการดำเนินงาน"))
    for t in [
        "ใช้ชุดฮาร์ดแวร์และสคริปต์ run_stepper_labs ต่อเนื่องจากการทดลองที่ 1 โดยระบุโหมดของ R6 และ R8 ผ่านพารามิเตอร์ 'R6Mode' และ 'R8Mode' (1 = Full Step, 2 = Half Step) และระบุ 'Accels' กับ 'MaxFreq' ของ Ramp",
        f"R6 Pull-in (R6_LossStep_PullIn.slx): Experiment Scheduler สั่งความถี่แบบก้าวกระโดดจากหยุดนิ่งไปยัง 200, 400, 600, 800, 1,000, 1,200, 1,400, 1,600, 2,000 และ 2,400 Hz ระดับละ 2.5 วินาที สลับกับพัก EN = 1 อีก 1.5 วินาที (ตัวนับ lost_steps ถูกรีเซ็ตทุกครั้งที่ EN = 1) ทำซ้ำ {n_trials_txt(n_trials_r6)} ต่อโหมด ระดับใดที่ความเร็วเฉลี่ยในสภาวะคงตัวต่ำกว่าร้อยละ 85 ของค่าทฤษฎีร่วมกับ lost_steps ช่วงท้ายระดับตั้งแต่ 4 ก้าวขึ้นไป ถือว่าหลุดก้าว และ Pull-in Frequency คือความถี่สูงสุดก่อนระดับแรกที่หลุดก้าว",
        "R8 Pull-out (R8_Accel_PullOut.slx): ค้างความถี่ไว้ที่ 200 Hz เป็นเวลา 0.5 วินาที แล้วเพิ่มความถี่เชิงเส้นตามอัตราเร่งที่กำหนดจนถึงเพดาน MaxFreq และค้างไว้ 1 วินาที ก่อนสั่ง EN = 1 การค้างที่ 200 Hz นี้แก้ปัญหาเฟิร์มแวร์ที่โหลดคาบ Timer ของคำสั่งแรก (1/f₁) ไว้ก่อน หากเริ่ม Ramp จาก 0 Hz คำสั่งแรกมีความถี่ต่ำมาก (เช่น 0.5 Hz ที่ 500 Hz/s) มอเตอร์จะค้างอยู่นานถึง 1/f₁ ≈ 2 วินาทีในขณะที่ความถี่คำสั่งเพิ่มขึ้นไปแล้ว ทำให้ผลการทดลองเพี้ยน",
        f"ตรวจจับจุด Pull-out จากการที่ความเร็วเฉลี่ยเคลื่อนที่ 80 ms ลดลงต่ำกว่าร้อยละ 70 ของค่าทฤษฎี แล้วย้อนเวลากลับไปยังจุดเริ่มต้นของการตก (ต่ำกว่าร้อยละ 90 ของทฤษฎี) และรายงานค่า f_echo ณ จุดนั้น หาก Ramp ถึงเพดานโดยไม่เกิด Loss Step จะบันทึกว่าเป็นค่าที่ถูกตัดที่เพดาน (Censored, ≥ MaxFreq) ทำซ้ำ {n_trials_txt(n_trials_r8)} ต่ออัตราเร่งต่อโหมด แล้วประมวลผลด้วย analyze_stepper_labs",
    ]:
        doc.add(bullet(t, num_id=55))

    # ---- Results 2
    doc.add(h_sec("ผลการทดลอง"))
    t_r6 = doc.tab_n + 1
    doc.add(body(f"ผลการหาความถี่ Pull-in จากการออกตัวแบบก้าวกระโดดแสดงในตารางที่ {t_r6} ผลความถี่ Pull-out เทียบกับอัตราเร่งของ Ramp แสดงในตารางที่ {t_r6 + 1} และกราฟสัญญาณเวลาขณะเกิด Loss Step กับกราฟสรุปผลของความเร่งแสดงในภาพถัดไป", True))
    r6_rows = []
    for m in sorted(data.r6):
        e = data.r6[m]
        tr = e.get("trials", [])
        cens = e.get("censored", [])
        tr_txt = ", ".join(("≥ " if (i < len(cens) and cens[i]) else "") + fhz(v) for i, v in enumerate(tr) if fin(v))
        fs = [v for v in e.get("first_stall", []) if fin(v)]
        r6_rows.append([mode_short(m), tr_txt or "-", f"{fhz(e.get('mean'))} ± {fhz(e.get('sd') or 0.0)}",
                        frpm(e.get("rpm")), (f"{fhz(min(fs))} ถึง {fhz(max(fs))}" if len(set(fs)) > 1 else (fhz(fs[0]) if fs else "ไม่หลุดก้าว")),
                        f"{e.get('n_cens', 0)}/{len(tr)}"])
    if r6_rows:
        doc.table(f"ความถี่ Pull-in จากการออกตัวแบบก้าวกระโดด (Step Input, R6) แยกตามโหมดการขับเคลื่อน",
                  ["โหมด", "Pull-in แต่ละครั้ง (Hz)", "เฉลี่ย ± SD (Hz)", "ความเร็วที่ Pull-in (RPM)", "ความถี่แรกที่หลุดก้าว (Hz)", "ไม่หลุดก้าวเลย / ทั้งหมด"],
                  r6_rows, [1250, 2400, 1600, 1500, 1650, 1346], sz=26)
    have_r8_trials = any(e.get("trials") for e in data.r8.values())
    r8_rows = []
    for m in modes2:
        first = True
        keys = ([(m, math.inf)] if (m in data.r6 or (m, math.inf) in data.r8) else []) + [(m, a) for a in data.accels if (m, a) in data.r8]
        for k in keys:
            a = k[1]
            if math.isinf(a):
                e6 = data.r6.get(m)
                if e6 and fin(e6.get("mean")):
                    e = {"mean": e6["mean"], "sd": e6.get("sd"), "rpm": e6.get("rpm"), "n": len(e6.get("trials", [])),
                         "n_cens": e6.get("n_cens", 0), "ceiling": e6.get("max_tested"), "trials": None}
                else:
                    e = data.r8[k]
                cond = "Step Input (R6)"
            else:
                e = data.r8[k]
                cond = f"{fmt(a, 0)} Hz/s"
            row = [mode_short(m) if first else "", cond]
            if have_r8_trials:
                trs = e.get("trials") or []
                row.append(", ".join(("≥ " if c else "") + fhz(v) for v, c in trs if fin(v)) or "-")
            rpm_txt = frpm(e.get("rpm")) if not is_censored_all(e) else f"≥ {frpm(e.get('rpm'))}"
            note = []
            if e.get("n_cens"):
                note.append(f"ถึงเพดาน {e['n_cens']}/{e.get('n') or '-'} ครั้ง")
            if not note:
                note.append("หลุดก้าวทุกครั้ง" if not math.isinf(a) else "Pull-in")
            row += [r8_cell(e), rpm_txt, " ".join(note)]
            r8_rows.append(row)
            first = False
    if r8_rows:
        hdr = ["โหมด", "ความเร่ง"] + (["Pull-out แต่ละครั้ง (Hz)"] if have_r8_trials else []) + ["เฉลี่ย ± SD (Hz)", "ความเร็วรอบ (RPM)", "หมายเหตุ"]
        widths = [1150, 1350] + ([2700] if have_r8_trials else []) + [1700, 1250, 1596]
        doc.table(f"ความถี่สูงสุดก่อนเกิด Loss Step เทียบกับอัตราเร่ง (Step Input และ Ramp เชิงเส้น) แยกตามโหมด" + (f" (เพดาน Ramp {ceil_txt} Hz)" if ceil_txt else ""),
                  hdr, r8_rows, widths, sz=26)
    for fp in data.find_fig("pullin"):
        doc.figure(fp, "ผลการทดสอบ Pull-in แบบก้าวกระโดด (R6)" + (" โหมด " + fig_mode(fp) if fig_mode(fp) else ""))
    for fp in data.find_fig("lossstep"):
        doc.figure(fp, "สัญญาณตามเวลาขณะเกิด Loss Step: ความถี่คำสั่งและ f_echo (บน) ความเร็วรอบทฤษฎีเทียบความเร็วดิบและ LPF (กลาง) และจำนวนก้าวที่สูญหาย (ล่าง)" + (" โหมด " + fig_mode(fp) if fig_mode(fp) else ""))
    doc.figure(next(iter(data.find_fig("pullout")), None),
               "ความถี่สูงสุดก่อนเกิด Loss Step เทียบกับอัตราเร่ง (Step Input และ Ramp) ของโหมด Full Step และ Half Step (ค่าเฉลี่ย ± SD)")

    # ---- Conclusion 2
    h2 = {m: h2_mode(data, m) for m in modes2}
    h2 = {m: v for m, v in h2.items() if v}
    doc.add(h_sec("สรุปผลการทดลอง"))
    c = []
    if data.r6:
        parts = [f"{mode_long(m)} {fhz(e['mean'])} ± {fhz(e.get('sd') or 0)} Hz ({frpm(e.get('rpm'))} RPM)" for m, e in sorted(data.r6.items()) if fin(e.get("mean"))]
        c.append("กรณีออกตัวแบบก้าวกระโดดจากหยุดนิ่ง ความถี่ Pull-in เฉลี่ยเท่ากับ " + " และ ".join(parts))
        if 1 in data.r6 and 2 in data.r6 and fin(data.r6[1].get("mean")) and fin(data.r6[2].get("mean")) and data.r6[1]["mean"] > 0:
            c.append(f"โหมด Half Step ออกตัวได้ที่ความถี่สูงกว่า Full Step {data.r6[2]['mean'] / data.r6[1]['mean']:.2f} เท่า ซึ่งสนับสนุนสมมติฐานที่ 1")
    for m, r in h2.items():
        vals = ", ".join(f"{r8_cell(e)} Hz ที่ {fmt(a, 0)} Hz/s" for a, e in r["rows"])
        s = f"กรณี Ramp ในโหมด {mode_long(m)} ได้ความถี่ Pull-out {vals}"
        if r["ramp_beats_step"]:
            s += f" ทุกค่าสูงกว่ากรณี Step Input ({fhz(r['step'])} Hz)"
        c.append(s)
    verdicts = {r["verdict"] for r in h2.values()}
    if h2:
        if verdicts & {"partial", "contradicted"}:
            c.append("ดังนั้นสมมติฐานที่ 2 ได้รับการสนับสนุนเพียงบางส่วน กล่าวคือการใช้ Ramp ช่วยให้มอเตอร์ไปถึงความถี่สูงกว่าการออกตัวแบบก้าวกระโดดอย่างชัดเจน แต่ความสัมพันธ์ระหว่างอัตราเร่งกับความถี่ Pull-out ไม่เป็นแบบทางเดียว (Non-monotonic) อัตราเร่งที่ต่ำที่สุดไม่ได้ให้ความถี่ Pull-out สูงที่สุด")
        elif verdicts == {"censored"}:
            c.append("ดังนั้นการทดลองยืนยันได้เพียงว่า Ramp ช่วยให้มอเตอร์ไปถึงความถี่สูงกว่า Step Input มาก แต่ไม่สามารถยืนยันส่วนที่ว่าอัตราเร่งต่ำกว่าให้ Pull-out สูงกว่าได้ เพราะทุกกรณีถึงเพดานความถี่ก่อน สมมติฐานที่ 2 จึงได้รับการสนับสนุนเพียงบางส่วน")
        elif "supported" in verdicts:
            c.append("ผลดังกล่าวสนับสนุนสมมติฐานที่ 2 ว่าอัตราเร่งที่ต่ำกว่าให้ความถี่ Pull-out สูงกว่า" + (" ยกเว้นบางโหมดที่ถึงเพดานความถี่ก่อน" if "censored" in verdicts else ""))
        else:
            c.append("ความถี่ Pull-out แทบไม่เปลี่ยนตามอัตราเร่งในช่วงที่ทดสอบ สมมติฐานที่ 2 จึงได้รับการสนับสนุนเพียงบางส่วน")
    doc.add(body(" ".join(c) if c else "ไม่พบตารางผลของการทดลองที่ 2 ในโฟลเดอร์ข้อมูลที่ระบุ", True))

    # ---- Discussion 2
    doc.add(h_sec("อภิปรายผล"))
    if data.r6:
        txt = "ความถี่ Pull-in ที่ต่ำเมื่อเทียบกับกรณี Ramp อธิบายได้จากสมการที่ (8) ขณะสั่งแบบก้าวกระโดด df/dt มีค่าสูงมากในจังหวะเริ่มต้น โรเตอร์ซึ่งหยุดนิ่งต้องเร่งให้ทันสนามแม่เหล็กภายในไม่กี่ก้าว แรงบิดเร่งความเฉื่อยที่ต้องการจึงเกินกว่าแรงบิดที่มอเตอร์สร้างได้"
        if 1 in data.r6 and 2 in data.r6 and fin(data.r6[1].get("rpm")) and fin(data.r6[2].get("rpm")):
            r1, r2 = data.r6[1]["rpm"], data.r6[2]["rpm"]
            txt += f" ที่น่าสังเกตคือเมื่อแปลงเป็นความเร็วรอบ Pull-in ของ Full Step ({frpm(r1)} RPM) และ Half Step ({frpm(r2)} RPM) " + ("ใกล้เคียงกัน แสดงว่าขีดจำกัดการออกตัวขึ้นกับความเร็วเชิงมุมที่โรเตอร์ต้องไล่ให้ทันมากกว่าจำนวนพัลส์ต่อวินาที Half Step จึงรับความถี่พัลส์ได้ราวสองเท่าเพราะแต่ละพัลส์ขยับมุมเพียงครึ่งหนึ่ง" if abs(r1 - r2) <= 0.25 * max(r1, r2) else "แตกต่างกัน แสดงว่านอกจากความเฉื่อยแล้ว ลักษณะแรงบิดแบบขั้นของ Full Step ก็มีผลต่อการออกตัวด้วย")
        if full_res and 1 in data.r6 and fin(data.r6[1].get("mean")):
            txt += f" นอกจากนี้ Pull-in ของ Full Step ({fhz(data.r6[1]['mean'])} Hz) อยู่ใกล้ย่านที่ Full Step หลุดก้าวในการทดลองที่ 1 ({fhz(full_res)} Hz) จึงเป็นไปได้ว่าเรโซแนนซ์ช่วงกลางมีส่วนจำกัดการออกตัวของโหมดนี้ด้วย"
        rs = [(m, t, f) for m, e in data.r6.items() for t, f in e.get("resync", [])]
        if rs:
            m, t, f = rs[0]
            txt += f" ในบางครั้ง (เช่น {mode_long(m)} ครั้งที่ {t}) มอเตอร์กลับมาออกตัวได้ที่ {fhz(f)} Hz หลังจากหลุดก้าวที่ความถี่ต่ำกว่า ซึ่งเป็นลักษณะของการหลุดก้าวจากเรโซแนนซ์เฉพาะย่าน มากกว่าการขาดแรงบิดโดยรวม"
        doc.add(body(txt, True))
    first_para = not data.r6
    for m, r in h2.items():
        if r["verdict"] == "censored":
            doc.add(body(f"สำหรับโหมด {mode_long(m)} ทุกอัตราเร่งไม่เกิด Loss Step จนถึงเพดาน {fhz(r['rows'][0][1].get('ceiling'))} Hz (คิดเป็นความเร็ว ≥ {frpm(r['rows'][0][1].get('rpm'))} RPM)" + (f" ซึ่งสูงกว่า Pull-in แบบก้าวกระโดด ({fhz(r['step'])} Hz) อย่างน้อย {r['rows'][0][1]['ceiling'] / r['step']:.1f} เท่า" if fin(r.get('step')) and r['step'] > 0 and fin(r['rows'][0][1].get('ceiling')) else "") + " ข้อมูลชุดนี้จึงยืนยันประโยชน์ของ Ramp แต่ไม่สามารถใช้แยกผลของอัตราเร่งได้ เพราะค่าที่แท้จริงอยู่เหนือเพดานที่ทดสอบ การทดลองต่อไปควรเพิ่ม MaxFreq จนเกิด Loss Step จริงในทุกอัตราเร่ง", first_para))
            first_para = False
            continue
        tot_n, tot_cens = r.get("total_n", 0), r.get("total_cens", 0)
        if 0 < tot_cens < tot_n:
            ceil_v = next((e.get("ceiling") for _, e in r["rows"] if fin(e.get("ceiling"))), None)
            ceil_rpm = ceil_v * 60.0 / (m * spr) if fin(ceil_v) else None
            per_acc_cens = ", ".join(f"{int(e.get('n_cens') or 0)}/{int(e.get('n') or 0)} ครั้ง ที่ {fmt(a, 0)} Hz/s" for a, e in sorted(r["rows"], reverse=True))
            stalled_f = [v for _, e in r["rows"] for v, c in (e.get("trials") or []) if fin(v) and not c]
            n_stall = tot_n - tot_cens
            stall_txt = ""
            if stalled_f:
                sf_min, sf_max = min(stalled_f), max(stalled_f)
                sr_min, sr_max = sf_min * 60.0 / (m * spr), sf_max * 60.0 / (m * spr)
                f_span = f"{fhz(sf_min)} ถึง {fhz(sf_max)} Hz ({frpm(sr_min)} ถึง {frpm(sr_max)} RPM)" if sf_max > sf_min else f"{fhz(sf_min)} Hz ({frpm(sr_min)} RPM)"
                stall_txt = f" ส่วนอีก {n_stall}/{tot_n} ครั้ง เกิดการหลุดก้าวจริงที่ความถี่สูงใกล้เพดานในช่วง {f_span}"
            means = [e["mean"] for _, e in r["rows"] if fin(e.get("mean"))]
            m_span = f"≥ {fhz(min(means))} ถึง ≥ {fhz(max(means))} Hz" if means else "-"
            step_ratio = (f" สูงกว่าค่า Pull-in แบบก้าวกระโดด ({fhz(r['step'])} Hz) ประมาณ {min(means) / r['step']:.1f} ถึง {max(means) / r['step']:.1f} เท่า" if fin(r.get("step")) and r["step"] > 0 and means else "")
            doc.add(body(f"สำหรับโหมด {mode_long(m)} เมื่อขยายเพดานความถี่ของ Ramp เป็น {fhz(ceil_v)} Hz ({frpm(ceil_rpm)} RPM) พบว่าส่วนใหญ่ถึงเพดานความถี่โดยไม่เกิด Loss Step รวม {tot_cens}/{tot_n} ครั้ง ในช่วงอัตราเร่ง {fmt(r['low_a'], 0)} ถึง {fmt(r['high_a'], 0)} Hz/s (ได้แก่ {per_acc_cens}){stall_txt} ส่งผลให้ค่าเฉลี่ยของแต่ละอัตราเร่งอยู่ในช่วง {m_span}{step_ratio} ข้อมูลนี้แสดงว่าโหมด {mode_long(m)} สามารถไต่ความถี่ผ่านย่านเรโซแนนซ์ขึ้นสู่ความเร็วสูงใกล้ขีดจำกัดเพดาน {fhz(ceil_v)} Hz ได้อย่างเสถียรในเกือบทุกรอบการทดลอง", first_para))
            first_para = False
            continue
        la, le, ba, be, ha, he = r["low_a"], r["low_e"], r["best_a"], r["best_e"], r["high_a"], r["high_e"]
        txt = f"สำหรับโหมด {mode_long(m)} ความถี่ Pull-out สูงสุดเกิดที่อัตราเร่ง {fmt(ba, 0)} Hz/s ({r8_cell(be)} Hz)"
        if r["verdict"] in ("partial", "contradicted") and ba != la:
            drop = 100.0 * (1 - le["mean"] / be["mean"]) if be["mean"] else 0
            txt += f" ส่วนอัตราเร่งต่ำสุด {fmt(la, 0)} Hz/s ให้ค่าเพียง {r8_cell(le)} Hz (ต่ำกว่าค่าสูงสุดร้อยละ {fmt(drop, 0)}) ซึ่งขัดกับสมมติฐานที่ 2 โดยตรง"
            res_f = lost_freqs(data, m)
            if res_f and le["mean"] < 2.0 * res_f[0]:
                txt += f" ค่านี้อยู่ใกล้ย่านที่โหมด {mode_long(m)} หลุดก้าวในการทดลองที่ 1 (ประมาณ {fhz(res_f[0])} Hz) แสดงว่ามอเตอร์ติดอยู่ในย่านเรโซแนนซ์ช่วงกลาง เมื่อเร่งช้า มอเตอร์ใช้เวลาผ่านช่วง ±100 Hz รอบย่านนี้นานถึง {200.0 / la:.2f} วินาที เทียบกับเพียง {200.0 / ba:.2f} วินาทีที่ {fmt(ba, 0)} Hz/s การแกว่งของโรเตอร์จึงมีเวลาสะสมพลังงานจนหลุดก้าว ในขณะที่ Ramp ที่เร็วกว่าพาโรเตอร์ผ่านย่านนี้ไปก่อนที่การแกว่งจะขยายตัว"
            else:
                txt += f" เนื่องจาก Ramp ที่ช้ากว่าทำให้มอเตอร์ใช้เวลาในย่านความถี่กลางนานขึ้น ({200.0 / la:.2f} วินาทีต่อช่วง 200 Hz เทียบกับ {200.0 / ba:.2f} วินาทีที่ {fmt(ba, 0)} Hz/s) การแกว่งจากเรโซแนนซ์จึงมีเวลาขยายตัวจนหลุดก้าว"
        if ha != ba and he["mean"] < be["mean"]:
            txt += f" ในอีกด้านหนึ่ง เมื่อเพิ่มอัตราเร่งเป็น {fmt(ha, 0)} Hz/s ความถี่ Pull-out ลดลงเหลือ {r8_cell(he)} Hz เพราะความเร่งเชิงมุมที่ต้องการตามสมการที่ (8) เพิ่มจาก {fmt(alpha(m, spr, ba), 1)} เป็น {fmt(alpha(m, spr, ha), 1)} rad/s² พจน์ J_total · α จึงกินแรงบิดที่มีอยู่มากขึ้น ในขณะที่แรงบิดของมอเตอร์ลดลงตามความถี่จาก Back-EMF และความเหนี่ยวนำ จุดที่แรงบิดคงเหลือไม่พอจึงเกิดที่ความถี่ต่ำลง ซึ่งเป็นส่วนที่สอดคล้องกับสมมติฐานที่ 2"
        verdict_txt = {"partial": "ผลรวมจึงเป็นแนวโน้มแบบไม่เป็นทางเดียว (Non-monotonic) มีอัตราเร่งที่เหมาะสมอยู่ช่วงกลาง สมมติฐานที่ 2 จึงได้รับการสนับสนุนเพียงบางส่วน: เป็นจริงเฉพาะเมื่ออัตราเร่งสูงกว่าค่าที่เหมาะสม แต่ไม่จริงเมื่อ Ramp ช้าจนมอเตอร์ค้างในย่านเรโซแนนซ์",
                       "contradicted": "ในช่วงที่ทดสอบ แนวโน้มจึงกลับทิศกับสมมติฐานที่ 2 คืออัตราเร่งสูงขึ้นกลับได้ความถี่ Pull-out สูงขึ้น เนื่องจากผลของเรโซแนนซ์มีน้ำหนักมากกว่าผลของความเฉื่อย สมมติฐานที่ 2 จึงได้รับการสนับสนุนเพียงบางส่วนเท่านั้น (เฉพาะส่วนที่ Ramp ดีกว่า Step Input)",
                       "supported": "แนวโน้มในโหมดนี้จึงสอดคล้องกับสมมติฐานที่ 2",
                       "flat": "ความแตกต่างระหว่างอัตราเร่งอยู่ในระดับเดียวกับความแปรปรวนระหว่างการทดลองซ้ำ จึงยังสรุปผลของอัตราเร่งในโหมดนี้ไม่ได้ชัดเจน"}[r["verdict"]]
        sds = [e.get("sd") for _, e in r["rows"] if fin(e.get("sd"))]
        if sds:
            worst = max(r["rows"], key=lambda t: t[1].get("sd") or 0)
            verdict_txt += f" ด้านความซ้ำได้ ส่วนเบี่ยงเบนมาตรฐานสูงสุดเท่ากับ {fhz(worst[1]['sd'])} Hz ที่ {fmt(worst[0], 0)} Hz/s ซึ่งสะท้อนว่าจุดหลุดก้าวใกล้ย่านเรโซแนนซ์และใกล้ขีดจำกัดแรงบิดมีความไวต่อสภาวะเริ่มต้นของการแกว่ง"
        doc.add(body(txt + " " + verdict_txt, first_para))
        first_para = False
    if 1 in h2 and 2 in h2:
        doc.add(body("เมื่อเปรียบเทียบสองโหมด Half Step ทนต่อการหลุดก้าวได้ดีกว่า Full Step อย่างชัดเจนทั้งในกรณี Step Input และ Ramp เพราะกระแสเปลี่ยนเป็นขั้นเล็กกว่าจึงกระตุ้นเรโซแนนซ์น้อยกว่า และความเร่งเชิงมุมต่อหน่วยอัตราเร่ง (Hz/s) มีค่าเพียงครึ่งหนึ่งตามสมการที่ (8) ในงานจริงหากต้องการความเร็วสูงจึงควรใช้ Half Step หรือ Microstep ร่วมกับ Ramp ที่มีอัตราเร่งพอเหมาะ แทนการลดอัตราเร่งลงเพียงอย่างเดียว"))

    # ---- Suggestions
    doc.add(h_sec("ข้อเสนอแนะ"))
    for t in [
        "ควรตั้งค่า EN = 1 ทุกครั้งหลังหยุดการทดลอง (โมเดลทำให้อัตโนมัติผ่าน StopFcn) เพื่อตัดกระแสขับและป้องกันความร้อนสะสมที่มอเตอร์และ DRV8825 ซึ่งอาจทำให้แรงบิดเปลี่ยนระหว่างการทดลองซ้ำ",
        "ควรทดสอบ Pull-out ซ้ำด้วยอัตราเร่งที่ละเอียดขึ้นรอบค่าที่เหมาะสม และใช้โปรไฟล์ S-Curve หรือการเร่งเร็วเฉพาะช่วงผ่านย่านเรโซแนนซ์ เพื่อยืนยันกลไกของแนวโน้มแบบไม่เป็นทางเดียว",
        "ควรเพิ่มเพดานความถี่ของ Ramp สำหรับโหมด Half Step และ Microstep จนเกิด Loss Step จริง เพื่อให้ได้ค่า Pull-out ที่ไม่ถูกตัดที่เพดาน",
        "ควรตรวจสอบมุมก้าวจาก Datasheet ของมอเตอร์ (ค่า StepsPerRev) และติดตั้งเซนเซอร์กระแสบนสายเฟสของ Stepper Motor แทนการใช้ PA1 ซึ่งอยู่บนเส้นทางของ DC Motor",
        "สำหรับงานที่ห้ามเกิด Loss Step ควรนำสัญญาณ Encoder มาควบคุมแบบวงปิด (Closed-Loop Stepper) หรือใช้ตัวนับ lost_steps เป็นสัญญาณเตือน และเพิ่มการทดสอบภายใต้โหลดเชิงกลเพื่อสร้างเส้นโค้ง Pull-in/Pull-out Torque-Speed จริง",
    ]:
        doc.add(p(run(t), num_id=1, left=360))

    doc.add(h_sec("อ้างอิง"))
    for url in [
        "https://github.com/MINIFI2548/FRA271_LAB2_ACTUATOR_FRAB12",
        "https://github.com/kitakitadesu/lab2",
        "https://www.ti.com/lit/ds/symlink/drv8825.pdf",
        "https://www.pololu.com/product/2982/faqs",
        "https://www.sameskydevices.com/product/resource/amt10.pdf",
        "https://www.orientalmotor.com/stepper-motors/technology/stepper-motor-basics.html",
        "https://www.ti.com/lit/an/slva488a/slva488a.pdf",
    ]:
        doc.add(p(run(url), jc="left"))

    build_appendix(doc, data, args)


def fig_mode(path):
    b = os.path.basename(path)
    if "Full_vs_Half" in b or ("Full" in b and "Half" in b):
        return "Full Step และ Half Step"
    for key, name in (("M1_Full", "Full Step"), ("M2_Half", "Half Step"), ("_Full", "Full Step"), ("_Half", "Half Step")):
        if key in b:
            return name
    return ""


def build_appendix(doc, data, args):
    spr = data.spr
    doc.add(h_lab("ภาคผนวก ก: โปรแกรมและวงจรควบคุม Stepper Motor บน Simulink", page_break=True))
    doc.add(h_sec("1. สถาปัตยกรรมฮาร์ดแวร์และการเชื่อมต่อสัญญาณ"))
    doc.add(body("ระบบใช้บอร์ด Nucleo STM32G474RE กับเฟิร์มแวร์ motorxplorer.bin สื่อสารกับ Simulink ผ่าน ST-Link Virtual COM Port ที่ 2,000,000 bps (8N1) ด้วยแพ็กเก็ตไบนารีของไลบรารี Waijung (Host Serial Setup, Host Serial Rx1, Host Serial Tx) บอร์ดสร้างพัลส์ความถี่แปรผันทางขา PC8 (TIM20_CH3) ไปยังขา STEP ของ DRV8825 อ่านความเร็วเชิงมุมจาก Encoder AMT103-V ผ่าน Timer 3 (PA6/PA7) และส่งค่าความถี่ที่สร้างจริงกลับมาเป็นสัญญาณ Stepper Frequency (echo) สรุปการเชื่อมต่อในตารางที่ ก.1", True))
    doc.table("สรุปการเชื่อมต่อขาสัญญาณระหว่าง Nucleo STM32G474RE กับ DRV8825 และ AMT103-V",
              ["อุปกรณ์", "ขาอุปกรณ์", "ขา STM32G474RE", "หน้าที่และชนิดข้อมูลใน Simulink"],
              [["DRV8825", "STEP", "PC8 (TIM20_CH3)", "ความถี่สัญญาณขับ (Stepper Frequency, single)"],
               ["DRV8825", "M0, M1, M2", "PB15, PB14, PB13", "กำหนดโหมด Microstep 0/1 (int16)"],
               ["DRV8825", "DIR", "PB2", "ทิศทางการหมุน 0/1 (int16)"],
               ["DRV8825", "EN", "PB1", "0 = เปิดขับ, 1 = ปิดขับ (int16)"],
               ["AMT103-V", "A, B (5V, GND)", "PA7, PA6 (3V3, GND)", "ความเร็วเชิงมุมเพลา (Motor Angular Velocity, rad/s, single)"],
               ["เซนเซอร์กระแส", "OUT", "PA1 (ADC)", "Current (PA1) อยู่บนเส้นทาง DC Motor ไม่ใช่กระแสเฟส Stepper"],
               ["ST-Link VCP", "UART TX/RX", "PA2, PA3", "2,000,000 bps 8N1, Simulink Fixed-step 0.001 s"]],
              [1600, 1750, 2150, 4246], ["center", "center", "center", "left"], label="ตารางที่ ก.1")

    doc.add(h_sec("2. ชุดโมเดลแบบ Scheduler: MotorXploer_Stepper.slx และโมเดลประจำหัวข้อ"))
    doc.add(body("ชุดโมเดลประกอบด้วยไฟล์หลัก MotorXploer_Stepper.slx และไฟล์ประจำหัวข้อการทดลอง 6 ไฟล์ในโฟลเดอร์ stepper_motor/ ทั้ง 7 ไฟล์สร้างขึ้นอัตโนมัติจากโมเดลต้นแบบ MotorXploer.slx ของผู้สอนด้วยสคริปต์ tools/build_stepper_suite.m (บันทึกเป็นรูปแบบ R2025b) และมีโครงสร้างภายในเหมือนกันทุกประการ ต่างกันเพียงค่าเริ่มต้นของ Exp Mode และ StopTime ตามตารางที่ ก.2 การรันจริงทำผ่าน run_stepper_labs ซึ่งตั้งค่าพอร์ต Exp Mode, Drive Mode, Accel Limit, Max Freq และ Full steps per rev ก่อนเรียก sim ทุกครั้ง ผู้ใช้จึงไม่ต้องแก้ไขบล็อกด้วยมือหรือเปิด/ปิด (Comment) บล็อกใดๆ เหมือนโมเดลรุ่นก่อน", True))
    doc.table("ไฟล์โมเดลในชุด Scheduler และค่าเริ่มต้นของแต่ละไฟล์",
              ["ไฟล์โมเดล", "Exp Mode", "StopTime (s)", "หน้าที่"],
              [["MotorXploer_Stepper.slx", "0", "inf", "โมเดลหลัก ใช้ได้ทุก Exp Mode 0 ถึง 5 ค่าเริ่มต้นเป็นโหมดควบคุมด้วยมือที่ปลอดภัย (Manual EN = 1)"],
               ["R0_Baseline_Calibration.slx", "1", "6", "บันทึกค่าศูนย์ PA1/PA0/ความเร็ว ขณะหยุดนิ่ง 5 s (EN = 1, f = 0 Hz)"],
               ["R3_DriveModes_RealOp.slx", "2", "38", "ขับครบ 6 โหมดที่ Manual Freq โหมดละ 4 s สลับพัก EN = 1 2 s"],
               ["R4_R5_FreqVsSpeed.slx", "3", "37", "ขั้นบันไดความถี่ 200 ถึง 1,600 Hz ระดับละ 4 s เปลี่ยนระดับด้วย Accel Limit"],
               ["R6_LossStep_PullIn.slx", "4", "44", "ก้าวกระโดดจากหยุดนิ่ง 200 ถึง 2,400 Hz (10 ระดับ) ระดับละ 2.5 s พัก EN = 1 1.5 s"],
               ["R8_Accel_PullOut.slx", "5", "12*", "ค้าง 200 Hz 0.5 s แล้ว Ramp ถึง Max Freq ด้วย Accel Limit ค้าง 1 s แล้ว EN = 1"],
               ["R14_Control_PerMode.slx", "0", "inf", "ควบคุมด้วยมือ (Manual Freq, Drive Mode, DIR, EN) สำหรับสาธิตแต่ละโหมด"]],
              [2700, 1000, 1250, 4796], ["left", "center", "center", "left"], label="ตารางที่ ก.2")
    doc.add(body("* สำหรับ R8 สคริปต์ run_stepper_labs คำนวณ StopTime ใหม่ทุกรอบจาก ceil(1.5 + 0.5 + (MaxFreq − 200)/Accel + 3.0) วินาที เพื่อให้ Ramp ครบถึงเพดานความถี่", True))

    doc.add(h_sec("3. การไหลของสัญญาณภายในโมเดล"))
    doc.add(body("ภายในแต่ละโมเดลแบ่งเป็น 5 พื้นที่ ดังสรุปในตารางที่ ก.3 และภาพที่ ก.1 แนวคิดหลักคือให้บล็อก MATLAB Function ชื่อ Experiment Scheduler ซึ่งขับด้วยนาฬิกา (Digital Clock, 0.001 s) เป็นผู้สร้างคำสั่งทั้งหมดตามเวลา แล้วส่งผ่าน Goto/From Tag (f_cmd, M0, M1, M2, DIR, EN) เข้ากรอบ Output to Nucleo-G474RE ของโมเดลต้นแบบ แทนบล็อกค่าคงที่เดิม โดยไม่เปลี่ยนชนิดข้อมูลขาเข้า Host Serial Tx (single 3 ช่อง และ int16 5 ช่อง) สัญญาณขาเข้าจากบอร์ด (omega, adc_i, f_echo) ถูกบันทึก (Signal Logging) และกระจายผ่าน Goto Tag ไปยังพื้นที่คำนวณ", True))
    doc.table("หน้าที่ของแต่ละพื้นที่ (Area) ในโมเดลแบบ Scheduler",
              ["พื้นที่ในโมเดล", "องค์ประกอบหลัก", "การทำงาน"],
              [["Exp Mode Guide", "Annotation", "คำอธิบาย Exp Mode 0 ถึง 5, ตารางขา M0 M1 M2 ของ Drive Mode 1 ถึง 6 และความหมายของสัญญาณ step_id, is_steady, lost_steps"],
               ["Experiment Scheduler (Clock)", "Digital Clock, ค่าคงที่ Exp Mode, Drive Mode, Accel Limit (Hz per s), Max Freq (Hz), Manual Freq/DIR/EN, MATLAB Function experiment_scheduler",
                "สร้าง freq_cmd, m0/m1/m2_cmd, dir_cmd, en_cmd ตามเวลาและ Exp Mode พร้อมสัญญาณกำกับ microstep_M, target_freq, accel_hz_s, is_steady (ช่วงสภาวะคงตัว) และ step_id (0 = พัก, 1..N = ลำดับขั้น, 99 = จบ) ส่งต่อด้วย Goto Tag"],
               ["MotorXploler Interface (ต้นแบบ)", "Host Serial Setup/Rx1/Tx, กรอบ Input/Output to Nucleo-G474RE",
                "รับคำสั่งจาก From Tag แปลงชนิดข้อมูลแล้วส่งเข้าบอร์ด รับ Motor Angular Velocity, Current (PA1), Load Cell (PA0), Stepper Frequency (echo) กลับมาและบันทึกข้อมูล"],
               ["Current (ADC to A)", "MATLAB Function current_adc_to_amps",
                "I = (ADC − 2137.5638) / 66.3185 (อัตราขยายจาก DC Motor) ค่าศูนย์แก้ด้วย R0 ภายหลัง ใช้เป็นข้อมูลประกอบเท่านั้นเพราะไม่ใช่กระแสเฟส Stepper"],
               ["Stepper Kinematics & Loss Step", "Product, Gain, Abs, Discrete Filter, Discrete-Time Integrator 2 ตัว (External Reset แบบ level)",
                f"rpm_theory = f_echo × 60 / (M × {spr}); rpm_meas = |ω| × 60 / 2π (ดิบ); rpm_meas_lpf = Butterworth อันดับ 2, 10 Hz, Ts = 1 ms; lost_steps = (รอบที่สั่ง − |รอบจริง|) × {spr} โดยอินทิเกรเตอร์ทั้งสองถูกรีเซ็ตตลอดเวลาที่ EN = 1"]],
              [2300, 3000, 4446], ["left", "left", "left"], label="ตารางที่ ก.3")
    sim_png = next(iter(data.find_fig("simulink", extra_dirs=[os.path.join(REPO, "stepper_data", "report_final")])), None)
    doc.figure(sim_png, "ผังบล็อก Simulink ของ MotorXploer_Stepper.slx: Experiment Scheduler (ซ้ายล่าง) ส่งคำสั่งผ่าน Goto/From เข้ากรอบ MotorXploler Interface (กลาง) และพื้นที่ Current กับ Stepper Kinematics & Loss Step (ขวา)",
               label="ภาพที่ ก.1")

    doc.add(h_sec("4. รายละเอียดการทำงานของ Experiment Scheduler"))
    for t in [
        "Exp Mode 0 (Manual/R14): ส่ง Manual Freq, Manual DIR และ Manual EN ตรงไปยังบอร์ด ค่าเริ่มต้น Manual EN = 1 ทำให้โมเดลปลอดภัยเมื่อเปิดใช้งาน",
        "Exp Mode 1 (R0): f = 0 Hz และ EN = 1 ตลอด 5 วินาที โดย is_steady = 1 ในช่วง 0.5 ถึง 5.0 วินาที เพื่อเฉลี่ยค่าศูนย์ของเซนเซอร์",
        "Exp Mode 2 (R3): หลังเริ่มต้น 1.5 วินาที วนครบ Drive Mode 1 ถึง 6 ช่องละ 6 วินาที (เปิดขับ 4 วินาทีด้วย Ramp ตาม Accel Limit, พัก EN = 1 อีก 2 วินาที) และ is_steady = 1 ในช่วง 1.2 ถึง 3.9 วินาทีของแต่ละช่อง",
        "Exp Mode 3 (R4/R5): ขั้นบันได 200 ถึง 1,600 Hz ขั้นละ 200 Hz ระดับละ 4 วินาที เปลี่ยนระดับด้วย Accel Limit และ is_steady = 1 ในช่วง 1.5 ถึง 3.9 วินาทีของแต่ละระดับ",
        "Exp Mode 4 (R6): ก้าวกระโดดจากหยุดนิ่งไปยัง 200, 400, 600, 800, 1,000, 1,200, 1,400, 1,600, 2,000 และ 2,400 Hz โดยไม่จำกัดความเร่ง เปิดขับ 2.5 วินาทีสลับพัก EN = 1 อีก 1.5 วินาที ซึ่งรีเซ็ต lost_steps ก่อนทุกระดับ",
        "Exp Mode 5 (R8): ค้าง 200 Hz 0.5 วินาที (แก้ปัญหา Timer preload ของเฟิร์มแวร์ที่ค้างคาบ 1/f₁ ของคำสั่งแรก) แล้วเพิ่มความถี่ 200 Hz + Accel × t จนถึง Max Freq ค้าง 1 วินาที แล้ว EN = 1",
        "ความถี่คำสั่งทุกโหมดถูกจำกัดในช่วง 0 ถึง 20,000 Hz และ Drive Mode ถูกแปลงเป็นขา M0 M1 M2 ตามตารางความจริง DRV8825 (1 = Full ถึง 6 = 1/32) ภายในฟังก์ชันเดียวกัน",
    ]:
        doc.add(bullet(t, num_id=58))

    doc.add(h_sec("5. การตั้งค่า Solver และระบบความปลอดภัย"))
    doc.add(body("ทุกโมเดลใช้ Solver แบบ Fixed-step Discrete คาบ 0.001 s เปิด Simulation Pacing ให้เวลาจำลองเท่ากับเวลาจริง และเปิด Signal Logging สำหรับ freq_cmd, EN, microstep_M, target_freq, accel_hz_s, is_steady, step_id, rpm_theory, rpm_meas, rpm_meas_lpf, lost_steps, Current (A) และสัญญาณ Rx ทั้ง 5 ช่อง ข้อมูลทั้งหมดถูกบันทึกลงไฟล์ .mat (logsout + meta) หนึ่งไฟล์ต่อหนึ่งรอบ แล้ว analyze_stepper_labs ส่งออกเป็นตาราง CSV ไฟล์ CSV ดิบ 1 kHz และกราฟ", True))
    doc.add(body("โมเดลมี Callback ชื่อ StopFcn ซึ่งทำงานทุกครั้งที่การจำลองหยุด ไม่ว่าจะหยุดตามเวลา กด Stop หรือเกิดข้อผิดพลาด StopFcn จะเปิดพอร์ตอนุกรมเดียวกันแล้วส่งเฟรมคำสั่ง PWM = 0, Stepper Freq = 0 Hz, M0 = M1 = M2 = 0, DIR = 0 และ EN = 1 ซ้ำ 3 ครั้ง เพื่อหยุดพัลส์และปิดไดรเวอร์ทันที ป้องกันไม่ให้มอเตอร์ค้างกระแสหรือหมุนต่อหลังจบการทดลอง"))

    # ---- Appendix B: data provenance
    doc.add(h_lab("ภาคผนวก ข: แหล่งข้อมูลและค่าสอบเทียบ", page_break=True))
    rels = [os.path.relpath(d, REPO) if os.path.abspath(d).startswith(REPO) else d for d in data.data_dirs]
    doc.add(body("ตัวเลข ตาราง และกราฟในรายงานนี้สร้างโดยอัตโนมัติด้วย tools/build_report_final.py จากผลประมวลผลของ analyze_stepper_labs และ tools/make_report_figures.m ในโฟลเดอร์ข้อมูลต่อไปนี้: " + ", ".join(rels), True))
    if data.r0:
        r0 = data.r0
        doc.table("ค่าสอบเทียบจากการทดลอง R0 (มอเตอร์หยุดนิ่ง, EN = 1)",
                  ["รายการ", "ค่าเฉลี่ย", "SD", "หน่วย"],
                  [["PA1 (Current) zero", fmt(num(r0.get("PA1_Zero_Counts")), 2), fmt(num(r0.get("PA1_SD_Counts")), 2), "counts"],
                   ["PA0 (Load Cell) zero", fmt(num(r0.get("PA0_Zero_Counts")), 2), fmt(num(r0.get("PA0_SD_Counts")), 2), "counts"],
                   ["ความเร็วเชิงมุม zero", fmt(num(r0.get("Omega_Zero_rad_s")), 4), fmt(num(r0.get("Omega_SD_rad_s")), 4), "rad/s"],
                   ["อัตราขยายกระแส (จาก DC Motor)", fmt(num(r0.get("ADC_Per_A")), 4), "-", "counts/A"]],
                  [3600, 2000, 2000, 2146], ["left", "center", "center", "center"], label="ตารางที่ ข.1")
    doc.add(body(f"สมมติฐานในการคำนวณ: มอเตอร์ {spr} ก้าวเต็มต่อรอบ ({360.0 / spr:.2f}°/ก้าว), Encoder {ENC_CPR:,} counts ต่อรอบ, คาบสุ่ม 1 ms และตัวกรอง LPF Butterworth อันดับ 2 ที่ 10 Hz สัมประสิทธิ์ b = [{LPF_B[0]:.6f}, {LPF_B[1]:.6f}, {LPF_B[2]:.6f}], a = [1, {LPF_A[1]:.6f}, {LPF_A[2]:.6f}]"))


# =============================================================================
# DOCX packaging
# =============================================================================
def patch_numbering(num_xml):
    adds = []
    for nid, abs_id in [(52, 15), (53, 15), (54, 15), (55, 15), (56, 50), (57, 50), (58, 15)]:
        if f'w:numId="{nid}"' in num_xml:
            continue
        adds.append(f'<w:num w:numId="{nid}"><w:abstractNumId w:val="{abs_id}"/>'
                    '<w:lvlOverride w:ilvl="0"><w:startOverride w:val="1"/></w:lvlOverride></w:num>')
    i = num_xml.rfind("</w:numbering>")
    return num_xml[:i] + "".join(adds) + num_xml[i:]


def patch_footer(ftr_xml):
    page_rpr = rpr(sz=28)
    ftr_xml = ftr_xml.replace('<w:r><w:instrText xml:space="preserve"> PAGE   \\* MERGEFORMAT </w:instrText></w:r>',
                              f'<w:r>{page_rpr}<w:instrText xml:space="preserve"> PAGE   \\* MERGEFORMAT </w:instrText></w:r>')
    return ftr_xml.replace("<w:r><w:rPr><w:noProof/></w:rPr><w:t>2</w:t></w:r>", f"<w:r>{page_rpr}<w:t>1</w:t></w:r>")


def write_docx(template, out_path, body_builder):
    work = tempfile.mkdtemp(prefix="stepper_report_final_")
    try:
        with zipfile.ZipFile(template) as zf:
            zf.extractall(work)
        doc_path = os.path.join(work, "word", "document.xml")
        with open(doc_path, encoding="utf-8") as fh:
            doc_xml = fh.read()
        m_open = re.search(r"^(.*?<w:body>)", doc_xml, flags=re.S)
        m_sect = re.search(r"(<w:sectPr\b.*?</w:sectPr>)\s*</w:body>\s*</w:document>", doc_xml, flags=re.S)
        if not (m_open and m_sect):
            raise RuntimeError("Failed to parse template document.xml")
        m_p0 = re.search(r"<w:p\b.*?</w:p>", doc_xml[m_open.end():], flags=re.S)
        doc = body_builder(m_p0.group(0))
        new_doc = f"{m_open.group(1)}{doc.xml()}{m_sect.group(1)}</w:body></w:document>"
        ET.fromstring(new_doc.encode("utf-8"))
        with open(doc_path, "w", encoding="utf-8") as fh:
            fh.write(new_doc)

        for rel, fn in (("numbering.xml", patch_numbering), ("footer1.xml", patch_footer)):
            pth = os.path.join(work, "word", rel)
            if os.path.isfile(pth):
                with open(pth, encoding="utf-8") as fh:
                    x = fn(fh.read())
                ET.fromstring(x.encode("utf-8"))
                with open(pth, "w", encoding="utf-8") as fh:
                    fh.write(x)

        media_dir = os.path.join(work, "word", "media")
        os.makedirs(media_dir, exist_ok=True)
        rels_path = os.path.join(work, "word", "_rels", "document.xml.rels")
        with open(rels_path, encoding="utf-8") as fh:
            rels = fh.read()
        entries = []
        for rid, src, media in doc.images:
            shutil.copyfile(src, os.path.join(media_dir, media))
            entries.append(f'<Relationship Id="{rid}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/{media}"/>')
        rels = rels.replace("</Relationships>", "".join(entries) + "</Relationships>")
        ET.fromstring(rels.encode("utf-8"))
        with open(rels_path, "w", encoding="utf-8") as fh:
            fh.write(rels)

        os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)
        tmp_out = out_path + ".tmp"
        with zipfile.ZipFile(tmp_out, "w", zipfile.ZIP_DEFLATED) as zout:
            ct = os.path.join(work, "[Content_Types].xml")
            zout.write(ct, "[Content_Types].xml")
            for root, _, files in os.walk(work):
                for fn in sorted(files):
                    fp = os.path.join(root, fn)
                    arc = os.path.relpath(fp, work).replace(os.sep, "/")
                    if arc != "[Content_Types].xml":
                        zout.write(fp, arc)
        os.replace(tmp_out, out_path)
        return doc
    finally:
        shutil.rmtree(work, ignore_errors=True)


LEFTOVER_RE = re.compile(r"\[(?:\.\.\.|…|รอ|placeholder|บันทึก)[^\]]*\]|\bTBD\b|\bxxx\b|\bXXX\b|\[\s*\.\.\.\s*±\s*\.\.\.\s*\]", re.I)


def self_check(out_path):
    with zipfile.ZipFile(out_path) as z:
        xml = z.read("word/document.xml").decode("utf-8")
        names = set(z.namelist())
    text = " ".join(re.findall(r"<w:t[^>]*>([^<]*)</w:t>", xml))
    hits = sorted(set(LEFTOVER_RE.findall(text)))
    rids = set(re.findall(r'r:embed="([^"]+)"', xml))
    return text, hits, rids, names


# =============================================================================
# CLI
# =============================================================================
def resolve(pth):
    return pth if os.path.isabs(pth) else os.path.join(REPO, pth)


def main(argv=None):
    ap = argparse.ArgumentParser(description="Build Lab2_2_Stepper_Motor_Report.docx from analyzed CSVs and report figures.")
    ap.add_argument("--data-dir", action="append", default=None,
                    help="analyzed run folder containing tables/*.csv (repeatable; later folders override earlier ones "
                         "for R6/R8 of the same drive mode). Default: stepper_data/final_5trials")
    ap.add_argument("--legacy", action="store_true",
                    help="use the committed 3-trial + LPF folders: " + ", ".join(LEGACY_DIRS))
    ap.add_argument("--fig-dir", action="append", default=None,
                    help="folder with 300-dpi report figures + Raw_vs_LPF_R3_metrics.csv (repeatable). "
                         "Default: <first data-dir>/report_final if it exists, else stepper_data/report_final")
    ap.add_argument("--template", default="Report+Format.docx")
    ap.add_argument("--out", default="Lab2_2_Stepper_Motor_Report.docx")
    ap.add_argument("--steps-per-rev", type=float, default=200.0)
    ap.add_argument("--ceiling-hz", type=float, default=None,
                    help="R8 ramp ceiling (MaxFreq) when it cannot be read from tables/queue.json/raw_csv")
    ap.add_argument("--author", action="append", default=None,
                    help='cover-page member line, e.g. --author "นาย ก ข 67340500001" (repeatable)')
    ap.add_argument("--strict", action="store_true", help="fail if a figure or a results table is missing")
    args = ap.parse_args(argv)

    if args.legacy:
        data_dirs = [resolve(d) for d in LEGACY_DIRS] + [resolve(d) for d in (args.data_dir or [])]
    elif args.data_dir:
        data_dirs = []
        for raw_d in args.data_dir:
            d = resolve(raw_d)
            if os.path.isdir(os.path.join(d, "tables")):
                data_dirs.append(d)
            elif os.path.isdir(os.path.join(d, "final_5trials", "tables")):
                data_dirs.append(os.path.join(d, "final_5trials"))
            else:
                sub_leg = [os.path.join(d, os.path.basename(ld)) for ld in LEGACY_DIRS
                           if os.path.isdir(os.path.join(d, os.path.basename(ld), "tables"))]
                if sub_leg:
                    data_dirs.extend(sub_leg)
                else:
                    data_dirs.append(d)
    else:
        def_d = resolve("stepper_data/final_5trials")
        if os.path.isdir(os.path.join(def_d, "tables")):
            data_dirs = [def_d]
        else:
            warn(f"{def_d}/tables not found; falling back to legacy 3-trial + LPF folders.")
            data_dirs = [resolve(d) for d in LEGACY_DIRS]
    for d in data_dirs:
        if not os.path.isdir(os.path.join(d, "tables")):
            sys.exit(f"ERROR: no analyzed tables in {d}/tables - run analyze_stepper_labs('{d}') first "
                     f"(or use --legacy for the committed 3-trial data).")
    fig_dirs = []
    if args.fig_dir:
        fig_dirs.extend(resolve(f) for f in args.fig_dir)
    for d in reversed(data_dirs):
        cand = os.path.join(d, "report_final")
        if os.path.isdir(cand) and cand not in fig_dirs:
            fig_dirs.append(cand)
    def_fig = resolve("stepper_data/report_final")
    if os.path.isdir(def_fig) and def_fig not in fig_dirs:
        fig_dirs.append(def_fig)
    for d in reversed(data_dirs):
        cand = os.path.join(d, "figures")
        if os.path.isdir(cand) and cand not in fig_dirs:
            fig_dirs.append(cand)
    template = resolve(args.template)
    out = resolve(args.out)
    if os.path.abspath(out) == os.path.abspath(DRAFT_DOCX):
        sys.exit("ERROR: refusing to overwrite the draft report; choose another --out")
    if not os.path.isfile(template):
        sys.exit(f"ERROR: template not found: {template}")

    spr = int(args.steps_per_rev) if float(args.steps_per_rev).is_integer() else args.steps_per_rev
    data = Data(data_dirs, fig_dirs, spr, args.ceiling_hz)
    if not data.files_used:
        sys.exit("ERROR: no analyzed CSV tables found in " + ", ".join(data_dirs))
    authors = args.author or [
        "สมาชิกกลุ่มที่ 1 (FRA271 Lab 2.2: Stepper Motor)",
        "สมาชิกกลุ่มที่ 2 (FRA271 Lab 2.2: Stepper Motor)",
        "สมาชิกกลุ่มที่ 3 (FRA271 Lab 2.2: Stepper Motor)",
    ]
    missing_tables = [n for n, k in (("R3", data.r3), ("R4_R5", data.r4), ("R6", data.r6), ("R8", data.r8)) if not k]
    if missing_tables:
        (sys.exit if args.strict else warn)(f"missing analyzed results for: {', '.join(missing_tables)}")

    def builder(cover_p0):
        doc = Doc(args.strict)
        build_body(doc, data, cover_p0, authors, args)
        return doc

    doc = write_docx(template, out, builder)
    text, hits, rids, names = self_check(out)
    print("DATA DIRS :", ", ".join(data_dirs))
    print("FIG DIRS  :", ", ".join(fig_dirs))
    print("TABLES    :", len(data.files_used), "CSV files;", f"{doc.tab_n} numbered tables + appendix tables")
    print("FIGURES   :", len(doc.images), "embedded:", ", ".join(os.path.basename(s) for _, s, _ in doc.images))
    if doc.missing:
        msg = "optional/extra figures not found (skipped): " + " | ".join(t[:60] for t in doc.missing)
        if args.strict and len(doc.images) < 5:
            os.remove(out)
            sys.exit("ERROR: " + msg)
    if hits:
        warn("leftover placeholder-like tokens: " + ", ".join(hits))
    expected_rids = {rid for rid, _, _ in doc.images}
    if any(f"word/media/{m}" not in names for _, _, m in doc.images) or not expected_rids.issubset(rids):
        sys.exit("ERROR: image relationship mismatch in output docx")
    print("WROTE     :", out, "bytes:", os.path.getsize(out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
