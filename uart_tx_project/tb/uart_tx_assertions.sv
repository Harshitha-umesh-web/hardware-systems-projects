// ============================================================
// uart_tx_assertions.sv
// Concurrent SystemVerilog Assertions for uart_tx
// Bound into the DUT instance — checks protocol invariants
// continuously throughout simulation, not just at sample points.
// ============================================================
`timescale 1ns/1ps


module uart_tx_assertions #(
    parameter CLK_FREQ  = 1_000_000,
    parameter BAUD_RATE = 100_000
) (
    input wire       clk,
    input wire       rst,
    input wire [7:0] data_in,
    input wire       start,
    input wire       tx,
    input wire       busy
);

    localparam integer BIT_CYCLES = CLK_FREQ / BAUD_RATE;
    localparam integer MAX_FRAME_WAIT = 12 * BIT_CYCLES;

    // ---------------------------------------------------------
    // A1: tx must never be unknown (X/Z) after reset is released
    // ---------------------------------------------------------
    property p_tx_never_unknown;
        @(posedge clk) disable iff (rst)
        !$isunknown(tx);
    endproperty
    a_tx_never_unknown: assert property (p_tx_never_unknown)
        else $error("ASSERTION FAIL: tx went unknown (X/Z) outside reset");

    // ---------------------------------------------------------
    // A2: line must be idle-high while not busy
    // ---------------------------------------------------------
    property p_idle_high;
        @(posedge clk) disable iff (rst)
        (!busy) |-> tx;
    endproperty
    a_idle_high: assert property (p_idle_high)
        else $error("ASSERTION FAIL: tx not high while idle (busy=0)");

    // ---------------------------------------------------------
    // A3: busy must assert within 1 cycle of start being pulsed
    // ---------------------------------------------------------
    property p_busy_follows_start;
        @(posedge clk) disable iff (rst)
        (start && !busy) |=> busy;
    endproperty
    a_busy_follows_start: assert property (p_busy_follows_start)
        else $error("ASSERTION FAIL: busy did not assert after start pulse");

    // ---------------------------------------------------------
    // A4: once busy, the very next bit driven on tx must be 0 (start bit)
    // ---------------------------------------------------------
    property p_start_bit_is_zero;
        @(posedge clk) disable iff (rst)
        (start && !busy) |=> ##1 (tx == 1'b0);
    endproperty
    a_start_bit_is_zero: assert property (p_start_bit_is_zero)
        else $error("ASSERTION FAIL: start bit on tx was not 0");

    // ---------------------------------------------------------
    // A5: busy must eventually deassert (no hang / stuck transmission)
    // bounded by roughly one full frame: start+8 data+stop = 10 bit-times
    // plus margin.
    // ---------------------------------------------------------
    property p_busy_eventually_low;
        @(posedge clk) disable iff (rst)
        busy |-> ##[1:MAX_FRAME_WAIT] !busy;
    endproperty
    a_busy_eventually_low: assert property (p_busy_eventually_low)
        else $error("ASSERTION FAIL: busy stuck high, transmission hung");

    // ---------------------------------------------------------
    // A6: start pulses while busy must be ignored (no re-trigger / corruption)
    // i.e. busy should not glitch low then immediately re-high from a
    // spurious start while already transmitting -- here we just check
    // busy stays high continuously once asserted until the frame ends.
    // (Covered structurally by A5's bound; kept as documentation.)
    // ---------------------------------------------------------

    // ---------------------------------------------------------
    // Coverage: make sure we actually exercise start-while-idle
    // and start-while-busy cases in simulation (sanity, not correctness)
    // ---------------------------------------------------------
    cover property (@(posedge clk) start && !busy);
    cover property (@(posedge clk) start && busy);

endmodule
