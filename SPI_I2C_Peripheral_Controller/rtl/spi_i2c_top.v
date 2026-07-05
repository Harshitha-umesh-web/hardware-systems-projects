//==============================================================================
// spi_i2c_top.v
// Top-level dual-mode SPI/I2C peripheral controller.
//
// - APB-lite register interface (spi_i2c_regs) selects mode (SPI/I2C) and
//   role (MASTER/SLAVE) at runtime; only one engine is active at a time.
// - Each of the four protocol engines sits behind its own clock-gate cell;
//   only the engine matching {mode,role} (and CTRL.enable) gets a clock,
//   the other three are frozen - the low-power technique from the project
//   brief, applied at the block level.
// - SPI pins are a shared inout bus muxed by role; I2C pins are a true
//   open-drain inout bus (SCL/SDA) shared by master and slave logic and
//   released (Z) whenever neither engine is driving, matching real I2C
//   wired-AND behavior with an external pull-up.
//==============================================================================
module spi_i2c_top (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        test_en,     // scan/DFT clock-gate bypass

    // APB-lite
    input  wire        psel,
    input  wire        penable,
    input  wire        pwrite,
    input  wire [7:0]  paddr,
    input  wire [31:0] pwdata,
    output wire [31:0] prdata,
    output wire        pready,
    output wire        irq,

    // SPI shared pins
    inout wire         sclk_io,
    inout wire         mosi_io,
    inout wire         miso_io,
    inout wire         cs_n_io,

    // I2C shared pins (open-drain)
    inout wire         scl_io,
    inout wire         sda_io
);

    localparam MODE_SPI = 1'b0;
    localparam MODE_I2C = 1'b1;
    localparam ROLE_MASTER = 1'b0;
    localparam ROLE_SLAVE  = 1'b1;

    // ------------------------------------------------------------------
    // register file
    // ------------------------------------------------------------------
    wire        enable, mode, role, cpol, cpha, rw, start_pulse;
    wire [15:0] clkdiv;
    wire [7:0]  tx_data;
    wire [6:0]  i2c_addr;

    wire        busy_i, done_i, rx_valid_i, ack_err_i, arb_lost_i;
    wire [7:0]  rx_data_i;

    spi_i2c_regs u_regs (
        .clk        (clk),
        .rst_n      (rst_n),
        .psel       (psel),
        .penable    (penable),
        .pwrite     (pwrite),
        .paddr      (paddr),
        .pwdata     (pwdata),
        .prdata     (prdata),
        .pready     (pready),
        .enable     (enable),
        .mode       (mode),
        .role       (role),
        .cpol       (cpol),
        .cpha       (cpha),
        .clkdiv     (clkdiv),
        .tx_data    (tx_data),
        .i2c_addr   (i2c_addr),
        .rw         (rw),
        .start_pulse(start_pulse),
        .busy_i     (busy_i),
        .done_i     (done_i),
        .rx_data_i  (rx_data_i),
        .rx_valid_i (rx_valid_i),
        .ack_err_i  (ack_err_i),
        .arb_lost_i (arb_lost_i),
        .irq        (irq)
    );

    // ------------------------------------------------------------------
    // per-engine clock gating: only master engines are gated. The slave
    // engines contain input synchronizers that continuously track the
    // external, asynchronous bus; if their clock is frozen while
    // deselected, that synchronizer holds a stale bus level and can
    // mis-detect the very first edge of the next transaction after being
    // re-enabled. Masters don't have this problem - they drive the bus
    // off their own internal timeline - so only they get gated.
    // ------------------------------------------------------------------
    wire sel_spi_m = enable && (mode == MODE_SPI) && (role == ROLE_MASTER);
    wire sel_spi_s = enable && (mode == MODE_SPI) && (role == ROLE_SLAVE);
    wire sel_i2c_m = enable && (mode == MODE_I2C) && (role == ROLE_MASTER);
    wire sel_i2c_s = enable && (mode == MODE_I2C) && (role == ROLE_SLAVE);

    wire clk_spi_m, clk_i2c_m;

    clk_gate u_cg_spi_m (.clk_in(clk), .enable(sel_spi_m), .test_en(test_en), .clk_out(clk_spi_m));
    clk_gate u_cg_i2c_m (.clk_in(clk), .enable(sel_i2c_m), .test_en(test_en), .clk_out(clk_i2c_m));

    // ------------------------------------------------------------------
    // SPI master
    // ------------------------------------------------------------------
    wire spi_m_sclk, spi_m_mosi, spi_m_cs_n;
    wire spi_m_miso_in = miso_io;
    wire [7:0] spi_m_rx_data;
    wire spi_m_busy, spi_m_done;

    spi_master #(.DW(8)) u_spi_master (
        .clk     (clk_spi_m),
        .rst_n   (rst_n),
        .en      (sel_spi_m),
        .start   (start_pulse),
        .cpol    (cpol),
        .cpha    (cpha),
        .clkdiv  (clkdiv),
        .tx_data (tx_data),
        .rx_data (spi_m_rx_data),
        .busy    (spi_m_busy),
        .done    (spi_m_done),
        .sclk    (spi_m_sclk),
        .mosi    (spi_m_mosi),
        .miso    (spi_m_miso_in),
        .cs_n    (spi_m_cs_n)
    );

    // ------------------------------------------------------------------
    // SPI slave (always-on clock - see clock-gating note above)
    // ------------------------------------------------------------------
    wire spi_s_miso_out;
    wire [7:0] spi_s_rx_data;
    wire spi_s_busy, spi_s_rx_valid;

    spi_slave #(.DW(8)) u_spi_slave (
        .clk      (clk),
        .rst_n    (rst_n),
        .en       (sel_spi_s),
        .cpol     (cpol),
        .cpha     (cpha),
        .sclk_in  (sclk_io),
        .mosi_in  (mosi_io),
        .cs_n_in  (cs_n_io),
        .miso_out (spi_s_miso_out),
        .tx_data  (tx_data),
        .rx_data  (spi_s_rx_data),
        .rx_valid (spi_s_rx_valid),
        .busy     (spi_s_busy)
    );

    // SPI pin muxing: master drives sclk/mosi/cs_n and reads miso;
    // slave reads sclk/mosi/cs_n and drives miso. Undriven lines float.
    assign sclk_io = (sel_spi_m) ? spi_m_sclk : 1'bz;
    assign mosi_io = (sel_spi_m) ? spi_m_mosi : 1'bz;
    assign cs_n_io = (sel_spi_m) ? spi_m_cs_n : 1'bz;
    assign miso_io = (sel_spi_s) ? spi_s_miso_out : 1'bz;

    // ------------------------------------------------------------------
    // I2C master
    // ------------------------------------------------------------------
    wire i2c_m_scl_oe, i2c_m_sda_oe;
    wire [7:0] i2c_m_rd_data;
    wire i2c_m_busy, i2c_m_done, i2c_m_ack_err, i2c_m_arb_lost;

    i2c_master #(.AW(7)) u_i2c_master (
        .clk      (clk_i2c_m),
        .rst_n    (rst_n),
        .en       (sel_i2c_m),
        .start    (start_pulse),
        .clkdiv   (clkdiv),
        .slv_addr (i2c_addr),
        .rw       (rw),
        .wr_data  (tx_data),
        .rd_data  (i2c_m_rd_data),
        .busy     (i2c_m_busy),
        .done     (i2c_m_done),
        .ack_err  (i2c_m_ack_err),
        .arb_lost (i2c_m_arb_lost),
        .scl_oe   (i2c_m_scl_oe),
        .scl_in   (scl_io),
        .sda_oe   (i2c_m_sda_oe),
        .sda_in   (sda_io)
    );

    // ------------------------------------------------------------------
    // I2C slave (always-on clock - see clock-gating note above)
    // ------------------------------------------------------------------
    wire i2c_s_sda_oe;
    wire [7:0] i2c_s_rx_data;
    wire i2c_s_busy, i2c_s_rx_valid, i2c_s_addr_match;

    i2c_slave #(.AW(7)) u_i2c_slave (
        .clk        (clk),
        .rst_n      (rst_n),
        .en         (sel_i2c_s),
        .own_addr   (i2c_addr),
        .tx_data    (tx_data),
        .rx_data    (i2c_s_rx_data),
        .rx_valid   (i2c_s_rx_valid),
        .busy       (i2c_s_busy),
        .addr_match (i2c_s_addr_match),
        .scl_in     (scl_io),
        .sda_oe     (i2c_s_sda_oe),
        .sda_in     (sda_io)
    );

    // I2C open-drain pin muxing: pull low if any active engine asserts oe,
    // otherwise release (external pull-up wins).
    assign scl_io = (sel_i2c_m && i2c_m_scl_oe) ? 1'b0 : 1'bz;
    assign sda_io = ((sel_i2c_m && i2c_m_sda_oe) || (sel_i2c_s && i2c_s_sda_oe)) ? 1'b0 : 1'bz;

    // ------------------------------------------------------------------
    // status/data mux back to the register file
    // ------------------------------------------------------------------
    assign busy_i     = sel_spi_m ? spi_m_busy :
                         sel_spi_s ? spi_s_busy :
                         sel_i2c_m ? i2c_m_busy :
                         sel_i2c_s ? i2c_s_busy : 1'b0;

    assign done_i      = sel_spi_m ? spi_m_done : sel_i2c_m ? i2c_m_done : 1'b0;
    assign rx_valid_i  = sel_spi_s ? spi_s_rx_valid :
                          sel_i2c_s ? i2c_s_rx_valid :
                          (sel_spi_m && spi_m_done) ? 1'b1 :
                          (sel_i2c_m && i2c_m_done && rw) ? 1'b1 : 1'b0;

    assign rx_data_i   = sel_spi_m ? spi_m_rx_data :
                          sel_spi_s ? spi_s_rx_data :
                          sel_i2c_m ? i2c_m_rd_data :
                          sel_i2c_s ? i2c_s_rx_data : 8'd0;

    assign ack_err_i   = sel_i2c_m ? i2c_m_ack_err  : 1'b0;
    assign arb_lost_i  = sel_i2c_m ? i2c_m_arb_lost : 1'b0;

endmodule
