// Static-shell glue for one GT quad: RX/TX lane adapters, the host register block and the clock
// crossings between them. One instance per quad, between gtwiz_versal and the two NoC streams.
//
// Registers (byte offsets in the quad's 64 KB window, host: PF2 BAR4 + 0x30000 for quad 106):
//   0x00 ID         RO  0x46475431
//   0x04 CTRL       RW  [0] rst_all [1] rst_tx_pll_and_datapath [2] rst_tx_datapath
//                       [3] rst_rx_pll_and_datapath [4] rst_rx_datapath [8] hold lane adapters in reset
//                       (RX sends nothing, TX takes and drops every beat)
//                       (reset value 0x100: no stream traffic into the kernel region until the host
//                       clears bit 8; a kernel-region reload with the streams running fails)
//   0x08 LOOPBACK   RW  3 bits per lane at [3L+2:3L] (0 normal, 2 near-end PMA)
//   0x0C TX_PRBS    RW  txprbssel, 4 bits per lane (0 off, 5 PRBS-31)
//   0x10 RX_PRBS    RW  rxprbssel, 4 bits per lane
//   0x14 POLARITY   RW  [3:0] tx, [7:4] rx
//   0x18 PRBS_CTRL  RW  [0] rxprbscntreset
//   0x20 STATUS     RO  [0] gtpowergood [1] tx reset done [2] rx reset done [7:4] rxprbslocked
//   0x24 RX_BEATS  0x28 RX_DROPS  0x2C TX_BEATS  0x30 TX_UNDERFLOWS   RO, free-running
//   0x3C BANK       RO  bank number of this quad (106, 110, 111, 112)
//   0x40 REFCLK_KHZ  0x44 TX_USRCLK_KHZ  0x48 RX_USRCLK_KHZ           RO, measured every GATE_CYCLES
//   0x50 + 4L  PRBS_ERR lane L   RO, rx_usrclk cycles with rxprbserr set, free-running
//   GT register port of the quad (gtwiz_versal Quad0_AXI_LITE), accessed one word at a time:
//   0x60 GT_ADDR    RW  byte address on the port (GT attribute address * 4)
//   0x64 GT_WDATA   RW  data for the next write
//   0x68 GT_CMD     W   1 = read, 2 = write (ignored while busy)
//                   R   [0] busy [1] the last access returned an error
//   0x6C GT_RDATA   RO  data of the last read
// On Versal the TXPRBSFORCEERR pin does not insert errors (AMD AR 76629); a TX PRBS error is
// forced through the GT attribute CH<n>_CHL_RSV_CFG1[5] on this port instead.
module felix_gt_quad_if #(
    parameter GATE_CYCLES = 100000,
    parameter BANK = 0
) (
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 s_axi_aclk CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF s_axi:m_axi_gt, ASSOCIATED_RESET s_axi_aresetn" *)
    input  wire         s_axi_aclk,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 s_axi_aresetn RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    input  wire         s_axi_aresetn,
    input  wire [15:0]  s_axi_awaddr,
    input  wire [2:0]   s_axi_awprot,
    input  wire         s_axi_awvalid,
    output reg          s_axi_awready,
    input  wire [31:0]  s_axi_wdata,
    input  wire [3:0]   s_axi_wstrb,
    input  wire         s_axi_wvalid,
    output reg          s_axi_wready,
    output wire [1:0]   s_axi_bresp,
    output reg          s_axi_bvalid,
    input  wire         s_axi_bready,
    input  wire [15:0]  s_axi_araddr,
    input  wire [2:0]   s_axi_arprot,
    input  wire         s_axi_arvalid,
    output reg          s_axi_arready,
    output reg  [31:0]  s_axi_rdata,
    output wire [1:0]   s_axi_rresp,
    output reg          s_axi_rvalid,
    input  wire         s_axi_rready,

    output wire         gt_rst_all,
    output wire         gt_rst_tx_pll_and_datapath,
    output wire         gt_rst_tx_datapath,
    output wire         gt_rst_rx_pll_and_datapath,
    output wire         gt_rst_rx_datapath,
    input  wire         gt_rst_tx_done,
    input  wire         gt_rst_rx_done,
    input  wire         gtpowergood,
    output wire [2:0]   ch0_loopback,
    output wire [2:0]   ch1_loopback,
    output wire [2:0]   ch2_loopback,
    output wire [2:0]   ch3_loopback,

    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 tx_usrclk CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF s_axis_tx" *)
    input  wire         tx_usrclk,
    output wire [127:0] txdata0,
    output wire [127:0] txdata1,
    output wire [127:0] txdata2,
    output wire [127:0] txdata3,
    output wire [3:0]   txprbssel0,
    output wire [3:0]   txprbssel1,
    output wire [3:0]   txprbssel2,
    output wire [3:0]   txprbssel3,
    output wire         txpolarity0,
    output wire         txpolarity1,
    output wire         txpolarity2,
    output wire         txpolarity3,

    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 rx_usrclk CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF m_axis_rx" *)
    input  wire         rx_usrclk,
    input  wire [127:0] rxdata0,
    input  wire [127:0] rxdata1,
    input  wire [127:0] rxdata2,
    input  wire [127:0] rxdata3,
    output wire [3:0]   rxprbssel0,
    output wire [3:0]   rxprbssel1,
    output wire [3:0]   rxprbssel2,
    output wire [3:0]   rxprbssel3,
    output wire         rxprbscntreset0,
    output wire         rxprbscntreset1,
    output wire         rxprbscntreset2,
    output wire         rxprbscntreset3,
    output wire         rxpolarity0,
    output wire         rxpolarity1,
    output wire         rxpolarity2,
    output wire         rxpolarity3,
    input  wire         rxprbslocked0,
    input  wire         rxprbslocked1,
    input  wire         rxprbslocked2,
    input  wire         rxprbslocked3,
    input  wire         rxprbserr0,
    input  wire         rxprbserr1,
    input  wire         rxprbserr2,
    input  wire         rxprbserr3,

    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 refclk_mon CLK" *)
    input  wire         refclk_mon,

    output wire [511:0] m_axis_rx_tdata,
    output wire [63:0]  m_axis_rx_tkeep,
    output wire         m_axis_rx_tlast,
    output wire         m_axis_rx_tvalid,
    input  wire         m_axis_rx_tready,

    input  wire [511:0] s_axis_tx_tdata,
    input  wire [63:0]  s_axis_tx_tkeep,
    input  wire         s_axis_tx_tlast,
    input  wire         s_axis_tx_tvalid,
    output wire         s_axis_tx_tready,

    output wire [17:0]  m_axi_gt_awaddr,
    output reg          m_axi_gt_awvalid,
    input  wire         m_axi_gt_awready,
    output wire [31:0]  m_axi_gt_wdata,
    output reg          m_axi_gt_wvalid,
    input  wire         m_axi_gt_wready,
    input  wire [1:0]   m_axi_gt_bresp,
    input  wire         m_axi_gt_bvalid,
    output reg          m_axi_gt_bready,
    output wire [17:0]  m_axi_gt_araddr,
    output reg          m_axi_gt_arvalid,
    input  wire         m_axi_gt_arready,
    input  wire [31:0]  m_axi_gt_rdata,
    input  wire [1:0]   m_axi_gt_rresp,
    input  wire         m_axi_gt_rvalid,
    output reg          m_axi_gt_rready
);

    // ---------------- registers (s_axi_aclk) ----------------
    reg [8:0]  ctrl;
    reg [11:0] loopback;
    reg [15:0] tx_prbs;
    reg [15:0] rx_prbs;
    reg [7:0]  polarity;
    reg        prbs_cntreset;
    reg [17:0] gt_addr;
    reg [31:0] gt_wdata;
    reg [1:0]  gt_req;
    reg        gt_busy, gt_err;
    reg [31:0] gt_rdata;

    assign gt_rst_all                 = ctrl[0];
    assign gt_rst_tx_pll_and_datapath = ctrl[1];
    assign gt_rst_tx_datapath         = ctrl[2];
    assign gt_rst_rx_pll_and_datapath = ctrl[3];
    assign gt_rst_rx_datapath         = ctrl[4];
    assign {ch3_loopback, ch2_loopback, ch1_loopback, ch0_loopback} = loopback;

    // ---------------- control into the GT clocks ----------------
    wire [20:0] tx_ctl;
    wire [21:0] rx_ctl;

    xpm_cdc_array_single #(.DEST_SYNC_FF(3), .SRC_INPUT_REG(1), .WIDTH(21)) cdc_tx_ctl (
        .src_clk(s_axi_aclk), .src_in({ctrl[8], polarity[3:0], tx_prbs}),
        .dest_clk(tx_usrclk), .dest_out(tx_ctl));
    xpm_cdc_array_single #(.DEST_SYNC_FF(3), .SRC_INPUT_REG(1), .WIDTH(22)) cdc_rx_ctl (
        .src_clk(s_axi_aclk), .src_in({ctrl[8], prbs_cntreset, polarity[7:4], rx_prbs}),
        .dest_clk(rx_usrclk), .dest_out(rx_ctl));

    assign {txprbssel3, txprbssel2, txprbssel1, txprbssel0}                 = tx_ctl[15:0];
    assign {txpolarity3, txpolarity2, txpolarity1, txpolarity0}             = tx_ctl[19:16];
    assign {rxprbssel3, rxprbssel2, rxprbssel1, rxprbssel0}                 = rx_ctl[15:0];
    assign {rxpolarity3, rxpolarity2, rxpolarity1, rxpolarity0}             = rx_ctl[19:16];
    assign {rxprbscntreset3, rxprbscntreset2, rxprbscntreset1, rxprbscntreset0} = {4{rx_ctl[20]}};

    // Lane adapters run only while the GT reports its reset done and the host does not hold them.
    wire tx_done_s, rx_done_s;
    xpm_cdc_single #(.DEST_SYNC_FF(3), .SRC_INPUT_REG(0)) cdc_tx_done (
        .src_clk(1'b0), .src_in(gt_rst_tx_done), .dest_clk(tx_usrclk), .dest_out(tx_done_s));
    xpm_cdc_single #(.DEST_SYNC_FF(3), .SRC_INPUT_REG(0)) cdc_rx_done (
        .src_clk(1'b0), .src_in(gt_rst_rx_done), .dest_clk(rx_usrclk), .dest_out(rx_done_s));

    reg tx_rst, rx_rst, tx_drop;
    always @(posedge tx_usrclk) tx_rst <= !tx_done_s || tx_ctl[20];
    // While held, the TX adapter also drops the beats it gets (see felix_gt_tx_adapter)
    always @(posedge tx_usrclk) tx_drop <= tx_ctl[20];
    always @(posedge rx_usrclk) rx_rst <= !rx_done_s || rx_ctl[21];

    // ---------------- lane adapters ----------------
    // A register stage sits between each adapter and its NoC stream cell: without it the adapter
    // FIFO memories connect straight to the NoC pins and these paths had no timing margin.
    wire [63:0] tx0, tx1, tx2, tx3;
    wire [31:0] tx_beats, tx_underflows, rx_beats, rx_drops;
    wire [511:0] tx_data, rx_data;
    wire         tx_valid, tx_ready, rx_valid, rx_ready;

    // The TX stage is never reset: hold and GT-not-ready are handled by the adapter behind it.
    felix_axis_reg tx_reg (
        .clk(tx_usrclk), .rst(1'b0),
        .s_tdata(s_axis_tx_tdata), .s_tvalid(s_axis_tx_tvalid), .s_tready(s_axis_tx_tready),
        .m_tdata(tx_data), .m_tvalid(tx_valid), .m_tready(tx_ready));

    felix_gt_tx_adapter tx_adapter (
        .clk(tx_usrclk), .rst(tx_rst), .drop(tx_drop),
        .s_axis_tdata(tx_data), .s_axis_tkeep({64{1'b1}}), .s_axis_tlast(1'b1),
        .s_axis_tvalid(tx_valid), .s_axis_tready(tx_ready),
        .txdata0(tx0), .txdata1(tx1), .txdata2(tx2), .txdata3(tx3),
        .beat_count(tx_beats), .underflow_count(tx_underflows));

    assign txdata0 = {64'd0, tx0};
    assign txdata1 = {64'd0, tx1};
    assign txdata2 = {64'd0, tx2};
    assign txdata3 = {64'd0, tx3};

    felix_gt_rx_adapter rx_adapter (
        .clk(rx_usrclk), .rst(rx_rst),
        .rxdata0(rxdata0[63:0]), .rxdata1(rxdata1[63:0]), .rxdata2(rxdata2[63:0]), .rxdata3(rxdata3[63:0]),
        .m_axis_tdata(rx_data), .m_axis_tkeep(m_axis_rx_tkeep), .m_axis_tlast(m_axis_rx_tlast),
        .m_axis_tvalid(rx_valid), .m_axis_tready(rx_ready),
        .beat_count(rx_beats), .drop_count(rx_drops));

    // Reset with the adapter, so a held quad sends nothing into the NoC (as before)
    felix_axis_reg rx_reg (
        .clk(rx_usrclk), .rst(rx_rst),
        .s_tdata(rx_data), .s_tvalid(rx_valid), .s_tready(rx_ready),
        .m_tdata(m_axis_rx_tdata), .m_tvalid(m_axis_rx_tvalid), .m_tready(m_axis_rx_tready));

    // ---------------- counters into s_axi_aclk ----------------
    reg [31:0] tx_cycles = 32'd0;
    reg [31:0] rx_cycles = 32'd0;
    reg [31:0] ref_cycles = 32'd0;
    reg [31:0] prbs_err [0:3];
    integer i;
    initial for (i = 0; i < 4; i = i + 1) prbs_err[i] = 32'd0;

    always @(posedge tx_usrclk)   tx_cycles  <= tx_cycles + 32'd1;
    always @(posedge refclk_mon) ref_cycles <= ref_cycles + 32'd1;
    always @(posedge rx_usrclk) begin
        rx_cycles <= rx_cycles + 32'd1;
        if (rxprbserr0) prbs_err[0] <= prbs_err[0] + 32'd1;
        if (rxprbserr1) prbs_err[1] <= prbs_err[1] + 32'd1;
        if (rxprbserr2) prbs_err[2] <= prbs_err[2] + 32'd1;
        if (rxprbserr3) prbs_err[3] <= prbs_err[3] + 32'd1;
    end

    wire [31:0] s_tx_beats, s_tx_underflows, s_tx_cycles;
    wire [31:0] s_rx_beats, s_rx_drops, s_rx_cycles, s_ref_cycles;
    wire [31:0] s_prbs_err [0:3];

    `define FELIX_GRAY(name, sclk, din, dout) \
        xpm_cdc_gray #(.DEST_SYNC_FF(3), .REG_OUTPUT(1), .WIDTH(32)) name ( \
            .src_clk(sclk), .src_in_bin(din), .dest_clk(s_axi_aclk), .dest_out_bin(dout));

    `FELIX_GRAY(cdc_tx_beats,  tx_usrclk,   tx_beats,      s_tx_beats)
    `FELIX_GRAY(cdc_tx_under,  tx_usrclk,   tx_underflows, s_tx_underflows)
    `FELIX_GRAY(cdc_tx_cycles, tx_usrclk,   tx_cycles,     s_tx_cycles)
    `FELIX_GRAY(cdc_rx_beats,  rx_usrclk,   rx_beats,      s_rx_beats)
    `FELIX_GRAY(cdc_rx_drops,  rx_usrclk,   rx_drops,      s_rx_drops)
    `FELIX_GRAY(cdc_rx_cycles, rx_usrclk,   rx_cycles,     s_rx_cycles)
    `FELIX_GRAY(cdc_ref,       refclk_mon,  ref_cycles,    s_ref_cycles)
    `FELIX_GRAY(cdc_err0,      rx_usrclk,   prbs_err[0],   s_prbs_err[0])
    `FELIX_GRAY(cdc_err1,      rx_usrclk,   prbs_err[1],   s_prbs_err[1])
    `FELIX_GRAY(cdc_err2,      rx_usrclk,   prbs_err[2],   s_prbs_err[2])
    `FELIX_GRAY(cdc_err3,      rx_usrclk,   prbs_err[3],   s_prbs_err[3])
    `undef FELIX_GRAY

    wire [6:0] status_s;
    xpm_cdc_array_single #(.DEST_SYNC_FF(3), .SRC_INPUT_REG(0), .WIDTH(7)) cdc_status (
        .src_clk(1'b0),
        .src_in({rxprbslocked3, rxprbslocked2, rxprbslocked1, rxprbslocked0, gt_rst_rx_done, gt_rst_tx_done, gtpowergood}),
        .dest_clk(s_axi_aclk), .dest_out(status_s));

    // Frequencies: cycles of each clock per GATE_CYCLES of s_axi_aclk (kHz at 100 MHz / 100000).
    reg [31:0] gate;
    reg [31:0] prev_ref, prev_tx, prev_rx;
    reg [31:0] khz_ref, khz_tx, khz_rx;

    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            gate <= 32'd0;
        end else if (gate == GATE_CYCLES - 1) begin
            gate     <= 32'd0;
            khz_ref  <= s_ref_cycles - prev_ref;
            khz_tx   <= s_tx_cycles - prev_tx;
            khz_rx   <= s_rx_cycles - prev_rx;
            prev_ref <= s_ref_cycles;
            prev_tx  <= s_tx_cycles;
            prev_rx  <= s_rx_cycles;
        end else begin
            gate <= gate + 32'd1;
        end
    end

    // ---------------- AXI-Lite ----------------
    assign s_axi_bresp = 2'b00;
    assign s_axi_rresp = 2'b00;

    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            s_axi_awready <= 1'b0;
            s_axi_wready  <= 1'b0;
            s_axi_bvalid  <= 1'b0;
            ctrl      <= 9'h100;
            loopback  <= 12'd0;
            tx_prbs   <= 16'd0;
            rx_prbs   <= 16'd0;
            polarity  <= 8'd0;
            prbs_cntreset <= 1'b0;
            gt_addr   <= 18'd0;
            gt_wdata  <= 32'd0;
            gt_req    <= 2'd0;
        end else begin
            gt_req <= 2'd0;
            if (s_axi_awready) begin
                s_axi_awready <= 1'b0;
                s_axi_wready  <= 1'b0;
                s_axi_bvalid  <= 1'b1;
            end else if (s_axi_bvalid) begin
                if (s_axi_bready)
                    s_axi_bvalid <= 1'b0;
            end else if (s_axi_awvalid && s_axi_wvalid) begin
                s_axi_awready <= 1'b1;
                s_axi_wready  <= 1'b1;
                case (s_axi_awaddr[7:2])
                    6'h01: ctrl      <= s_axi_wdata[8:0];
                    6'h02: loopback  <= s_axi_wdata[11:0];
                    6'h03: tx_prbs   <= s_axi_wdata[15:0];
                    6'h04: rx_prbs   <= s_axi_wdata[15:0];
                    6'h05: polarity  <= s_axi_wdata[7:0];
                    6'h06: prbs_cntreset <= s_axi_wdata[0];
                    6'h18: gt_addr   <= s_axi_wdata[17:0];
                    6'h19: gt_wdata  <= s_axi_wdata;
                    6'h1A: gt_req    <= s_axi_wdata[1:0];
                    default: ;
                endcase
            end
        end
    end

    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            s_axi_arready <= 1'b0;
            s_axi_rvalid  <= 1'b0;
            s_axi_rdata   <= 32'd0;
        end else begin
            if (s_axi_arready) begin
                s_axi_arready <= 1'b0;
                s_axi_rvalid  <= 1'b1;
            end else if (s_axi_rvalid) begin
                if (s_axi_rready)
                    s_axi_rvalid <= 1'b0;
            end else if (s_axi_arvalid) begin
                s_axi_arready <= 1'b1;
                case (s_axi_araddr[7:2])
                    6'h00: s_axi_rdata <= 32'h46475431;
                    6'h01: s_axi_rdata <= {23'd0, ctrl};
                    6'h02: s_axi_rdata <= {20'd0, loopback};
                    6'h03: s_axi_rdata <= {16'd0, tx_prbs};
                    6'h04: s_axi_rdata <= {16'd0, rx_prbs};
                    6'h05: s_axi_rdata <= {24'd0, polarity};
                    6'h06: s_axi_rdata <= {31'd0, prbs_cntreset};
                    6'h08: s_axi_rdata <= {24'd0, status_s[6:3], 1'b0, status_s[2:0]};
                    6'h09: s_axi_rdata <= s_rx_beats;
                    6'h0A: s_axi_rdata <= s_rx_drops;
                    6'h0B: s_axi_rdata <= s_tx_beats;
                    6'h0C: s_axi_rdata <= s_tx_underflows;
                    6'h0F: s_axi_rdata <= BANK;
                    6'h10: s_axi_rdata <= khz_ref;
                    6'h11: s_axi_rdata <= khz_tx;
                    6'h12: s_axi_rdata <= khz_rx;
                    6'h14: s_axi_rdata <= s_prbs_err[0];
                    6'h15: s_axi_rdata <= s_prbs_err[1];
                    6'h16: s_axi_rdata <= s_prbs_err[2];
                    6'h17: s_axi_rdata <= s_prbs_err[3];
                    6'h18: s_axi_rdata <= {14'd0, gt_addr};
                    6'h19: s_axi_rdata <= gt_wdata;
                    6'h1A: s_axi_rdata <= {30'd0, gt_err, gt_busy};
                    6'h1B: s_axi_rdata <= gt_rdata;
                    default: s_axi_rdata <= 32'd0;
                endcase
            end
        end
    end

    // ---------------- GT register port: one access per GT_CMD write ----------------
    assign m_axi_gt_awaddr = gt_addr;
    assign m_axi_gt_araddr = gt_addr;
    assign m_axi_gt_wdata  = gt_wdata;

    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            gt_busy          <= 1'b0;
            gt_err           <= 1'b0;
            gt_rdata         <= 32'd0;
            m_axi_gt_awvalid <= 1'b0;
            m_axi_gt_wvalid  <= 1'b0;
            m_axi_gt_bready  <= 1'b0;
            m_axi_gt_arvalid <= 1'b0;
            m_axi_gt_rready  <= 1'b0;
        end else if (!gt_busy) begin
            if (gt_req == 2'd1) begin
                gt_busy          <= 1'b1;
                m_axi_gt_arvalid <= 1'b1;
                m_axi_gt_rready  <= 1'b1;
            end else if (gt_req == 2'd2) begin
                gt_busy          <= 1'b1;
                m_axi_gt_awvalid <= 1'b1;
                m_axi_gt_wvalid  <= 1'b1;
                m_axi_gt_bready  <= 1'b1;
            end
        end else begin
            if (m_axi_gt_arready) m_axi_gt_arvalid <= 1'b0;
            if (m_axi_gt_awready) m_axi_gt_awvalid <= 1'b0;
            if (m_axi_gt_wready)  m_axi_gt_wvalid  <= 1'b0;
            if (m_axi_gt_rvalid && m_axi_gt_rready) begin
                gt_rdata        <= m_axi_gt_rdata;
                gt_err          <= m_axi_gt_rresp[1];
                m_axi_gt_rready <= 1'b0;
                gt_busy         <= 1'b0;
            end
            if (m_axi_gt_bvalid && m_axi_gt_bready) begin
                gt_err          <= m_axi_gt_bresp[1];
                m_axi_gt_bready <= 1'b0;
                gt_busy         <= 1'b0;
            end
        end
    end

endmodule
