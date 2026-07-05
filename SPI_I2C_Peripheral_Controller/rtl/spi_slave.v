//==============================================================================
// spi_slave.v
// Synthesizable SPI slave engine.
//
// SCLK/MOSI/CS_N are external, asynchronous to `clk`, so they are brought in
// through 2-FF synchronizers and edge-detected in the system clock domain.
// This assumes clk oversamples SCLK by a healthy margin (>=4x recommended) -
// a standard, documented constraint for synchronous-fabric SPI slaves.
//
// Supports all 4 SPI modes via {cpol,cpha}; multiple back-to-back bytes are
// supported while CS_N stays asserted (tx_data is re-latched after each byte).
//==============================================================================
module spi_slave #(
    parameter DW = 8
) (
    input  wire            clk,
    input  wire            rst_n,
    input  wire            en,

    input  wire            cpol,
    input  wire            cpha,

    input  wire            sclk_in,
    input  wire            mosi_in,
    input  wire            cs_n_in,
    output wire            miso_out,

    input  wire [DW-1:0]   tx_data,   // next byte to shift out
    output reg  [DW-1:0]   rx_data,
    output reg             rx_valid,  // 1-cycle pulse: full byte received
    output reg             busy
);

    // ---------------- input synchronizers ----------------
    reg [1:0] sclk_sync, cs_sync, mosi_sync;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sclk_sync <= 2'b00;
            cs_sync   <= 2'b11;
            mosi_sync <= 2'b00;
        end else begin
            sclk_sync <= {sclk_sync[0], sclk_in};
            cs_sync   <= {cs_sync[0],   cs_n_in};
            mosi_sync <= {mosi_sync[0], mosi_in};
        end
    end

    wire sclk_s = sclk_sync[1];
    wire cs_n_s = cs_sync[1];
    wire mosi_s = mosi_sync[1];

    reg sclk_prev, cs_n_prev;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sclk_prev <= 1'b0;
            cs_n_prev <= 1'b1;
        end else begin
            sclk_prev <= sclk_s;
            cs_n_prev <= cs_n_s;
        end
    end

    wire sclk_rise = ~sclk_prev &  sclk_s;
    wire sclk_fall =  sclk_prev & ~sclk_s;

    wire leading_edge  = cpol ? sclk_fall : sclk_rise;
    wire trailing_edge = cpol ? sclk_rise : sclk_fall;

    wire cs_falling = cs_n_prev & ~cs_n_s;  // start of transaction
    wire cs_rising  = ~cs_n_prev &  cs_n_s; // end of transaction

    // ---------------- shift engine ----------------
    reg [DW-1:0] tx_shreg;
    reg [DW-1:0] rx_shreg;
    reg [3:0]    bit_cnt;

    assign miso_out = tx_shreg[DW-1];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_shreg <= {DW{1'b0}};
            rx_shreg <= {DW{1'b0}};
            rx_data  <= {DW{1'b0}};
            bit_cnt  <= 4'd0;
            rx_valid <= 1'b0;
            busy     <= 1'b0;
        end else begin
            rx_valid <= 1'b0;

            if (!en) begin
                busy <= 1'b0;
            end else if (cs_falling) begin
                tx_shreg <= tx_data; // CPHA0: MSB pre-driven for master to sample
                bit_cnt  <= 4'd0;
                busy     <= 1'b1;
            end else if (cs_rising) begin
                busy <= 1'b0;
            end else if (busy) begin
                if (leading_edge) begin
                    if (!cpha)
                        rx_shreg <= {rx_shreg[DW-2:0], mosi_s}; // sample
                    else if (bit_cnt != 4'd0)
                        tx_shreg <= {tx_shreg[DW-2:0], 1'b0};   // drive next (skip on the
                                                                 // first leading edge of a
                                                                 // byte - the pre-loaded MSB
                                                                 // must stay put for it)
                end else if (trailing_edge) begin
                    if (!cpha) begin
                        tx_shreg <= {tx_shreg[DW-2:0], 1'b0};   // drive next
                    end else begin
                        rx_shreg <= {rx_shreg[DW-2:0], mosi_s}; // sample
                    end

                    if (bit_cnt == DW-1) begin
                        // byte complete: CPHA1 samples its final bit this
                        // very edge, so build rx_data from the fresh value;
                        // CPHA0 already holds the settled byte in rx_shreg.
                        rx_data  <= cpha ? {rx_shreg[DW-2:0], mosi_s} : rx_shreg;
                        rx_valid <= 1'b1;
                        bit_cnt  <= 4'd0;
                        tx_shreg <= tx_data; // reload for next byte, CS still low
                    end else begin
                        bit_cnt <= bit_cnt + 4'd1;
                    end
                end
            end
        end
    end

endmodule
