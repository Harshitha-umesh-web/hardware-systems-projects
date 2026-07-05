// ============================================================
// tb_uart_tx.v
// Self-checking testbench for uart_tx
// Uses a small clock divider (fast sim) via parameter override
// ============================================================
`timescale 1ns/1ps

module tb_uart_tx;

    // Use small divider so simulation runs fast: CLK_FREQ/BAUD_RATE = 10
    localparam CLK_FREQ  = 1_000_000;
    localparam BAUD_RATE = 100_000;   // -> divider = 10 clk cycles per bit
    localparam CLK_PERIOD = 20;       // ns -> 50 MHz sim clock (arbitrary, just needs to toggle)
    localparam integer BIT_CYCLES = CLK_FREQ / BAUD_RATE;

    reg        clk;
    reg        rst;
    reg  [7:0] data_in;
    reg        start;
    wire       tx;
    wire       busy;

    integer errors = 0;
    integer i;
    reg [7:0] captured;

    uart_tx #(
        .CLK_FREQ (CLK_FREQ),
        .BAUD_RATE(BAUD_RATE)
    ) dut (
        .clk     (clk),
        .rst     (rst),
        .data_in (data_in),
        .start   (start),
        .tx      (tx),
        .busy    (busy)
    );

    // clock generation
    always #(CLK_PERIOD/2) clk = ~clk;

    // task: send one byte and sample the tx line to reconstruct the frame
    task send_and_check(input [7:0] byte_to_send);
        integer b;
        begin
            // wait for idle
            wait (busy == 1'b0);
            @(negedge clk);
            data_in = byte_to_send;
            start   = 1'b1;
            @(negedge clk);
            start   = 1'b0;

            // check start bit
            repeat (BIT_CYCLES/2) @(posedge clk); // sample mid-bit
            if (tx !== 1'b0) begin
                $display("ERROR: start bit not 0 (got %b) for byte %02h", tx, byte_to_send);
                errors = errors + 1;
            end

            captured = 8'd0;
            for (b = 0; b < 8; b = b + 1) begin
                repeat (BIT_CYCLES) @(posedge clk);
                captured[b] = tx;
            end

            // stop bit
            repeat (BIT_CYCLES) @(posedge clk);
            if (tx !== 1'b1) begin
                $display("ERROR: stop bit not 1 (got %b) for byte %02h", tx, byte_to_send);
                errors = errors + 1;
            end

            if (captured !== byte_to_send) begin
                $display("ERROR: byte mismatch. sent=%02h captured=%02h", byte_to_send, captured);
                errors = errors + 1;
            end else begin
                $display("PASS: byte %02h transmitted and captured correctly", byte_to_send);
            end

            // small gap
            repeat (BIT_CYCLES) @(posedge clk);
        end
    endtask

    initial begin
        clk = 0;
        rst = 1;
        start = 0;
        data_in = 8'd0;
        repeat (5) @(posedge clk);
        rst = 0;

        // idle line check
        @(posedge clk);
        if (tx !== 1'b1) begin
            $display("ERROR: idle tx line not high at reset");
            errors = errors + 1;
        end

        send_and_check(8'h55); // 01010101
        send_and_check(8'hA3);
        send_and_check(8'h00);
        send_and_check(8'hFF);
        send_and_check(8'h81);

        if (errors == 0)
            $display("\n=== ALL TESTS PASSED ===");
        else
            $display("\n=== %0d TEST(S) FAILED ===", errors);

        $finish;
    end

    // optional waveform dump
    initial begin
        $dumpfile("uart_tx.vcd");
        $dumpvars(0, tb_uart_tx);
    end

endmodule
