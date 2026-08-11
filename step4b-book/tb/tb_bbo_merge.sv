// Self-checking testbench for bbo_merge.
//
// The module's whole specification is one sentence -- the merged stream must be
// the stream price_ladder would have produced alone -- so the reference here is
// that stream, computed independently: take the true BBO after each delta and
// drop consecutive duplicates. Nothing in the checker re-implements the DUT's
// baseline register or its suppression rule, because a reference that shared
// those would agree with a broken DUT about exactly the things worth checking.
//
// The stimulus reproduces the real interleaving rather than a convenient one.
// Deltas are serialized through price_ladder, which accepts from IDLE and
// asserts o_valid in that same cycle, so for delta k the arrivals are always
//
//   lad(k-1) on the accept cycle ... fast(k) one cycle later ... lad(k) ten
//   cycles after that, and only if the BBO changed
//
// If that ordering is what makes a single baseline register sufficient, then a
// testbench that drives some other spacing is not testing the argument.
//
// Three things are checked beyond stream equality:
//   * a deferred delta contributes nothing early -- its record, if any, is the
//     ladder's, and it still lands in sequence;
//   * a fast record arriving in the same cycle as a ladder record loses, and the
//     change it carried is not lost with it;
//   * a certain-and-wrong fast record (which fast_bbo's contract forbids, so it
//     has to be injected here) is corrected by the ladder and counted.
`timescale 1ns/1ps
module tb_bbo_merge;
  logic clk = 0, rst_n = 0;
  always #2.3 clk = ~clk;                       // ~215 MHz

  logic        i_fast_valid = 0, i_fast_certain = 0;
  logic [47:0] i_fast_ts = 0;
  logic        i_fast_has_bid = 0, i_fast_has_ask = 0;
  logic [31:0] i_fast_bid_price = 0, i_fast_bid_qty = 0;
  logic [31:0] i_fast_ask_price = 0, i_fast_ask_qty = 0;

  logic        i_lad_valid = 0;
  logic [47:0] i_lad_ts = 0;
  logic        i_lad_has_bid = 0, i_lad_has_ask = 0;
  logic [31:0] i_lad_bid_price = 0, i_lad_bid_qty = 0;
  logic [31:0] i_lad_ask_price = 0, i_lad_ask_qty = 0;

  logic        o_valid, o_has_bid, o_has_ask;
  logic [47:0] o_ts;
  logic [31:0] o_bid_price, o_bid_qty, o_ask_price, o_ask_qty;
  logic [31:0] early_cnt, late_cnt, mismatch_cnt;

  bbo_merge dut (.*);

  typedef struct {
    longint unsigned ts;
    bit              has_bid, has_ask;
    int unsigned     bid_price, bid_qty, ask_price, ask_qty;
  } rec_t;

  // ---- expected stream, built as the stimulus is written ----
  rec_t exp_q [$];
  int   n_got = 0, errors = 0;

  // the ladder's own baseline: what it last emitted, which is what decides
  // whether it emits at all for a given delta
  rec_t lad_base;

  // the ladder record owed for the PREVIOUS delta, driven on the next accept
  rec_t pend_rec;
  bit   pend_valid = 0;

  // ---- checker ----
  // `checking` goes low for the injected certain-and-wrong case at the end, which
  // deliberately produces records the ladder alone would not have.
  bit checking = 1;

  always @(posedge clk) if (rst_n && o_valid && checking) begin
    automatic rec_t e;
    n_got++;
    if (exp_q.size() == 0) begin
      errors++;
      $display("EXTRA record ts=%0d bid %0d@%0d ask %0d@%0d",
               o_ts, o_bid_qty, o_bid_price, o_ask_qty, o_ask_price);
    end else begin
      e = exp_q.pop_front();
      if (o_ts !== e.ts[47:0] ||
          o_has_bid !== e.has_bid || o_bid_price !== e.bid_price || o_bid_qty !== e.bid_qty ||
          o_has_ask !== e.has_ask || o_ask_price !== e.ask_price || o_ask_qty !== e.ask_qty) begin
        errors++;
        $display("MISMATCH got ts=%0d bid %0d@%0d ask %0d@%0d | want ts=%0d bid %0d@%0d ask %0d@%0d",
                 o_ts, o_bid_qty, o_bid_price, o_ask_qty, o_ask_price,
                 e.ts, e.bid_qty, e.bid_price, e.ask_qty, e.ask_price);
      end
    end
  end

  // ---- stimulus ----
  task automatic tick(input int n = 1);
    repeat (n) @(posedge clk);
  endtask

  task automatic drive_lad(input rec_t r);
    i_lad_valid     <= 1'b1;      i_lad_ts        <= r.ts[47:0];
    i_lad_has_bid   <= r.has_bid; i_lad_bid_price <= r.bid_price; i_lad_bid_qty <= r.bid_qty;
    i_lad_has_ask   <= r.has_ask; i_lad_ask_price <= r.ask_price; i_lad_ask_qty <= r.ask_qty;
  endtask

  // One delta. `certain` says whether fast_bbo could answer it; the book after
  // the delta is passed in, since the reference is the book, not the DUT's rules.
  // `coincide` drives the previous delta's ladder record in the same cycle as
  // this delta's fast record, which is the priority case.
  task automatic delta(input longint unsigned ts,
                       input bit certain,
                       input bit has_bid, input int unsigned bp, input int unsigned bq,
                       input bit has_ask, input int unsigned ap, input int unsigned aq,
                       input bit coincide = 0);
    automatic rec_t now;
    automatic bit   lad_emits;

    now.ts        = ts;
    now.has_bid   = has_bid;
    now.bid_price = has_bid ? bp : 0;
    now.bid_qty   = has_bid ? bq : 0;
    now.has_ask   = has_ask;
    now.ask_price = has_ask ? ap : 0;
    now.ask_qty   = has_ask ? aq : 0;

    // The ladder emits only when the book differs from what IT last emitted, and
    // the merged stream is exactly those records.
    lad_emits = (now.has_bid   !== lad_base.has_bid)   ||
                (now.bid_price !== lad_base.bid_price) || (now.bid_qty !== lad_base.bid_qty) ||
                (now.has_ask   !== lad_base.has_ask)   ||
                (now.ask_price !== lad_base.ask_price) || (now.ask_qty !== lad_base.ask_qty);
    if (lad_emits) begin
      exp_q.push_back(now);
      lad_base = now;
    end

    // the accept cycle: the previous delta's ladder record lands here
    if (!coincide) begin
      if (pend_valid) begin
        drive_lad(pend_rec);
        tick();
        i_lad_valid <= 1'b0;
        pend_valid = 0;
      end else begin
        tick();
      end
    end

    // the fast record, one cycle after the accept (or on top of the pending
    // ladder record, when the coincidence is being exercised)
    if (coincide && pend_valid) begin
      drive_lad(pend_rec);
      pend_valid = 0;
    end
    i_fast_valid     <= 1'b1;
    i_fast_certain   <= certain;
    i_fast_ts        <= ts[47:0];
    // A deferred record still carries the PRE-delta book, as fast_bbo emits it;
    // the merge must ignore it entirely rather than treat it as a value.
    i_fast_has_bid   <= certain ? now.has_bid   : lad_base.has_bid;
    i_fast_bid_price <= certain ? now.bid_price : lad_base.bid_price;
    i_fast_bid_qty   <= certain ? now.bid_qty   : lad_base.bid_qty;
    i_fast_has_ask   <= certain ? now.has_ask   : lad_base.has_ask;
    i_fast_ask_price <= certain ? now.ask_price : lad_base.ask_price;
    i_fast_ask_qty   <= certain ? now.ask_qty   : lad_base.ask_qty;
    tick();
    i_fast_valid <= 1'b0;
    i_lad_valid  <= 1'b0;

    // the ladder's own pass over this delta
    tick(9);
    if (lad_emits) begin
      pend_rec   = now;
      pend_valid = 1;
    end
  endtask

  task automatic flush();
    if (pend_valid) begin
      drive_lad(pend_rec);
      tick();
      i_lad_valid <= 1'b0;
      pend_valid = 0;
    end
    tick(10);
  endtask

  initial begin
    lad_base = '{ts: 0, has_bid: 0, has_ask: 0,
                 bid_price: 0, bid_qty: 0, ask_price: 0, ask_qty: 0};
    tick(4);
    rst_n = 1;
    tick(2);

    // ---- an ordinary run: certain records, each a change ----
    delta(48'd1000, 1, 1, 100_00, 500, 1, 101_00, 400);
    delta(48'd1001, 1, 1, 100_00, 700, 1, 101_00, 400);
    delta(48'd1002, 1, 1, 100_50, 200, 1, 101_00, 400);

    // ---- certain records that change nothing: no record may appear ----
    delta(48'd1003, 1, 1, 100_50, 200, 1, 101_00, 400);
    delta(48'd1004, 1, 1, 100_50, 200, 1, 101_00, 400);

    // ---- a deferral: the best bid empties, only the ladder knows the next ----
    delta(48'd1005, 0, 1, 100_00, 500, 1, 101_00, 400);
    // and the delta after it, still deferred because fast_bbo would be stale
    delta(48'd1006, 0, 1, 100_00, 500, 1, 100_90, 300);
    delta(48'd1007, 1, 1, 100_00, 900, 1, 100_90, 300);

    // ---- one side empties entirely: price and qty must read zero ----
    delta(48'd1008, 0, 0, 0, 0, 1, 100_90, 300);
    delta(48'd1009, 1, 0, 0, 0, 1, 100_90, 100);
    delta(48'd1010, 1, 1, 99_00, 50, 1, 100_90, 100);

    // ---- the coincidence: fast and ladder in the same cycle ----
    // The ladder's record is for the PREVIOUS delta, so it must win, and the
    // change this fast record carried has to survive via its own ladder record.
    delta(48'd1011, 1, 1, 99_00, 80, 1, 100_90, 100, 1);
    delta(48'd1012, 1, 1, 99_00, 90, 1, 100_90, 100);

    flush();

    if (exp_q.size() != 0) begin
      errors++;
      $display("MISSING %0d records at the end", exp_q.size());
    end
    if (mismatch_cnt != 0) begin
      errors++;
      $display("mismatch_cnt=%0d before the injection, expected 0", mismatch_cnt);
    end
    if (early_cnt == 0 || late_cnt == 0) begin
      errors++;
      $display("early=%0d late=%0d -- both paths must have delivered records",
               early_cnt, late_cnt);
    end

    // ---- injection: certain and WRONG, which fast_bbo promises never to be ----
    // The ladder's value must still be the one that stands, and the disagreement
    // must be counted. The stream checker is off from here: this deliberately
    // produces a record the ladder alone would not have.
    begin
      automatic int unsigned early_before = early_cnt;
      automatic int unsigned mism_before  = mismatch_cnt;
      checking = 0;

      i_fast_valid     <= 1'b1;  i_fast_certain   <= 1'b1;
      i_fast_ts        <= 48'd2000;
      i_fast_has_bid   <= 1'b1;  i_fast_bid_price <= 98_00;  i_fast_bid_qty <= 11;
      i_fast_has_ask   <= 1'b1;  i_fast_ask_price <= 100_90; i_fast_ask_qty <= 100;
      tick();
      i_fast_valid <= 1'b0;
      tick(9);
      i_lad_valid     <= 1'b1;   i_lad_ts         <= 48'd2000;
      i_lad_has_bid   <= 1'b1;   i_lad_bid_price  <= 97_00;  i_lad_bid_qty  <= 22;
      i_lad_has_ask   <= 1'b1;   i_lad_ask_price  <= 100_90; i_lad_ask_qty  <= 100;
      tick();
      i_lad_valid <= 1'b0;
      tick(5);

      if (early_cnt != early_before + 1) begin
        errors++;
        $display("the wrong-but-certain record was not emitted early");
      end
      if (mismatch_cnt != mism_before + 1) begin
        errors++;
        $display("mismatch_cnt=%0d, expected %0d -- the disagreement was not counted",
                 mismatch_cnt, mism_before + 1);
      end
      if (o_bid_price !== 97_00 || o_bid_qty !== 22) begin
        errors++;
        $display("the ladder's correction did not win: bid %0d@%0d",
                 o_bid_qty, o_bid_price);
      end
    end

    $display("bbo_merge: %0d records, early=%0d late=%0d mismatch=%0d",
             n_got, early_cnt, late_cnt, mismatch_cnt);
    if (errors == 0)
      $display("PASS: bbo_merge -- the merged stream is the ladder's stream");
    else
      $display("FAIL: bbo_merge -- %0d errors", errors);
    $finish;
  end
endmodule
