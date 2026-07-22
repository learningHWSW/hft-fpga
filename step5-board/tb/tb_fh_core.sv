// End-to-end TB for fh_core: MoldUDP64 payload beats (512-bit) -> BBO.
//
// This is the first test of the WHOLE chain at CMAC width — step 3b stopped at
// the decoder and step 4b ran the book at 64-bit. Drives a .mold file as
// 512-bit beats (one packet = ceil(len/64) beats, last beat partial) and logs
// the BBO stream in the same canonical format as step 4b, so the Makefile can
// diff it against scripts/dump_bbo.py over the equivalent .itch.
//
// The core input has no backpressure (an internal elastic FIFO absorbs and
// counts drops), so the injection rate is a knob: +gap=<n> idle cycles between
// packets. gap=0 is a full-line-rate stress run that shows where the
// correctness-first FSMs (order table 2 cy/msg, ladder 3 cy/record) become the
// bottleneck; a realistic gap reproduces market pacing with zero drops.
//
// +mold=<path>, +loc=<n>, +base=<n>, +gap=<n>.
`timescale 1ns/1ps

module tb_fh_core;
  import itch5_pkg::*;

  localparam int DATA_W = 512;
  localparam int KEEP_W = DATA_W/8;

  logic clk = 1'b0;
  logic rst_n = 1'b0;
  always #1.552 clk = ~clk;   // 322.265625 MHz CMAC datapath clock

  logic [DATA_W-1:0] tdata;
  logic [KEEP_W-1:0] tkeep;
  logic tvalid, tlast;

  logic [15:0] track_locate = 16'd1;
  logic [31:0] cfg_base     = 32'd1500000;
  int          gap          = 24;

  logic        init_done;
  logic        bbo_valid, bbo_has_bid, bbo_has_ask;
  logic [47:0] bbo_ts;
  logic [31:0] bbo_bid_price, bbo_bid_qty, bbo_ask_price, bbo_ask_qty;
  logic        ev_gap, ev_hb, ev_eos;
  logic [63:0] ev_seq, ev_expected;
  logic [31:0] st_gap_total, st_dup_cnt, st_frame_err, st_ot_overflow, st_ot_miss,
               st_pl_oob, st_beat_drop, st_msg_drop, st_delta_drop;
  logic [9:0]  st_beat_lvl, st_msg_lvl, st_delta_lvl;

  fh_core #(.DATA_W(DATA_W)) dut (
    .init_done(init_done),
    .clk(clk), .rst_n(rst_n),
    .track_locate(track_locate), .cfg_base(cfg_base),
    .s_tdata(tdata), .s_tkeep(tkeep), .s_tvalid(tvalid), .s_tlast(tlast),
    .bbo_valid(bbo_valid), .bbo_ts(bbo_ts),
    .bbo_has_bid(bbo_has_bid), .bbo_bid_price(bbo_bid_price), .bbo_bid_qty(bbo_bid_qty),
    .bbo_has_ask(bbo_has_ask), .bbo_ask_price(bbo_ask_price), .bbo_ask_qty(bbo_ask_qty),
    .ev_gap(ev_gap), .ev_hb(ev_hb), .ev_eos(ev_eos),
    .ev_seq(ev_seq), .ev_expected(ev_expected),
    .st_gap_total(st_gap_total), .st_dup_cnt(st_dup_cnt), .st_frame_err(st_frame_err),
    .st_ot_overflow(st_ot_overflow), .st_ot_miss(st_ot_miss), .st_pl_oob(st_pl_oob),
    .st_beat_drop(st_beat_drop), .st_msg_drop(st_msg_drop), .st_delta_drop(st_delta_drop),
    .st_beat_level_max(st_beat_lvl), .st_msg_level_max(st_msg_lvl),
    .st_delta_level_max(st_delta_lvl)
  );

  // ---------------- monitor ----------------
  int fd_log, n_bbo = 0;
  initial fd_log = $fopen("bbo_rtl.log", "w");

  always @(posedge clk) if (rst_n && bbo_valid) begin
    n_bbo++;
    $fdisplay(fd_log, "%0d bid=%0d:%0d ask=%0d:%0d",
              bbo_ts, bbo_bid_price, bbo_bid_qty, bbo_ask_price, bbo_ask_qty);
  end

  // ---------------- driver: one packet -> ceil(len/64) beats ----------------
  byte unsigned payload[];

  task automatic send_packet(input int n);
    int i, k;
    i = 0;
    while (i < n) begin
      k = (n - i > KEEP_W) ? KEEP_W : (n - i);
      @(negedge clk);
      tdata = '0; tkeep = '0;
      for (int j = 0; j < k; j++) begin
        tdata[8*j +: 8] = payload[i+j];
        tkeep[j] = 1'b1;
      end
      tvalid = 1'b1;
      tlast  = (i + k == n);
      i += k;
    end
    @(negedge clk);
    tvalid = 1'b0; tlast = 1'b0; tkeep = '0;
  endtask

  initial begin
    string fname;
    int fd, c1, c2, len, loc;

    fname = "../step1-sw-parser/test.mold";
    void'($value$plusargs("mold=%s", fname));
    if ($value$plusargs("loc=%d", loc)) track_locate = loc[15:0];
    void'($value$plusargs("base=%d", cfg_base));
    void'($value$plusargs("gap=%d", gap));

    fd = $fopen(fname, "rb");
    if (fd == 0) begin $display("FATAL: cannot open %s", fname); $finish; end

    tvalid = 1'b0; tlast = 1'b0; tkeep = '0; tdata = '0;
    repeat (5) @(negedge clk);
    rst_n = 1'b1;
    // URAM has no init: the table clears itself and holds s_ready low.
    // The market-data path ignores s_ready by design, so nothing may be
    // injected until the sweep finishes.
    wait (init_done);
    repeat (2) @(negedge clk);

    forever begin
      c1 = $fgetc(fd);
      if (c1 == -1) break;
      c2 = $fgetc(fd);
      len = (c1 << 8) | c2;
      if (len == 0 || len > 4000) begin $display("FATAL: bad packet length %0d", len); break; end
      payload = new[len];
      for (int x = 0; x < len; x++) payload[x] = byte'($fgetc(fd));
      send_packet(len);
      repeat (gap) @(negedge clk);
    end
    $fclose(fd);

    repeat (200) @(posedge clk);
    $fclose(fd_log);
    $display("TB done: %0d BBO updates (gap=%0d)", n_bbo, gap);
    $display("  splitter : gap_total=%0d dup=%0d frame_err=%0d",
             st_gap_total, st_dup_cnt, st_frame_err);
    $display("  table    : overflow=%0d miss=%0d", st_ot_overflow, st_ot_miss);
    $display("  ladder   : oob=%0d", st_pl_oob);
    $display("  drops    : beat=%0d msg=%0d delta=%0d",
             st_beat_drop, st_msg_drop, st_delta_drop);
    $display("  fifo hwm : beat=%0d msg=%0d delta=%0d",
             st_beat_lvl, st_msg_lvl, st_delta_lvl);
    if (st_beat_drop || st_msg_drop || st_delta_drop || st_ot_overflow)
      $display("NOTE: drops occurred — injection outran the correctness-first FSMs");
    $finish;
  end

endmodule
