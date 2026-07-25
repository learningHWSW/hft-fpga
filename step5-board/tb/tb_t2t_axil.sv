// Wrapper smoke test for t2t_axil across its three asynchronous clocks.
//
// It exercises the glue that only exists in the wrapper, end to end: an
// AXI-Lite config write on axil_clk sets the multicast group and source
// address; a CTRL commit crosses cfg_cdc into the core (load_core), which arms
// igmp_join and pulses its join; the report crosses the IGMP cdc_fifo into the
// CMAC domain and the arbiter puts it on tx. Catching that exact frame on
// tx_tdata proves cfg_cdc + load_core + igmp_join + cdc_fifo + axis_tx_arb are
// wired correctly. The frame is diffed byte-for-byte against gen_igmp.py's
// golden (igmp_gold.mem). Finally it reads the ID register back through AXI to
// confirm the read path and status resync clock survive.
//
// No RX feed is driven, so the order path is idle and the arbiter grants the
// report; this is about the control/CDC wiring, not the datapath (verified in
// tb_t2t).
`timescale 1ns/1ps
module tb_t2t_axil;
  localparam int DATA_W = 512;
  localparam int AW     = 12;
  localparam int FRAME_B = 60;

  logic cmac_clk = 0, core_clk = 0, axil_clk = 0;
  logic cmac_rst_n = 0, core_rst_n = 0, axil_rst_n = 0;
  always #1.55 cmac_clk = ~cmac_clk;   // 322 MHz
  always #2.30 core_clk = ~core_clk;   // ~217 MHz
  always #2.00 axil_clk = ~axil_clk;   // 250 MHz

  // CMAC RX idle; TX always ready
  logic [DATA_W-1:0]   rx_d = 0, tx_d;
  logic [DATA_W/8-1:0] rx_k = 0, tx_k;
  logic rx_v = 0, rx_l = 0, tx_v, tx_l, tx_r = 1;

  // AXI-Lite
  logic [AW-1:0] awaddr, araddr;
  logic awvalid, awready, wvalid, wready, bvalid, bready;
  logic arvalid, arready, rvalid, rready;
  logic [31:0] wdata, rdata;
  logic [3:0]  wstrb;
  logic [1:0]  bresp, rresp;

  t2t_axil #(.DATA_W(DATA_W), .AXIL_AW(AW), .IGMP_INTERVAL(32'd1000)) dut (
    .cmac_clk(cmac_clk), .cmac_rst_n(cmac_rst_n),
    .rx_tdata(rx_d), .rx_tkeep(rx_k), .rx_tvalid(rx_v), .rx_tlast(rx_l),
    .tx_tdata(tx_d), .tx_tkeep(tx_k), .tx_tvalid(tx_v), .tx_tlast(tx_l), .tx_tready(tx_r),
    .core_clk(core_clk), .core_rst_n(core_rst_n),
    .axil_clk(axil_clk), .axil_rst_n(axil_rst_n),
    .s_axil_awaddr(awaddr), .s_axil_awvalid(awvalid), .s_axil_awready(awready),
    .s_axil_wdata(wdata), .s_axil_wstrb(wstrb), .s_axil_wvalid(wvalid), .s_axil_wready(wready),
    .s_axil_bresp(bresp), .s_axil_bvalid(bvalid), .s_axil_bready(bready),
    .s_axil_araddr(araddr), .s_axil_arvalid(arvalid), .s_axil_arready(arready),
    .s_axil_rdata(rdata), .s_axil_rresp(rresp), .s_axil_rvalid(rvalid), .s_axil_rready(rready)
  );

  // ---- capture the first TX frame's first beat ----
  logic [DATA_W-1:0] tx_first;
  logic got_tx = 0;
  always @(posedge cmac_clk) if (cmac_rst_n && tx_v && tx_r && !got_tx) begin
    tx_first <= tx_d;
    got_tx   <= 1'b1;
  end

  logic [7:0] gold [FRAME_B];
  int errs = 0;

  // ---- AXI master ----
  task automatic axi_write(input [AW-1:0] a, input [31:0] d);
    @(negedge axil_clk); awaddr=a; wdata=d; wstrb=4'hF; awvalid=1; wvalid=1; bready=1;
    do @(posedge axil_clk); while (!(awready && wready));
    @(negedge axil_clk); awvalid=0; wvalid=0;
    do @(posedge axil_clk); while (!bvalid);
    @(negedge axil_clk); bready=0;
  endtask
  task automatic axi_read(input [AW-1:0] a, output [31:0] d);
    @(negedge axil_clk); araddr=a; arvalid=1; rready=1;
    do @(posedge axil_clk); while (!arready);
    @(negedge axil_clk); arvalid=0;
    do @(posedge axil_clk); while (!rvalid);
    d = rdata;
    @(negedge axil_clk); rready=0;
  endtask

  logic [31:0] rb;
  int g;

  initial begin
    $readmemh("igmp_gold.mem", gold);
    awvalid=0; wvalid=0; bready=0; arvalid=0; rready=0;
    repeat (5) @(negedge axil_clk); axil_rst_n = 1;
    repeat (5) @(negedge core_clk); core_rst_n = 1;
    repeat (5) @(negedge cmac_clk); cmac_rst_n = 1;
    repeat (5) @(negedge axil_clk);

    // configure group 233.54.12.1, src_mac 00:11:22:33:44:55, src_ip 10.0.0.2
    axi_write('h00, 32'hE9360C01);          // cfg_group_ip
    axi_write('h74, 32'h22334455);          // cfg_src_mac lo
    axi_write('h78, 32'h00000011);          // cfg_src_mac hi (00:11 high bytes)
    axi_write('h7C, 32'h0A000002);          // cfg_src_ip
    axi_write('h9C, 32'h00000001);          // CTRL: commit (bit0 = load)

    // wait for the report to cross all the way to tx
    g = 0;
    while (!got_tx && g < 20000) begin @(posedge cmac_clk); g++; end
    if (!got_tx) begin $display("FAIL: no TX frame after commit"); errs++; end
    else begin
      for (int k = 0; k < FRAME_B; k++)
        if (tx_first[8*k +: 8] !== gold[k]) begin
          errs++;
          if (errs <= 8) $display("FAIL: tx byte %0d got %02h exp %02h",
                                  k, tx_first[8*k +: 8], gold[k]);
        end
    end

    // read the ID register back through AXI (read path + status clock alive)
    axi_read('h1FC, rb);
    if (rb !== 32'h5432_5430) begin $display("FAIL: ID read %h", rb); errs++; end

    if (errs == 0)
      $display("PASS: t2t_axil AXI config -> IGMP report on tx (byte-exact), ID read ok");
    else
      $display("FAIL: %0d error(s)", errs);
    $finish;
  end

  initial begin repeat (400000) @(posedge cmac_clk); $display("FAIL: timeout"); $finish; end
endmodule
