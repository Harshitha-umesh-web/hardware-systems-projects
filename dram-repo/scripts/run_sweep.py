"""
run_sweep.py  (v2 — matches the real Ramulator2 Python API)
--------------------------------------------------------------
Your build of Ramulator2 is a Python module, not a CLI tool that reads YAML
files. This script builds the simulation directly in Python, the same way
Ramulator2's own test suite does (see tests/latency_throughput/utils/runner.py
in the ramulator2 repo, which this is adapted from).

WHAT IT DOES:
1. Builds a DDR4 DRAM object with default timings (DDR4_8Gb_x8 / DDR4_2400R).
2. For each of nCL, nRCD, nRP, nRAS, creates variants at -20%, -10%, +10%, +20%
   by passing the override directly to the DDR4() constructor (this build
   supports per-parameter overrides as kwargs, confirmed from their own tests).
3. Builds a controller + memory system + a synthetic traffic-generating
   frontend (LatencyThroughputTrace, built into Ramulator2 — no need for our
   own trace file with this API).
4. Runs the simulation and pulls stats out of sim.stats (a nested dict).
5. Writes everything to results/sweep_results.csv.

NOTE ON PARAM NAMES:
DDR4 in Ramulator2 uses JEDEC-style names: nCL (not tCL), nRCD, nRP, nRAS.
These are the actual constructor kwarg names — confirmed from their
device_timings tests (e.g. "nFAW=60" style overrides) and spec.py, which
reads nCL, nRCD, nRP, nRFC, nRTP from the resolved timing dict.
"""

import os
import csv
import ramulator


PARAMS = ["nCL", "nRCD", "nRP", "nRAS"]
PCT_CHANGES = [-0.2, -0.1, 0.1, 0.2]

ORG_PRESET = "DDR4_8Gb_x8"
TIMING_PRESET = "DDR4_2400R"

NUM_PROBE_REQUESTS = 5000       # smaller than their test suite for speed
WARMUP_CYCLES = 2000
FRONTEND_CLOCK_RATIO = 8
READ_RATIO = 80                 # 80% reads, 20% writes
NOP_COUNTER = 20                # spacing between requests (affects load level)

RESULTS_CSV = "results/sweep_results.csv"


def get_default_timing_value(param):
    """Read the default (unmodified) value of a timing param from the preset."""
    dram = ramulator.dram.DDR4(org_preset=ORG_PRESET, timing_preset=TIMING_PRESET)
    _, timing_dict = dram.resolve()
    if param not in timing_dict:
        raise KeyError(
            f"'{param}' not found in resolved timing dict. Available keys: "
            f"{sorted(timing_dict.keys())}"
        )
    return timing_dict[param]


def build_and_run(overrides: dict) -> dict:
    """Build one full simulation with the given timing overrides and run it."""
    dram = ramulator.dram.DDR4(
        org_preset=ORG_PRESET,
        timing_preset=TIMING_PRESET,
        **overrides,
    )

    from tests.utils import extract_dram_layout  # provided by the repo
    layout = extract_dram_layout(dram)

    frontend = ramulator.frontend.LatencyThroughputTrace(
        clock_ratio=FRONTEND_CLOCK_RATIO,
        nop_counter=NOP_COUNTER,
        num_probe_requests=NUM_PROBE_REQUESTS,
        latency_measure_mode="random-probe",
        latency_sample_count=NUM_PROBE_REQUESTS,
        num_streaming_requests=0,
        streaming_only=False,
        warmup_cycles=WARMUP_CYCLES,
        seed=12345,
        read_ratio=READ_RATIO,
        stream_cls=layout.get("num_cls", 128),
        stagger_stream_rows=True,
        **layout,
    )

    ctrl = ramulator.controller.GenericDDR(
        dram=dram,
        scheduler=ramulator.scheduler.FRFCFSRowHit(),
        row_policy=ramulator.row_policy.Open(),
        addr_mapper=ramulator.addr_mapper.PassThroughAddrMapper(),
        refresh_manager=ramulator.refresh_manager.NoRefresh(),
    )

    mem = ramulator.memory_system.GenericDRAM(
        clock_ratio=1,
        controllers=[ctrl],
        channel_mapper=ramulator.channel_mapper.PassThroughChannelMapper(),
    )

    sim = ramulator.Simulation(frontend, mem)
    sim.run()
    return sim.stats


def extract_latency_bandwidth(stats: dict):
    """Ramulator2's stats dict is nested; pull out latency/bandwidth values.

    NOTE: the exact key names/nesting can differ slightly by build. If this
    raises a KeyError, print(stats) to see the real structure and adjust the
    lookups below — this is a one-time calibration step.
    """
    # Print once so you can see the real shape if something goes wrong.
    latency = None
    bandwidth = None

    def search(d, needle_substrings):
        for k, v in d.items():
            if isinstance(v, dict):
                found = search(v, needle_substrings)
                if found is not None:
                    return found
            else:
                lk = k.lower()
                if any(s in lk for s in needle_substrings):
                    return v
        return None

    latency = search(stats, ["latency"])
    bandwidth = search(stats, ["bandwidth", "throughput"])
    return latency, bandwidth, stats


def main():
    os.makedirs("results", exist_ok=True)
    rows = []

    print("Running baseline...")
    baseline_stats = build_and_run({})
    lat, bw, raw = extract_latency_bandwidth(baseline_stats)
    if lat is None or bw is None:
        print("[!] Could not auto-find latency/bandwidth keys. Full stats dict:")
        print(raw)
    rows.append({
        "param": "baseline", "pct_change": 0, "original_val": "",
        "new_val": "", "latency": lat, "bandwidth": bw
    })

    for param in PARAMS:
        default_val = get_default_timing_value(param)
        for pct in PCT_CHANGES:
            new_val = max(1, round(default_val * (1 + pct)))
            print(f"Running {param} {pct*100:+.0f}% ({default_val} -> {new_val})...")
            stats = build_and_run({param: new_val})
            lat, bw, raw = extract_latency_bandwidth(stats)
            rows.append({
                "param": param, "pct_change": pct,
                "original_val": default_val, "new_val": new_val,
                "latency": lat, "bandwidth": bw
            })

    with open(RESULTS_CSV, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        writer.writeheader()
        writer.writerows(rows)

    print(f"\nDone. Results written to {RESULTS_CSV}")


if __name__ == "__main__":
    main()
