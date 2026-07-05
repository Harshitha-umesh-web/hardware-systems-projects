#!/usr/bin/env bash
#==============================================================================
# run_waves.sh
# One-command waveform workflow for the SPI/I2C controller testbench.
#
# What it does:
#   1. Makes sure tb/spi_i2c_tb_top.sv dumps a VCD (adds the two lines if
#      they're not already there - safe to run this script over and over).
#   2. Compiles with Icarus Verilog.
#   3. Runs the simulation, producing wave.vcd.
#   4. Opens wave.vcd in Surfer automatically.
#
# Usage (from the project root):
#   bash scripts/run_waves.sh
#==============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

TB_TOP="tb/spi_i2c_tb_top.sv"

echo "==> Checking for waveform dump lines in $TB_TOP ..."
if grep -q '\$dumpfile' "$TB_TOP"; then
    echo "    Already present - leaving the file as-is."
else
    echo "    Not found - inserting \$dumpfile/\$dumpvars right before the first @(posedge rst_n);"
    # Insert the two dump lines immediately before the FIRST occurrence of
    # "@(posedge rst_n);" (the start of the test sequence's initial block).
    awk '
        !done && /@\(posedge rst_n\);/ {
            print "        $dumpfile(\"wave.vcd\");"
            print "        $dumpvars(0, spi_i2c_tb_top);"
            done = 1
        }
        { print }
    ' "$TB_TOP" > "$TB_TOP.tmp"
    mv "$TB_TOP.tmp" "$TB_TOP"
    echo "    Done."
fi

echo "==> Compiling with Icarus Verilog ..."
mkdir -p build
iverilog -g2012 -o build/sim.out rtl/*.v tb/spi_i2c_pkg.sv tb/spi_i2c_tb_top.sv

echo "==> Running simulation ..."
vvp build/sim.out | tee sim_log.txt

if grep -q "REGRESSION: PASS" sim_log.txt; then
    echo "==> Simulation PASSED. wave.vcd has been generated."
else
    echo "==> WARNING: simulation did not report REGRESSION: PASS - check sim_log.txt above."
fi

if [ -f wave.vcd ]; then
    if command -v surfer >/dev/null 2>&1; then
        echo "==> Opening wave.vcd in Surfer ..."
        surfer wave.vcd &
    else
        echo "==> wave.vcd created, but 'surfer' command not found on PATH."
        echo "    Open it manually with: surfer wave.vcd"
    fi
else
    echo "==> wave.vcd was not created - something went wrong above."
fi
