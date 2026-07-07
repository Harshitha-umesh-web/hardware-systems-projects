"""
plot_results.py
-----------------
Reads results/sweep_results.csv and produces three plots:
  - latency_vs_param.png
  - bandwidth_vs_param.png
  - energy_vs_param.png (if energy column present)

Each plot shows all 4 parameters (tCL, tRCD, tRP, tRAS) on one figure with
% change on the x-axis, so you can visually compare sensitivity.
"""

import csv
import matplotlib.pyplot as plt

RESULTS_CSV = "results/sweep_results.csv"
PARAMS = ["nCL", "nRCD", "nRP", "nRAS"]


def load_rows():
    with open(RESULTS_CSV) as f:
        return list(csv.DictReader(f))


def plot_metric(rows, metric, ylabel, out_path):
    plt.figure(figsize=(7, 5))
    for param in PARAMS:
        xs, ys = [], []
        for r in rows:
            if r["param"] != param:
                continue
            val = r.get(metric, "")
            if val in ("", None):
                continue
            xs.append(float(r["pct_change"]) * 100)
            ys.append(float(val))
        if xs:
            pairs = sorted(zip(xs, ys))
            xs, ys = zip(*pairs)
            plt.plot(xs, ys, marker="o", label=param)

    plt.xlabel("Parameter change (%)")
    plt.ylabel(ylabel)
    plt.title(f"{ylabel} vs timing parameter change")
    plt.legend()
    plt.grid(True, alpha=0.3)
    plt.tight_layout()
    plt.savefig(out_path, dpi=150)
    plt.close()
    print(f"Saved {out_path}")


def main():
    rows = load_rows()
    if not rows:
        print("No rows found in CSV. Run run_sweep.py first.")
        return

    plot_metric(rows, "latency", "Average latency (cycles or ns)",
                "results/latency_vs_param.png")
    plot_metric(rows, "bandwidth", "Bandwidth (GB/s)",
                "results/bandwidth_vs_param.png")

    if any("energy_pj_per_access" in r for r in rows):
        plot_metric(rows, "energy_pj_per_access", "Energy per access (pJ)",
                    "results/energy_vs_param.png")
    else:
        print("No energy column found — run run_cacti.py first if you want this plot.")


if __name__ == "__main__":
    main()
