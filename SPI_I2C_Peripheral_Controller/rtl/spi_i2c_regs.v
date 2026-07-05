//==============================================================================
// spi_i2c_regs.v
// APB-lite register file / programmer's interface for the dual-mode
// SPI+I2C controller. Zero wait-state slave (pready is tied high).
//
// Address map (word-aligned, byte offsets):
//   0x00 CTRL    [0]=enable [1]=mode(0=SPI,1=I2C) [2]=role(0=MASTER,1=SLAVE)
//                [3]=cpol   [4]=cpha
//   0x04 CLKDIV  [15:0] engine clock divider
//   0x08 TXDATA  [7:0]  byte to transmit next
//   0x0C RXDATA  [7:0]  last byte received (read-to-clear rx_valid)
//   0x10 ADDR    [6:0]  I2C target address (master) / own address (slave)
//   0x14 CMD     [0]=start (self-clearing write strobe) [1]=rw (0=wr,1=rd)
//   0x18 STATUS  [0]=busy [1]=done(sticky, W1C) [2]=ack_err(W1C)
//                [3]=arb_lost(W1C) [4]=rx_valid(sticky, cleared by RXDATA rd)
//   0x1C IRQEN   [0]=done_ie  (irq = done_ie & status.done)
//==============================================================================
module spi_i2c_regs (
    input  wire        clk,
    input  wire        rst_n,

    // APB-lite
    input  wire        psel,
    input  wire        penable,
    input  wire        pwrite,
    input  wire [7:0]  paddr,
    input  wire [31:0] pwdata,
    output reg  [31:0] prdata,
    output wire        pready,

    // config outputs -> engines
    output reg          enable,
    output reg          mode,     // 0=SPI, 1=I2C
    output reg          role,     // 0=MASTER, 1=SLAVE
    output reg          cpol,
    output reg          cpha,
    output reg  [15:0]  clkdiv,
    output reg  [7:0]   tx_data,
    output reg  [6:0]   i2c_addr,
    output reg          rw,
    output wire         start_pulse,

    // status inputs <- engines
    input  wire         busy_i,
    input  wire         done_i,      // 1-cycle pulse
    input  wire [7:0]    rx_data_i,
    input  wire          rx_valid_i, // 1-cycle pulse
    input  wire          ack_err_i,  // 1-cycle pulse
    input  wire          arb_lost_i, // 1-cycle pulse

    output wire          irq
);

    localparam ADDR_CTRL   = 8'h00;
    localparam ADDR_CLKDIV = 8'h04;
    localparam ADDR_TXDATA = 8'h08;
    localparam ADDR_RXDATA = 8'h0C;
    localparam ADDR_ADDR   = 8'h10;
    localparam ADDR_CMD    = 8'h14;
    localparam ADDR_STATUS = 8'h18;
    localparam ADDR_IRQEN  = 8'h1C;

    assign pready = 1'b1; // zero-wait-state slave

    wire apb_write = psel & penable & pwrite;
    wire apb_read  = psel & penable & ~pwrite;

    reg        start_reg;
    assign start_pulse = start_reg;

    reg [7:0]  rx_data_reg;
    reg        sticky_done, sticky_ack_err, sticky_arb_lost, sticky_rx_valid;
    reg        irq_en;

    // ---------------- writes ----------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            enable    <= 1'b0;
            mode      <= 1'b0;
            role      <= 1'b0;
            cpol      <= 1'b0;
            cpha      <= 1'b0;
            clkdiv    <= 16'd4;
            tx_data   <= 8'd0;
            i2c_addr  <= 7'd0;
            rw        <= 1'b0;
            start_reg <= 1'b0;
            irq_en    <= 1'b0;
        end else begin
            start_reg <= 1'b0; // self-clearing strobe

            if (apb_write) begin
                case (paddr)
                    ADDR_CTRL: begin
                        enable <= pwdata[0];
                        mode   <= pwdata[1];
                        role   <= pwdata[2];
                        cpol   <= pwdata[3];
                        cpha   <= pwdata[4];
                    end
                    ADDR_CLKDIV: clkdiv   <= pwdata[15:0];
                    ADDR_TXDATA: tx_data  <= pwdata[7:0];
                    ADDR_ADDR:   i2c_addr <= pwdata[6:0];
                    ADDR_CMD: begin
                        rw        <= pwdata[1];
                        start_reg <= pwdata[0];
                    end
                    ADDR_IRQEN: irq_en <= pwdata[0];
                    default: ;
                endcase
            end
        end
    end

    // ---------------- sticky status ----------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sticky_done     <= 1'b0;
            sticky_ack_err  <= 1'b0;
            sticky_arb_lost <= 1'b0;
            sticky_rx_valid <= 1'b0;
            rx_data_reg     <= 8'd0;
        end else begin
            if (done_i)      sticky_done     <= 1'b1;
            if (ack_err_i)   sticky_ack_err  <= 1'b1;
            if (arb_lost_i)  sticky_arb_lost <= 1'b1;
            if (rx_valid_i) begin
                sticky_rx_valid <= 1'b1;
                rx_data_reg     <= rx_data_i;
            end

            // write-1-to-clear on STATUS
            if (apb_write && paddr == ADDR_STATUS) begin
                if (pwdata[1]) sticky_done     <= 1'b0;
                if (pwdata[2]) sticky_ack_err  <= 1'b0;
                if (pwdata[3]) sticky_arb_lost <= 1'b0;
            end
            // read-to-clear on RXDATA
            if (apb_read && paddr == ADDR_RXDATA)
                sticky_rx_valid <= 1'b0;
        end
    end

    assign irq = irq_en & sticky_done;

    // ---------------- reads ----------------
    always @(*) begin
        prdata = 32'd0;
        case (paddr)
            ADDR_CTRL:   prdata = {27'd0, cpha, cpol, role, mode, enable};
            ADDR_CLKDIV: prdata = {16'd0, clkdiv};
            ADDR_TXDATA: prdata = {24'd0, tx_data};
            ADDR_RXDATA: prdata = {24'd0, rx_data_reg};
            ADDR_ADDR:   prdata = {25'd0, i2c_addr};
            ADDR_CMD:    prdata = {30'd0, rw, 1'b0};
            ADDR_STATUS: prdata = {27'd0, sticky_rx_valid, sticky_arb_lost,
                                    sticky_ack_err, sticky_done, busy_i};
            ADDR_IRQEN:  prdata = {31'd0, irq_en};
            default:     prdata = 32'd0;
        endcase
    end

endmodule
