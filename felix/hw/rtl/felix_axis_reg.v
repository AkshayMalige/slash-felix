// AXI-Stream register stage (skid buffer): data, valid and ready are all registered, so neither
// side has a combinational path to the other. Placed between a lane adapter FIFO and its NoC
// stream cell, where the FIFO memory output and enables otherwise run straight into the NoC pins
// at the GT user clock. Full throughput; holds up to two beats.
module felix_axis_reg #(
    parameter W = 512
) (
    input  wire         clk,
    input  wire         rst,
    input  wire [W-1:0] s_tdata,
    input  wire         s_tvalid,
    output wire         s_tready,
    output reg  [W-1:0] m_tdata,
    output reg          m_tvalid = 1'b0,
    input  wire         m_tready
);

    reg [W-1:0] skid;
    reg         skid_valid = 1'b0;

    assign s_tready = !skid_valid;

    always @(posedge clk) begin
        if (rst) begin
            m_tvalid   <= 1'b0;
            skid_valid <= 1'b0;
        end else if (!m_tvalid || m_tready) begin
            if (skid_valid) begin
                m_tdata    <= skid;
                m_tvalid   <= 1'b1;
                skid_valid <= 1'b0;
            end else begin
                m_tdata  <= s_tdata;
                m_tvalid <= s_tvalid;
            end
        end else if (s_tvalid && !skid_valid) begin
            skid       <= s_tdata;
            skid_valid <= 1'b1;
        end
    end

endmodule
