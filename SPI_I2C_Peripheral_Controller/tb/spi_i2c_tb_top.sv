//==============================================================================
// spi_i2c_tb_top.sv
// Top-level testbench. Two spi_i2c_top instances share the SPI bus and the
// I2C bus, one configured as MASTER and the other as SLAVE, so the DUT
// verifies itself against itself in both protocols and both directions.
//
// Run (Icarus Verilog):
//   iverilog -g2012 -o sim.out -I ../rtl \
//       ../rtl/*.v spi_i2c_pkg.sv spi_i2c_assertions.sv spi_i2c_tb_top.sv
//   vvp sim.out
//
// Run (Verilator, lint + sim):
//   verilator --binary -Wall --timing -sv \
//       ../rtl/*.v spi_i2c_pkg.sv spi_i2c_assertions.sv spi_i2c_tb_top.sv \
//       --top-module spi_i2c_tb_top -o sim.out
//   ./obj_dir/sim.out
//==============================================================================
`timescale 1ns/1ps

import spi_i2c_pkg::*;

interface apb_if (input logic clk);
    logic        psel;
    logic        penable;
    logic        pwrite;
    logic [7:0]  paddr;
    logic [31:0] pwdata;
    logic [31:0] prdata;
    logic        pready;

    task automatic write(logic [7:0] addr, logic [31:0] data);
        @(posedge clk);
        psel    <= 1'b1;
        pwrite  <= 1'b1;
        paddr   <= addr;
        pwdata  <= data;
        penable <= 1'b0;
        @(posedge clk);
        penable <= 1'b1;
        @(posedge clk);
        psel    <= 1'b0;
        penable <= 1'b0;
        pwrite  <= 1'b0;
    endtask

    task automatic read(logic [7:0] addr, output logic [31:0] data);
        @(posedge clk);
        psel    <= 1'b1;
        pwrite  <= 1'b0;
        paddr   <= addr;
        penable <= 1'b0;
        @(posedge clk);
        penable <= 1'b1;
        @(posedge clk);
        data    = prdata;
        psel    <= 1'b0;
        penable <= 1'b0;
    endtask
endinterface

module spi_i2c_tb_top;

    // ---------------- clock / reset ----------------
    logic clk = 0;
    logic rst_n = 0;
    always #5 clk = ~clk; // 100 MHz

    initial begin
        rst_n = 0;
        repeat (5) @(posedge clk);
        rst_n = 1;
    end

    // ---------------- shared buses ----------------
    wire sclk_bus, mosi_bus, miso_bus, cs_n_bus;
    wire scl_bus, sda_bus;
    pullup(scl_bus);
    pullup(sda_bus);

    // ---------------- APB interfaces ----------------
    apb_if apb_a(clk);
    apb_if apb_b(clk);

    // ---------------- DUTs ----------------
    // dut_a: configured as the MASTER side in each test
    // dut_b: configured as the SLAVE side in each test
    spi_i2c_top dut_a (
        .clk(clk), .rst_n(rst_n), .test_en(1'b0),
        .psel(apb_a.psel), .penable(apb_a.penable), .pwrite(apb_a.pwrite),
        .paddr(apb_a.paddr), .pwdata(apb_a.pwdata), .prdata(apb_a.prdata),
        .pready(apb_a.pready), .irq(),
        .sclk_io(sclk_bus), .mosi_io(mosi_bus), .miso_io(miso_bus), .cs_n_io(cs_n_bus),
        .scl_io(scl_bus), .sda_io(sda_bus)
    );

    spi_i2c_top dut_b (
        .clk(clk), .rst_n(rst_n), .test_en(1'b0),
        .psel(apb_b.psel), .penable(apb_b.penable), .pwrite(apb_b.pwrite),
        .paddr(apb_b.paddr), .pwdata(apb_b.pwdata), .prdata(apb_b.prdata),
        .pready(apb_b.pready), .irq(),
        .sclk_io(sclk_bus), .mosi_io(mosi_bus), .miso_io(miso_bus), .cs_n_io(cs_n_bus),
        .scl_io(scl_bus), .sda_io(sda_bus)
    );

    // ---------------- scoreboard bookkeeping ----------------
    int pass_cnt = 0;
    int fail_cnt = 0;

    task automatic check_equal(string what, logic [31:0] act, logic [31:0] exp);
        if (act === exp) begin
            pass_cnt++;
            $display("[PASS] %-40s got=0x%0h exp=0x%0h", what, act, exp);
        end else begin
            fail_cnt++;
            $error("[FAIL] %-40s got=0x%0h exp=0x%0h", what, act, exp);
        end
    endtask

    task automatic check_true(string what, logic act);
        if (act === 1'b1) begin
            pass_cnt++;
            $display("[PASS] %-40s", what);
        end else begin
            fail_cnt++;
            $error("[FAIL] %-40s (expected 1'b1, got %0b)", what, act);
        end
    endtask

    // poll STATUS.busy on apb_a until it clears, or timeout
    task automatic wait_done(string tag);
        logic [31:0] st;
        int timeout = 2000;
        st = 32'h1;
        while (st[0] && timeout > 0) begin
            apb_a.read(ADDR_STATUS, st);
            timeout--;
            repeat (5) @(posedge clk);
        end
        if (timeout == 0) begin
            fail_cnt++;
            $error("[FAIL] %s: timed out waiting for busy to clear", tag);
        end
    endtask

    // ---------------- functional coverage ----------------
    // NOTE: SystemVerilog `covergroup`/`coverpoint`/`cross` are a
    // commercial-simulator feature (VCS/Questa/Xcelium) that Icarus
    // Verilog does not implement. To keep this testbench runnable on the
    // free open-source toolchain, coverage is tracked manually here with
    // plain bit vectors instead - same intent (did we exercise every
    // interesting case?), portable syntax. If you have access to a
    // simulator with real covergroup support, swap this block back for
    // the covergroup version described in docs/README.md.

    // bit index = {cpol, cpha} -> all 4 SPI modes
    reg [3:0] spi_mode_hit = 4'b0000;
    // bit index = {rw, ack_err} -> I2C write-ack, write-nack, read-ack, read-nack
    reg [3:0] i2c_txn_hit  = 4'b0000;
    // bit0=zero byte seen, bit1=0xFF seen, bit2=some mid-range byte seen
    reg [2:0] byte_bin_hit = 3'b000;

    task automatic mark_spi_mode(bit cpol, bit cpha);
        spi_mode_hit[{cpol, cpha}] = 1'b1;
    endtask

    task automatic mark_i2c_txn(bit rw, bit ack_err);
        i2c_txn_hit[{rw, ack_err}] = 1'b1;
    endtask

    function automatic int popcount4(logic [3:0] v);
        popcount4 = v[0] + v[1] + v[2] + v[3];
    endfunction

    function automatic int popcount3(logic [2:0] v);
        popcount3 = v[0] + v[1] + v[2];
    endfunction
    task automatic mark_byte(logic [7:0] b);
        if (b == 8'h00)      byte_bin_hit[0] = 1'b1;
        else if (b == 8'hFF) byte_bin_hit[1] = 1'b1;
        else                 byte_bin_hit[2] = 1'b1;
    endtask

    // ---------------- SPI directed test ----------------
    task automatic run_spi_test(bit cpol, bit cpha, logic [7:0] m_tx, logic [7:0] s_tx);
        logic [31:0] rd;

        $display("\n---- SPI test: CPOL=%0b CPHA=%0b m_tx=0x%0h s_tx=0x%0h ----",
                  cpol, cpha, m_tx, s_tx);

        apb_a.write(ADDR_CTRL, ctrl_word(1'b0, MODE_SPI, ROLE_MASTER, cpol, cpha));
        apb_b.write(ADDR_CTRL, ctrl_word(1'b0, MODE_SPI, ROLE_SLAVE,  cpol, cpha));
        apb_a.write(ADDR_CLKDIV, 32'd4);
        apb_b.write(ADDR_CLKDIV, 32'd4);
        apb_a.write(ADDR_TXDATA, m_tx);
        apb_b.write(ADDR_TXDATA, s_tx);

        apb_a.write(ADDR_CTRL, ctrl_word(1'b1, MODE_SPI, ROLE_MASTER, cpol, cpha));
        apb_b.write(ADDR_CTRL, ctrl_word(1'b1, MODE_SPI, ROLE_SLAVE,  cpol, cpha));
        repeat (5) @(posedge clk);

        apb_a.write(ADDR_CMD, cmd_word(1'b1, 1'b0)); // start pulse
        wait_done("spi_master");
        repeat (10) @(posedge clk);

        apb_a.read(ADDR_RXDATA, rd);
        check_equal($sformatf("SPI master captured slave byte (cpol=%0b cpha=%0b)", cpol, cpha),
                    rd[7:0], s_tx);

        apb_b.read(ADDR_RXDATA, rd);
        check_equal($sformatf("SPI slave captured master byte (cpol=%0b cpha=%0b)", cpol, cpha),
                    rd[7:0], m_tx);

        // disable both before next test to force the top-level mux back to
        // "nothing selected" and exercise the clock-gating idle path
        apb_a.write(ADDR_CTRL, 32'h0);
        apb_b.write(ADDR_CTRL, 32'h0);

        mark_spi_mode(cpol, cpha);
        mark_byte(m_tx);
        mark_byte(s_tx);
    endtask

    // ---------------- I2C directed test ----------------
    task automatic run_i2c_write(logic [6:0] addr, logic [6:0] slv_own_addr, logic [7:0] data);
        logic [31:0] rd;
        bit expect_ack = (addr == slv_own_addr);

        $display("\n---- I2C write test: taddr=0x%0h slv_addr=0x%0h data=0x%0h ----",
                  addr, slv_own_addr, data);

        apb_a.write(ADDR_CTRL, ctrl_word(1'b0, MODE_I2C, ROLE_MASTER, 1'b0, 1'b0));
        apb_b.write(ADDR_CTRL, ctrl_word(1'b0, MODE_I2C, ROLE_SLAVE,  1'b0, 1'b0));
        apb_a.write(ADDR_CLKDIV, 32'd8);
        apb_b.write(ADDR_ADDR, slv_own_addr);
        apb_a.write(ADDR_ADDR, addr);
        apb_a.write(ADDR_TXDATA, data);

        apb_a.write(ADDR_CTRL, ctrl_word(1'b1, MODE_I2C, ROLE_MASTER, 1'b0, 1'b0));
        apb_b.write(ADDR_CTRL, ctrl_word(1'b1, MODE_I2C, ROLE_SLAVE,  1'b0, 1'b0));
        apb_a.write(ADDR_STATUS, 32'h0000000E); // W1C: clear done/ack_err/arb_lost
        repeat (5) @(posedge clk);

        apb_a.write(ADDR_CMD, cmd_word(1'b1, 1'b0)); // start pulse, rw=0 (write)
        wait_done("i2c_master_write");
        repeat (10) @(posedge clk);

        apb_a.read(ADDR_STATUS, rd);
        if (expect_ack) begin
            check_equal("I2C write: address ACKed (ack_err==0)", rd[2], 1'b0);
            apb_b.read(ADDR_STATUS, rd);
            check_equal("I2C write: slave rx_valid set", rd[4], 1'b1);
            apb_b.read(ADDR_RXDATA, rd);
            check_equal("I2C write: slave received correct byte", rd[7:0], data);
        end else begin
            check_equal("I2C write: mismatched address NACKed (ack_err==1)", rd[2], 1'b1);
        end

        apb_a.write(ADDR_CTRL, 32'h0);
        apb_b.write(ADDR_CTRL, 32'h0);

        mark_i2c_txn(1'b0, !expect_ack);
    endtask

    task automatic run_i2c_read(logic [6:0] addr, logic [6:0] slv_own_addr, logic [7:0] slv_data);
        logic [31:0] rd;

        $display("\n---- I2C read test: taddr=0x%0h slv_addr=0x%0h slv_data=0x%0h ----",
                  addr, slv_own_addr, slv_data);

        apb_a.write(ADDR_CTRL, ctrl_word(1'b0, MODE_I2C, ROLE_MASTER, 1'b0, 1'b0));
        apb_b.write(ADDR_CTRL, ctrl_word(1'b0, MODE_I2C, ROLE_SLAVE,  1'b0, 1'b0));
        apb_a.write(ADDR_CLKDIV, 32'd8);
        apb_b.write(ADDR_ADDR, slv_own_addr);
        apb_a.write(ADDR_ADDR, addr);
        apb_b.write(ADDR_TXDATA, slv_data); // byte the slave will return

        apb_a.write(ADDR_CTRL, ctrl_word(1'b1, MODE_I2C, ROLE_MASTER, 1'b0, 1'b0));
        apb_b.write(ADDR_CTRL, ctrl_word(1'b1, MODE_I2C, ROLE_SLAVE,  1'b0, 1'b0));
        apb_a.write(ADDR_STATUS, 32'h0000000E); // W1C: clear done/ack_err/arb_lost
        repeat (5) @(posedge clk);

        apb_a.write(ADDR_CMD, cmd_word(1'b1, 1'b1)); // start pulse, rw=1 (read)
        wait_done("i2c_master_read");
        repeat (10) @(posedge clk);

        apb_a.read(ADDR_STATUS, rd);
        check_equal("I2C read: address ACKed (ack_err==0)", rd[2], 1'b0);
        apb_a.read(ADDR_RXDATA, rd);
        check_equal("I2C read: master received correct byte", rd[7:0], slv_data);

        apb_a.write(ADDR_CTRL, 32'h0);
        apb_b.write(ADDR_CTRL, 32'h0);

        mark_i2c_txn(1'b1, 1'b0);
        mark_byte(slv_data);
    endtask

    // ---------------- test sequence ----------------
    initial begin
        @(posedge rst_n);
        repeat (10) @(posedge clk);

        // SPI: sweep all 4 CPOL/CPHA modes with edge-case + mid-range bytes
        run_spi_test(1'b0, 1'b0, 8'hA5, 8'h5A);
        run_spi_test(1'b0, 1'b1, 8'h00, 8'hFF);
        run_spi_test(1'b1, 1'b0, 8'hFF, 8'h00);
        run_spi_test(1'b1, 1'b1, 8'h3C, 8'hC3);

        // I2C: matching address write, matching address read, mismatched address
        run_i2c_write(7'h50, 7'h50, 8'h42);
        run_i2c_read (7'h50, 7'h50, 8'h99);
        run_i2c_write(7'h51, 7'h50, 8'hDE); // address mismatch -> expect NACK

        repeat (20) @(posedge clk);

        $display("\n================ COVERAGE SUMMARY ================");
        $display("SPI mode coverage    : %0d/4 modes   (%0.1f%%)",
                  popcount4(spi_mode_hit), popcount4(spi_mode_hit) * 100.0 / 4.0);
        $display("I2C txn coverage     : %0d/4 combos  (%0.1f%%)",
                  popcount4(i2c_txn_hit), popcount4(i2c_txn_hit) * 100.0 / 4.0);
        $display("Byte value coverage  : %0d/3 bins    (%0.1f%%)",
                  popcount3(byte_bin_hit), popcount3(byte_bin_hit) * 100.0 / 3.0);

        $display("\n================ REGRESSION SUMMARY ================");
        $display("PASS: %0d  FAIL: %0d", pass_cnt, fail_cnt);
        if (fail_cnt == 0)
            $display("REGRESSION: PASS");
        else
            $display("REGRESSION: FAIL");

        $finish;
    end

    // safety timeout in case a wait_done loop or DUT hang isn't caught
    initial begin
        #200000;
        $display("REGRESSION: FAIL (global timeout)");
        $finish;
    end

endmodule
