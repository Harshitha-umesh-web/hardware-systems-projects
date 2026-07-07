"""
compare_standards.py
-----------------------
Bonus extension: compares baseline latency/bandwidth across ALL DRAM
standards Ramulator2 ships test configs for (DDR3, DDR4, DDR5, LPDDR5,
LPDDR6, GDDR6, GDDR7, HBM1-4) -- not just DDR4.

WHY THIS REUSES THEIR CODE DIRECTLY:
Rather than reinventing config-building for every standard (each has
different controller classes, clock ratios, etc.), this imports Ramulator2's
own `run_single_config_point` (from tests/latency_throughput/utils/runner.py)
and its own per-standard testcase configs (from
tests/latency_throughput/testcases/*.py). This is the same machinery their
own test suite uses -- we're just calling it directly and collecting results
into a comparison table instead of running it as a pytest.

MUST BE RUN FROM THE ramulator2 REPO ROOT (needs `tests` importable).

WHAT IT DOES:
1. Loads every standard's config from tests/latency_throughput/testcases/
2. Runs ONE representative point per standard (moderate load: read_ratio=80,
   a mid-range nop_counter from each config's own list, no refresh, to keep
   runtime short) using their run_single_config_point().
3. Extracts latency + bandwidth from the returned stats dict.
4. Writes results/standards_comparison.csv
5. Plots a grouped bar chart comparing latency and bandwidth across
   standards.
"""

import os
import csv
import matplotlib.pyplot as plt

from tests.latency_throughput.testcases import STANDARDS
from tests.latency_throughput.utils.runner import run_single_config_point

RESULTS_CSV = "results/standards_comparison.csv"
READ_RATIO = 80
NUM_PROBE_REQUESTS = 3000     # smaller than full test suite, for speed
WARMUP_CYCLES = 2000


def extract_latency_bandwidth(stats: dict):
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
    return latency, bandwidth


def main():
    os.makedirs("results", exist_ok=True)
    rows = []

    for name in sorted(STANDARDS.keys()):
        cfg = STANDARDS[name]
        # pick a mid-range nop_counter (moderate load, not max stress)
        nop_counters = cfg["nop_counters"]
        mid_nop = nop_counters[len(nop_counters) // 2]

        print(f"Running {name} (nop_counter={mid_nop})...")
        try:
            stats = run_single_config_point(
                cfg,
                nop_counter=mid_nop,
                read_ratio=READ_RATIO,
                num_probe_requests=NUM_PROBE_REQUESTS,
                refresh_enabled=False,
                frontend_clock_ratio=cfg["frontend_clock_ratio"],
                warmup_cycles=WARMUP_CYCLES,
            )
            latency, bandwidth = extract_latency_bandwidth(stats)
        except Exception as e:
            print(f"  [!] {name} failed: {e}")
            latency, bandwidth = None, None

        rows.append({"standard": name, "latency": latency, "bandwidth": bandwidth})

    with open(RESULTS_CSV, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=["standard", "latency", "bandwidth"])
        writer.writeheader()
        writer.writerows(rows)
    print(f"\nSaved {RESULTS_CSV}")

    # Plot
    valid_rows = [r for r in rows if r["latency"] is not None]
    names = [r["standard"] for r in valid_rows]
    lats = [float(r["latency"]) for r in valid_rows]
    bws = [float(r["bandwidth"]) for r in valid_rows]

    fig, axes = plt.subplots(1, 2, figsize=(14, 5))

    axes[0].bar(names, lats, color="steelblue")
    axes[0].set_ylabel("Latency (ns)")
    axes[0].set_title("Latency by DRAM Standard")
    axes[0].tick_params(axis="x", rotation=45)

    axes[1].bar(names, bws, color="darkorange")
    axes[1].set_ylabel("Bandwidth (GB/s)")
    axes[1].set_title("Bandwidth by DRAM Standard")
    axes[1].tick_params(axis="x", rotation=45)

    plt.tight_layout()
    plt.savefig("results/standards_comparison.png", dpi=150)
    plt.close()
    print("Saved results/standards_comparison.png")


if __name__ == "__main__":
    main()
