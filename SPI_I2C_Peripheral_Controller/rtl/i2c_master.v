//==============================================================================
// i2c_master.v
// Synthesizable I2C master engine (single-byte transactions, 7-bit addressing).
//
// Bus model: open-drain, modeled as separate output-enable (`*_oe`, 1 = pull
// line low) and input (`*_in`) per wire; an external pull-up (or the
// testbench's pull-up model) brings the line high whenever oe=0 on every
// driver. The actual tri-state pad belongs at the top level / IO ring, not
// in this core.
//
// Sequence: START -> 7-bit addr + R/W -> slave ACK -> one data byte
// (direction per R/W) -> ACK (write: slave drives / read: master drives,
// always NACK since this is a single-byte transfer) -> STOP.
//
// Features:
//   - Clock stretching: after releasing SCL, the master waits for
//     scl_in==1 before starting the high-phase timer, so a slow slave can
//     hold SCL low to gain time.
//   - Simple arbitration-loss detection: whenever the master releases SDA
//     expecting it to float high, if sda_in reads back 0 while SCL is high,
//     another device is driving the bus -> abort, flag arb_lost.
//
// clkdiv sets each SCL half-period in clk cycles (SCL period is
// approximately 2*(clkdiv+1) clk cycles, plus any clock-stretch delay).
//==============================================================================
module i2c_master #(
    parameter AW = 7
) (
    input  wire            clk,
    input  wire            rst_n,
    input  wire            en,
    input  wire            start,       // 1-cycle pulse: begin a transaction
    input  wire [15:0]     clkdiv,

    input  wire [AW-1:0]   slv_addr,
    input  wire            rw,          // 0 = write, 1 = read
    input  wire [7:0]      wr_data,
    output reg  [7:0]      rd_data,

    output reg             busy,
    output reg             done,        // 1-cycle pulse on completion
    output reg             ack_err,     // address or data byte was NACKed
    output reg             arb_lost,

    output reg             scl_oe,      // 1 = actively pull SCL low
    input  wire            scl_in,
    output reg             sda_oe,      // 1 = actively pull SDA low
    input  wire            sda_in
);

    // ---- macro sequencing states ----
    localparam S_IDLE       = 3'd0;
    localparam S_START      = 3'd1;
    localparam S_CLK_LOW    = 3'd2;
    localparam S_CLK_RELSCL = 3'd3; // release SCL, wait out any stretching
    localparam S_CLK_HIGH   = 3'd4;
    localparam S_STOP_SETUP = 3'd5; // force SDA low with SCL low before STOP
    localparam S_STOP       = 3'd6; // release SDA while SCL high -> STOP
    localparam S_DONE       = 3'd7;

    // ---- which byte/ack the S_CLK_* loop is currently clocking ----
    localparam P_ADDR       = 3'd0; // master drives addr+rw bits
    localparam P_ADDR_ACK   = 3'd1; // slave drives ack
    localparam P_WDATA      = 3'd2; // master drives write-data bits
    localparam P_WDATA_ACK  = 3'd3; // slave drives ack
    localparam P_RDATA      = 3'd4; // slave drives read-data bits
    localparam P_RACK       = 3'd5; // master drives ack/nack (always nack here)

    reg [2:0]  state;
    reg [2:0]  phase;
    reg [3:0]  bit_cnt;
    reg [7:0]  shreg;
    reg [15:0] div_cnt;

    wire div_tick = (div_cnt == clkdiv);
    wire timed_state = (state == S_CLK_LOW)  || (state == S_CLK_HIGH) ||
                        (state == S_START)    || (state == S_STOP_SETUP) ||
                        (state == S_STOP);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            div_cnt <= 16'd0;
        else if (!timed_state || div_tick)
            div_cnt <= 16'd0;
        else
            div_cnt <= div_cnt + 16'd1;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state    <= S_IDLE;
            phase    <= P_ADDR;
            bit_cnt  <= 4'd0;
            shreg    <= 8'd0;
            scl_oe   <= 1'b0;
            sda_oe   <= 1'b0;
            busy     <= 1'b0;
            done     <= 1'b0;
            ack_err  <= 1'b0;
            arb_lost <= 1'b0;
            rd_data  <= 8'd0;
        end else begin
            done <= 1'b0;

            case (state)
                //-----------------------------------------------------
                S_IDLE: begin
                    scl_oe   <= 1'b0; // bus idle: both lines released high
                    sda_oe   <= 1'b0;
                    ack_err  <= 1'b0;
                    arb_lost <= 1'b0;
                    if (en && start) begin
                        busy    <= 1'b1;
                        shreg   <= {slv_addr, rw};
                        bit_cnt <= 4'd7;
                        phase   <= P_ADDR;
                        state   <= S_START;
                    end
                end

                //-----------------------------------------------------
                S_START: begin
                    // SCL assumed released/high on entry; pull SDA low
                    // while SCL is still high -> START condition.
                    sda_oe <= 1'b1;
                    if (div_tick)
                        state <= S_CLK_LOW; // fall into bit 0 (MSB) of addr
                end

                //-----------------------------------------------------
                S_CLK_LOW: begin
                    scl_oe <= 1'b1; // drive SCL low, set up SDA underneath it
                    case (phase)
                        P_ADDR, P_WDATA:  sda_oe <= ~shreg[7];
                        P_ADDR_ACK, P_WDATA_ACK, P_RDATA: sda_oe <= 1'b0; // release for peer
                        P_RACK:           sda_oe <= 1'b0; // NACK = release (single-byte read)
                        default:          sda_oe <= 1'b0;
                    endcase
                    if (div_tick)
                        state <= S_CLK_RELSCL;
                end

                //-----------------------------------------------------
                S_CLK_RELSCL: begin
                    scl_oe <= 1'b0; // release SCL, let pull-up bring it high
                    if (scl_in)     // stalls here while a slave stretches
                        state <= S_CLK_HIGH;
                end

                //-----------------------------------------------------
                S_CLK_HIGH: begin
                    // Arbitration only applies while the master itself is
                    // trying to assert a bit value (address/write-data
                    // phases). During ACK phases and read-data, releasing
                    // SDA is deliberate - it's the slave's turn to drive,
                    // and it pulling SDA low (e.g. a normal ACK) is
                    // expected, not a bus conflict.
                    if (!sda_oe && !sda_in && (phase == P_ADDR || phase == P_WDATA)) begin
                        // expected SDA released/high but bus reads low:
                        // another driver is on the bus.
                        arb_lost <= 1'b1;
                        state    <= S_STOP_SETUP;
                    end else if (div_tick) begin
                        state <= S_CLK_LOW; // default: continue to next bit
                        case (phase)
                            P_ADDR, P_WDATA: begin
                                if (bit_cnt == 4'd0)
                                    phase <= (phase == P_ADDR) ? P_ADDR_ACK : P_WDATA_ACK;
                                else begin
                                    bit_cnt <= bit_cnt - 4'd1;
                                    shreg   <= {shreg[6:0], 1'b0};
                                end
                            end
                            P_RDATA: begin
                                rd_data <= {rd_data[6:0], sda_in};
                                if (bit_cnt == 4'd0)
                                    phase <= P_RACK;
                                else
                                    bit_cnt <= bit_cnt - 4'd1;
                            end
                            P_ADDR_ACK: begin
                                if (sda_in) begin
                                    ack_err <= 1'b1; // address NACKed, abort
                                    phase   <= P_ADDR;
                                    state   <= S_STOP_SETUP; // overrides default above
                                end else if (rw) begin
                                    phase   <= P_RDATA;
                                    bit_cnt <= 4'd7;
                                end else begin
                                    phase   <= P_WDATA;
                                    bit_cnt <= 4'd7;
                                    shreg   <= wr_data;
                                end
                            end
                            P_WDATA_ACK: begin
                                if (sda_in) ack_err <= 1'b1; // data byte NACKed
                                phase <= P_ADDR;
                                state <= S_STOP_SETUP; // overrides default above
                            end
                            P_RACK: begin
                                phase <= P_ADDR;
                                state <= S_STOP_SETUP; // overrides default above
                            end
                            default: ;
                        endcase
                    end
                end

                //-----------------------------------------------------
                S_STOP_SETUP: begin
                    scl_oe <= 1'b1; // ensure SCL low
                    sda_oe <= 1'b1; // ensure SDA low
                    if (div_tick)
                        state <= S_STOP;
                end

                //-----------------------------------------------------
                S_STOP: begin
                    scl_oe <= 1'b0; // release SCL high first
                    if (scl_in) begin
                        if (div_tick) begin
                            sda_oe <= 1'b0; // release SDA while SCL high -> STOP
                            state  <= S_DONE;
                        end
                    end
                end

                //-----------------------------------------------------
                S_DONE: begin
                    busy  <= 1'b0;
                    done  <= 1'b1;
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
