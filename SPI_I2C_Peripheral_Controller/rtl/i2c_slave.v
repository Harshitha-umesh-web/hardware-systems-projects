//==============================================================================
// i2c_slave.v
// Synthesizable I2C slave engine, 7-bit addressing, single data byte per
// transaction (matches i2c_master.v's single-byte transaction model).
//
// The slave never generates SCL (no clock stretching in this core - noted
// as a scope simplification; see docs/README.md). It reacts to SCL edges
// supplied by whichever master owns the bus:
//   - samples incoming bits (address, write data, master's own ACK) on the
//     SCL rising edge,
//   - drives its own outgoing bits (ACK, read data) starting at the SCL
//     falling edge so the value is settled well before the next rising edge.
//
// START = SDA falls while SCL is steady high. STOP = SDA rises while SCL is
// steady high. Either is detected combinationally from the synchronized bus
// and takes priority over whatever phase the FSM is in, per the I2C spec.
//==============================================================================
module i2c_slave #(
    parameter AW = 7
) (
    input  wire            clk,
    input  wire            rst_n,
    input  wire            en,
    input  wire [AW-1:0]   own_addr,

    input  wire [7:0]      tx_data,    // byte returned when a master reads us
    output reg  [7:0]      rx_data,
    output reg             rx_valid,   // 1-cycle pulse: full byte received
    output reg             busy,
    output reg             addr_match, // 1-cycle pulse: we were addressed

    input  wire            scl_in,
    output reg             sda_oe,     // 1 = actively pull SDA low
    input  wire            sda_in
);

    // ---------------- input synchronizers ----------------
    reg [1:0] scl_sync, sda_sync;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            scl_sync <= 2'b11;
            sda_sync <= 2'b11;
        end else begin
            scl_sync <= {scl_sync[0], scl_in};
            sda_sync <= {sda_sync[0], sda_in};
        end
    end
    wire scl_s = scl_sync[1];
    wire sda_s = sda_sync[1];

    reg scl_prev, sda_prev;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            scl_prev <= 1'b1;
            sda_prev <= 1'b1;
        end else begin
            scl_prev <= scl_s;
            sda_prev <= sda_s;
        end
    end

    wire scl_rise = ~scl_prev &  scl_s;
    wire scl_fall =  scl_prev & ~scl_s;
    wire start_cond = scl_prev & scl_s &  sda_prev & ~sda_s; // SDA falls, SCL steady high
    wire stop_cond  = scl_prev & scl_s & ~sda_prev &  sda_s; // SDA rises, SCL steady high

    // ---------------- main FSM ----------------
    localparam S_IDLE      = 3'd0;
    localparam S_ADDR      = 3'd1;
    localparam S_ADDR_ACK  = 3'd2;
    localparam S_WDATA     = 3'd3;
    localparam S_WDATA_ACK  = 3'd4;
    localparam S_RDATA      = 3'd5;
    localparam S_RACK       = 3'd6;
    localparam S_MISMATCH   = 3'd7;
    localparam S_WDATA_DONE = 4'd8; // holds the ACK drive until master truly moves on

    reg [3:0] state;
    reg [3:0] bit_cnt;
    reg [7:0] rx_shreg;
    reg [7:0] tx_shreg;
    reg [7:0] addr_rw_byte;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= S_IDLE;
            bit_cnt      <= 4'd0;
            rx_shreg     <= 8'd0;
            tx_shreg     <= 8'd0;
            addr_rw_byte <= 8'd0;
            sda_oe       <= 1'b0;
            busy         <= 1'b0;
            rx_data      <= 8'd0;
            rx_valid     <= 1'b0;
            addr_match   <= 1'b0;
        end else begin
            rx_valid   <= 1'b0;
            addr_match <= 1'b0;

            if (stop_cond) begin
                state  <= S_IDLE;
                busy   <= 1'b0;
                sda_oe <= 1'b0;
            end else if (!en) begin
                state  <= S_IDLE;
                busy   <= 1'b0;
                sda_oe <= 1'b0;
            end else if (start_cond) begin
                state   <= S_ADDR;
                bit_cnt <= 4'd7;
                busy    <= 1'b1;
                sda_oe  <= 1'b0;
            end else begin
                case (state)
                    S_IDLE: sda_oe <= 1'b0;

                    //---------------------------------------------
                    S_ADDR: begin
                        if (scl_rise) begin
                            rx_shreg <= {rx_shreg[6:0], sda_s};
                            if (bit_cnt == 4'd0) begin
                                addr_rw_byte <= {rx_shreg[6:0], sda_s};
                                state        <= S_ADDR_ACK;
                            end else begin
                                bit_cnt <= bit_cnt - 4'd1;
                            end
                        end
                    end

                    //---------------------------------------------
                    S_ADDR_ACK: begin
                        if (scl_fall)
                            sda_oe <= (addr_rw_byte[7:1] == own_addr); // ACK if matched
                        if (scl_rise) begin
                            if (addr_rw_byte[7:1] == own_addr) begin
                                addr_match <= 1'b1;
                                bit_cnt    <= 4'd7;
                                if (addr_rw_byte[0]) begin // master wants to read us
                                    tx_shreg <= tx_data;
                                    state    <= S_RDATA;
                                end else begin            // master will write us
                                    state <= S_WDATA;
                                end
                            end else begin
                                state <= S_MISMATCH;
                            end
                        end
                    end

                    //---------------------------------------------
                    S_WDATA: begin
                        // Only release at scl_fall (start of this bit's low
                        // phase). Releasing unconditionally here would fire
                        // on the very first cycle of this state - which is
                        // still mid-high-phase of the preceding ACK bit -
                        // and SDA falling->rising while SCL is steady high
                        // looks exactly like a STOP condition on the bus.
                        if (scl_fall) sda_oe <= 1'b0; // release: master drives data
                        if (scl_rise) begin
                            rx_shreg <= {rx_shreg[6:0], sda_s};
                            if (bit_cnt == 4'd0) begin
                                rx_data <= {rx_shreg[6:0], sda_s};
                                state   <= S_WDATA_ACK;
                            end else begin
                                bit_cnt <= bit_cnt - 4'd1;
                            end
                        end
                    end

                    //---------------------------------------------
                    S_WDATA_ACK: begin
                        if (scl_fall) sda_oe <= 1'b1; // slave ACKs the byte
                        if (scl_rise) begin
                            rx_valid <= 1'b1;
                            // Don't release SDA or go to S_IDLE yet - S_IDLE
                            // releases unconditionally, and the master won't
                            // actually finish sampling this ACK bit (its own
                            // high-phase timer) for a while yet. Releasing
                            // now would make SDA float high while the
                            // master's SCL is still high - an apparent STOP.
                            // Keep driving until the master genuinely pulls
                            // SCL low again for whatever comes next.
                            state <= S_WDATA_DONE;
                        end
                    end

                    //---------------------------------------------
                    S_WDATA_DONE: begin
                        if (scl_fall) begin
                            sda_oe <= 1'b0;
                            state  <= S_IDLE;
                        end
                    end

                    //---------------------------------------------
                    S_RDATA: begin
                        if (scl_fall) sda_oe <= ~tx_shreg[7];
                        if (scl_rise) begin
                            if (bit_cnt == 4'd0) begin
                                state <= S_RACK;
                            end else begin
                                bit_cnt  <= bit_cnt - 4'd1;
                                tx_shreg <= {tx_shreg[6:0], 1'b0};
                            end
                        end
                    end

                    //---------------------------------------------
                    S_RACK: begin
                        // same reasoning as S_WDATA above: only release at
                        // scl_fall, not unconditionally on state entry.
                        if (scl_fall) sda_oe <= 1'b0; // release: master drives ACK/NACK
                        if (scl_rise)
                            state <= S_IDLE; // master's ack/nack sampled by testbench monitor
                    end

                    //---------------------------------------------
                    S_MISMATCH: begin
                        sda_oe <= 1'b0; // not addressed - stay off the bus
                    end

                    default: state <= S_IDLE;
                endcase
            end
        end
    end

endmodule
