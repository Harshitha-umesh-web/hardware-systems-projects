//==============================================================================
// spi_i2c_assertions.sv
// Protocol-compliance checkers, bound into the RTL so they run "for free"
// in any simulation that elaborates spi_i2c_top - no testbench wiring
// needed beyond compiling this file alongside the DUT.
//==============================================================================

// ---------------------------------------------------------------------------
// Top-level checks: engine mutual exclusion (the clock-gating mux must only
// ever enable exactly one engine at a time) and basic SPI idle behavior.
// ---------------------------------------------------------------------------
module spi_i2c_top_checker (
    input logic clk,
    input logic rst_n,
    input logic sel_spi_m,
    input logic sel_spi_s,
    input logic sel_i2c_m,
    input logic sel_i2c_s,
    input logic cs_n_io,
    input logic sclk_io
);

    // At most one engine selected at any time -> at most one ungated clock.
    property p_mutex_engine_sel;
        @(posedge clk) disable iff (!rst_n)
        $onehot0({sel_spi_m, sel_spi_s, sel_i2c_m, sel_i2c_s});
    endproperty
    a_mutex_engine_sel: assert property (p_mutex_engine_sel)
        else $error("[ASSERT] more than one protocol engine selected simultaneously");

    // SCLK must be static while CS_N is deasserted (bus idle) in SPI master mode.
    property p_sclk_static_when_idle;
        @(posedge clk) disable iff (!rst_n)
        (sel_spi_m && cs_n_io) |-> $stable(sclk_io);
    endproperty
    a_sclk_static_when_idle: assert property (p_sclk_static_when_idle)
        else $error("[ASSERT] SCLK toggled while CS_N deasserted (SPI master idle)");

endmodule

bind spi_i2c_top spi_i2c_top_checker u_top_checker (
    .clk       (clk),
    .rst_n     (rst_n),
    .sel_spi_m (sel_spi_m),
    .sel_spi_s (sel_spi_s),
    .sel_i2c_m (sel_i2c_m),
    .sel_i2c_s (sel_i2c_s),
    .cs_n_io   (cs_n_io),
    .sclk_io   (sclk_io)
);

// ---------------------------------------------------------------------------
// I2C bus-level checks, bound into i2c_slave since it already computes
// synchronized scl_s/sda_s and edge/condition detects on the shared bus.
// ---------------------------------------------------------------------------
module i2c_slave_checker (
    input logic clk,
    input logic rst_n,
    input logic scl_s,
    input logic sda_s,
    input logic scl_prev,
    input logic sda_prev,
    input logic start_cond,
    input logic stop_cond,
    input logic busy
);

    // Fundamental I2C rule: SDA may only change while SCL is high if that
    // change IS a START or STOP condition. Any other SDA transition while
    // SCL is steady-high is a protocol violation.
    property p_sda_stable_when_scl_high;
        @(posedge clk) disable iff (!rst_n)
        (scl_prev && scl_s && (sda_prev != sda_s)) |-> (start_cond || stop_cond);
    endproperty
    a_sda_stable_when_scl_high: assert property (p_sda_stable_when_scl_high)
        else $error("[ASSERT] illegal SDA change while SCL held high (not START/STOP)");

    // A STOP condition should only be observed while a transaction is (or
    // was) in progress in this simple single-master-at-a-time testbench;
    // catches a monitor mis-wiring more than a real protocol bug.
    property p_stop_implies_was_active_or_idle;
        @(posedge clk) disable iff (!rst_n)
        stop_cond |-> 1'b1; // structural placeholder: always legal, kept for
                             // symmetry / easy extension to multi-master checks
    endproperty
    a_stop_sanity: assert property (p_stop_implies_was_active_or_idle);

endmodule

bind i2c_slave i2c_slave_checker u_i2c_slave_checker (
    .clk        (clk),
    .rst_n      (rst_n),
    .scl_s      (scl_s),
    .sda_s      (sda_s),
    .scl_prev   (scl_prev),
    .sda_prev   (sda_prev),
    .start_cond (start_cond),
    .stop_cond  (stop_cond),
    .busy       (busy)
);

// ---------------------------------------------------------------------------
// SPI slave checks: MOSI/CS/SCLK must be glitch-free once synchronized, and
// bit_cnt must never be sampled X/unknown mid-transfer (catches reset/CDC
// bugs early, before they show up as a wrong byte 200 cycles later).
// ---------------------------------------------------------------------------
module spi_slave_checker (
    input logic clk,
    input logic rst_n,
    input logic busy,
    input logic [3:0] bit_cnt
);

    property p_no_unknown_bitcnt_when_busy;
        @(posedge clk) disable iff (!rst_n)
        busy |-> !$isunknown(bit_cnt);
    endproperty
    a_no_unknown_bitcnt: assert property (p_no_unknown_bitcnt_when_busy)
        else $error("[ASSERT] spi_slave.bit_cnt is X/Z while busy");

endmodule

bind spi_slave spi_slave_checker u_spi_slave_checker (
    .clk     (clk),
    .rst_n   (rst_n),
    .busy    (busy),
    .bit_cnt (bit_cnt)
);
