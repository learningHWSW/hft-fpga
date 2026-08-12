// The per-symbol config block, at NSYM = 2.
//
// tb_axil_regfile covers the map at NSYM = 1, where the block does not exist:
// symbol 0's locate, band base and stock come from the registers they have
// always come from, and the four-word-per-symbol block at 0x0C0 is unread.
// So the one thing a multi-symbol build actually depends on -- that writing
// 0x0C0 lands on symbol 1 and not on symbol 0, and that symbol 0 is unmoved by
// it -- has no coverage at all from that testbench.
//
// It is worth its own file because the failure is silent in the worst way. The
// per-symbol registers exist in the address map whatever NSYM the build has, so
// a host configuring a second symbol against a single-symbol bitstream writes
// them successfully and they are simply never read; and a slice error here
// would configure symbol 1's ladder with symbol 0's band, which produces a book
// that is empty rather than wrong. Neither shows up as a bus error.
//
// The checks are deliberately asymmetric about symbol 0: it must be readable
// through its ORIGINAL offsets and must NOT be reachable through the block,
// because that asymmetry is the compatibility promise -- offsets that shipped
// did not move.
`timescale 1ns/1ps
module tb_axil_regfile_msym;
  localparam int NSYM = 2;
  localparam int AW   = 12;

  logic aclk = 0, aresetn = 0;
  always #2.5 aclk = ~aclk;

  logic [AW-1:0] awaddr, araddr;
  logic          awvalid, wvalid, bready, arvalid, rready;
  logic [31:0]   wdata, rdata;
  logic [3:0]    wstrb = 4'hF;
  logic          awready, wready, bvalid, arready, rvalid;
  logic [1:0]    bresp, rresp;

  logic [NSYM*16-1:0] cfg_track_locate;
  logic [NSYM*32-1:0] cfg_band_base;
  logic [NSYM*64-1:0] cfg_stock;
  logic [NSYM*32-1:0] st_position;

  int fails = 0;
  task automatic check_eq(input string what, input logic [63:0] got,
                          input logic [63:0] exp);
    if (got !== exp) begin
      $display("FAIL: %s = %h, expected %h", what, got, exp);
      fails++;
    end else $display("  ok: %s = %h", what, got);
  endtask

  axil_regfile #(.NSYM(NSYM), .ADDR_W(AW)) dut (
    .aclk(aclk), .aresetn(aresetn),
    .s_axil_awaddr(awaddr), .s_axil_awvalid(awvalid), .s_axil_awready(awready),
    .s_axil_wdata(wdata), .s_axil_wstrb(wstrb), .s_axil_wvalid(wvalid),
    .s_axil_wready(wready),
    .s_axil_bresp(bresp), .s_axil_bvalid(bvalid), .s_axil_bready(bready),
    .s_axil_araddr(araddr), .s_axil_arvalid(arvalid), .s_axil_arready(arready),
    .s_axil_rdata(rdata), .s_axil_rresp(rresp), .s_axil_rvalid(rvalid),
    .s_axil_rready(rready),
    .cfg_track_locate(cfg_track_locate), .cfg_band_base(cfg_band_base),
    .cfg_stock(cfg_stock),
    .st_position_all(st_position),
    // everything else is exercised by tb_axil_regfile; tie it off
    .cfg_group_ip(), .cfg_udp_port(), .cfg_enable(), .cfg_max_spread(),
    .cfg_ratio_shift(), .cfg_min_qty(), .cfg_order_qty(), .cfg_pos_limit(),
    .cfg_max_inflight(), .cfg_sweep_en(), .cfg_sweep_min_levels(),
    .cfg_sweep_gap(), .cfg_token_prefix(), .cfg_firm(), .cfg_tif(),
    .cfg_ouch_min_qty(), .cfg_display(), .cfg_capacity(), .cfg_sweep(),
    .cfg_cross(), .cfg_cust(), .cfg_dst_mac(), .cfg_src_mac(), .cfg_src_ip(),
    .cfg_dst_ip(), .cfg_src_port(), .cfg_dst_port(), .cfg_init_seq(),
    .cfg_ack_num(), .cfg_window(), .cfg_init_id(), .cfg_igmp_en(),
    .cfg_igmp_interval(), .cfg_group_ip_b(),
    .cfg_load(), .cfg_order_ack(), .cfg_resend_req(), .cfg_resend_age(),
    .cfg_rto_en(), .cfg_rto_cycles(), .cfg_rto_retries(),
    .st_rx_drop('0), .st_rx_hwm('0), .st_init_done('0), .st_frames_in('0),
    .st_frames_kept('0), .st_gap_total('0), .st_ot_overflow('0), .st_pl_oob('0),
    .st_beat_drop('0), .st_msg_drop('0), .st_delta_drop('0), .st_sent('0),
    .st_blk_pos('0), .st_blk_inflight('0), .st_blk_txfull('0), .st_seq_num('0),
    .st_frame_cnt('0), .st_tx_drop('0), .st_bbo_early('0), .st_bbo_late('0),
    .st_bbo_mismatch('0), .st_rx_peer_ack('0), .st_rx_ooo('0), .st_rx_dup('0),
    .st_rx_sess_frames('0), .st_rto_fired('0), .st_rto_gaveup('0),
    .st_rb_stored('0), .st_rb_resent('0), .st_rb_drop('0), .st_blk_qty('0),
    .st_bbo_arb_drop('0)
  );

  task automatic axi_write(input logic [AW-1:0] a, input logic [31:0] d);
    @(negedge aclk); awaddr = a; wdata = d; awvalid = 1; wvalid = 1; bready = 1;
    wait (bvalid);
    @(negedge aclk); awvalid = 0; wvalid = 0;
    @(negedge aclk); bready = 0;
  endtask

  // `wait (rvalid)` alone is a race: rvalid can still be asserted from the
  // previous read when this one starts, and the task then captures a stale
  // rdata. Sample on the clock edge where the transfer actually completes.
  task automatic axi_read(input logic [AW-1:0] a, output logic [31:0] d);
    @(negedge aclk); araddr = a; arvalid = 1; rready = 1;
    do @(posedge aclk); while (!(rvalid && rready));
    d = rdata;
    @(negedge aclk); arvalid = 0; rready = 0;
    @(negedge aclk);
  endtask

  // regmap.py: SYM_BASE 0x0C0, four words per symbol, symbols 1..4
  localparam int SYM_BASE = 'h0C0, SYM_STRIDE = 16;

  logic [31:0] rb;
  initial begin
    awvalid = 0; wvalid = 0; bready = 0; arvalid = 0; rready = 0;
    repeat (4) @(negedge aclk);
    aresetn = 1;
    repeat (2) @(negedge aclk);

    // symbol 0 through its original offsets
    axi_write('h008, 32'd13);          // CFG_TRACK_LOCATE
    axi_write('h00C, 32'd2800000);     // CFG_BAND_BASE
    axi_write('h044, 32'h4C504141);    // CFG_STOCK_LO  "AAPL"
    axi_write('h048, 32'h20202020);    // CFG_STOCK_HI  "    "

    // symbol 1 through the per-symbol block
    axi_write(SYM_BASE + 0,  32'd6556);
    axi_write(SYM_BASE + 4,  32'd2100000);
    axi_write(SYM_BASE + 8,  32'h20515151);   // "QQQ " little end first
    axi_write(SYM_BASE + 12, 32'h20202020);
    repeat (2) @(negedge aclk);

    $display("TB: per-symbol config block at 0x%03h, stride %0d", SYM_BASE, SYM_STRIDE);
    check_eq("symbol 0 locate",  cfg_track_locate[15:0],   16'd13);
    check_eq("symbol 1 locate",  cfg_track_locate[31:16],  16'd6556);
    check_eq("symbol 0 base",    cfg_band_base[31:0],      32'd2800000);
    check_eq("symbol 1 base",    cfg_band_base[63:32],     32'd2100000);
    check_eq("symbol 0 stock",   cfg_stock[63:0],   64'h20202020_4C504141);
    check_eq("symbol 1 stock",   cfg_stock[127:64], 64'h20202020_20515151);

    // The compatibility promise, stated as a test: symbol 0 is NOT reachable
    // through the block. If it were, the block would have been laid out from
    // symbol 0 and four shipped offsets would have moved.
    axi_write(SYM_BASE + 0, 32'd999);
    repeat (2) @(negedge aclk);
    check_eq("symbol 0 locate unmoved by a block write", cfg_track_locate[15:0], 16'd13);
    check_eq("symbol 1 locate took the block write",     cfg_track_locate[31:16], 16'd999);

    // config words read back what was written, per-symbol block included
    axi_read(SYM_BASE + 4, rb);  check_eq("readback base 1", rb, 32'd2100000);
    axi_read('h00C, rb);         check_eq("readback base 0", rb, 32'd2800000);

    // per-symbol positions: symbol 0 at its shipped offset, 1 in the new block,
    // and symbols the build does not have read zero rather than aliasing
    st_position[31:0]  = 32'd800;          // symbol 0: +800
    st_position[63:32] = 32'hFFFFFF9C;     // symbol 1: -100
    repeat (2) @(negedge aclk);
    axi_read('h13C, rb); check_eq("st_position (symbol 0)",   rb, 32'd800);
    axi_read('h180, rb); check_eq("st_position_1",            rb, 32'hFFFFFF9C);
    axi_read('h184, rb); check_eq("st_position_2 (absent)",   rb, 32'd0);
    axi_read('h18C, rb); check_eq("st_position_4 (absent)",   rb, 32'd0);

    // The build geometry register: what the bitstream says it is.
    axi_read('h194, rb);
    check_eq("st_build_geom", rb, {8'd0, 8'd16, 8'd13, 8'd2});   // this build

    if (fails == 0) $display("PASS: per-symbol config block and positions, NSYM=2");
    else            $display("FAIL: %0d check(s) failed", fails);
    $finish;
  end
endmodule
