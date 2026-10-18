// RX lane adapter: 4 GT lanes x 64 bits per rx_usrclk -> one 512-bit AXI-Stream beat every
// second clock. Lane L is bits [128L+127:128L]; its first GT word is in the low 64 bits.
// A raw lane cannot pause, so a beat that does not fit into the FIFO is dropped and counted.
module felix_gt_rx_adapter #(
    parameter FIFO_DEPTH = 512
) (
    input  wire         clk,
    input  wire         rst,
    input  wire [63:0]  rxdata0,
    input  wire [63:0]  rxdata1,
    input  wire [63:0]  rxdata2,
    input  wire [63:0]  rxdata3,
    output wire [511:0] m_axis_tdata,
    output wire [63:0]  m_axis_tkeep,
    output wire         m_axis_tlast,
    output wire         m_axis_tvalid,
    input  wire         m_axis_tready,
    output reg  [31:0]  beat_count,
    output reg  [31:0]  drop_count
);

    reg         phase;
    reg [255:0] first;
    reg [511:0] beat;
    reg         beat_valid;

    always @(posedge clk) begin
        if (rst) begin
            phase      <= 1'b0;
            beat_valid <= 1'b0;
        end else begin
            beat_valid <= phase;
            phase      <= ~phase;
            if (!phase)
                first <= {rxdata3, rxdata2, rxdata1, rxdata0};
            else
                beat <= {rxdata3, first[255:192], rxdata2, first[191:128],
                         rxdata1, first[127:64],  rxdata0, first[63:0]};
        end
    end

    wire         full, empty, wr_rst_busy, rd_rst_busy;
    wire [511:0] dout;
    wire         wr_ok = beat_valid && !full && !wr_rst_busy;
    wire         rd_en = m_axis_tvalid && m_axis_tready;

    xpm_fifo_sync #(
        .FIFO_MEMORY_TYPE ("auto"),
        .FIFO_WRITE_DEPTH (FIFO_DEPTH),
        .WRITE_DATA_WIDTH (512),
        .READ_DATA_WIDTH  (512),
        .READ_MODE        ("fwft"),
        .FIFO_READ_LATENCY(0),
        .USE_ADV_FEATURES ("0000")
    ) fifo (
        .wr_clk(clk), .rst(rst),
        .din(beat), .wr_en(wr_ok), .full(full), .wr_rst_busy(wr_rst_busy),
        .dout(dout), .rd_en(rd_en), .empty(empty), .rd_rst_busy(rd_rst_busy),
        .sleep(1'b0), .injectsbiterr(1'b0), .injectdbiterr(1'b0),
        .overflow(), .prog_full(), .wr_data_count(), .almost_full(), .wr_ack(),
        .underflow(), .prog_empty(), .rd_data_count(), .almost_empty(), .data_valid(),
        .sbiterr(), .dbiterr()
    );

    assign m_axis_tdata  = dout;
    assign m_axis_tkeep  = {64{1'b1}};
    assign m_axis_tlast  = 1'b1;
    assign m_axis_tvalid = !empty && !rd_rst_busy;

    always @(posedge clk) begin
        if (rst) begin
            beat_count <= 32'd0;
            drop_count <= 32'd0;
        end else begin
            if (wr_ok)
                beat_count <= beat_count + 32'd1;
            if (beat_valid && full && !wr_rst_busy)
                drop_count <= drop_count + 32'd1;
        end
    end

endmodule
