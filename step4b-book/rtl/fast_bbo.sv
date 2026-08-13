// Fast top-of-book — answer the common case in one cycle instead of ten.
//
// WHY. price_ladder is ~10 of the imbalance path's ~28 core cycles, and it is
// deep because closing timing required splitting its read-modify-write. It earns
// that depth: it holds 4,096 levels per side and finds the best by a grouped
// priority scan over an occupancy bitmap, which is the only way to answer "what
// is the best level now" in general.
//
// But it is not the general question that is hot. sweep_detect already runs 19
// cycles rather than 28 for exactly this reason: it taps the order-table delta
// and skips the ladder. This module gives the imbalance path the same shortcut,
// and the reason it can is that MOST deltas do not need a scan at all:
//
//   add at a price better than the best   -> that IS the new best         certain
//   add at the best price                 -> best qty increases           certain
//   add at a worse price                  -> best unchanged               certain
//   remove at a worse price               -> best unchanged               certain
//   remove at the best, partial           -> best qty decreases           certain
//   remove at the best, emptying it       -> new best is the next
//                                            occupied level, which only
//                                            the ladder knows              DEFER
//
// Only the last row needs the scan. Everything else is a comparison and an
// add or subtract against two registers.
//
// THE SAFETY PROPERTY, and why it is stated this way. The design's headline claim
// is that there is no regime in which it emits a WRONG order, re-confirmed on
// silicon at every non-saturated load. An approximate fast path is exactly how a
// claim like that gets quietly lost, so this module never approximates: it either
// knows the answer or says it does not. `o_certain` low means "ask the ladder",
// not "here is a guess". The testbench checks the one property that matters --
// o_certain is never asserted alongside a BBO that differs from a full book
// model -- rather than checking that the numbers look plausible.
//
// ORDERING, which is what makes byte-identical output achievable. The strategy
// fires on the RISING EDGE of a condition evaluated per BBO record, so the
// sequence of BBO records must not change or different orders come out. This
// module therefore does not skip or reorder anything: it emits the same records
// in the same order, and `o_certain` only says whether this one was available
// early. A consumer must still hold a fast record behind any earlier deferred
// one, or record k could overtake k-1 and change the edges.
//
// NOT WIRED IN. This is the module and its contract. Integrating it means
// deciding where the fast and slow records rejoin, and that ordering rule is the
// part that has to be got right; see step4b-book/README.md.
`timescale 1ns/1ps
module fast_bbo (
  input  logic        clk,
  input  logic        rst_n,

  // one book delta per message, straight off the order table
  input  logic        i_valid,
  input  logic [47:0] i_ts,
  input  logic [7:0]  i_side,          // "B" or "S"
  input  logic        i_has_rem,
  input  logic [31:0] i_rem_price,
  input  logic [31:0] i_rem_qty,
  input  logic        i_has_add,
  input  logic [31:0] i_add_price,
  input  logic [31:0] i_add_qty,

  // authoritative BBO from price_ladder, used to resync after a deferral
  input  logic        i_lad_valid,
  input  logic        i_lad_has_bid,
  input  logic [31:0] i_lad_bid_price,
  input  logic [31:0] i_lad_bid_qty,
  input  logic        i_lad_has_ask,
  input  logic [31:0] i_lad_ask_price,
  input  logic [31:0] i_lad_ask_qty,

  output logic        o_valid,
  output logic        o_certain,       // low = this record needs the ladder
  output logic [47:0] o_ts,
  output logic        o_has_bid,
  output logic [31:0] o_bid_price,
  output logic [31:0] o_bid_qty,
  output logic        o_has_ask,
  output logic [31:0] o_ask_price,
  output logic [31:0] o_ask_qty,

  output logic [31:0] certain_cnt,     // records answered without the ladder
  output logic [31:0] defer_cnt        // records that needed it
);
  // Shadow of the top of book. `stale` means a deferral has happened and nothing
  // may be answered from these registers until the ladder resyncs them.
  logic        has_bid, has_ask, stale;
  logic [31:0] bid_price, bid_qty, ask_price, ask_qty;

  wire is_bid = (i_side == "B");

  // FORWARDING, and it is not optional. The ladder's BBO for delta N-1 arrives in
  // the SAME cycle the ladder accepts delta N -- measured on the real chain, 9 of
  // 10 handshakes coincide, because price_ladder asserts o_valid in its last
  // state and i_ready in the next. Without this bypass the resync's `stale <= 0`
  // and the deferral's `stale <= 1` land in one evaluation, the deferral wins,
  // and the module defers forever: 0 % early on the first real run.
  //
  // So when the ladder is speaking this cycle, its record IS the book before this
  // delta, and it is what the delta must be applied to. Same shape of fix as the
  // order table's r_fwd and the ladder's own removal-to-add forward.
  wire        eff_stale   = stale && !i_lad_valid;
  wire        eff_has_bid = i_lad_valid ? i_lad_has_bid   : has_bid;
  wire [31:0] eff_bid_px  = i_lad_valid ? i_lad_bid_price : bid_price;
  wire [31:0] eff_bid_q   = i_lad_valid ? i_lad_bid_qty   : bid_qty;
  wire        eff_has_ask = i_lad_valid ? i_lad_has_ask   : has_ask;
  wire [31:0] eff_ask_px  = i_lad_valid ? i_lad_ask_price : ask_price;
  wire [31:0] eff_ask_q   = i_lad_valid ? i_lad_ask_qty   : ask_qty;

  // Current best on the side this delta touches.
  wire        cur_has = is_bid ? eff_has_bid : eff_has_ask;
  wire [31:0] cur_px  = is_bid ? eff_bid_px  : eff_ask_px;
  wire [31:0] cur_qty = is_bid ? eff_bid_q   : eff_ask_q;

  // "Better" is higher for bids and lower for asks -- the only place the two
  // sides differ, and the reason this is one module rather than two.
  function automatic logic better(input logic bid, input logic [31:0] a,
                                  input logic [31:0] b);
    return bid ? (a > b) : (a < b);
  endfunction

  // Does the removal empty the level it is taken from? rem_qty is the amount
  // leaving that price, so >= means the level is gone and the next best is
  // whatever the ladder's occupancy bitmap says.
  wire rem_hits_best = i_has_rem && cur_has && (i_rem_price == cur_px);
  wire rem_empties   = rem_hits_best && (i_rem_qty >= cur_qty);

  // An add that lands on a level better than the current best defines the new
  // best outright -- no scan needed, because nothing between them can matter.
  wire add_improves  = i_has_add && (!cur_has || better(is_bid, i_add_price, cur_px));
  wire add_at_best   = i_has_add && cur_has && (i_add_price == cur_px);

  // The quantity the best level ends up with, as ONE arithmetic expression.
  // Written the obvious way -- subtract the removal, then add the add -- it is
  // two 32-bit carry chains in SERIES, and that series is the path out of the
  // delta FIFO into these registers. At one symbol it closed on every directive;
  // at two, with the delta bus fanning out to a second lane, it became the
  // binding path (FINDINGS 4.4).
  //
  // Selecting the operands first is the same arithmetic at half the depth:
  // rem_hits_best and add_at_best are comparisons that resolve in parallel with
  // each other anyway, so this trades two chained adds for two muxes and one
  // fused a - b + c. Identical in every case, including both-at-once, which is
  // the one the sequential form made look ordered when it is not.
  wire [31:0] q_sub = rem_hits_best ? i_rem_qty : 32'd0;
  wire [31:0] q_add = add_at_best   ? i_add_qty : 32'd0;
  wire [31:0] q_net = cur_qty - q_sub + q_add;

  // The one case that needs the ladder. An add in the same delta does NOT rescue
  // it: U replaces an order, and the new level may be worse than some other
  // resting level this module cannot see.
  wire defer = eff_stale || (rem_empties && !add_improves);

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      has_bid <= 1'b0; has_ask <= 1'b0; stale <= 1'b1;
      bid_price <= '0; bid_qty <= '0; ask_price <= '0; ask_qty <= '0;
      o_valid <= 1'b0; o_certain <= 1'b0;
      certain_cnt <= '0; defer_cnt <= '0;
    end else begin
      o_valid <= 1'b0;

      // Resync from the authoritative BBO. This is what clears `stale`, so a
      // deferral costs exactly one ladder round trip and not a permanent
      // downgrade to the slow path.
      if (i_lad_valid) begin
        has_bid   <= i_lad_has_bid;  bid_price <= i_lad_bid_price;
        bid_qty   <= i_lad_bid_qty;
        has_ask   <= i_lad_has_ask;  ask_price <= i_lad_ask_price;
        ask_qty   <= i_lad_ask_qty;
        stale     <= 1'b0;
      end

      if (i_valid) begin
        o_valid   <= 1'b1;
        o_ts      <= i_ts;
        o_certain <= !defer;
        if (defer) defer_cnt <= defer_cnt + 1'b1;
        else       certain_cnt <= certain_cnt + 1'b1;

        if (defer) begin
          // Say nothing rather than guess; the ladder's record is the answer.
          stale <= 1'b1;
          // Outputs still carry the pre-delta book, but o_certain is low so a
          // consumer must ignore them. Emitting the old values rather than X
          // keeps the record shape uniform for the ordering logic downstream.
          o_has_bid <= eff_has_bid; o_bid_price <= eff_bid_px; o_bid_qty <= eff_bid_q;
          o_has_ask <= eff_has_ask; o_ask_price <= eff_ask_px; o_ask_qty <= eff_ask_q;
        end else begin
          // q_net already carries the partial removal (partial by defer above)
          // and the add-at-best, both of them or neither.
          automatic logic [31:0] nq = q_net;
          automatic logic [31:0] npx = cur_px;
          automatic logic        nh  = cur_has;

          // An add better than the current best defines the level outright, so
          // it replaces the accumulated quantity rather than joining it.
          if (add_improves) begin
            nh = 1'b1; npx = i_add_price; nq = i_add_qty;
          end

          // The BBO record describes the book AFTER this delta, so the outputs
          // are registered from the NEW values here rather than mirroring the
          // shadow registers -- those update on this same edge and would make
          // every record one delta stale.
          if (is_bid) begin
            has_bid   <= nh;  bid_price   <= npx; bid_qty   <= nq;
            has_ask   <= eff_has_ask; ask_price <= eff_ask_px; ask_qty <= eff_ask_q;
            o_has_bid <= nh;  o_bid_price <= npx; o_bid_qty <= nq;
            o_has_ask <= eff_has_ask; o_ask_price <= eff_ask_px; o_ask_qty <= eff_ask_q;
          end else begin
            has_ask   <= nh;  ask_price   <= npx; ask_qty   <= nq;
            has_bid   <= eff_has_bid; bid_price <= eff_bid_px; bid_qty <= eff_bid_q;
            o_has_ask <= nh;  o_ask_price <= npx; o_ask_qty <= nq;
            o_has_bid <= eff_has_bid; o_bid_price <= eff_bid_px; o_bid_qty <= eff_bid_q;
          end
        end
      end
    end
  end
endmodule
