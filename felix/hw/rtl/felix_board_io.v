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
//   0x0C I2C_MUX    W   [0] 1 = reset the board I2C switch (TCA9548A U86 at 0x77) once more
//                   R   [0] switch reset active
//
// The I2C switch reset (BP40 in bank 707, through level shifter U17) is held low for MUX_RST_CYCLES
// right after configuration and after each I2C_MUX write, high otherwise. With the line only ever
// driven high, a switch that came up not answering its address stayed that way and every AMC
// sensor read failed (2026-10-22: NACK at 0x77, bus idle).
module felix_board_io #(
    parameter MUX_RST_CYCLES = 1024
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

    output wire [3:0]  ff_rst_b,
    output wire [3:0]  ff_sel_b,
    input  wire [3:0]  ff_prsnt_b,
    input  wire [3:0]  ff_intr_b,
    output wire        ff6_rst_b,
    output wire        ff6_sel_b,
    input  wire        ff6_prsnt_b,
    input  wire        ff6_intr_b,
    output wire [1:0]  ioexp_rst_b,
    input  wire [1:0]  ioexp_intr_b,
    output wire        i2c_mux_rst_b
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

    // I2C switch reset: counts down from configuration (initial value) and from each host request.
    // Not tied to s_axi_aresetn, so a reset of the register block does not reset the switch.
    reg [$clog2(MUX_RST_CYCLES):0] mux_rst_cnt = MUX_RST_CYCLES;
    reg                            mux_rst_b = 1'b0;
    reg                            mux_rst_go = 1'b0;
    always @(posedge s_axi_aclk) begin
        if (mux_rst_go)
            mux_rst_cnt <= MUX_RST_CYCLES;
        else if (mux_rst_cnt != 0)
            mux_rst_cnt <= mux_rst_cnt - 1'b1;
        mux_rst_b <= (mux_rst_cnt == 0) && !mux_rst_go;
    end
    assign i2c_mux_rst_b = mux_rst_b;

    // Present and interrupt inputs, synchronised to the register clock and inverted to active high
    wire [11:0] in_s;
    xpm_cdc_array_single #(.DEST_SYNC_FF(3), .SRC_INPUT_REG(0), .WIDTH(12)) cdc_in (
        .src_clk(1'b0),
        .src_in({ioexp_intr_b, ff6_intr_b, ff6_prsnt_b, ff_intr_b, ff_prsnt_b}),
        .dest_clk(s_axi_aclk), .dest_out(in_s));
    wire [31:0] status = {6'd0, ~in_s[11:10], 6'd0, ~in_s[9], ~in_s[8], 4'd0, ~in_s[7:4], 4'd0, ~in_s[3:0]};

    assign s_axi_bresp = 2'b00;
    assign s_axi_rresp = 2'b00;

    // AXI-Lite write: FF_CTRL (0x04) and I2C_MUX (0x0C)
    always @(posedge s_axi_aclk) begin
        mux_rst_go <= 1'b0;
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
            if (s_axi_awaddr[7:2] == 6'h03 && s_axi_wdata[0])
                mux_rst_go <= 1'b1;
        end
    end

    // AXI-Lite read: ID, FF_CTRL, FF_STATUS, I2C_MUX
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
                6'h03: s_axi_rdata <= {31'd0, !mux_rst_b};
                default: s_axi_rdata <= 32'd0;
            endcase
        end
    end

endmodule
