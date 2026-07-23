// End-to-end TB for the whole tick-to-trade chain: Ethernet frames in on the
// CMAC clock, order frames out on the CMAC clock.
//
// This exists because t2t_top is the one module in the project whose wiring
// had never been executed — synthesis will happily build a design where two
// correct blocks are connected wrongly. Running the same real replay through
// it and diffing the emitted TCP frames against step 6's golden proves the
// integration, not just the parts.
//
// TWO CLOCKS, deliberately incommensurate (3.103 ns and 4.618 ns) and
// phase-offset, so the CDC crossings are exercised the way they will be on the
// card rather than in lockstep.
//
// LATENCY, and what can honestly be measured here. The first attempt stamped
// the cycle of the most recent frame-end and subtracted it when an order frame
// appeared. That is wrong: frames keep arriving while an order is in flight, so
// the stamp gets overwritten by a LATER frame than the one that caused the
// order, and the result is a meaningless lower bound (it reported min=1).
// Attributing an order to its causing frame needs a tag through the pipeline,
// which the DUT does not carry.
//
// What IS attributable is the decision-to-wire half: between the BBO that fires
// an order and that order's frame leaving tcp_tx, nothing else can intervene,
// because only one order is ever in flight through the builder and framer. So
// that is what gets measured, in core-clock cycles, and the front half
// (wire -> BBO) is left unmeasured rather than guessed at.
//
// Cycles are exact in simulation; nanoseconds on silicon are not. Neither
// number should ever be quoted as a measured hardware latency.
//
// THE IN-FLIGHT LIMITER IS DISABLED HERE (cfg_max_inflight = 0xFFFF) because
// acknowledgements come from host software that does not exist yet, so nothing
// can drive cfg_order_ack and the counter would saturate after four orders and
// stop trading for the rest of the replay. The limiter is verified in step 6's
// testbench instead, where acks can be scheduled exactly. What this TB is for
// is the wiring and the clock crossings, and disabling one gate makes the run
// exercise MORE of the chain, not less. The golden is generated with the same
// setting.
//
// +eth=<path> stimulus, +frm=<path> emitted frames, +gap=<n> idle beats.
`timescale 1ns/1ps
module tb_t2t;
  localparam int DATA_W = 512;
  localparam int KEEP_W = DATA_W / 8;

  logic cmac_clk = 0, core_clk = 0;
  logic cmac_rst_n = 0, core_rst_n = 0;
  initial forever #1.5515 cmac_clk = ~cmac_clk;             // 322.265625 MHz
  initial begin #0.7; forever #2.309 core_clk = ~core_clk; end  // 216.5 MHz

  logic [DATA_W-1:0] rx_tdata = '0;
  logic [KEEP_W-1:0] rx_tkeep = '0;
  logic              rx_tvalid = 0, rx_tlast = 0;

  logic [DATA_W-1:0] tx_tdata;
  logic [KEEP_W-1:0] tx_tkeep;
  logic              tx_tvalid, tx_tlast;
  logic              tx_tready = 1;

  logic [15:0] track_locate = 16'd13;
  logic [31:0] cfg_base     = 32'd2800000;
  int          gap          = 24;
  logic        cfg_load     = 0;

  logic        st_init_done;
  logic [31:0] st_rx_drop, st_rx_hwm, st_frames_in, st_frames_kept;
  logic [31:0] st_gap_total, st_ot_overflow, st_pl_oob;
  logic [31:0] st_beat_drop, st_msg_drop, st_delta_drop;
  logic [31:0] st_sent, st_blk_pos, st_blk_inflight, st_blk_txfull;
  logic signed [31:0] st_position;
  logic [31:0] st_seq_num, st_frame_cnt, st_tx_drop;

  t2t_top #(.DATA_W(DATA_W)) dut (
    .cmac_clk(cmac_clk), .cmac_rst_n(cmac_rst_n),
    .rx_tdata(rx_tdata), .rx_tkeep(rx_tkeep), .rx_tvalid(rx_tvalid), .rx_tlast(rx_tlast),
    .tx_tdata(tx_tdata), .tx_tkeep(tx_tkeep), .tx_tvalid(tx_tvalid), .tx_tlast(tx_tlast),
    .tx_tready(tx_tready),
    .core_clk(core_clk), .core_rst_n(core_rst_n),

    .cfg_group_ip(32'hE9360C01), .cfg_udp_port(16'd26477),   // 233.54.12.1
    .cfg_track_locate(track_locate), .cfg_band_base(cfg_base),

    .cfg_enable(1'b1),
    .cfg_max_spread(32'd2000), .cfg_ratio_shift(4'd1),
    .cfg_min_qty(32'd100), .cfg_order_qty(32'd100),
    .cfg_pos_limit(32'd1000), .cfg_max_inflight(16'hFFFF),
    .cfg_order_ack(1'b0),   // no ack source: see the note below
    // sweep disabled here so this TB keeps checking exactly the imbalance path
    // against the existing golden; the sweep->order path is verified bit-exact
    // in step6's tb_strategy (test-combined).
    .cfg_sweep_en(1'b0), .cfg_sweep_min_levels(32'd3), .cfg_sweep_gap(48'd1000000),

    .cfg_token_prefix({"1","0","A","G","P","F"}),
    .cfg_stock({" "," "," "," ","L","P","A","A"}),
    .cfg_firm({"1","T","F","H"}),
    .cfg_tif(32'd0), .cfg_ouch_min_qty(32'd0),
    .cfg_display("Y"), .cfg_capacity("P"), .cfg_sweep("N"),
    .cfg_cross("N"), .cfg_cust("N"),

    .cfg_dst_mac(48'hAABBCCDDEEFF), .cfg_src_mac(48'h001122334455),
    .cfg_src_ip(32'h0A000002), .cfg_dst_ip(32'h0A000009),
    .cfg_src_port(16'd40001), .cfg_dst_port(16'd4001),
    .cfg_init_seq(32'h10000000), .cfg_ack_num(32'h20000000),
    .cfg_window(16'd65535), .cfg_init_id(16'h1000), .cfg_load(cfg_load),

    .st_init_done(st_init_done),
    .st_rx_drop(st_rx_drop), .st_rx_hwm(st_rx_hwm),
    .st_frames_in(st_frames_in), .st_frames_kept(st_frames_kept),
    .st_gap_total(st_gap_total), .st_ot_overflow(st_ot_overflow), .st_pl_oob(st_pl_oob),
    .st_beat_drop(st_beat_drop), .st_msg_drop(st_msg_drop), .st_delta_drop(st_delta_drop),
    .st_sent(st_sent), .st_blk_pos(st_blk_pos),
    .st_blk_inflight(st_blk_inflight), .st_blk_txfull(st_blk_txfull),
    .st_position(st_position), .st_seq_num(st_seq_num),
    .st_frame_cnt(st_frame_cnt), .st_tx_drop(st_tx_drop)
  );

  // ---------------- latency instrumentation ----------------
  // Decision-to-wire only, in core-clock cycles: the BBO that fires an order,
  // through strategy -> ouch_builder -> tcp_tx, to that order's first framed
  // beat. Attributable because only one order is in flight through that path.
  longint unsigned core_cyc = 0;
  longint unsigned bbo_cyc = 0;
  bit              pending = 0;
  longint unsigned lat_min = 64'hFFFF_FFFF, lat_max = 0, lat_sum = 0;
  int              lat_n = 0;

  always @(posedge core_clk) begin
    core_cyc <= core_cyc + 1;
    if (core_rst_n) begin
      // the BBO that produced an order: strategy asserts o_valid two cycles
      // later, so remember every BBO and keep the one that actually fired
      if (dut.bbo_valid) bbo_cyc <= core_cyc;
      if (dut.ord_valid) pending <= 1'b1;
      if (pending && dut.frm_tvalid) begin
        automatic longint unsigned d = core_cyc - bbo_cyc;
        if (d < lat_min) lat_min = d;
        if (d > lat_max) lat_max = d;
        lat_sum += d;
        lat_n++;
        pending <= 1'b0;
      end
    end
  end

  longint unsigned cmac_cyc = 0;
  always @(posedge cmac_clk) cmac_cyc <= cmac_cyc + 1;

  // ---------------- frame capture ----------------
  int               ffrm, n_frames = 0;
  logic [8*106-1:0] acc;
  int               acc_b = 0;

  always @(posedge cmac_clk) begin
    if (cmac_rst_n && tx_tvalid && tx_tready) begin
      automatic int nb = 0;
      for (int i = 0; i < KEEP_W; i++) if (tx_tkeep[i]) nb++;
      for (int i = 0; i < nb; i++) acc[8*(acc_b + i) +: 8] = tx_tdata[8*i +: 8];
      acc_b += nb;
      if (tx_tlast) begin
        for (int i = 0; i < acc_b; i++) $fwrite(ffrm, "%02x", acc[8*i +: 8]);
        $fwrite(ffrm, "\n");
        acc_b = 0;
        n_frames++;
      end
    end
  end

  // ---------------- driver ----------------
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
      rx_tvalid = 1'b1;
      rx_tlast  = (i + k == n);
      i += k;
    end
    @(negedge cmac_clk);
    rx_tvalid = 1'b0; rx_tlast = 1'b0; rx_tkeep = '0;
  endtask

  initial begin
    string fname, frmname;
    int fd, c1, c2, len, loc;

    fname = "real.eth";
    void'($value$plusargs("eth=%s", fname));
    frmname = "t2t_rtl.log";
    void'($value$plusargs("frm=%s", frmname));
    if ($value$plusargs("loc=%d", loc)) track_locate = loc[15:0];
    void'($value$plusargs("base=%d", cfg_base));
    void'($value$plusargs("gap=%d", gap));

    fd   = $fopen(fname, "rb");
    ffrm = $fopen(frmname, "w");
    if (fd == 0) begin $display("FATAL: cannot open %s", fname); $finish; end

    repeat (5) @(negedge cmac_clk);
    cmac_rst_n = 1'b1; core_rst_n = 1'b1;
    repeat (5) @(negedge core_clk);
    cfg_load = 1'b1;                    // software hands over the connection
    repeat (2) @(negedge core_clk);
    cfg_load = 1'b0;
    // UltraRAM has no init, so the order table clears itself after reset. The
    // feed must not be enabled before that finishes.
    wait (st_init_done);
    repeat (2) @(negedge cmac_clk);

    forever begin
      c1 = $fgetc(fd);
      if (c1 == -1) break;
      c2 = $fgetc(fd);
      len = (c1 << 8) | c2;
      if (len == 0 || len > 4000) begin $display("FATAL: bad frame length %0d", len); break; end
      payload = new[len];
      for (int x = 0; x < len; x++) payload[x] = byte'($fgetc(fd));
      send_frame(len);
      repeat (gap) @(negedge cmac_clk);
    end
    $fclose(fd);

    repeat (500) @(posedge cmac_clk);
    $fclose(ffrm);

    $display("TB done: %0d order frames out", n_frames);
    $display("  rx    : in=%0d kept=%0d cdc_drop=%0d cdc_hwm=%0d",
             st_frames_in, st_frames_kept, st_rx_drop, st_rx_hwm);
    $display("  feed  : gap=%0d ot_overflow=%0d oob=%0d drops(beat=%0d msg=%0d delta=%0d)",
             st_gap_total, st_ot_overflow, st_pl_oob,
             st_beat_drop, st_msg_drop, st_delta_drop);
    $display("  strat : sent=%0d pos=%0d blocked(pos=%0d inflight=%0d txfull=%0d)",
             st_sent, st_position, st_blk_pos, st_blk_inflight, st_blk_txfull);
    $display("  tx    : frames=%0d next_seq=%08x cdc_drop=%0d",
             st_frame_cnt, st_seq_num, st_tx_drop);
    if (lat_n > 0)
      $display("  latency (core cyc, BBO -> framed order): min=%0d avg=%0d max=%0d",
               lat_min, lat_sum / lat_n, lat_max);
    if (st_rx_drop != 0) $display("FAIL: RX CDC dropped %0d beats", st_rx_drop);
    if (st_tx_drop != 0) $display("FAIL: TX CDC dropped %0d beats", st_tx_drop);
    if (n_frames != st_frame_cnt) $display("FAIL: captured %0d frames, engine built %0d",
                                           n_frames, st_frame_cnt);
    $finish;
  end

endmodule
