// Full-datapath TB for t2t_axil: the whole chain exercised THROUGH the wrapper.
//
// tb_t2t proves t2t_top with config on direct ports. This proves the same real
// replay when configuration arrives over AXI-Lite and crosses cfg_cdc into the
// core -- i.e. that the control plane actually drives the datapath -- and that
// order frames and IGMP reports share the one CMAC TX through axis_tx_arb
// without corrupting each other. Three asynchronous clocks (cmac/core/axil).
//
// The TX now carries two frame kinds, so capture splits them by IP protocol:
//   proto 6  (TCP)  -> order frame  -> logged, diffed against step 6's golden
//   proto 2  (IGMP) -> membership report -> counted
// With IGMP enabled, the join fires reports during the run; injecting a query
// mid-replay must produce at least one more, which proves the RX query detector
// path end to end (rx -> igmp_query_detect -> igmp_join -> cdc -> arbiter -> tx).
//
// +eth=<path> stimulus, +frm=<path> order frames out.
`timescale 1ns/1ps
module tb_t2t_axil_full;
  localparam int DATA_W = 512;
  localparam int KEEP_W = DATA_W / 8;
  localparam int AW     = 12;
  localparam logic [31:0] GROUP = 32'hE9360C01;   // 233.54.12.1

  logic cmac_clk = 0, core_clk = 0, axil_clk = 0;
  logic cmac_rst_n = 0, core_rst_n = 0, axil_rst_n = 0;
  initial forever #1.5515 cmac_clk = ~cmac_clk;               // 322.27 MHz
  initial begin #0.7;  forever #2.309 core_clk = ~core_clk; end   // 216.5 MHz
  initial begin #0.3;  forever #2.000 axil_clk = ~axil_clk; end   // 250 MHz

  logic [DATA_W-1:0] rx_tdata = '0;
  logic [KEEP_W-1:0] rx_tkeep = '0;
  logic              rx_tvalid = 0, rx_tlast = 0;
  logic [DATA_W-1:0] tx_tdata;
  logic [KEEP_W-1:0] tx_tkeep;
  logic              tx_tvalid, tx_tlast, tx_tready = 1;

  // AXI-Lite
  logic [AW-1:0] awaddr, araddr;
  logic awvalid, awready, wvalid, wready, bvalid, bready;
  logic arvalid, arready, rvalid, rready;
  logic [31:0] wdata, rdata;
  logic [3:0]  wstrb;
  logic [1:0]  bresp, rresp;

  t2t_axil #(.DATA_W(DATA_W), .AXIL_AW(AW)) dut (
    .cmac_clk(cmac_clk), .cmac_rst_n(cmac_rst_n),
    .rx_tdata(rx_tdata), .rx_tkeep(rx_tkeep), .rx_tvalid(rx_tvalid), .rx_tlast(rx_tlast),
    .tx_tdata(tx_tdata), .tx_tkeep(tx_tkeep), .tx_tvalid(tx_tvalid), .tx_tlast(tx_tlast), .tx_tready(tx_tready),
    .core_clk(core_clk), .core_rst_n(core_rst_n),
    .axil_clk(axil_clk), .axil_rst_n(axil_rst_n),
    .s_axil_awaddr(awaddr), .s_axil_awvalid(awvalid), .s_axil_awready(awready),
    .s_axil_wdata(wdata), .s_axil_wstrb(wstrb), .s_axil_wvalid(wvalid), .s_axil_wready(wready),
    .s_axil_bresp(bresp), .s_axil_bvalid(bvalid), .s_axil_bready(bready),
    .s_axil_araddr(araddr), .s_axil_arvalid(arvalid), .s_axil_arready(arready),
    .s_axil_rdata(rdata), .s_axil_rresp(rresp), .s_axil_rvalid(rvalid), .s_axil_rready(rready)
  );

  // ---------------- AXI master ----------------
  task automatic axi_write(input [AW-1:0] a, input [31:0] d);
    @(negedge axil_clk); awaddr=a; wdata=d; wstrb=4'hF; awvalid=1; wvalid=1; bready=1;
    do @(posedge axil_clk); while (!(awready && wready));
    @(negedge axil_clk); awvalid=0; wvalid=0;
    do @(posedge axil_clk); while (!bvalid);
    @(negedge axil_clk); bready=0;
  endtask

  // every cfg_* register at its word offset (regmap REG order), matching the
  // exact values tb_t2t drives so the golden is the same
  task automatic configure;
    axi_write('h00, GROUP);              // cfg_group_ip
    axi_write('h04, 32'h0000_676D);      // cfg_udp_port 26477
    axi_write('h08, 32'h0000_000D);      // cfg_track_locate 13
    axi_write('h0C, 32'd2800000);        // cfg_band_base
    axi_write('h10, 32'h0000_0001);      // cfg_enable
    axi_write('h14, 32'd2000);           // cfg_max_spread
    axi_write('h18, 32'h0000_0001);      // cfg_ratio_shift
    axi_write('h1C, 32'd100);            // cfg_min_qty
    axi_write('h20, 32'd100);            // cfg_order_qty
    axi_write('h24, 32'd1000);           // cfg_pos_limit
    axi_write('h28, 32'h0000_FFFF);      // cfg_max_inflight (limiter off)
    axi_write('h2C, 32'h0000_0000);      // cfg_sweep_en = 0 (imbalance path only)
    axi_write('h30, 32'h0000_0003);      // cfg_sweep_min_levels
    axi_write('h34, 32'd1000000);        // cfg_sweep_gap lo
    axi_write('h38, 32'h0000_0000);      // cfg_sweep_gap hi
    axi_write('h3C, 32'h4147_5046);      // cfg_token_prefix lo  "AGPF"
    axi_write('h40, 32'h0000_3130);      // cfg_token_prefix hi  "10"
    axi_write('h44, 32'h4C50_4141);      // cfg_stock lo  "LPAA"
    axi_write('h48, 32'h2020_2020);      // cfg_stock hi  "    "
    axi_write('h4C, 32'h3154_4648);      // cfg_firm  "1TFH"
    axi_write('h50, 32'h0000_0000);      // cfg_tif
    axi_write('h54, 32'h0000_0000);      // cfg_ouch_min_qty
    axi_write('h58, 32'h0000_0041);      // cfg_display "A" (0x41)
    axi_write('h5C, 32'h0000_0050);      // cfg_capacity "P"
    axi_write('h60, 32'h0000_004E);      // cfg_sweep "N"
    axi_write('h64, 32'h0000_004E);      // cfg_cross "N"
    axi_write('h68, 32'h0000_004E);      // cfg_cust "N"
    axi_write('h6C, 32'hCCDD_EEFF);      // cfg_dst_mac lo
    axi_write('h70, 32'h0000_AABB);      // cfg_dst_mac hi
    axi_write('h74, 32'h2233_4455);      // cfg_src_mac lo
    axi_write('h78, 32'h0000_0011);      // cfg_src_mac hi
    axi_write('h7C, 32'h0A00_0002);      // cfg_src_ip
    axi_write('h80, 32'h0A00_0009);      // cfg_dst_ip
    axi_write('h84, 32'h0000_9C41);      // cfg_src_port 40001
    axi_write('h88, 32'h0000_0FA1);      // cfg_dst_port 4001
    axi_write('h8C, 32'h1000_0000);      // cfg_init_seq
    axi_write('h90, 32'h2000_0000);      // cfg_ack_num
    axi_write('h94, 32'h0000_FFFF);      // cfg_window
    axi_write('h98, 32'h0000_1000);      // cfg_init_id
    axi_write('h9C, 32'h0000_0001);      // cfg_igmp_en
    axi_write('hA0, 32'h4000_0000);      // cfg_igmp_interval (huge: no periodic in-sim)
    axi_write('hA4, GROUP);              // cfg_group_ip_b (= A: single-feed replay)
    axi_write('hA8, 32'h0000_0001);      // CTRL: commit (load)
  endtask

  // ---------------- TX capture, split by protocol ----------------
  int ffrm, n_orders = 0, n_igmp = 0, n_arp = 0;
  logic [8*106-1:0] acc;
  int acc_b = 0;

  always @(posedge cmac_clk) begin
    if (cmac_rst_n && tx_tvalid && tx_tready) begin
      automatic int nb = 0;
      for (int i = 0; i < KEEP_W; i++) if (tx_tkeep[i]) nb++;
      for (int i = 0; i < nb; i++) acc[8*(acc_b + i) +: 8] = tx_tdata[8*i +: 8];
      acc_b += nb;
      if (tx_tlast) begin
        automatic logic [15:0] eth = {acc[8*12 +: 8], acc[8*13 +: 8]};
        if (eth == 16'h0806) begin                 // ethertype ARP -> reply
          n_arp++;
        end else if (acc[8*23 +: 8] == 8'd6) begin // IPv4 protocol 6 = TCP order
          for (int i = 0; i < acc_b; i++) $fwrite(ffrm, "%02x", acc[8*i +: 8]);
          $fwrite(ffrm, "\n");
          n_orders++;
        end else if (acc[8*23 +: 8] == 8'd2) begin // IPv4 protocol 2 = IGMP report
          n_igmp++;
        end
        acc_b = 0;
      end
    end
  end

  // ---------------- RX driver ----------------
  byte unsigned payload[];
  task automatic send_frame(input int n);
    int i, k;
    i = 0;
    while (i < n) begin
      k = (n - i > KEEP_W) ? KEEP_W : (n - i);
      @(negedge cmac_clk);
      rx_tdata = '0; rx_tkeep = '0;
      for (int j = 0; j < k; j++) begin
        rx_tdata[8*j +: 8] = payload[i+j];
        rx_tkeep[j] = 1'b1;
      end
      rx_tvalid = 1'b1; rx_tlast = (i + k == n);
      i += k;
    end
    @(negedge cmac_clk);
    rx_tvalid = 1'b0; rx_tlast = 1'b0; rx_tkeep = '0;
  endtask

  // build a Group-Specific IGMP query for GROUP (IHL5, proto 2, type 0x11)
  task automatic inject_query;
    payload = new[46];
    for (int i = 0; i < 46; i++) payload[i] = 8'h00;
    payload[0]=8'h01; payload[1]=8'h00; payload[2]=8'h5e;       // mcast dst mac
    payload[3]=8'h36; payload[4]=8'h0c; payload[5]=8'h01;
    payload[6]=8'haa; payload[7]=8'hbb; payload[8]=8'hcc;       // some router src
    payload[9]=8'hdd; payload[10]=8'hee; payload[11]=8'hff;
    payload[12]=8'h08; payload[13]=8'h00;                       // ethertype IPv4
    payload[14]=8'h45; payload[22]=8'h01; payload[23]=8'd2;     // ihl5, ttl1, IGMP
    payload[30]=GROUP[31:24]; payload[31]=GROUP[23:16];         // dst = group
    payload[32]=GROUP[15:8];  payload[33]=GROUP[7:0];
    payload[34]=8'h11;                                          // IGMP query
    payload[38]=GROUP[31:24]; payload[39]=GROUP[23:16];
    payload[40]=GROUP[15:8];  payload[41]=GROUP[7:0];
    send_frame(46);
  endtask

  // build an ARP who-has request for our IP (10.0.0.2, cfg_src_ip)
  task automatic inject_arp;
    payload = new[60];
    for (int i = 0; i < 60; i++) payload[i] = 8'h00;
    for (int i = 0; i < 6; i++) payload[i] = 8'hff;             // broadcast dst
    payload[6]=8'hde; payload[7]=8'had; payload[8]=8'hbe;       // requester mac
    payload[9]=8'hef; payload[10]=8'h00; payload[11]=8'h01;
    payload[12]=8'h08; payload[13]=8'h06;                       // ethertype ARP
    payload[14]=8'h00; payload[15]=8'h01; payload[16]=8'h08; payload[17]=8'h00;
    payload[18]=8'h06; payload[19]=8'h04; payload[20]=8'h00; payload[21]=8'h01; // request
    payload[22]=8'hde; payload[23]=8'had; payload[24]=8'hbe;    // sha = requester
    payload[25]=8'hef; payload[26]=8'h00; payload[27]=8'h01;
    payload[28]=8'h0a; payload[29]=8'h00; payload[30]=8'h00; payload[31]=8'h63; // spa 10.0.0.99
    payload[38]=8'h0a; payload[39]=8'h00; payload[40]=8'h00; payload[41]=8'h02; // tpa = our ip
    send_frame(60);
  endtask

  // ---------------- sequence ----------------
  int fd, c1, c2, len, n_igmp_pre, n_arp_pre;
  string fname, frmname;
  initial begin
    awvalid=0; wvalid=0; bready=0; arvalid=0; rready=0;
    fname = "real.eth"; void'($value$plusargs("eth=%s", fname));
    frmname = "t2t_rtl.log"; void'($value$plusargs("frm=%s", frmname));
    fd = $fopen(fname, "rb"); ffrm = $fopen(frmname, "w");
    if (fd == 0) begin $display("FATAL: cannot open %s", fname); $finish; end

    repeat (6) @(negedge axil_clk); axil_rst_n = 1;
    repeat (6) @(negedge core_clk); core_rst_n = 1;
    repeat (6) @(negedge cmac_clk); cmac_rst_n = 1;
    repeat (4) @(negedge axil_clk);

    configure();                          // all cfg over AXI, then commit
    wait (dut.u_t2t.st_init_done);        // URAM clear sweep done
    repeat (4) @(negedge cmac_clk);

    // replay the real feed
    forever begin
      c1 = $fgetc(fd); if (c1 == -1) break;
      c2 = $fgetc(fd); len = (c1 << 8) | c2;
      if (len == 0 || len > 4000) begin $display("FATAL: bad len %0d", len); break; end
      payload = new[len];
      for (int x = 0; x < len; x++) payload[x] = byte'($fgetc(fd));
      send_frame(len);
      repeat (48) @(negedge cmac_clk);
    end
    $fclose(fd);

    // RX-side IGMP query: must produce at least one more report
    repeat (40) @(negedge cmac_clk);
    n_igmp_pre = n_igmp;
    inject_query();
    repeat (200) @(posedge cmac_clk);

    // RX-side ARP who-has us: must produce a reply on the same TX
    n_arp_pre = n_arp;
    inject_arp();
    repeat (200) @(posedge cmac_clk);
    $fclose(ffrm);

    $display("TB done: %0d orders, %0d IGMP (%0d after query), %0d ARP (%0d after who-has)",
             n_orders, n_igmp, n_igmp - n_igmp_pre, n_arp, n_arp - n_arp_pre);
    if (n_orders == 0) $display("FAIL: no order frames out through the wrapper");
    if (n_igmp == 0)   $display("FAIL: no IGMP reports (join path dead)");
    if (n_igmp - n_igmp_pre < 1)
      $display("FAIL: RX query produced no report (detector path dead)");
    if (n_arp - n_arp_pre < 1)
      $display("FAIL: ARP who-has produced no reply (responder path dead)");
    $finish;
  end

  // safety net only: the replay terminates on EOF well before this; the full
  // real feed needs tens of millions of CMAC cycles
  initial begin repeat (500000000) @(posedge cmac_clk); $display("FAIL: timeout"); $finish; end
endmodule
