#!/usr/bin/env python3
"""
regression.py
Scripted regression runner for the SPI/I2C controller project.

What it does:
  1. Compiles + simulates the SystemVerilog testbench (Icarus Verilog by
     default, Verilator optionally) and scans the log for the
     "REGRESSION: PASS/FAIL" marker plus any [FAIL]/assertion errors.
  2. Optionally runs a Yosys lint pass (`check`) on the RTL on its own,
     independent of whether a liberty file is available, to catch latches-
     where-not-expected, multi-driven nets, width mismatches, etc.
  3. Optionally runs the full Yosys synthesis script if a liberty path is
     given, and reports the resulting cell/area summary.
  4. Prints a single pass/fail summary and exits non-zero on any failure,
     so this can be dropped straight into a CI job.

Usage:
  python3 regression.py                          # sim only, iverilog
  python3 regression.py --sim verilator          # sim only, verilator
  python3 regression.py --lint                   # + yosys lint
  python3 regression.py --synth --liberty x.lib  # + yosys synthesis
  python3 regression.py --all --liberty x.lib    # everything
"""

import argparse
import re
import subprocess
import sys
import time
from pathlib import Path

ROOT     = Path(__file__).resolve().parent.parent
RTL_DIR  = ROOT / "rtl"
TB_DIR   = ROOT / "tb"
SYN_DIR  = ROOT / "syn"
BUILD    = ROOT / "build"

RTL_FILES = sorted(RTL_DIR.glob("*.v"))
# Note: spi_i2c_assertions.sv (SVA property/assert property checkers) is
# deliberately excluded here - Icarus Verilog doesn't support concurrent
# assertions. If you're running with a simulator that does (Verilator with
# --assert, or a commercial simulator), add it back to this list.
TB_FILES = [
    TB_DIR / "spi_i2c_pkg.sv",
    TB_DIR / "spi_i2c_tb_top.sv",
]

PASS_MARKER = "REGRESSION: PASS"
FAIL_MARKER = "REGRESSION: FAIL"
FAIL_LINE_RE = re.compile(r"\[FAIL\]|ASSERT|\$error", re.IGNORECASE)


def run(cmd, cwd=None):
    print(f"$ {' '.join(cmd)}")
    t0 = time.time()
    proc = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)
    dt = time.time() - t0
    return proc.returncode, proc.stdout + proc.stderr, dt


def sim_iverilog():
    BUILD.mkdir(exist_ok=True)
    out_bin = BUILD / "sim.out"
    cmd = ["iverilog", "-g2012", "-o", str(out_bin)] + \
          [str(f) for f in RTL_FILES] + [str(f) for f in TB_FILES]
    rc, log, dt = run(cmd)
    if rc != 0:
        return False, f"[compile failed, {dt:.1f}s]\n{log}"

    rc, log, dt = run(["vvp", str(out_bin)])
    return rc == 0, f"[sim ran in {dt:.1f}s]\n{log}"


def sim_verilator():
    BUILD.mkdir(exist_ok=True)
    cmd = [
        "verilator", "--binary", "-Wall", "--timing", "-sv",
        "-Wno-DECLFILENAME", "-Wno-UNUSEDSIGNAL",
        "--top-module", "spi_i2c_tb_top",
        "-Mdir", str(BUILD / "obj_dir"),
        "-o", "sim.out",
    ] + [str(f) for f in RTL_FILES] + [str(f) for f in TB_FILES]
    rc, log, dt = run(cmd)
    if rc != 0:
        return False, f"[verilate failed, {dt:.1f}s]\n{log}"

    sim_bin = BUILD / "obj_dir" / "sim.out"
    rc, log, dt = run([str(sim_bin)])
    return rc == 0, f"[sim ran in {dt:.1f}s]\n{log}"


def yosys_lint():
    script = f"""
    read_verilog -sv {' '.join(str(f) for f in RTL_FILES)}
    hierarchy -check -top spi_i2c_top
    check -mapped
    """
    rc, log, dt = run(["yosys", "-p", script])
    return rc == 0, f"[lint ran in {dt:.1f}s]\n{log}"


def yosys_synth(liberty):
    cmd = ["yosys", "-c", str(SYN_DIR / "yosys_synth.tcl")]
    if liberty:
        cmd += ["--", liberty]
    rc, log, dt = run(cmd, cwd=ROOT)
    return rc == 0, f"[synth ran in {dt:.1f}s]\n{log}"


def evaluate_sim_log(log: str) -> tuple[bool, list[str]]:
    """Return (passed, list_of_failure_lines) based on markers + error scan."""
    failures = [ln for ln in log.splitlines() if FAIL_LINE_RE.search(ln)]
    if PASS_MARKER in log and FAIL_MARKER not in log and not failures:
        return True, []
    return False, failures


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--sim", choices=["iverilog", "verilator", "none"], default="iverilog")
    ap.add_argument("--lint", action="store_true", help="run yosys `check` lint pass")
    ap.add_argument("--synth", action="store_true", help="run full yosys synthesis")
    ap.add_argument("--liberty", default="", help="liberty file for --synth (optional)")
    ap.add_argument("--all", action="store_true", help="run sim + lint + synth")
    args = ap.parse_args()

    if args.all:
        args.lint = True
        args.synth = True

    overall_ok = True
    sections = []

    if args.sim != "none":
        print(f"\n== Simulation ({args.sim}) ==")
        if args.sim == "iverilog":
            ran_ok, log = sim_iverilog()
        else:
            ran_ok, log = sim_verilator()

        print(log)
        sim_ok, failures = evaluate_sim_log(log) if ran_ok else (False, ["tool failed to run"])
        overall_ok &= sim_ok
        sections.append(("simulation", sim_ok, failures))

    if args.lint:
        print("\n== Yosys lint ==")
        ok, log = yosys_lint()
        print(log)
        overall_ok &= ok
        sections.append(("yosys lint", ok, [] if ok else ["yosys check reported errors"]))

    if args.synth:
        print("\n== Yosys synthesis ==")
        ok, log = yosys_synth(args.liberty)
        print(log)
        overall_ok &= ok
        sections.append(("yosys synth", ok, [] if ok else ["synthesis failed"]))

    print("\n================ REGRESSION REPORT ================")
    for name, ok, failures in sections:
        status = "PASS" if ok else "FAIL"
        print(f"  [{status}] {name}")
        for f in failures[:10]:
            print(f"      {f}")
        if len(failures) > 10:
            print(f"      ... and {len(failures) - 10} more")

    print("\nOVERALL:", "PASS" if overall_ok else "FAIL")
    sys.exit(0 if overall_ok else 1)


if __name__ == "__main__":
    main()
