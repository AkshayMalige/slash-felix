// TX lane adapter: one 512-bit AXI-Stream beat -> 4 GT lanes x 64 bits over two tx_usrclk
// cycles (low half of each lane first, same layout as the RX adapter). The GT needs a word
// every clock, so when no beat is waiting it sends idle words and counts an underflow (counted only
// after the first beat, so the idle time before a kernel starts is not counted). It starts
// sending only when PREFILL beats are buffered, and again after an underflow, so NoC delivery
// jitter is absorbed by the FIFO instead of inserting idle words into the lanes. While the host holds
// the streams (drop) it takes every beat and drops it: refusing beats would leave the kernel's data
// waiting in the NoC, and a kernel load fails while data waits there. While the GT is not ready
// (rst without drop) beats wait.
module felix_gt_tx_adapter #(
    parameter FIFO_DEPTH = 512,
    parameter PREFILL    = 256
) (
    input  wire         clk,
    input  wire         rst,
    input  wire         drop,
    input  wire [511:0] s_axis_tdata,
    input  wire [63:0]  s_axis_tkeep,
    input  wire         s_axis_tlast,
    input  wire         s_axis_tvalid,
    output wire         s_axis_tready,
    output reg  [63:0]  txdata0,
    output reg  [63:0]  txdata1,
    output reg  [63:0]  txdata2,
    output reg  [63:0]  txdata3,
    output reg  [31:0]  beat_count,
    output reg  [31:0]  underflow_count
);

    wire         full, empty, wr_rst_busy, rd_rst_busy;
    wire [511:0] dout;
    reg          have_high;
    reg  [255:0] high;
    reg          started;
    reg          running;
    wire [$clog2(FIFO_DEPTH):0] rd_count;

    // Idle words: PRBS-7 (x^7 + x^6 + 1), the same 64 bits on every lane, sent in reset, while held
    // and on underflows. Over fibre a line of zeros left some receivers in a bad state until their
    // next reset (2026-10-22). PRBS-31 checkers never lock on PRBS-7.
    reg  [6:0]  idle_state = 7'h7F;
    reg  [6:0]  idle_next;
    reg  [63:0] idle_word;
    integer     i;

    always @(*) begin
        idle_next = idle_state;
        for (i = 0; i < 64; i = i + 1) begin
            idle_word[i] = idle_next[6] ^ idle_next[5];
            idle_next    = {idle_next[5:0], idle_word[i]};
        end
    end

    always @(posedge clk) idle_state <= (idle_state == 7'd0) ? 7'h7F : idle_next;

    wire rd_en = !rst && !have_high && !empty && !rd_rst_busy && (running || rd_count >= PREFILL);

    // Held: always ready (beats are dropped). Otherwise ready while the FIFO has room.
    assign s_axis_tready = drop || (!rst && !full && !wr_rst_busy);

    xpm_fifo_sync #(
        .FIFO_MEMORY_TYPE ("auto"),
        .FIFO_WRITE_DEPTH (FIFO_DEPTH),
        .WRITE_DATA_WIDTH (512),
        .READ_DATA_WIDTH  (512),
        .READ_MODE        ("fwft"),
        .FIFO_READ_LATENCY(0),
        .RD_DATA_COUNT_WIDTH($clog2(FIFO_DEPTH) + 1),
        .USE_ADV_FEATURES ("0400")
    ) fifo (
        .wr_clk(clk), .rst(rst),
        .din(s_axis_tdata), .wr_en(s_axis_tvalid && s_axis_tready && !rst), .full(full),
        .wr_rst_busy(wr_rst_busy),
        .dout(dout), .rd_en(rd_en), .empty(empty), .rd_rst_busy(rd_rst_busy),
        .sleep(1'b0), .injectsbiterr(1'b0), .injectdbiterr(1'b0),
        .overflow(), .prog_full(), .wr_data_count(), .almost_full(), .wr_ack(),
        .underflow(), .prog_empty(), .rd_data_count(rd_count), .almost_empty(), .data_valid(),
        .sbiterr(), .dbiterr()
    );

    always @(posedge clk) begin
        if (rst) begin
            have_high       <= 1'b0;
            started         <= 1'b0;
            running         <= 1'b0;
            beat_count      <= 32'd0;
            underflow_count <= 32'd0;
            {txdata3, txdata2, txdata1, txdata0} <= {4{idle_word}};
        end else if (have_high) begin
            {txdata3, txdata2, txdata1, txdata0} <= high;
            have_high <= 1'b0;
        end else if (rd_en) begin
            {txdata3, txdata2, txdata1, txdata0} <=
                {dout[447:384], dout[319:256], dout[191:128], dout[63:0]};
            high       <= {dout[511:448], dout[383:320], dout[255:192], dout[127:64]};
            have_high  <= 1'b1;
            started    <= 1'b1;
            running    <= 1'b1;
            beat_count <= beat_count + 32'd1;
        end else begin
            {txdata3, txdata2, txdata1, txdata0} <= {4{idle_word}};
            running <= 1'b0;
            if (started)
                underflow_count <= underflow_count + 32'd1;
        end
    end

endmodule
