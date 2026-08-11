// Multi-symbol TB for fh_core: two tracked books through one chain.
//
// WHAT THIS HAS TO PROVE, and why it needs no new golden. With NSYM = 2 there
// is one order table, one delta stream and two price ladders, and the claim
// is that each symbol's BBO sequence is EXACTLY what a single-symbol build
// tracking that symbol alone would emit. The books are independent -- an AAPL
// order cannot appear on MSFT's ladder -- so that claim is checkable against
// the goldens that already exist: split the tagged output stream by bbo_sym
// and diff each half against dump_bbo.py for its own locate.
//
// That is a stronger test than a purpose-built two-symbol golden would be,
// because the reference is the SAME program that verifies the single-symbol
// build. A two-symbol golden written for this test could share a mistake with
// the RTL it was written beside; these two cannot, because one of them has
// been diffed against the single-symbol RTL since step 4b.
//
// WHAT IT DELIBERATELY DOES NOT CHECK is the interleaving of the two streams.
// bbo_arb preserves order per symbol and not across symbols (see its header),
// so a merged log would be a test of arbitration timing, not of the books.
// Splitting by tag is the check that matches the guarantee.
//
// THE STIMULUS IS THE GAP-FREE VARIANT. gen_itch.py's default MoldUDP64 plan
// drops a packet on purpose to exercise gap recovery, and the two messages in
// it are MSFT's cancel and delete -- fine when MSFT is untracked noise, fatal
// here, because the golden is generated from the .itch (every message) and the
// RTL would see a book missing two of its four events. --clean is the same
// messages with a contiguous sequence.
//
// +mold=<path>, +loc0/+loc1=<n>, +base0/+base1=<n>, +gap=<n>.
`timescale 1ns/1ps

module tb_fh_core_msym;
  import itch5_pkg::*;

  localparam int DATA_W = 512;
  localparam int KEEP_W = DATA_W/8;
  localparam int NSYM   = 2;
  localparam int SYMW   = $clog2(NSYM);

  logic clk = 1'b0;
  logic rst_n = 1'b0;
  always #1.552 clk = ~clk;   // 322.265625 MHz CMAC datapath clock

  logic [DATA_W-1:0] tdata;
  logic [KEEP_W-1:0] tkeep;
  logic tvalid, tlast;

  // AAPL is locate 1 around $150, MSFT is locate 2 around $430 -- the band base
  // is per symbol precisely because those do not overlap, and a shared base
  // would put one of the two entirely out of band.
  logic [NSYM*16-1:0] track_locate = {16'd2, 16'd1};
  logic [NSYM*32-1:0] cfg_base     = {32'd4300000, 32'd1500000};
  int                 gap          = 24;

  logic            init_done;
  logic            bbo_valid, bbo_has_bid, bbo_has_ask;
  logic [SYMW-1:0] bbo_sym;
  logic [47:0]     bbo_ts;
  logic [31:0]     bbo_bid_price, bbo_bid_qty, bbo_ask_price, bbo_ask_qty;
  logic            ev_gap, ev_hb, ev_eos;
  logic [63:0]     ev_seq, ev_expected;
  logic [31:0] st_gap_total, st_dup_cnt, st_frame_err, st_ot_overflow, st_ot_miss,
               st_pl_oob, st_beat_drop, st_msg_drop, st_delta_drop;
  logic [9:0]  st_beat_lvl, st_msg_lvl, st_delta_lvl;
  logic [31:0] st_bbo_early, st_bbo_late, st_bbo_mismatch, st_bbo_arb_drop;

  fh_core #(.DATA_W(DATA_W), .NSYM(NSYM)) dut (
    .init_done(init_done),
    .cfg_sweep_min_levels(32'd3), .cfg_sweep_gap(48'd1000000),
    .o_sweep(), .o_sweep_sym(), .o_sweep_is_buy(), .st_sweep_cnt(),
    .clk(clk), .rst_n(rst_n),
    .track_locate(track_locate), .cfg_base(cfg_base),
    .s_tdata(tdata), .s_tkeep(tkeep), .s_tvalid(tvalid), .s_tlast(tlast),
    .bbo_valid(bbo_valid), .bbo_sym(bbo_sym), .bbo_ts(bbo_ts),
    .bbo_has_bid(bbo_has_bid), .bbo_bid_price(bbo_bid_price), .bbo_bid_qty(bbo_bid_qty),
    .bbo_has_ask(bbo_has_ask), .bbo_ask_price(bbo_ask_price), .bbo_ask_qty(bbo_ask_qty),
    .ev_gap(ev_gap), .ev_hb(ev_hb), .ev_eos(ev_eos),
    .ev_seq(ev_seq), .ev_expected(ev_expected),
    .st_gap_total(st_gap_total), .st_dup_cnt(st_dup_cnt), .st_frame_err(st_frame_err),
    .st_ot_overflow(st_ot_overflow), .st_ot_miss(st_ot_miss), .st_pl_oob(st_pl_oob),
    .st_beat_drop(st_beat_drop), .st_msg_drop(st_msg_drop), .st_delta_drop(st_delta_drop),
    .st_beat_level_max(st_beat_lvl), .st_msg_level_max(st_msg_lvl),
    .st_delta_level_max(st_delta_lvl),
    .st_bbo_early(st_bbo_early), .st_bbo_late(st_bbo_late),
    .st_bbo_mismatch(st_bbo_mismatch), .st_bbo_arb_drop(st_bbo_arb_drop)
  );

  // ---------------- monitor: one log per symbol ----------------
  int fd_log [NSYM];
  int n_bbo  [NSYM];
  initial begin
    for (int k = 0; k < NSYM; k++) begin
      fd_log[k] = $fopen($sformatf("bbo_rtl_s%0d.log", k), "w");
      n_bbo[k]  = 0;
    end
  end

  always @(posedge clk) if (rst_n && bbo_valid) begin
    n_bbo[bbo_sym]++;
    $fdisplay(fd_log[bbo_sym], "%0d bid=%0d:%0d ask=%0d:%0d",
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
    int fd, c1, c2, len, v;

    fname = "../step1-sw-parser/test_clean.mold";
    void'($value$plusargs("mold=%s", fname));
    if ($value$plusargs("loc0=%d", v)) track_locate[15:0]  = v[15:0];
    if ($value$plusargs("loc1=%d", v)) track_locate[31:16] = v[15:0];
    if ($value$plusargs("base0=%d", v)) cfg_base[31:0]  = v;
    if ($value$plusargs("base1=%d", v)) cfg_base[63:32] = v;
    void'($value$plusargs("gap=%d", gap));

    fd = $fopen(fname, "rb");
    if (fd == 0) begin $display("FATAL: cannot open %s", fname); $finish; end

    tvalid = 1'b0; tlast = 1'b0; tkeep = '0; tdata = '0;
    repeat (5) @(negedge clk);
    rst_n = 1'b1;
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
    for (int k = 0; k < NSYM; k++) $fclose(fd_log[k]);

    $display("TB done: symbol 0 = %0d BBO updates, symbol 1 = %0d (gap=%0d)",
             n_bbo[0], n_bbo[1], gap);
    $display("  splitter : gap_total=%0d dup=%0d frame_err=%0d",
             st_gap_total, st_dup_cnt, st_frame_err);
    $display("  table    : overflow=%0d miss=%0d", st_ot_overflow, st_ot_miss);
    $display("  book     : oob=%0d early=%0d late=%0d mismatch=%0d arb_drop=%0d",
             st_pl_oob, st_bbo_early, st_bbo_late, st_bbo_mismatch, st_bbo_arb_drop);
    $display("  drops    : beat=%0d msg=%0d delta=%0d",
             st_beat_drop, st_msg_drop, st_delta_drop);

    // Failures the diff cannot see, because they would show up as a stream
    // that is short rather than as a stream that is wrong.
    if (st_bbo_mismatch != 0)
      $display("FAIL: fast_bbo contradicted a ladder %0d times", st_bbo_mismatch);
    if (st_bbo_arb_drop != 0)
      $display("FAIL: the BBO merge dropped %0d record(s)", st_bbo_arb_drop);
    if (st_beat_drop != 0 || st_msg_drop != 0 || st_delta_drop != 0)
      $display("FAIL: a FIFO overflowed -- the diff below is not meaningful");
    // Both books have to have DONE something, or two empty logs would diff
    // clean against two empty goldens and this would pass having tested nothing.
    for (int k = 0; k < NSYM; k++)
      if (n_bbo[k] == 0) $display("FAIL: symbol %0d produced no BBO records", k);

    $finish;
  end
endmodule
