// Input buffers and frequency counters for the GT reference clock pins of the FireFly quads.
// Input i = 2*q + r: q = quad 106, 110, 111, 112; r = REFCLK0 (Si5345) or REFCLK1 (Si570).
// Each pin pair gets an IBUFDS_GTE5: O (refclk_o<i>) goes to a GT quad that uses this reference,
// ODIV2 (same frequency) through a BUFG_GT (refclk_mon<i>) to a counter and to that quad's own counter.
//
// Registers (byte offsets, host: PF2 BAR4 + 0x70000):
//   0x00 ID      RO  0x434C4B4D
//   0x04 COUNT   RO  number of inputs (8)
//   0x10 + 4i    RO  input i in kHz, measured every GATE_CYCLES of s_axi_aclk (0 = no clock)
module felix_refclk_meter #(
    parameter GATE_CYCLES = 100000
) (
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 s_axi_aclk CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF s_axi, ASSOCIATED_RESET s_axi_aresetn" *)
    input  wire        s_axi_aclk,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 s_axi_aresetn RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    input  wire        s_axi_aresetn,
    input  wire [15:0] s_axi_awaddr,
    input  wire [2:0]  s_axi_awprot,
    input  wire        s_axi_awvalid,
    output reg         s_axi_awready,
    input  wire [31:0] s_axi_wdata,
    input  wire [3:0]  s_axi_wstrb,
    input  wire        s_axi_wvalid,
    output reg         s_axi_wready,
    output wire [1:0]  s_axi_bresp,
    output reg         s_axi_bvalid,
    input  wire        s_axi_bready,
    input  wire [15:0] s_axi_araddr,
    input  wire [2:0]  s_axi_arprot,
    input  wire        s_axi_arvalid,
    output reg         s_axi_arready,
    output reg  [31:0] s_axi_rdata,
    output wire [1:0]  s_axi_rresp,
    output reg         s_axi_rvalid,
    input  wire        s_axi_rready,

    input  wire [7:0]  refclk_p,
    input  wire [7:0]  refclk_n,
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 refclk_o0 CLK" *)
    (* X_INTERFACE_PARAMETER = "FREQ_HZ 156250000" *)
    output wire        refclk_o0,
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 refclk_o1 CLK" *)
    (* X_INTERFACE_PARAMETER = "FREQ_HZ 156250000" *)
    output wire        refclk_o1,
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 refclk_o2 CLK" *)
    (* X_INTERFACE_PARAMETER = "FREQ_HZ 156250000" *)
    output wire        refclk_o2,
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 refclk_o3 CLK" *)
    (* X_INTERFACE_PARAMETER = "FREQ_HZ 156250000" *)
    output wire        refclk_o3,
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 refclk_o4 CLK" *)
    (* X_INTERFACE_PARAMETER = "FREQ_HZ 156250000" *)
    output wire        refclk_o4,
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 refclk_o5 CLK" *)
    (* X_INTERFACE_PARAMETER = "FREQ_HZ 156250000" *)
    output wire        refclk_o5,
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 refclk_o6 CLK" *)
    (* X_INTERFACE_PARAMETER = "FREQ_HZ 156250000" *)
    output wire        refclk_o6,
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 refclk_o7 CLK" *)
    (* X_INTERFACE_PARAMETER = "FREQ_HZ 156250000" *)
    output wire        refclk_o7,
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 refclk_mon0 CLK" *)
    (* X_INTERFACE_PARAMETER = "FREQ_HZ 156250000" *)
    output wire        refclk_mon0,
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 refclk_mon1 CLK" *)
    (* X_INTERFACE_PARAMETER = "FREQ_HZ 156250000" *)
    output wire        refclk_mon1,
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 refclk_mon2 CLK" *)
    (* X_INTERFACE_PARAMETER = "FREQ_HZ 156250000" *)
    output wire        refclk_mon2,
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 refclk_mon3 CLK" *)
    (* X_INTERFACE_PARAMETER = "FREQ_HZ 156250000" *)
    output wire        refclk_mon3,
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 refclk_mon4 CLK" *)
    (* X_INTERFACE_PARAMETER = "FREQ_HZ 156250000" *)
    output wire        refclk_mon4,
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 refclk_mon5 CLK" *)
    (* X_INTERFACE_PARAMETER = "FREQ_HZ 156250000" *)
    output wire        refclk_mon5,
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 refclk_mon6 CLK" *)
    (* X_INTERFACE_PARAMETER = "FREQ_HZ 156250000" *)
    output wire        refclk_mon6,
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 refclk_mon7 CLK" *)
    (* X_INTERFACE_PARAMETER = "FREQ_HZ 156250000" *)
    output wire        refclk_mon7
);

    wire [7:0] refclk_o;
    wire [7:0] refclk_mon;
    wire [7:0] odiv2;
    assign {refclk_o7, refclk_o6, refclk_o5, refclk_o4, refclk_o3, refclk_o2, refclk_o1, refclk_o0} = refclk_o;
    assign {refclk_mon7, refclk_mon6, refclk_mon5, refclk_mon4,
            refclk_mon3, refclk_mon2, refclk_mon1, refclk_mon0} = refclk_mon;
    reg  [31:0] cnt [0:7];
    wire [31:0] s_cnt [0:7];
    reg  [31:0] prev [0:7];
    reg  [31:0] khz [0:7];

    genvar i;
    generate
        for (i = 0; i < 8; i = i + 1) begin : g_in
            IBUFDS_GTE5 #(
                .REFCLK_EN_TX_PATH (1'b0),
                .REFCLK_HROW_CK_SEL(0),
                .REFCLK_ICNTL_RX   (0)
            ) ibuf (
                .O(refclk_o[i]), .ODIV2(odiv2[i]), .CEB(1'b0), .I(refclk_p[i]), .IB(refclk_n[i])
            );
            BUFG_GT #(.SIM_DEVICE("VERSAL_PREMIUM")) bufg (
                .O(refclk_mon[i]), .CE(1'b1), .CEMASK(1'b0), .CLR(1'b0), .CLRMASK(1'b0),
                .DIV(3'b000), .I(odiv2[i])
            );
            initial cnt[i] = 32'd0;
            always @(posedge refclk_mon[i]) cnt[i] <= cnt[i] + 32'd1;
            xpm_cdc_gray #(.DEST_SYNC_FF(3), .REG_OUTPUT(1), .WIDTH(32)) cdc (
                .src_clk(refclk_mon[i]), .src_in_bin(cnt[i]), .dest_clk(s_axi_aclk), .dest_out_bin(s_cnt[i]));
        end
    endgenerate

    reg [31:0] gate;
    integer k;
    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            gate <= 32'd0;
        end else if (gate == GATE_CYCLES - 1) begin
            gate <= 32'd0;
            for (k = 0; k < 8; k = k + 1) begin
                khz[k]  <= s_cnt[k] - prev[k];
                prev[k] <= s_cnt[k];
            end
        end else begin
            gate <= gate + 32'd1;
        end
    end

    // AXI-Lite: read-only registers; writes are accepted and ignored.
    assign s_axi_bresp = 2'b00;
    assign s_axi_rresp = 2'b00;

    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            s_axi_awready <= 1'b0;
            s_axi_wready  <= 1'b0;
            s_axi_bvalid  <= 1'b0;
        end else if (s_axi_awready) begin
            s_axi_awready <= 1'b0;
            s_axi_wready  <= 1'b0;
            s_axi_bvalid  <= 1'b1;
        end else if (s_axi_bvalid) begin
            if (s_axi_bready)
                s_axi_bvalid <= 1'b0;
        end else if (s_axi_awvalid && s_axi_wvalid) begin
            s_axi_awready <= 1'b1;
            s_axi_wready  <= 1'b1;
        end
    end

    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            s_axi_arready <= 1'b0;
            s_axi_rvalid  <= 1'b0;
            s_axi_rdata   <= 32'd0;
        end else if (s_axi_arready) begin
            s_axi_arready <= 1'b0;
            s_axi_rvalid  <= 1'b1;
        end else if (s_axi_rvalid) begin
            if (s_axi_rready)
                s_axi_rvalid <= 1'b0;
        end else if (s_axi_arvalid) begin
            s_axi_arready <= 1'b1;
            if (s_axi_araddr[7:2] >= 6'h04 && s_axi_araddr[7:2] <= 6'h0B)
                s_axi_rdata <= khz[s_axi_araddr[4:2] - 3'd4];
            else
                case (s_axi_araddr[7:2])
                    6'h00: s_axi_rdata <= 32'h434C4B4D;
                    6'h01: s_axi_rdata <= 32'd8;
                    default: s_axi_rdata <= 32'd0;
                endcase
        end
    end

endmodule
