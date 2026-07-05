# Makefile for uart_tx simulation
# Requires: Icarus Verilog (iverilog, vvp), optionally GTKWave
# Assertions require Verilator (iverilog does not support concurrent SVA)
#
# Install (macOS via Homebrew):
#   brew install icarus-verilog
#   brew install --cask gtkwave
#   brew install verilator
#
# Usage:
#   make sim      -> compile + run testbench (iverilog), print PASS/FAIL
#   make wave     -> open waveform in gtkwave (after make sim)
#   make assert   -> run testbench + SVA assertions (verilator)
#   make clean    -> remove build artifacts

RTL_DIR = rtl
TB_DIR  = tb
TOP_TB  = tb_uart_tx
OUT     = sim.out
VCD     = uart_tx.vcd

sim:
	iverilog -g2012 -o $(OUT) $(TB_DIR)/$(TOP_TB).v $(RTL_DIR)/uart_tx.v
	vvp $(OUT)

wave: sim
	gtkwave $(VCD) &

# Verilator run: RTL + testbench + assertion bind file.
# --assert enables concurrent assertion checking (SVA).
# --timing needed since this design uses posedge-based always blocks with delays via task waits.
assert:
	verilator --binary --assert --timing -Wno-fatal \
		--top-module $(TOP_TB) \
		$(RTL_DIR)/uart_tx.v \
		$(TB_DIR)/uart_tx_assertions.sv \
		$(TB_DIR)/uart_tx_bind.sv \
		$(TB_DIR)/$(TOP_TB).v \
		-o uart_tx_assert_sim
	obj_dir/uart_tx_assert_sim

clean:
	rm -f $(OUT) $(VCD)
	rm -rf obj_dir

.PHONY: sim wave assert clean
