// ============================================================
// uart_tx.v
// Simple 8-bit UART Transmitter
// Frame: 1 start bit (0), 8 data bits (LSB first), 1 stop bit (1)
// Baud rate set by CLK_FREQ / BAUD_RATE parameters (clock divider)
// ============================================================
`timescale 1ns/1ps


module uart_tx #(
    parameter CLK_FREQ  = 50_000_000,  // system clock frequency in Hz
    parameter BAUD_RATE = 115_200      // desired baud rate
) (
    input  wire       clk,
    input  wire       rst,        // synchronous, active-high
    input  wire [7:0] data_in,    // byte to transmit
    input  wire       start,      // pulse high for 1 cycle to begin transmission
    output reg        tx,         // serial output line (idle = 1)
    output reg        busy        // high while transmitting
);

    localparam integer DIV_COUNT = CLK_FREQ / BAUD_RATE;

    // FSM states
    localparam [1:0] IDLE  = 2'd0,
                      START = 2'd1,
                      DATA  = 2'd2,
                      STOP  = 2'd3;

    reg [1:0]  state;
    reg [15:0] clk_cnt;     // baud tick counter
    reg [2:0]  bit_idx;     // which data bit we're on (0-7)
    reg [7:0]  data_shift;  // latched data being shifted out

    wire baud_tick = (clk_cnt == DIV_COUNT - 1);

    always @(posedge clk) begin
        if (rst) begin
            state      <= IDLE;
            clk_cnt    <= 16'd0;
            bit_idx    <= 3'd0;
            data_shift <= 8'd0;
            tx         <= 1'b1;   // idle line is high
            busy       <= 1'b0;
        end else begin
            case (state)

                IDLE: begin
                    tx      <= 1'b1;
                    busy    <= 1'b0;
                    clk_cnt <= 16'd0;
                    if (start) begin
                        data_shift <= data_in;
                        busy       <= 1'b1;
                        state      <= START;
                    end
                end

                START: begin
                    tx <= 1'b0;   // start bit
                    if (baud_tick) begin
                        clk_cnt <= 16'd0;
                        bit_idx <= 3'd0;
                        state   <= DATA;
                    end else begin
                        clk_cnt <= clk_cnt + 16'd1;
                    end
                end

                DATA: begin
                    tx <= data_shift[bit_idx]; // LSB first
                    if (baud_tick) begin
                        clk_cnt <= 16'd0;
                        if (bit_idx == 3'd7) begin
                            state <= STOP;
                        end else begin
                            bit_idx <= bit_idx + 3'd1;
                        end
                    end else begin
                        clk_cnt <= clk_cnt + 16'd1;
                    end
                end

                STOP: begin
                    tx <= 1'b1;   // stop bit
                    if (baud_tick) begin
                        clk_cnt <= 16'd0;
                        busy    <= 1'b0;
                        state   <= IDLE;
                    end else begin
                        clk_cnt <= clk_cnt + 16'd1;
                    end
                end

                default: state <= IDLE;

            endcase
        end
    end

endmodule
