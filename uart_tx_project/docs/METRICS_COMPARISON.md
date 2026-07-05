# Physical Design Metrics — Floorplan Comparison

Two OpenLane runs of the *exact same* RTL, differing only in floorplan
sizing strategy. This isolates and quantifies the cost of an oversized,
fixed-size die versus a right-sized, density-driven floorplan.

| Metric | `uart_tx` (fixed 200×200 die) | `uart_tx_small` (auto-sized, 35% util) | Change |
|---|---|---|---|
| Die area | 0.04 mm² | 0.0072 mm² | **~5.6× smaller** |
| Core area | 33,344 µm² | 4,661 µm² | ~7.2× smaller |
| Core utilization | 5.1% | 37.5% | Much tighter packing |
| Synthesized logic cells | 150 | 150 | **Identical** — same design |
| Fill cells | 501 | 94 | 5.3× fewer |
| Decap cells | 2,381 | 277 | 8.6× fewer |
| Welltap cells | 469 | 67 | 7× fewer |
| Total cells (incl. filler) | 3,539 | 625 | 5.7× fewer overall |
| Worst negative slack (WNS) | 0.0 ns | 0.0 ns | Both timing-clean |
| Critical path delay | 1.47 ns | 1.43 ns | Nearly identical |
| Routing violations | 0 | 0 | Both DRC-clean |
| LVS errors | 0 | 0 | Both clean |

## Takeaway

The same 150-cell synthesized netlist was placed and routed in both
runs. The only variable was floorplan sizing strategy
(`FP_SIZING: absolute` with a fixed oversized die, vs.
`FP_SIZING: relative` with an auto-computed die at 35% target
utilization).

Forcing a design into a die far larger than it needs doesn't add
functionality — it forces the tool to spend the empty space on **filler
cells** (`fill_*`), **decoupling capacitors** (`decap_*`), and **well-tap
cells** (`tapvpwrvgnd_*`) purely to satisfy DRC and power-grid continuity
rules. This run needed **over 5× as many filler cells** for no
functional benefit — pure silicon-area waste that would cost real money
in an actual tapeout.

Both floorplans are electrically and functionally identical: 0 ns
worst-case slack, 0 DRC violations, 0 LVS errors, near-identical
critical path. The `uart_tx_small` variant is the one worth using in
practice.
