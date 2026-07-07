"""
append_energy.py
------------------
Appends a constant energy-per-access column (from CACTI's output) to
results/sweep_results.csv.

WHY A CONSTANT VALUE:
CACTI's "best memory configuration" search picks from its own internal
preset DIMM/DRAM configs — it does not accept our specific nCL/nRCD/nRP/nRAS
timing overrides as input. So we can't get a *different* CACTI energy number
per sweep point. Instead we use CACTI's one DRAM-level energy estimate
(32.6101 nJ per access, from `./cacti -infile cache.cfg`) as a constant
baseline, and pair it with each row's measured bandwidth/latency.

STATE THIS LIMITATION IN YOUR WRITE-UP: energy doesn't change across the
sweep here because CACTI wasn't driven by our timing changes — it's a
DRAM-level ballpark number, not a per-configuration energy simulation.
A more accurate follow-up would use DRAMPower, which does take JEDEC timing
parameters as direct input.
"""

import csv

RESULTS_CSV = "results/sweep_results.csv"
ENERGY_NJ_PER_ACCESS = 32.6101  # from CACTI's "top 3 best memory configurations" output


def main():
    with open(RESULTS_CSV) as f:
        rows = list(csv.DictReader(f))

    for row in rows:
        row["energy_nj_per_access"] = ENERGY_NJ_PER_ACCESS

    fieldnames = list(rows[0].keys())
    with open(RESULTS_CSV, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)

    print(f"Appended constant energy_nj_per_access={ENERGY_NJ_PER_ACCESS} to all rows.")
    print(f"Updated: {RESULTS_CSV}")


if __name__ == "__main__":
    main()
