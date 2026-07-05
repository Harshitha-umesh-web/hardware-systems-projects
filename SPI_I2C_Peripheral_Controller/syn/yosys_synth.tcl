#==============================================================================
# yosys_synth.tcl
# Synthesis script for the SPI/I2C controller.
#
# Usage:
#   yosys -c syn/yosys_synth.tcl -- <path/to/cells.lib>
#   (liberty path is optional - omit it to run a generic/FPGA-style synth
#   for structural/area review when no PDK liberty is on hand)
#
# Any freely available open-PDK liberty works, e.g. sky130_fd_sc_hd or
# Nangate/FreePDK45 - this script only assumes standard cells with the
# usual combinational + DFF + latch primitives; no vendor-specific setup.
#==============================================================================

set top       "spi_i2c_top"
set rtl_dir   "rtl"
set out_dir   "syn/out"
set liberty   ""

# grab optional liberty path passed after "--"
if {$argc > 0} {
    set liberty [lindex $argv 0]
}

file mkdir $out_dir

# ---- read RTL ----
read_verilog -sv $rtl_dir/clk_gate.v
read_verilog -sv $rtl_dir/spi_master.v
read_verilog -sv $rtl_dir/spi_slave.v
read_verilog -sv $rtl_dir/i2c_master.v
read_verilog -sv $rtl_dir/i2c_slave.v
read_verilog -sv $rtl_dir/spi_i2c_regs.v
read_verilog -sv $rtl_dir/spi_i2c_top.v

hierarchy -check -top $top

# ---- generic elaboration / cleanup, shared by both flows ----
proc do_generic_passes {} {
    synth -run coarse
    opt_clean
    memory_collect
    fsm
    opt
}

do_generic_passes

if {$liberty ne ""} {
    puts "==> Liberty-targeted synthesis using: $liberty"

    dfflibmap -liberty $liberty
    abc -liberty $liberty

    # keep the latch-based clock-gate cell intact rather than letting ABC
    # dissolve it into random logic - preserves the intended ICG structure
    # for downstream power/CTS tools; comment out if your flow inserts ICG
    # cells automatically via `clockgate` insertion instead.
    setattr -mod -set keep 1 clk_gate

    opt_clean
    stat -liberty $liberty
    write_verilog -noattr $out_dir/${top}_netlist.v
    write_json         $out_dir/${top}_netlist.json
} else {
    puts "==> No liberty supplied - running generic synth for structural/area review only"
    puts "    (results are NOT representative of real silicon area/timing)"

    synth -top $top
    opt -purge
    stat
    write_verilog -noattr $out_dir/${top}_generic_netlist.v
}

puts "==> Synthesis complete. Netlist(s) written to $out_dir/"
