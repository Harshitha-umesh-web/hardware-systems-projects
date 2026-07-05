#==============================================================================
# constraints.sdc
# Timing constraints for spi_i2c_top. Targets a modest 100 MHz system clock;
# the SPI/I2C engines themselves run far slower (clkdiv-generated), so the
# critical path is expected to live in the APB register file and the FSM
# next-state logic, not the protocol pins.
#==============================================================================

set CLK_PORT   clk
set CLK_PERIOD 10.0   ;# 100 MHz

create_clock -name sys_clk -period $CLK_PERIOD [get_ports $CLK_PORT]
set_clock_uncertainty 0.3  [get_clocks sys_clk]
set_clock_transition  0.15 [get_clocks sys_clk]

# asynchronous reset / DFT signal - not timed against sys_clk
set_false_path -from [get_ports rst_n]
set_false_path -from [get_ports test_en]

# APB is a simple synchronous register interface running at sys_clk;
# assume a reasonably fast host, giving generous but non-zero I/O delays.
set_input_delay  -clock sys_clk 2.0 [get_ports {psel penable pwrite paddr* pwdata*}]
set_output_delay -clock sys_clk 2.0 [get_ports {prdata* pready irq}]

# The SPI/I2C physical pins are asynchronous relative to sys_clk from the
# ASIC's point of view (external bus, brought in through synchronizers
# inside spi_slave/i2c_slave); treat them as false paths for internal
# timing closure, but still bound transition/load so pad drivers don't get
# sized arbitrarily.
set_false_path -from [get_ports {sclk_io mosi_io miso_io cs_n_io scl_io sda_io}]
set_false_path -to   [get_ports {sclk_io mosi_io miso_io cs_n_io scl_io sda_io}]

set_max_transition 0.5 [current_design]
set_max_fanout      16 [current_design]

set_load 0.05 [get_ports {prdata* pready irq sclk_io mosi_io miso_io cs_n_io scl_io sda_io}]
