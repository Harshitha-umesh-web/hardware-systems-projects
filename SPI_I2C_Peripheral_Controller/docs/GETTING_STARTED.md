# Getting Started — Step by Step (Beginner Guide)

This assumes you've never run a hardware simulator before. Follow the
steps in order. Don't skip ahead — each step depends on the last one
working.

---

## Step 0: What you actually need installed

Three tools, all free:

| Tool | What it does | Do you need it right now? |
|------|--------------|---------------------------|
| `iverilog` | Compiles + runs your Verilog/SystemVerilog | Yes, first |
| `gtkwave`  | Lets you *see* signals as waveforms | Yes, second |
| `yosys`    | Synthesis (RTL → gates) | Later, once sim works |

You do **not** need OpenSTA or a liberty file yet. Ignore the STA step
entirely until simulation is fully working — it's the last step, not the
first.

---

## Step 1: Install the tools

**If you're on Windows:** install WSL2 first (search "install WSL" —
it's one command in PowerShell: `wsl --install`), then open the Ubuntu
terminal it gives you and do the Linux steps below inside that.

**Linux (Ubuntu/Debian) or WSL2:**
```bash
sudo apt-get update
sudo apt-get install -y iverilog gtkwave yosys
```

**macOS (with Homebrew):**
```bash
brew install icarus-verilog gtkwave yosys
```

Check it worked:
```bash
iverilog -V
yosys -V
```
Both should print a version number, not "command not found". If either
fails, stop here and fix that before moving on — nothing else will work.

---

## Step 2: Get the project files in one place

Put the whole `spi_i2c_controller` folder somewhere easy, e.g.:
```bash
cd ~
mkdir -p projects
cd projects
# copy/move the spi_i2c_controller folder here
cd spi_i2c_controller
ls
```
You should see: `rtl/`, `tb/`, `syn/`, `scripts/`, `docs/`.

---

## Step 3: Compile the design (no simulation yet — just check it builds)

This step only checks that the Verilog/SystemVerilog is *syntactically*
valid — it doesn't run anything yet.

```bash
iverilog -g2012 -o build/sim.out rtl/*.v tb/spi_i2c_pkg.sv tb/spi_i2c_assertions.sv tb/spi_i2c_tb_top.sv
```

- **No output at all, no errors** → good, it compiled. Move to Step 4.
- **Errors** → read the first error only (ignore the rest, they're often
  caused by the first one). It'll say something like
  `rtl/i2c_master.v:123: syntax error`. Open that file at that line and
  look for a typo, a missing semicolon, or a mismatched `begin`/`end`.
  Paste the exact error back to me if you get stuck — I'll fix it.

If you see a `-bash: iverilog: command not found` error, go back to Step 1.

---

## Step 4: Run the simulation

```bash
vvp build/sim.out
```

You'll get a wall of text. Here's what to actually look at:

1. Lines starting with `[PASS]` or `[FAIL]` — one per check.
2. Near the very end, a block like:
   ```
   ================ REGRESSION SUMMARY ================
   PASS: 12  FAIL: 0
   REGRESSION: PASS
   ```

If it says `REGRESSION: PASS` with `FAIL: 0` — the design behaves
correctly on everything the testbench checks. That's the goal.

If you see `[FAIL]` lines or `REGRESSION: FAIL`:
- Copy the exact `[FAIL]` line(s) and the `[ASSERT]`/`$error` lines above
  them.
- Send them to me — that's precisely the debugging conversation this
  project is designed to produce. I built the RTL carefully but never
  got to compile it myself (no simulator in my sandbox), so this is the
  first real test of it. Finding and fixing a bug together is a normal,
  expected part of this — not a sign something went wrong on your end.

---

## Step 5: Watch it happen (waveforms) — do this even if tests pass

Reading pass/fail text is necessary but boring; *seeing* the SPI/I2C
signals wiggle is how this actually clicks. Add two lines to the top of
the testbench's test sequence.

Open `tb/spi_i2c_tb_top.sv`, find this block near the bottom:
```systemverilog
    initial begin
        @(posedge rst_n);
        repeat (10) @(posedge clk);
```
Change it to:
```systemverilog
    initial begin
        $dumpfile("wave.vcd");
        $dumpvars(0, spi_i2c_tb_top);
        @(posedge rst_n);
        repeat (10) @(posedge clk);
```

Recompile and rerun (Steps 3 and 4). You'll now have a `wave.vcd` file.
Open it:
```bash
gtkwave wave.vcd
```

In GTKWave:
1. Left panel → click `dut_a` (or `dut_b`) to see its signals.
2. Drag `sclk_io`, `mosi_io`, `miso_io`, `cs_n_io` into the waveform pane.
3. Zoom into one of the SPI transfers and watch: `cs_n_io` drops low,
   `sclk_io` toggles 8 times, `mosi_io`/`miso_io` change on the edges you
   read about in `spi_master.v`'s comments.
4. Do the same for `scl_io`/`sda_io` during an I2C test — look for the
   START condition (SDA drops while SCL is still high) and STOP
   (SDA rises while SCL is high).

This is the single most useful thing you can do to actually understand
(and be able to talk about) how the protocol timing works.

---

## Step 6: Read the RTL in this order

Don't start with `spi_i2c_top.v` — it's just wiring. Read in this order,
each one is self-contained:

1. `rtl/clk_gate.v` — tiny, 15 lines, explains itself.
2. `rtl/spi_master.v` — read the big comment block at the top first,
   then the state machine (`ST_IDLE → ST_CS_SETUP → ST_RUN → ST_CS_HOLD`).
3. `rtl/spi_slave.v` — same protocol, opposite role.
4. `rtl/i2c_master.v` — more states, but same pattern: a `case` on
   `state`, driven by a clock-divider tick.
5. `rtl/i2c_slave.v`
6. `rtl/spi_i2c_regs.v` — the "software-visible" register map.
7. `rtl/spi_i2c_top.v` — now that you know what each block does, this
   is just "which wire goes where."

For each file, try to answer out loud: *what does this module do if I
never touch it, and what makes it start doing something?* That's the
question interviewers actually ask.

---

## Step 7: Run the lint / synthesis pass

Once simulation passes, try:
```bash
yosys -p "read_verilog -sv rtl/clk_gate.v rtl/spi_master.v rtl/spi_slave.v rtl/i2c_master.v rtl/i2c_slave.v rtl/spi_i2c_regs.v rtl/spi_i2c_top.v; hierarchy -check -top spi_i2c_top; check -mapped"
```
This just checks the design is structurally sound (no accidental
latches, no multiply-driven nets). No errors = good.

Then run the full generic synthesis (no liberty file needed):
```bash
yosys -c syn/yosys_synth.tcl
```
Look at the `stat` output near the end — it prints cell counts and a
rough area number. That's your "synthesis results" for a resume bullet,
even without a real PDK.

If you later want a *real* liberty file for accurate gates/timing, the
free option is Google/SkyWater's open-source **sky130** PDK. That's an
optional add-on, not required to finish this project.

---

## Step 8: Run everything with one command

Once the manual steps above all work, the script automates them:
```bash
python3 scripts/regression.py --lint
```
This compiles, sims, lints, and prints one final `OVERALL: PASS/FAIL`
line with a non-zero exit code on failure — exactly what a CI pipeline
would do.

---

## If you get stuck at any step

Tell me:
1. Which step number.
2. The exact command you ran.
3. The exact error text (copy-paste, not paraphrased).

I'll fix the specific file/line — no need to re-explain the whole
project each time.
