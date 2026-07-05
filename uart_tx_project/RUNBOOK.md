# RUNBOOK — Full Step-by-Step Instructions (macOS, Apple Silicon)

This document walks through the entire flow from a clean machine to a
finished GDSII layout, exactly as this project was built.

---

## Part 1 — Functional simulation

### Install
```bash
brew install icarus-verilog
brew install --cask gtkwave
```

### Run
```bash
cd uart_tx_project
make sim
```

Expected output:
```
PASS: byte 55 transmitted and captured correctly
PASS: byte a3 transmitted and captured correctly
PASS: byte 00 transmitted and captured correctly
PASS: byte ff transmitted and captured correctly
PASS: byte 81 transmitted and captured correctly

=== ALL TESTS PASSED ===
```

### (Optional) View the waveform
```bash
make wave
```

---

## Part 2 — Formal-style SVA assertions

Icarus Verilog has very limited concurrent-assertion support, so this
step uses Verilator instead.

### Install
```bash
brew install verilator
```

### Run
```bash
make assert
```

Runs the same testbench, but now with 5 concurrent assertions checked
on every clock edge throughout the whole simulation (see main README
for what each one checks). A clean run ends with the same
`ALL TESTS PASSED` plus no `%Error` assertion failures.

---

## Part 3 — Synthesis sanity check

### Install
```bash
brew install yosys
```

### Run
```bash
yosys -p "read_verilog rtl/uart_tx.v; synth -top uart_tx; stat"
```

Confirms: no inferred latches, sane cell count, clean synthesis.

---

## Part 4 — Full physical design (OpenLane + SKY130)

### 4.1 — Install Docker Desktop
Download for Apple Silicon: https://www.docker.com/products/docker-desktop/

Install, open once, wait for the whale icon in the menu bar to stop
animating, then verify:
```bash
docker --version
docker run hello-world
```

### 4.2 — Prerequisites
```bash
xcode-select --install
```

### 4.3 — Clone and build OpenLane
```bash
cd ~
git clone https://github.com/The-OpenROAD-Project/OpenLane.git
cd OpenLane
make        # pulls Docker image + builds/downloads SKY130 PDK (15-30+ min)
make test   # runs a sample design end-to-end to confirm the toolchain works
```
Look for: `Basic test passed`

### 4.4 — Add this design (naive floorplan)
```bash
mkdir -p ~/OpenLane/designs/uart_tx/src
cp rtl/uart_tx.v ~/OpenLane/designs/uart_tx/src/
cp openlane/uart_tx/config.json ~/OpenLane/designs/uart_tx/
```

### 4.5 — Add the optimized-floorplan variant
```bash
mkdir -p ~/OpenLane/designs/uart_tx_small/src
cp rtl/uart_tx.v ~/OpenLane/designs/uart_tx_small/src/
cp openlane/uart_tx_small/config.json ~/OpenLane/designs/uart_tx_small/
```

### 4.6 — Run both flows
```bash
cd ~/OpenLane
make mount
```
Inside the Docker container shell:
```bash
./flow.tcl -design uart_tx
./flow.tcl -design uart_tx_small
exit
```

### 4.7 — Find your results
```bash
ls ~/OpenLane/designs/uart_tx/runs/
ls ~/OpenLane/designs/uart_tx_small/runs/
```
Each run folder contains:
- `results/final/gds/uart_tx.gds` — the finished layout
- `reports/metrics.csv` — full metrics (area, timing, power, violations)

### 4.8 — View the layout
Install KLayout via Homebrew (more reliable than the .dmg on macOS,
avoids Gatekeeper/notarization headaches):
```bash
brew install --cask klayout
```
If macOS blocks it as "not from an identified developer": System
Settings → Privacy & Security → scroll to Security → "Open Anyway".

Then open your GDS:
```bash
open -a KLayout ~/OpenLane/designs/uart_tx_small/runs/<RUN_TAG>/results/final/gds/uart_tx.gds
```
(Replace `<RUN_TAG>` with your actual timestamped run folder name.)

---

## Common issues encountered (and fixes)

| Problem | Fix |
|---|---|
| Verilator error: "Range delay maximum must be >= minimum" on `##[1:12*BIT_CYCLES]` | Precompute the multiplication as its own `localparam` before using it in the delay range — Verilator's parser doesn't like inline expressions there |
| Assertion `a_start_bit_is_zero` failing | Real design behavior: FSM state transitions take 1 cycle, and the new state's action takes effect 1 cycle *after that* — so start-bit latency from `start` is 2 cycles, not 1. Fixed by adding `##1` to the property. |
| `klayout` "not opened, could not verify developer" | Right-click → Open (not double-click), or System Settings → Privacy & Security → Open Anyway |
| Old KLayout crashes with "cannot be opened because of a problem" | Version too old for current macOS — reinstall via `brew install --cask klayout` |
| `unzip` treating a shell comment as a filename argument | Never append a trailing `#` comment on the same line as a shell command being copy-pasted |
| `docker mount` / `flow.tcl` errors about missing files | Check `VERILOG_FILES` path in `config.json` matches where you actually placed the `.v` file relative to the design folder (`dir::src/uart_tx.v`) |

---

## Toolchain versions used

- Verilator 5.050
- Yosys (via Homebrew, current at time of writing)
- OpenLane (latest `master` branch, The-OpenROAD-Project)
- SKY130 PDK (open_pdks, pulled automatically by OpenLane's `make`)
- KLayout (current, via Homebrew cask)
- macOS, Apple Silicon (arm64)
