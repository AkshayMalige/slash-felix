// Testbench for felix_gt_quad_if: GT modelled as a 3-cycle loop from txdata to rxdata on one
// 402.832 MHz clock. A source sends beats with per-lane word counters (with gaps, so the TX
// adapter underflows), a sink with random back-pressure checks that every lane receives the
// same words in order, and the AXI-Lite tasks check the registers and frequency counters. The
// GT register port is a word memory with random ready delays and an error at 0x3FFFC.
`timescale 1ps/1ps
module tb_felix_gt_quad_if;

    localparam int GATE = 1000;
    localparam int NBEATS = 3000;

    logic aclk = 0, aresetn = 0, gtclk = 0, refdiv2 = 0;
    always #5000 aclk = ~aclk;
    always #1241 gtclk = ~gtclk;
    always #6400 refdiv2 = ~refdiv2;

    logic [15:0] awaddr, araddr;
    logic awvalid = 0, wvalid = 0, bready = 1, arvalid = 0, rready = 1;
    logic [31:0] wdata;
    wire awready, wready, bvalid, arready, rvalid;
    wire [1:0] bresp, rresp;
    wire [31:0] rdata;

    logic tx_done = 0, rx_done = 0;
    logic [3:0] prbserr = 0;
    wire [127:0] txd [4];
    logic [127:0] rxd [4];
    wire [2:0] lb [4];
    wire [17:0] gt_awaddr, gt_araddr;
    wire [31:0] gt_wdata;
    wire gt_awvalid, gt_wvalid, gt_bready, gt_arvalid, gt_rready;
    logic gt_awready = 0, gt_wready = 0, gt_bvalid = 0, gt_arready = 0, gt_rvalid = 0;
    logic [1:0] gt_bresp = 0, gt_rresp = 0;
    logic [31:0] gt_rdata = 0;

    wire [511:0] rx_tdata;
    wire [63:0]  rx_tkeep;
    wire         rx_tlast, rx_tvalid;
    logic        rx_tready = 0;
    logic [511:0] tx_tdata;
    logic         tx_tvalid = 0;
    wire          tx_tready;

    felix_gt_quad_if #(.GATE_CYCLES(GATE), .BANK(110)) dut (
        .s_axi_aclk(aclk), .s_axi_aresetn(aresetn),
        .s_axi_awaddr(awaddr), .s_axi_awprot(3'b0), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
        .s_axi_wdata(wdata), .s_axi_wstrb(4'hF), .s_axi_wvalid(wvalid), .s_axi_wready(wready),
        .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
        .s_axi_araddr(araddr), .s_axi_arprot(3'b0), .s_axi_arvalid(arvalid), .s_axi_arready(arready),
        .s_axi_rdata(rdata), .s_axi_rresp(rresp), .s_axi_rvalid(rvalid), .s_axi_rready(rready),
        .gt_rst_all(), .gt_rst_tx_pll_and_datapath(), .gt_rst_tx_datapath(),
        .gt_rst_rx_pll_and_datapath(), .gt_rst_rx_datapath(),
        .gt_rst_tx_done(tx_done), .gt_rst_rx_done(rx_done), .gtpowergood(1'b1),
        .ch0_loopback(lb[0]), .ch1_loopback(lb[1]), .ch2_loopback(lb[2]), .ch3_loopback(lb[3]),
        .tx_usrclk(gtclk),
        .txdata0(txd[0]), .txdata1(txd[1]), .txdata2(txd[2]), .txdata3(txd[3]),
        .txprbssel0(), .txprbssel1(), .txprbssel2(), .txprbssel3(),
        .txpolarity0(), .txpolarity1(), .txpolarity2(), .txpolarity3(),
        .rx_usrclk(gtclk),
        .rxdata0(rxd[0]), .rxdata1(rxd[1]), .rxdata2(rxd[2]), .rxdata3(rxd[3]),
        .rxprbssel0(), .rxprbssel1(), .rxprbssel2(), .rxprbssel3(),
        .rxprbscntreset0(), .rxprbscntreset1(), .rxprbscntreset2(), .rxprbscntreset3(),
        .rxpolarity0(), .rxpolarity1(), .rxpolarity2(), .rxpolarity3(),
        .rxprbslocked0(1'b1), .rxprbslocked1(1'b0), .rxprbslocked2(1'b1), .rxprbslocked3(1'b0),
        .rxprbserr0(prbserr[0]), .rxprbserr1(prbserr[1]), .rxprbserr2(prbserr[2]), .rxprbserr3(prbserr[3]),
        .refclk_mon(refdiv2),
        .m_axis_rx_tdata(rx_tdata), .m_axis_rx_tkeep(rx_tkeep), .m_axis_rx_tlast(rx_tlast),
        .m_axis_rx_tvalid(rx_tvalid), .m_axis_rx_tready(rx_tready),
        .s_axis_tx_tdata(tx_tdata), .s_axis_tx_tkeep({64{1'b1}}), .s_axis_tx_tlast(1'b1),
        .s_axis_tx_tvalid(tx_tvalid), .s_axis_tx_tready(tx_tready),
        .m_axi_gt_awaddr(gt_awaddr), .m_axi_gt_awvalid(gt_awvalid), .m_axi_gt_awready(gt_awready),
        .m_axi_gt_wdata(gt_wdata), .m_axi_gt_wvalid(gt_wvalid), .m_axi_gt_wready(gt_wready),
        .m_axi_gt_bresp(gt_bresp), .m_axi_gt_bvalid(gt_bvalid), .m_axi_gt_bready(gt_bready),
        .m_axi_gt_araddr(gt_araddr), .m_axi_gt_arvalid(gt_arvalid), .m_axi_gt_arready(gt_arready),
        .m_axi_gt_rdata(gt_rdata), .m_axi_gt_rresp(gt_rresp), .m_axi_gt_rvalid(gt_rvalid),
        .m_axi_gt_rready(gt_rready));

    // GT register port model
    logic [31:0] gt_mem [int];
    logic aw_done = 0, w_done = 0;
    logic [17:0] aw_q;
    logic [31:0] w_q;
    always @(posedge aclk) begin
        if (gt_awvalid && gt_awready) begin aw_done <= 1; aw_q <= gt_awaddr; end
        if (gt_wvalid && gt_wready) begin w_done <= 1; w_q <= gt_wdata; end
        gt_awready <= gt_awvalid && !gt_awready && !aw_done && ($urandom % 3 == 0);
        gt_wready  <= gt_wvalid && !gt_wready && !w_done && ($urandom % 3 == 0);
        if (aw_done && w_done && !gt_bvalid) begin
            gt_bvalid <= 1;
            gt_bresp  <= (aw_q == 18'h3FFFC) ? 2'b10 : 2'b00;
            if (aw_q != 18'h3FFFC) gt_mem[aw_q] = w_q;
            aw_done <= 0;
            w_done  <= 0;
        end else if (gt_bvalid && gt_bready) begin
            gt_bvalid <= 0;
        end
        if (gt_arvalid && gt_arready) begin
            gt_rvalid <= 1;
            gt_rresp  <= (gt_araddr == 18'h3FFFC) ? 2'b10 : 2'b00;
            gt_rdata  <= gt_mem.exists(gt_araddr) ? gt_mem[gt_araddr] : (32'hDEAD0000 | gt_araddr);
        end else if (gt_rvalid && gt_rready) begin
            gt_rvalid <= 0;
        end
        gt_arready <= gt_arvalid && !gt_arready && !gt_rvalid && ($urandom % 3 == 0);
    end

    // GT loop: 3 cycles from txdata to rxdata
    logic [255:0] pipe [3];
    always @(posedge gtclk) begin
        pipe[0] <= {txd[3][63:0], txd[2][63:0], txd[1][63:0], txd[0][63:0]};
        pipe[1] <= pipe[0];
        pipe[2] <= pipe[1];
        for (int l = 0; l < 4; l++) rxd[l] <= {64'hDEAD_BEEF_DEAD_BEEF, pipe[2][64*l +: 64]};
    end

    int errors = 0;
    task automatic check(input bit cond, input string msg);
        if (!cond) begin errors++; $display("FAIL: %s", msg); end
    endtask

    task automatic axi_write(input logic [15:0] a, input logic [31:0] d);
        @(posedge aclk); awaddr <= a; wdata <= d; awvalid <= 1; wvalid <= 1;
        do @(posedge aclk); while (!(awready && wready));
        awvalid <= 0; wvalid <= 0;
        do @(posedge aclk); while (!bvalid);
    endtask

    task automatic axi_read(input logic [15:0] a, output logic [31:0] d);
        @(posedge aclk); araddr <= a; arvalid <= 1;
        do @(posedge aclk); while (!arready);
        arvalid <= 0;
        do @(posedge aclk); while (!rvalid);
        d = rdata;
    endtask

    // one GT register access through GT_ADDR/GT_WDATA/GT_CMD; returns GT_CMD status when done
    task automatic gt_access(input logic [17:0] a, input logic [31:0] wd, input bit wr,
                             output logic [31:0] st);
        axi_write(16'h60, a);
        if (wr) axi_write(16'h64, wd);
        axi_write(16'h68, wr ? 32'h2 : 32'h1);
        for (int i = 0; i < 100; i++) begin
            axi_read(16'h68, st);
            if (!st[0]) return;
        end
        check(0, "GT access still busy after 100 polls");
    endtask

    // Source: beat k carries, for lane L, words 2k and 2k+1 tagged with the lane number.
    int sent = 0;
    int extra = 0;  // beats offered after the run, while the adapters are held
    function automatic logic [63:0] word(int lane, longint idx);
        return {8'hA0 + 8'(lane), 56'(idx)};
    endfunction
    always @(posedge gtclk) begin
        if (tx_tvalid && tx_tready) sent <= sent + 1;
        if (!(tx_tvalid && !tx_tready)) begin
            if (sent + (tx_tvalid && tx_tready) < NBEATS + extra && ($urandom % 100) < 70) begin
                automatic int k = sent + (tx_tvalid && tx_tready);
                for (int l = 0; l < 4; l++)
                    tx_tdata[128*l +: 128] <= {word(l, 2*k + 1), word(l, 2*k)};
                tx_tvalid <= rx_done;
            end else begin
                tx_tvalid <= 0;
            end
        end
    end

    // Sink: random back-pressure; unpack each lane, skip zero (underflow) words, check order.
    longint next_idx [4] = '{0, 0, 0, 0};
    int zero_words = 0, got_words = 0;
    always @(posedge gtclk) begin
        rx_tready <= ($urandom % 100) < 85;
        if (rx_tvalid && rx_tready) begin
            for (int h = 0; h < 2; h++) begin
                logic [63:0] w [4];
                for (int l = 0; l < 4; l++) w[l] = rx_tdata[128*l + 64*h +: 64];
                if (w[0] == 64'd0) begin
                    zero_words++;
                    for (int l = 1; l < 4; l++) check(w[l] == 64'd0, "lanes not zero together");
                end else begin
                    got_words++;
                    for (int l = 0; l < 4; l++) begin
                        if (w[l] != word(l, next_idx[l]))
                            check(0, $sformatf("lane %0d got %h expected %h", l, w[l], word(l, next_idx[l])));
                        next_idx[l] = next_idx[l] + 1;
                    end
                end
            end
        end
    end

    logic [31:0] d;
    initial begin
        repeat (20) @(posedge aclk);
        aresetn <= 1;
        axi_read(16'h00, d);  check(d == 32'h46475431, $sformatf("ID %h", d));
        axi_read(16'h04, d);  check(d == 32'h100, $sformatf("CTRL reset value %h", d));
        axi_write(16'h04, 32'h0);
        axi_write(16'h08, 32'h492);
        axi_read(16'h08, d);  check(d == 32'h492, $sformatf("LOOPBACK %h", d));
        repeat (2) @(posedge aclk);
        check(lb[0] == 3'd2 && lb[3] == 3'd2, "loopback outputs");
        axi_write(16'h0C, 32'h5555);
        axi_read(16'h0C, d);  check(d == 32'h5555, "TX_PRBS");

        tx_done <= 1; rx_done <= 1;
        repeat (40) @(posedge gtclk);
        @(posedge gtclk); prbserr[2] <= 1;
        repeat (7) @(posedge gtclk);
        prbserr[2] <= 0;

        wait (sent == NBEATS);
        repeat (2000) @(posedge gtclk);
        check(got_words == 2 * NBEATS, $sformatf("got %0d words, sent %0d", got_words, 2 * NBEATS));
        $display("words received %0d, underflow zero words %0d", got_words, zero_words);

        repeat (3 * GATE) @(posedge aclk);
        axi_read(16'h24, d);  check(d == NBEATS + zero_words / 2 || d >= NBEATS, $sformatf("RX_BEATS %0d", d));
        $display("RX_BEATS %0d", d);
        axi_read(16'h28, d);  check(d == 0, $sformatf("RX_DROPS %0d", d));
        axi_read(16'h2C, d);  check(d == NBEATS, $sformatf("TX_BEATS %0d", d));
        axi_read(16'h30, d);  $display("TX_UNDERFLOWS %0d", d);
        check(d > 0, "expected some underflows with the 70% source");
        axi_read(16'h20, d);  check(d[2:0] == 3'b111 && d[7:4] == 4'b0101, $sformatf("STATUS %h", d));
        axi_read(16'h3C, d);  check(d == 110, $sformatf("BANK %0d", d));
        axi_read(16'h40, d);  $display("REFCLK %0d (expect ~781)", d); check(d >= 779 && d <= 783, "refclk div2 count");
        axi_read(16'h44, d);  $display("TX_USRCLK %0d (expect ~4029)", d); check(d >= 4025 && d <= 4033, "tx usrclk count");
        axi_read(16'h48, d);  check(d >= 4025 && d <= 4033, "rx usrclk count");
        axi_read(16'h58, d);  check(d == 7, $sformatf("PRBS_ERR lane 2 = %0d", d));
        axi_read(16'h54, d);  check(d == 0, "PRBS_ERR lane 1");

        gt_access(18'h3188, 32'h20, 1, d);
        check(d[1:0] == 2'b00, $sformatf("GT write status %h", d));
        check(gt_mem.exists(18'h3188) && gt_mem[18'h3188] == 32'h20, "GT write reached the port");
        axi_write(16'h64, 32'h0);
        gt_access(18'h3188, 0, 0, d);
        check(d[1:0] == 2'b00, $sformatf("GT read status %h", d));
        axi_read(16'h6C, d);  check(d == 32'h20, $sformatf("GT read data %h", d));
        gt_access(18'h31DC, 0, 0, d);
        axi_read(16'h6C, d);  check(d == 32'hDEAD31DC, $sformatf("GT read of unwritten word %h", d));
        gt_access(18'h3FFFC, 32'h1, 1, d);
        check(d[1:0] == 2'b10, $sformatf("GT write error not reported, status %h", d));
        gt_access(18'h3188, 0, 0, d);
        check(d[1:0] == 2'b00, $sformatf("GT error flag not cleared by a good access, status %h", d));
        axi_read(16'h60, d);  check(d == 32'h3188, $sformatf("GT_ADDR %h", d));

        axi_write(16'h04, 32'h100);
        repeat (20) @(posedge gtclk);
        check(tx_tready == 1, "held TX adapter takes beats (and drops them) instead of refusing them");
        extra = 64;
        wait (sent == NBEATS + 64);
        repeat (20) @(posedge gtclk);
        axi_read(16'h2C, d);  check(d == 0, $sformatf("beats taken while held reached the lanes: TX_BEATS %0d", d));
        axi_write(16'h04, 32'h0);

        if (errors == 0) $display("TB_RESULT: PASS");
        else             $display("TB_RESULT: FAIL (%0d errors)", errors);
        $finish;
    end

    initial begin
        #50ms;
        $display("TB_RESULT: FAIL (timeout)");
        $finish;
    end

endmodule
