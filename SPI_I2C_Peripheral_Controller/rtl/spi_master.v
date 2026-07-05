//==============================================================================
// spi_master.v
// Synthesizable SPI master engine.
//
// - Supports all 4 SPI modes via {cpol,cpha}.
// - SCLK frequency = clk / (2*(clkdiv+1)).
// - Single in-flight transfer of DW bits, MSB first, full-duplex.
// - Uses two independent shift registers (tx_shreg drives MOSI, rx_shreg
//   captures MISO) so the drive-edge and sample-edge can differ per CPHA
//   without aliasing TX/RX data in one register.
//
// Protocol timing reference (SPI mode terminology):
//   CPHA=0: data driven a half period *before* the first SCLK edge
//           (during CS assertion), sampled on the leading edge, next bit
//           driven on the trailing edge.
//   CPHA=1: data driven on the leading edge, sampled on the trailing edge.
//   CPOL selects the idle level of SCLK (0 = idle low, 1 = idle high).
//==============================================================================
module spi_master #(
    parameter DW = 8
) (
    input  wire            clk,
    input  wire            rst_n,

    input  wire            en,        // block enable; must be 1 to start
    input  wire            start,     // 1-cycle pulse: begin a transfer
    input  wire            cpol,
    input  wire            cpha,
    input  wire [15:0]     clkdiv,    // SCLK half-period in clk cycles - 1

    input  wire [DW-1:0]   tx_data,
    output reg  [DW-1:0]   rx_data,
    output reg             busy,
    output reg             done,      // 1-cycle pulse on transfer completion

    output reg             sclk,
    output wire            mosi,
    input  wire            miso,
    output reg             cs_n
);

    localparam ST_IDLE     = 3'd0;
    localparam ST_CS_SETUP = 3'd1;
    localparam ST_RUN      = 3'd2;
    localparam ST_CS_HOLD  = 3'd3;

    localparam EDGE_W  = 8; // supports DW up to 127
    localparam EDGE_MAX = (2*DW) - 1;

    reg [2:0]        state;
    reg [15:0]       div_cnt;
    reg [EDGE_W-1:0] edge_idx;
    reg [DW-1:0]     tx_shreg;
    reg [DW-1:0]     rx_shreg;

    wire div_tick = (div_cnt == clkdiv);
    wire is_leading_edge = ~edge_idx[0]; // even index = leading edge

    assign mosi = tx_shreg[DW-1];

    // clock divider counter - runs whenever a transfer is in flight
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            div_cnt <= 16'd0;
        else if (state == ST_IDLE)
            div_cnt <= 16'd0;
        else if (div_tick)
            div_cnt <= 16'd0;
        else
            div_cnt <= div_cnt + 16'd1;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state    <= ST_IDLE;
            sclk     <= 1'b0;
            cs_n     <= 1'b1;
            busy     <= 1'b0;
            done     <= 1'b0;
            edge_idx <= {EDGE_W{1'b0}};
            tx_shreg <= {DW{1'b0}};
            rx_shreg <= {DW{1'b0}};
            rx_data  <= {DW{1'b0}};
        end else begin
            done <= 1'b0;

            case (state)
                //-----------------------------------------------------
                ST_IDLE: begin
                    sclk <= cpol;
                    cs_n <= 1'b1;
                    busy <= 1'b0;
                    if (en && start) begin
                        tx_shreg <= tx_data; // CPHA0: MSB now valid on MOSI
                        cs_n     <= 1'b0;
                        busy     <= 1'b1;
                        edge_idx <= {EDGE_W{1'b0}};
                        state    <= ST_CS_SETUP;
                    end
                end

                //-----------------------------------------------------
                ST_CS_SETUP: begin
                    // hold CS asserted for one divider period before the
                    // first SCLK edge (satisfies CS-to-SCLK setup time and
                    // gives CPHA=0 slaves time to see the pre-driven bit)
                    if (div_tick)
                        state <= ST_RUN;
                end

                //-----------------------------------------------------
                ST_RUN: begin
                    if (div_tick) begin
                        sclk <= ~sclk;

                        if (is_leading_edge) begin
                            if (!cpha)
                                rx_shreg <= {rx_shreg[DW-2:0], miso}; // sample
                            else if (edge_idx != 0)
                                tx_shreg <= {tx_shreg[DW-2:0], 1'b0}; // drive next
                        end else begin
                            if (!cpha)
                                tx_shreg <= {tx_shreg[DW-2:0], 1'b0}; // drive next
                            else
                                rx_shreg <= {rx_shreg[DW-2:0], miso}; // sample
                        end

                        if (edge_idx == EDGE_MAX) begin
                            state   <= ST_CS_HOLD;
                            // CPHA=0 already sampled the last bit on the
                            // previous leading edge, so rx_shreg is already
                            // complete here - use it as-is. CPHA=1 samples
                            // its last bit on this very (trailing) edge, so
                            // rx_shreg is still one cycle stale here and we
                            // must build the final value fresh from miso.
                            rx_data <= (!cpha) ? rx_shreg
                                               : {rx_shreg[DW-2:0], miso};
                        end else begin
                            edge_idx <= edge_idx + 1'b1;
                        end
                    end
                end

                //-----------------------------------------------------
                ST_CS_HOLD: begin
                    if (div_tick) begin
                        cs_n  <= 1'b1;
                        busy  <= 1'b0;
                        done  <= 1'b1;
                        state <= ST_IDLE;
                    end
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule
