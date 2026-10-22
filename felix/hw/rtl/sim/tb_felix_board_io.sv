// Testbench for felix_board_io: reset levels of the board lines, FF_CTRL writes, FF_STATUS bits,
// the I2C switch reset pulse after configuration and on request (I2C_MUX).
`timescale 1ps/1ps
module tb_felix_board_io;

    logic aclk = 0, aresetn = 0;
    always #5000 aclk = ~aclk;

    logic [15:0] awaddr, araddr;
    logic awvalid = 0, wvalid = 0, bready = 1, arvalid = 0, rready = 1;
    logic [31:0] wdata;
    wire awready, wready, bvalid, arready, rvalid;
    wire [1:0] bresp, rresp;
    wire [31:0] rdata;

    wire [3:0] rst_b, sel_b;
    wire ff6_rst_b, ff6_sel_b;
    wire [1:0] ioexp_rst_b;
    wire mux_rst_b;
    // Board inputs (active low) with a mixed pattern, so every FF_STATUS bit position is checked
    logic [3:0] prsnt_b = 4'b1010, intr_b = 4'b1101;
    logic ff6_prsnt_b = 0, ff6_intr_b = 1;
    logic [1:0] ioexp_intr_b = 2'b01;

    // Count clock cycles with the I2C switch reset low, and the low pulses
    int mux_low = 0, mux_pulses = 0;
    logic mux_prev = 1;
    always @(posedge aclk) begin
        if (!mux_rst_b) mux_low++;
        if (mux_prev && !mux_rst_b) mux_pulses++;
        mux_prev <= mux_rst_b;
    end

    felix_board_io #(.MUX_RST_CYCLES(64)) dut (
        .s_axi_aclk(aclk), .s_axi_aresetn(aresetn),
        .s_axi_awaddr(awaddr), .s_axi_awprot(3'b0), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
        .s_axi_wdata(wdata), .s_axi_wstrb(4'hF), .s_axi_wvalid(wvalid), .s_axi_wready(wready),
        .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
        .s_axi_araddr(araddr), .s_axi_arprot(3'b0), .s_axi_arvalid(arvalid), .s_axi_arready(arready),
        .s_axi_rdata(rdata), .s_axi_rresp(rresp), .s_axi_rvalid(rvalid), .s_axi_rready(rready),
        .ff_rst_b(rst_b), .ff_sel_b(sel_b), .ff_prsnt_b(prsnt_b), .ff_intr_b(intr_b),
        .ff6_rst_b(ff6_rst_b), .ff6_sel_b(ff6_sel_b), .ff6_prsnt_b(ff6_prsnt_b), .ff6_intr_b(ff6_intr_b),
        .ioexp_rst_b(ioexp_rst_b), .ioexp_intr_b(ioexp_intr_b), .i2c_mux_rst_b(mux_rst_b));

    int errors = 0;
    task automatic check(input bit cond, input string msg);
        if (!cond) begin errors++; $display("FAIL: %s", msg); end
    endtask

    // Simple AXI-Lite master: one write or read at a time
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

    logic [31:0] d;
    initial begin
        #1;
        // Levels before and after reset, ID and reset value of FF_CTRL
        check(rst_b == 4'hF && sel_b == 4'h0, "FireFly lines before reset: running, selected");
        check(ff6_rst_b == 1 && ff6_sel_b == 0 && ioexp_rst_b == 2'b11, "fixed lines");
        check(mux_rst_b == 0, "I2C switch held in reset right after configuration");
        repeat (20) @(posedge aclk);
        aresetn <= 1;
        check(rst_b == 4'hF && sel_b == 4'h0, "FireFly lines after reset");
        axi_read(16'h00, d);  check(d == 32'h4252494F, $sformatf("ID %h", d));
        axi_read(16'h04, d);  check(d == 32'h00F, $sformatf("FF_CTRL reset value %h", d));
        repeat (5) @(posedge aclk);
        axi_read(16'h08, d);
        check(d == {6'd0, 2'b10, 6'd0, 1'b0, 1'b1, 4'd0, 4'b0010, 4'd0, 4'b0101}, $sformatf("FF_STATUS %h", d));
        // FF_CTRL write reaches the lines; the fixed lines and FF_STATUS are not writable
        axi_write(16'h04, 32'h0000_0A06);
        repeat (2) @(posedge aclk);
        check(rst_b == 4'h6 && sel_b == 4'hA, $sformatf("after write: rst_b %h sel_b %h", rst_b, sel_b));
        axi_read(16'h04, d);  check(d == 32'hA06, $sformatf("FF_CTRL %h", d));
        check(ff6_rst_b == 1 && ff6_sel_b == 0 && ioexp_rst_b == 2'b11, "fixed lines unchanged by writes");
        axi_write(16'h08, 32'hFFFF_FFFF);
        axi_read(16'h04, d);  check(d == 32'hA06, "a write to FF_STATUS changes nothing");
        // Start-up pulse: one, MUX_RST_CYCLES long, then the line stays high
        repeat (100) @(posedge aclk);
        check(mux_rst_b == 1 && mux_pulses == 1 && mux_low >= 64 && mux_low <= 66,
              $sformatf("start-up pulse: %0d pulse(s), %0d cycles low", mux_pulses, mux_low));
        axi_read(16'h0C, d);  check(d == 32'h0, $sformatf("I2C_MUX idle %h", d));
        // Host request: a write of 0 does nothing, a write of 1 gives one more pulse of the same length
        axi_write(16'h0C, 32'h0);
        repeat (5) @(posedge aclk);
        check(mux_rst_b == 1 && mux_pulses == 1, "I2C_MUX write of 0 does not reset the switch");
        mux_low = 0;
        axi_write(16'h0C, 32'h1);
        axi_read(16'h0C, d);  check(d == 32'h1, $sformatf("I2C_MUX reads 1 during the pulse (%h)", d));
        check(rst_b == 4'h6 && sel_b == 4'hA, "FireFly lines unchanged by I2C_MUX");
        repeat (100) @(posedge aclk);
        check(mux_rst_b == 1 && mux_pulses == 2 && mux_low >= 64 && mux_low <= 66,
              $sformatf("requested pulse: %0d pulses, %0d cycles low", mux_pulses, mux_low));
        aresetn <= 0;
        repeat (3) @(posedge aclk);
        check(rst_b == 4'hF && sel_b == 4'h0, "reset restores the FELIX levels");
        aresetn <= 1;
        repeat (100) @(posedge aclk);
        check(mux_rst_b == 1 && mux_pulses == 2, "a register-block reset does not reset the switch");

        if (errors == 0) $display("TB_RESULT: PASS");
        else             $display("TB_RESULT: FAIL (%0d errors)", errors);
        $finish;
    end

    initial begin
        #1ms;
        $display("TB_RESULT: FAIL (timeout)");
        $finish;
    end

endmodule
