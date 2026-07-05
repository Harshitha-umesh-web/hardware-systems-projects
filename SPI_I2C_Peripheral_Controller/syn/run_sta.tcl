#==============================================================================
# run_sta.tcl
# OpenSTA static timing analysis for the synthesized SPI/I2C controller.
#
# Usage:
#   sta -no_init syn/run_sta.tcl \
#       -var liberty  path/to/cells.lib \
#       -var netlist  syn/out/spi_i2c_top_netlist.v \
#       -var top      spi_i2c_top
#
# (OpenSTA reads -var via `sta_util::` in some builds; if your OpenSTA
# version doesn't support -var, just hardcode the three paths below.)
#==============================================================================

set liberty_path  [expr {[info exists ::liberty] ? $::liberty : "cells.lib"}]
set netlist_path  [expr {[info exists ::netlist] ? $::netlist : "syn/out/spi_i2c_top_netlist.v"}]
set top_name      [expr {[info exists ::top]     ? $::top     : "spi_i2c_top"}]

read_liberty $liberty_path
read_verilog $netlist_path
link_design  $top_name

read_sdc syn/constraints.sdc

set_propagated_clock [all_clocks]

report_checks -path_delay min_max -fields {slew cap input_pin} -digits 3

puts "\n==================== SUMMARY ===================="
report_worst_slack -max
report_worst_slack -min
report_tns
report_wns

puts "\n==================== POWER (if supported) ===================="
report_power

puts "\n==================== AREA ===================="
report_design_area
