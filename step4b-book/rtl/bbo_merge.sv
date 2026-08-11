// BBO rejoin — where the fast and slow top-of-book paths become one stream.
//
// fast_bbo answers most deltas in a cycle; price_ladder answers all of them in
// eleven. Both are correct, so the only question integration has to settle is
// which record reaches the strategy, and in what order. Get that wrong and the
// design still "works" -- it just sends different orders, which is the failure
// this project is least able to detect from the outside.
//
// THE PROPERTY TO PRESERVE. The strategy fires on the RISING EDGE of a condition
// evaluated per BBO record. So the output of this module must be, record for
// record and value for value, the stream price_ladder would have produced alone.
// Only the cycle it arrives on may change. That is the whole specification.
//
// The two inputs do not have the same shape, which is the part that makes this
// more than a mux:
//
//   fast_bbo    one record per delta, certain or not      6,740 on the real replay
//   price_ladder  one record per CHANGE of the BBO          1,779 on the same run
//
// They are therefore not in one-to-one correspondence and cannot be matched up
// pairwise. What makes them comparable is that both describe the same book, so
// this module keeps the one piece of state that reconciles them: the last BBO it
// EMITTED. A record is emitted when it differs from that baseline and dropped
// when it does not, which is exactly price_ladder's own S_OUT test against its
// o_* registers. Two change-detectors sharing a definition and a baseline agree
// by construction, so:
//
//   * a fast record the ladder would not have emitted is dropped here,
//   * the ladder's record for a delta the fast path already answered arrives
//     carrying the value we just emitted, compares equal, and is dropped -- the
//     duplicate suppression falls out rather than needing a per-delta tag,
//   * and no change can be lost, because dropping only ever happens on equality.
//
// ORDERING, and why one register is enough. Deltas are strictly serialized: the
// ladder accepts the next one only from IDLE, and it asserts o_valid in that same
// cycle. So for delta k the events are always
//
//   accept(k) ... fast(k) at accept+1 ... lad(k) at accept(k+1) ... fast(k+1)
//
// -- fast(k) can never overtake lad(k-1), and lad(k) always lands before
// fast(k+1). A record answered early therefore cannot jump ahead of a deferred
// one, which is the ordering hazard the step-4b README calls out. It holds only
// because fast_bbo is driven from the ladder's ACCEPT handshake rather than from
// the raw delta stream; feeding it earlier would break the interleaving and is
// the wiring mistake to avoid.
//
// A COINCIDENCE STILL HAS A RULE. The timing above says the two inputs never
// arrive together, but a mux with no priority would be a trap for whoever
// re-times the feed later. The ladder wins, and the fast record is discarded
// rather than queued: dropping it costs latency on one record and nothing else,
// because the ladder processes every delta and will emit any change it caused.
// The fast path is an optimisation; the ladder is the backstop.
//
// mismatch_cnt IS THE SAFETY NET. It counts every case where the ladder's answer
// contradicts an early one -- the ladder emitting a value we did not emit early,
// or staying silent after we did. fast_bbo's contract says this cannot happen
// (o_certain is never asserted with a BBO that differs from a full book model,
// 0 wrong in 1,174 cross-checks on real data), so a nonzero count means that
// contract broke, and the counter is how it gets noticed instead of a golden diff
// months later. The ladder's value wins whenever it speaks, so the datapath
// re-converges on the next ladder record. One exception is worth stating plainly:
// an early record claiming a change the ladder then does not confirm leaves this
// module's baseline ahead of the ladder's until the ladder next emits. The point
// of the counter is that it is loud, not that the recovery is total.
`timescale 1ns/1ps
module bbo_merge (
  input  logic        clk,
  input  logic        rst_n,

  // early answer from fast_bbo: one record per delta, usable only when certain
  input  logic        i_fast_valid,
  input  logic        i_fast_certain,
  input  logic [47:0] i_fast_ts,
  input  logic        i_fast_has_bid,
  input  logic [31:0] i_fast_bid_price,
  input  logic [31:0] i_fast_bid_qty,
  input  logic        i_fast_has_ask,
  input  logic [31:0] i_fast_ask_price,
  input  logic [31:0] i_fast_ask_qty,

  // authoritative answer from price_ladder: only when the BBO changed
  input  logic        i_lad_valid,
  input  logic [47:0] i_lad_ts,
  input  logic        i_lad_has_bid,
  input  logic [31:0] i_lad_bid_price,
  input  logic [31:0] i_lad_bid_qty,
  input  logic        i_lad_has_ask,
  input  logic [31:0] i_lad_ask_price,
  input  logic [31:0] i_lad_ask_qty,

  output logic        o_valid,
  output logic [47:0] o_ts,
  output logic        o_has_bid,
  output logic [31:0] o_bid_price,
  output logic [31:0] o_bid_qty,
  output logic        o_has_ask,
  output logic [31:0] o_ask_price,
  output logic [31:0] o_ask_qty,

  output logic [31:0] early_cnt,       // records delivered by the fast path
  output logic [31:0] late_cnt,        // records delivered by the ladder
  output logic [31:0] mismatch_cnt     // must stay 0: see the header
);
  // ---- source select: the ladder wins a coincidence, see the header ----
  wire lad_take  = i_lad_valid;
  wire fast_take = i_fast_valid && i_fast_certain && !i_lad_valid;
  wire s_valid   = lad_take || fast_take;

  wire [47:0] s_ts      = lad_take ? i_lad_ts      : i_fast_ts;
  wire        s_has_bid = lad_take ? i_lad_has_bid : i_fast_has_bid;
  wire        s_has_ask = lad_take ? i_lad_has_ask : i_fast_has_ask;

  // An absent side carries zero price and qty. That is price_ladder's own
  // convention (S_PX writes 0 when the side is empty) and the baseline has to
  // share it, or a stale price left on a vacated side would read as a change and
  // insert a record the ladder never had.
  wire [31:0] s_bid_price = s_has_bid ? (lad_take ? i_lad_bid_price : i_fast_bid_price) : 32'd0;
  wire [31:0] s_bid_qty   = s_has_bid ? (lad_take ? i_lad_bid_qty   : i_fast_bid_qty)   : 32'd0;
  wire [31:0] s_ask_price = s_has_ask ? (lad_take ? i_lad_ask_price : i_fast_ask_price) : 32'd0;
  wire [31:0] s_ask_qty   = s_has_ask ? (lad_take ? i_lad_ask_qty   : i_fast_ask_qty)   : 32'd0;

  // ---- the shared baseline: the last BBO this module emitted ----
  // Reset values match price_ladder's, so the FIRST record is detected as a
  // change by both for the same reason.
  logic        e_has_bid, e_has_ask;
  logic [31:0] e_bid_price, e_bid_qty, e_ask_price, e_ask_qty;

  wire changed = (s_has_bid   != e_has_bid)   ||
                 (s_bid_price != e_bid_price) || (s_bid_qty != e_bid_qty) ||
                 (s_has_ask   != e_has_ask)   ||
                 (s_ask_price != e_ask_price) || (s_ask_qty != e_ask_qty);

  wire emit = s_valid && changed;

  // Was the delta now in the ladder answered early, and did that answer produce a
  // record? Both bits are needed to tell the two disagreement shapes apart: the
  // ladder contradicting an early record, and the ladder staying silent after one.
  logic pend_certain, pend_emitted;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      o_valid      <= 1'b0;
      o_has_bid    <= 1'b0; o_bid_price <= '0; o_bid_qty <= '0;
      o_has_ask    <= 1'b0; o_ask_price <= '0; o_ask_qty <= '0;
      e_has_bid    <= 1'b0; e_bid_price <= '0; e_bid_qty <= '0;
      e_has_ask    <= 1'b0; e_ask_price <= '0; e_ask_qty <= '0;
      pend_certain <= 1'b0;
      pend_emitted <= 1'b0;
      early_cnt    <= '0;
      late_cnt     <= '0;
      mismatch_cnt <= '0;
    end else begin
      o_valid <= 1'b0;

      if (emit) begin
        o_valid     <= 1'b1;     o_ts        <= s_ts;
        o_has_bid   <= s_has_bid; o_bid_price <= s_bid_price; o_bid_qty <= s_bid_qty;
        o_has_ask   <= s_has_ask; o_ask_price <= s_ask_price; o_ask_qty <= s_ask_qty;
        e_has_bid   <= s_has_bid; e_bid_price <= s_bid_price; e_bid_qty <= s_bid_qty;
        e_has_ask   <= s_has_ask; e_ask_price <= s_ask_price; e_ask_qty <= s_ask_qty;
        if (lad_take) late_cnt  <= late_cnt  + 1'b1;
        else          early_cnt <= early_cnt + 1'b1;
      end

      // The ladder has spoken for the pending delta: agreement means its record
      // repeats what we already emitted, so `changed` is low and it is dropped.
      if (i_lad_valid) begin
        if (pend_certain && changed) mismatch_cnt <= mismatch_cnt + 1'b1;
        pend_certain <= 1'b0;
        pend_emitted <= 1'b0;
      end

      // A new delta's early answer. If the previous one emitted a change and the
      // ladder never confirmed it, that silence is the other disagreement.
      //
      // `fast_take`, not `i_fast_certain`: a record discarded by the coincidence
      // rule was never honoured, so the delta it described is not one this module
      // answered early and the ladder's record for it must pass unchallenged.
      if (i_fast_valid) begin
        if (!i_lad_valid && pend_certain && pend_emitted)
          mismatch_cnt <= mismatch_cnt + 1'b1;
        pend_certain <= fast_take;
        pend_emitted <= fast_take && changed;
      end
    end
  end

endmodule
