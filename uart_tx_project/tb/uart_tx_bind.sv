// ============================================================
// uart_tx_bind.sv
// Binds the assertion module to every instance of uart_tx
// Keeps assertions out of the synthesizable RTL entirely.
// ============================================================

bind uart_tx uart_tx_assertions #(
    .CLK_FREQ  (CLK_FREQ),
    .BAUD_RATE (BAUD_RATE)
) uart_tx_sva_inst (
    .clk     (clk),
    .rst     (rst),
    .data_in (data_in),
    .start   (start),
    .tx      (tx),
    .busy    (busy)
);
