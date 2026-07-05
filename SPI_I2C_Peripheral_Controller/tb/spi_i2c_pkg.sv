//==============================================================================
// spi_i2c_pkg.sv
// Shared parameters/types for the SPI/I2C controller testbench.
// Mirrors the register map defined in rtl/spi_i2c_regs.v.
//==============================================================================
package spi_i2c_pkg;

    localparam bit [7:0] ADDR_CTRL   = 8'h00;
    localparam bit [7:0] ADDR_CLKDIV = 8'h04;
    localparam bit [7:0] ADDR_TXDATA = 8'h08;
    localparam bit [7:0] ADDR_RXDATA = 8'h0C;
    localparam bit [7:0] ADDR_ADDR   = 8'h10;
    localparam bit [7:0] ADDR_CMD    = 8'h14;
    localparam bit [7:0] ADDR_STATUS = 8'h18;
    localparam bit [7:0] ADDR_IRQEN  = 8'h1C;

    localparam bit MODE_SPI = 1'b0;
    localparam bit MODE_I2C = 1'b1;
    localparam bit ROLE_MASTER = 1'b0;
    localparam bit ROLE_SLAVE  = 1'b1;

    // CTRL[4:0] = {cpha,cpol,role,mode,enable}
    function automatic logic [31:0] ctrl_word(bit en, bit mode, bit role,
                                               bit cpol, bit cpha);
        ctrl_word = {27'd0, cpha, cpol, role, mode, en};
    endfunction

    // CMD[1:0] = {rw,start}
    function automatic logic [31:0] cmd_word(bit start, bit rw);
        cmd_word = {30'd0, rw, start};
    endfunction

    typedef struct packed {
        logic busy;
        logic done;
        logic ack_err;
        logic arb_lost;
        logic rx_valid;
    } status_t;

    function automatic status_t decode_status(logic [31:0] w);
        decode_status.busy     = w[0];
        decode_status.done     = w[1];
        decode_status.ack_err  = w[2];
        decode_status.arb_lost = w[3];
        decode_status.rx_valid = w[4];
    endfunction

endpackage
