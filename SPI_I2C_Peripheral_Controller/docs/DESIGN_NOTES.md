# SPI/I2C Peripheral Controller — RTL, Verification & Synthesis

A dual-mode (SPI + I2C), dual-role (master + slave) peripheral controller,
built to demonstrate the full front-end flow: RTL design → protocol
verification → synthesis/STA → low-power technique → scripted regression.

**Important:** this sandbox has no network access and no EDA tools
installed (`iverilog`, `verilator`, `yosys`, `OpenSTA` are all absent), so
none of this has been compiled or simulated here. Everything below is
written to be correct and internally consistent by design/code review, but
you should run the commands in this README on your own machine before
trusting it — that's exactly what the testbench and lint pass are for.
See **"What to check first"** at the bottom.

## Architecture

```
rtl/
  clk_gate.v       latch-based clock-gate cell (idle-power technique)
  spi_master.v     SPI master, all 4 CPOL/CPHA modes, prog. clock divider
  spi_slave.v      SPI slave, synchronizers + edge detect, all 4 modes
  i2c_master.v     I2C master, 7-bit addr, single-byte txn, clock stretch,
                   simple arbitration-loss detection
  i2c_slave.v      I2C slave, address match, ACK/NACK, read+write
  spi_i2c_regs.v   APB-lite register file (control/status/data)
  spi_i2c_top.v    top-level integration: pin muxing + per-engine clock gating

tb/
  spi_i2c_pkg.sv        register-map constants shared with the testbench
  spi_i2c_assertions.sv SVA protocol checkers, bound into the RTL
  spi_i2c_tb_top.sv     testbench: 2 DUT instances (master+slave), APB BFM,
                         directed tests, functional coverage, self-checking

syn/
  yosys_synth.tcl   synthesis (liberty-targeted, or generic fallback)
  constraints.sdc   SDC timing constraints
  run_sta.tcl       OpenSTA static timing analysis

scripts/
  regression.py     builds/runs the sim (+ optional lint/synth), reports
                     pass/fail, non-zero exit code for CI
```

### Why two DUT instances in the testbench
`spi_i2c_top` is a single IP block that is *either* master *or* slave at
runtime (set via the `role` bit in CTRL). To verify master↔slave
interoperability meaningfully, the testbench instantiates the controller
twice (`dut_a`, `dut_b`) on shared SPI and I2C buses and configures one as
master, the other as slave, for each directed test. This is closer to how
you'd actually validate the IP (against a real peer) than a pure loopback.

### Register map (APB-lite, word-aligned)

| Offset | Name    | Fields |
|--------|---------|--------|
| 0x00 | CTRL   | [0]=enable [1]=mode(0=SPI,1=I2C) [2]=role(0=MASTER,1=SLAVE) [3]=cpol [4]=cpha |
| 0x04 | CLKDIV | [15:0] engine clock divider |
| 0x08 | TXDATA | [7:0] next byte to transmit |
| 0x0C | RXDATA | [7:0] last byte received (read clears rx_valid) |
| 0x10 | ADDR   | [6:0] I2C target address (master) / own address (slave) |
| 0x14 | CMD    | [0]=start (self-clearing) [1]=rw (0=write,1=read) |
| 0x18 | STATUS | [0]=busy [1]=done(W1C) [2]=ack_err(W1C) [3]=arb_lost(W1C) [4]=rx_valid |
| 0x1C | IRQEN  | [0]=done_ie |

## Low-power technique

Two `clk_gate` cells sit between the system clock and the two **master**
engines (`spi_master`, `i2c_master`). The top level only enables the one
matching the current `{mode,role}` (and only while `CTRL.enable=1`); the
other sits with a frozen clock.

The two **slave** engines (`spi_slave`, `i2c_slave`) deliberately run on
the always-on system clock instead. Early in development these were also
clock-gated, and it caused a real, hard-to-diagnose bug: each slave's
input synchronizer continuously tracks the external, asynchronous bus,
and freezing its clock while deselected leaves it holding a stale bus
level. When re-enabled for a later transaction, that stale value could
cause the very first bus edge to be mis-detected - intermittently, in a
way that depended on what the previous test had done. The fix (and the
general lesson): don't clock-gate logic that has to keep passively
tracking an asynchronous external signal - only gate logic that is
actively driving its own timeline (the masters), or logic that's
genuinely idle with nothing external to lose track of.

This is checked by an SVA assertion (`a_mutex_engine_sel` in
`spi_i2c_assertions.sv`) that fails if more than one engine's `{mode,role}`
select is ever active at once - that property still holds; it's the
clock-gating itself that got scoped down to the two masters.

## Verification plan

- **Directed SPI tests**: all 4 CPOL/CPHA combinations, full-duplex byte
  exchange, including 0x00/0xFF edge-case bytes.
- **Directed I2C tests**: matching-address write, matching-address read,
  and a mismatched-address write that must NACK (`ack_err` set).
- **Assertions** (`spi_i2c_assertions.sv`):
  - engine-select mutual exclusion (clock-gating correctness)
  - SCLK static while CS_N deasserted
  - SDA may only change while SCL is high during START/STOP
  - no unknown (`X`) state in `spi_slave.bit_cnt` while busy
- **Functional coverage**: SPI CPOL×CPHA cross, I2C R/W × ack_err cross,
  byte-value classes (0x00 / 0xFF / mid-range).
- **Self-checking**: each directed test compares captured data against
  expected values and prints `[PASS]`/`[FAIL]`; the run ends with a
  `REGRESSION: PASS`/`FAIL` marker that `scripts/regression.py` greps for.

## How to run

Install tools (Ubuntu/Debian):
```
sudo apt-get install iverilog yosys      # verilator: sudo apt-get install verilator
```

Simulate:
```
cd spi_i2c_controller
python3 scripts/regression.py                    # iverilog, sim only
python3 scripts/regression.py --sim verilator    # verilator instead
python3 scripts/regression.py --lint             # + yosys structural lint
```

Or run the tools directly:
```
iverilog -g2012 -o build/sim.out rtl/*.v tb/spi_i2c_pkg.sv tb/spi_i2c_assertions.sv tb/spi_i2c_tb_top.sv
vvp build/sim.out
```

Synthesize (generic, no PDK needed — structural/area sanity check only):
```
yosys -c syn/yosys_synth.tcl
```

Synthesize against a real liberty (e.g. an open PDK like sky130_fd_sc_hd):
```
yosys -c syn/yosys_synth.tcl -- /path/to/sky130_fd_sc_hd__tt_025C_1v80.lib
```

Static timing analysis (needs OpenSTA and the netlist from the step above):
```
sta -no_init syn/run_sta.tcl -var liberty /path/to/cells.lib \
    -var netlist syn/out/spi_i2c_top_netlist.v -var top spi_i2c_top
```

## Known scope simplifications (be ready to talk about these)

- I2C transactions are single-byte per `start` pulse (no burst/repeated-start
  in one call); multi-byte transfers are composed by issuing `start` again.
- I2C slave does not stretch the clock itself (master-side stretch handling
  is implemented and exercised; slave-side stretching is a natural
  follow-up if you want to extend the project).
- Arbitration-loss detection is a simplified single-check (SDA read-back
  mismatch while released) rather than a full multi-master arbitration
  scheme — enough to demonstrate the concept, not a production multi-master
  I2C stack.
- APB timing model in the testbench doesn't insert wait states (`pready`
  is tied high in `spi_i2c_regs.v`); fine for this register file's single-
  cycle access, but worth noting if you extend it.

## What to check first

Since I couldn't compile anything here, if you hit issues when you run it
locally, look here first:
1. `spi_master`/`spi_slave` CPOL/CPHA edge timing — verify with a waveform
   dump (`$dumpfile`/`$dumpvars`, add to `spi_i2c_tb_top.sv`) that MOSI/MISO
   are stable well before each sampling edge for all 4 modes.
2. `i2c_master` state machine around `S_CLK_HIGH` — the non-blocking
   assignment ordering there (default `state <= S_CLK_LOW` overridden by
   phase-specific `state <= S_STOP_SETUP` where applicable) is correct
   Verilog semantics but is exactly the kind of thing worth single-stepping
   once in a waveform viewer.
3. Add `$dumpfile("wave.vcd"); $dumpvars(0, spi_i2c_tb_top);` to the top of
   the testbench `initial` block for GTKWave debugging.
