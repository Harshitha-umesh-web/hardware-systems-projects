//==============================================================================
// clk_gate.v
// Latch-based clock gating cell (standard "ICG" RTL idiom).
//
// Gates clk_in with `enable`, using a negedge-triggered latch to re-time the
// enable so the gated clock cannot glitch when `enable` changes near a rising
// edge of clk_in. `test_en` forces the clock through during scan/ATPG.
//
// In a real ASIC flow this RTL pattern is what synthesis tools (DC, Genus,
// Yosys+techmap) recognize and map onto a technology clock-gating cell
// (e.g. CKLNQD*, or CLKGATE_X1 in an open PDK) -- do NOT rely on the raw
// latch+AND surviving synthesis untouched; that mapping is what actually
// saves power. See syn/yosys_synth.tcl for how this is handled.
//==============================================================================
module clk_gate (
    input  wire clk_in,
    input  wire enable,   // level enable: 1 = clock passes through
    input  wire test_en,  // scan/DFT override: forces clock always-on
    output wire clk_out
);

    reg en_latched;

    always @(negedge clk_in) begin
        if (test_en)
            en_latched <= 1'b1;
        else
            en_latched <= enable;
    end

    assign clk_out = clk_in & en_latched;

endmodule
