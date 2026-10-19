// Board control lines in bank 703 (1.5 V, through SN74AVC4T245 level shifters; schematic pp.31,
// 46-49): reset, I2C select, present and interrupt of the FireFly 1 and 2 TX and RX modules, plus
// lines that must keep the levels the FELIX firmware gives them once the bank is in use (its unused
// pins are pulled low): FireFly 6 out of reset and selected, both I/O expanders out of reset.
// Module order in each 4-bit field: FF1 TX, FF1 RX, FF2 TX, FF2 RX.
//
// Registers (byte offsets, host: PF2 BAR4 + 0x78000):
//   0x00 ID         RO  0x4252494F
//   0x04 FF_CTRL    RW  [3:0] reset_b (1 = module running), [11:8] select_b (0 = I2C enabled);
//                       reset value 0x00F, the FELIX firmware default
//   0x08 FF_STATUS  RO  [3:0] module present, [11:8] module interrupt, [16] FF6 present,
//                       [17] FF6 interrupt, [24] I/O expander 1 interrupt, [25] I/O expander 2 interrupt
//                       (all active high here; the board lines are active low)
module felix_board_io (
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

    output wire [3:0]  ff_rst_b,
    output wire [3:0]  ff_sel_b,
    input  wire [3:0]  ff_prsnt_b,
    input  wire [3:0]  ff_intr_b,
    output wire        ff6_rst_b,
    output wire        ff6_sel_b,
    input  wire        ff6_prsnt_b,
    input  wire        ff6_intr_b,
    output wire [1:0]  ioexp_rst_b,
    input  wire [1:0]  ioexp_intr_b
);

    // FireFly 1/2 reset and I2C select, host-writable; start with the modules running and selected
    reg [3:0] rst_b = 4'hF;
    reg [3:0] sel_b = 4'h0;
    assign ff_rst_b    = rst_b;
    assign ff_sel_b    = sel_b;
    // Lines that only need fixed FELIX levels
    assign ff6_rst_b   = 1'b1;
    assign ff6_sel_b   = 1'b0;
    assign ioexp_rst_b = 2'b11;

    // Present and interrupt inputs, synchronised to the register clock and inverted to active high
    wire [11:0] in_s;
    xpm_cdc_array_single #(.DEST_SYNC_FF(3), .SRC_INPUT_REG(0), .WIDTH(12)) cdc_in (
        .src_clk(1'b0),
        .src_in({ioexp_intr_b, ff6_intr_b, ff6_prsnt_b, ff_intr_b, ff_prsnt_b}),
        .dest_clk(s_axi_aclk), .dest_out(in_s));
    wire [31:0] status = {6'd0, ~in_s[11:10], 6'd0, ~in_s[9], ~in_s[8], 4'd0, ~in_s[7:4], 4'd0, ~in_s[3:0]};

    assign s_axi_bresp = 2'b00;
    assign s_axi_rresp = 2'b00;

    // AXI-Lite write: only FF_CTRL (0x04) is writable
    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            s_axi_awready <= 1'b0;
            s_axi_wready  <= 1'b0;
            s_axi_bvalid  <= 1'b0;
            rst_b         <= 4'hF;
            sel_b         <= 4'h0;
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
            if (s_axi_awaddr[7:2] == 6'h01) begin
                rst_b <= s_axi_wdata[3:0];
                sel_b <= s_axi_wdata[11:8];
            end
        end
    end

    // AXI-Lite read: ID, FF_CTRL, FF_STATUS
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
            case (s_axi_araddr[7:2])
                6'h00: s_axi_rdata <= 32'h4252494F;
                6'h01: s_axi_rdata <= {20'd0, sel_b, 4'd0, rst_b};
                6'h02: s_axi_rdata <= status;
                default: s_axi_rdata <= 32'd0;
            endcase
        end
    end

endmodule
