// Strategy trigger + risk gate — step 6. Turns the book engine's BBO stream
// into order intents, which the OUCH builder downstream turns into wire bytes.
//
// The rule is an order-book imbalance taker (see scripts/dump_orders.py, which
// is the golden this must match line for line):
//   tight  = both sides present and (ask - bid) <= cfg_max_spread
//   buy    = tight && bid_qty >= (ask_qty << cfg_ratio_shift) && ask_qty >= cfg_min_qty
//   sell   = tight && ask_qty >= (bid_qty << cfg_ratio_shift) && bid_qty >= cfg_min_qty
// Size resting heavily on one side with a tight spread is the classic signal
// for an imminent move, so a buy lifts the offer and a sell hits the bid. The
// ratio is a SHIFT rather than a multiply: no DSP, and no rounding for the
// golden and the RTL to disagree about.
//
// Orders fire on the RISING EDGE of a signal. A condition that stays true
// across a thousand BBO updates must send one order, not a thousand — this is
// the difference between a strategy and a runaway loop, so the edge state
// advances on EVERY record, including records where the risk gate blocks.
//
// MULTI-SYMBOL. The BBO stream is tagged (i_sym), and the state that describes
// a BOOK is per symbol while the state that describes the TRANSMIT PATH is not.
// The split is not a convenience -- it is what the two kinds of state mean:
//
//   per symbol   prev_buy / prev_sell, the rising-edge memory. Sharing it would
//                let a condition holding on one name suppress the edge on
//                another, which is not a risk decision, it is a lost order.
//   per symbol   the latched two-sided BBO the sweep path prices against. A
//                sweep in one name must not be priced at another name's inside
//                market -- that is an order at a nonsense price.
//   per symbol   position, and cfg_pos_limit is applied to each independently.
//                Long one name and short another is not flat.
//   SHARED       inflight. It counts orders on ONE TCP session with one
//                replay buffer; the resource being limited is the wire, not
//                the book.
//   SHARED       the counters. One number per rejection reason is what the
//                register map carries and what the question ("is it quiet or
//                is it blocked?") needs; per-symbol totals would be NSYM times
//                the registers for the same answer.
//
// NSYM = 1 leaves every array one deep and every index constant zero, so the
// single-symbol behaviour every golden here checks is unchanged.
//
// Risk gate, applied before anything leaves:
//   * cfg_enable       kill switch
//   * cfg_pos_limit    |position| after the order may not exceed it, PER SYMBOL
//   * cfg_max_inflight orders sent but not yet acknowledged, across all symbols
// Position moves OPTIMISTICALLY, as though every order fills in full. That is
// wrong, but wrong in the safe direction: an unfilled order still consumes
// position budget, so the error can only suppress trading, never permit more.
// Real fills coming back from the host is future work.
//
// Backpressure: if the transmit path is not ready the order is DROPPED and
// counted, never queued. A queued order in this business is a stale order —
// by the time the path drains, the book that justified it has moved. The
// counter is what makes the loss visible instead of silent.
`timescale 1ns/1ps
module strategy #(
  parameter int NSYM = 1,
  parameter int SYMW = (NSYM > 1) ? $clog2(NSYM) : 1
)(
  input  logic         clk,
  input  logic         rst_n,

  // configuration (host-written, read as a set while cfg_enable is low)
  input  logic         cfg_enable,
  input  logic [31:0]  cfg_max_spread,
  input  logic [3:0]   cfg_ratio_shift,
  input  logic [31:0]  cfg_min_qty,
  input  logic [31:0]  cfg_order_qty,
  input  logic [31:0]  cfg_pos_limit,
  input  logic [15:0]  cfg_max_inflight,

  // BBO stream from the book engine, tagged with the symbol whose book moved
  input  logic         i_valid,
  input  logic [SYMW-1:0] i_sym,
  input  logic [47:0]  i_ts,
  input  logic         i_has_bid,
  input  logic [31:0]  i_bid_price,
  input  logic [31:0]  i_bid_qty,
  input  logic         i_has_ask,
  input  logic [31:0]  i_ask_price,
  input  logic [31:0]  i_ask_qty,

  // sweep / momentum-ignition trigger, from sweep_detect. A buy sweep means
  // the offer was lifted through several levels, so the strategy takes the SAME
  // side (buys, expecting continuation — the measured signal, FINDINGS §5). It
  // is priced at the latest BBO the block has latched, so a sweep between BBO
  // updates still has a price to trade at.
  input  logic         cfg_sweep_en,
  input  logic         i_sweep,
  input  logic [SYMW-1:0] i_sweep_sym,
  input  logic         i_sweep_is_buy,

  // one acknowledgement pulse per order the host/exchange has confirmed
  input  logic         i_ack,

  // order intent. o_sym tells the OUCH builder which stock symbol to put in the
  // message -- the one field of an Enter Order that is per name.
  output logic         o_valid,
  output logic [SYMW-1:0] o_sym,
  output logic [47:0]  o_ts,
  output logic         o_is_buy,
  output logic [31:0]  o_qty,
  output logic [31:0]  o_price,
  input  logic         o_ready,

  // observability — every rejection reason is counted separately, so a quiet
  // strategy can be told apart from a blocked one
  output logic [31:0]  sent_cnt,
  output logic [31:0]  blk_pos_cnt,
  output logic [31:0]  blk_inflight_cnt,
  output logic [31:0]  blk_txfull_cnt,
  output logic [31:0]  blk_qty_cnt,        // shares outside OUCH's legal range
  // one signed position per symbol, packed: symbol k is position[32*k +: 32]
  output logic [NSYM*32-1:0] position,
  output logic [15:0]  inflight
);
  // Comparisons are done at 48 bits. cfg_ratio_shift can reach 15 and the
  // quantities are 32 bits, so a 32-bit compare could wrap and turn a huge
  // shifted value into a small one — i.e. invent a signal. The golden is
  // Python, where integers never wrap, so the RTL has to not wrap either.
  localparam int CW = 48;

  // At NSYM = 1 the symbol tag carries no information -- there is one book, so
  // every record belongs to it -- and reading the port would be wrong whatever
  // drove it. Forcing the index to zero says that, and means a caller built
  // before the tag existed (every single-symbol testbench in this repo) cannot
  // put an X into an array index and produce a mysterious failure a long way
  // downstream. At NSYM > 1 the tag is the only thing that says which book, so
  // it is read exactly as given.
  wire [SYMW-1:0] sym_in    = (NSYM == 1) ? '0 : i_sym;
  wire [SYMW-1:0] sweep_sym = (NSYM == 1) ? '0 : i_sweep_sym;

  // ---- stage 1: evaluate the rule ----
  logic        s1_valid, s1_buy, s1_sell;
  logic [SYMW-1:0] s1_sym;
  logic [47:0] s1_ts;
  logic [31:0] s1_buy_qty, s1_buy_px, s1_sell_qty, s1_sell_px;

  wire two_sided = i_has_bid && i_has_ask && (i_bid_price != 0) && (i_ask_price != 0);
  wire tight     = two_sided && ((i_ask_price - i_bid_price) <= cfg_max_spread);

  wire [CW-1:0] bidq_w  = CW'(i_bid_qty);
  wire [CW-1:0] askq_w  = CW'(i_ask_qty);
  wire [CW-1:0] bid_shl = bidq_w << cfg_ratio_shift;
  wire [CW-1:0] ask_shl = askq_w << cfg_ratio_shift;

  wire buy_sig  = tight && (bidq_w >= ask_shl) && (i_ask_qty >= cfg_min_qty);
  wire sell_sig = tight && (askq_w >= bid_shl) && (i_bid_qty >= cfg_min_qty);

  // take no more than is resting on the side being taken
  wire [31:0] buy_qty  = (i_ask_qty < cfg_order_qty) ? i_ask_qty : cfg_order_qty;
  wire [31:0] sell_qty = (i_bid_qty < cfg_order_qty) ? i_bid_qty : cfg_order_qty;

  // Latest two-sided BBO PER SYMBOL, held so a sweep arriving between BBO
  // updates has a price. Updated on every BBO event for that symbol; the sweep
  // path reads the REGISTERED value, i.e. the last BBO seen strictly before the
  // sweep, which is what the golden uses too.
  logic        bbo_ok      [NSYM];
  logic [31:0] bbo_bid_px  [NSYM], bbo_bid_qty [NSYM];
  logic [31:0] bbo_ask_px  [NSYM], bbo_ask_qty [NSYM];

  // sweep path, pipelined one stage to line up with the imbalance path
  logic        s1_sweep, s1_sweep_buy;
  logic [SYMW-1:0] s1_sweep_sym;
  logic [47:0] s1_sweep_ts;
  logic [31:0] s1_sweep_qty, s1_sweep_px;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      s1_valid <= 1'b0;
      s1_sweep <= 1'b0;
      for (int k = 0; k < NSYM; k++) bbo_ok[k] <= 1'b0;
    end else begin
      s1_valid    <= i_valid;
      s1_sym      <= sym_in;
      s1_ts       <= i_ts;
      s1_buy      <= buy_sig;
      s1_sell     <= sell_sig;
      s1_buy_qty  <= buy_qty;
      s1_buy_px   <= i_ask_price;   // lift the offer
      s1_sell_qty <= sell_qty;
      s1_sell_px  <= i_bid_price;   // hit the bid

      if (i_valid && two_sided) begin
        bbo_ok     [sym_in] <= 1'b1;
        bbo_bid_px [sym_in] <= i_bid_price; bbo_bid_qty[sym_in] <= i_bid_qty;
        bbo_ask_px [sym_in] <= i_ask_price; bbo_ask_qty[sym_in] <= i_ask_qty;
      end

      // A sweep can only be priced once a two-sided BBO exists FOR ITS OWN
      // symbol; take the same side as the sweep at that book's current best.
      s1_sweep     <= i_sweep && cfg_sweep_en && bbo_ok[sweep_sym];
      s1_sweep_sym <= sweep_sym;
      s1_sweep_buy <= i_sweep_is_buy;
      s1_sweep_ts  <= i_ts;
      s1_sweep_qty <= i_sweep_is_buy
                    ? ((bbo_ask_qty[sweep_sym] < cfg_order_qty) ? bbo_ask_qty[sweep_sym] : cfg_order_qty)
                    : ((bbo_bid_qty[sweep_sym] < cfg_order_qty) ? bbo_bid_qty[sweep_sym] : cfg_order_qty);
      s1_sweep_px  <= i_sweep_is_buy ? bbo_ask_px[sweep_sym] : bbo_bid_px[sweep_sym];
    end
  end

  // ---- stage 2: edge detect, risk gate, emit ----
  // buy_sig and sell_sig cannot both hold: that would need
  // bid_qty >= 2^k * ask_qty and ask_qty >= 2^k * bid_qty at once.
  // Per symbol: a condition that holds on one name must not swallow another
  // name's edge. This is the array whose sharing would be an outright bug, not
  // merely an approximation.
  logic prev_buy [NSYM], prev_sell [NSYM];

  wire fire_buy  = s1_valid && s1_buy  && !prev_buy [s1_sym];
  wire fire_sell = s1_valid && s1_sell && !prev_sell[s1_sym];
  wire imb_fire  = fire_buy || fire_sell;

  // Merge the two trigger sources. Sweep has priority over imbalance — it is
  // the rarer, stronger signal — and only one order leaves per cycle. In the
  // testbench (and golden) BBO and sweep arrive on separate cycles, so a BBO
  // edge and a sweep never contend; the priority is a safety rule for the real
  // chain where they could coincide.
  wire        want    = s1_sweep || imb_fire;
  wire [SYMW-1:0] eff_sym = s1_sweep ? s1_sweep_sym : s1_sym;
  wire        eff_buy = s1_sweep ? s1_sweep_buy : fire_buy;
  wire [47:0] eff_ts  = s1_sweep ? s1_sweep_ts  : s1_ts;
  wire [31:0] eff_qty = s1_sweep ? s1_sweep_qty : (fire_buy ? s1_buy_qty : s1_sell_qty);
  wire [31:0] eff_px  = s1_sweep ? s1_sweep_px  : (fire_buy ? s1_buy_px  : s1_sell_px);

  wire signed [31:0] eff_qty_s = signed'(eff_qty);
  // The limit is applied to the order's OWN symbol. A shared position would let
  // a long in one name pay for a short in another, which is not what a position
  // limit is for.
  wire signed [31:0] pos_cur = signed'(position[32*eff_sym +: 32]);
  wire signed [31:0] pos_new = eff_buy ? (pos_cur + eff_qty_s) : (pos_cur - eff_qty_s);
  wire pos_ok      = (pos_new <= signed'(cfg_pos_limit)) &&
                     (pos_new >= -signed'(cfg_pos_limit));
  wire inflight_ok = (inflight < cfg_max_inflight);

  // OUCH 4.2, Enter Order: "Shares ... Must be greater than zero and less than
  // 1,000,000". Nothing in this design guaranteed that -- the quantity is
  // min(resting, cfg_order_qty), so a zero-size level with cfg_min_qty=0 gives
  // zero shares, and any cfg_order_qty at or above a million passes straight
  // through. The venue would reject the order; we would learn about it from a
  // rejection message, which is the expensive way to find out.
  //
  // REJECTED, not clamped. Clamping would send a DIFFERENT order from the one
  // the strategy decided on and hide the misconfiguration that caused it; a
  // counted refusal says exactly what happened. Same reasoning as the blocked
  // transmit path dropping rather than queueing.
  localparam int unsigned OUCH_MAX_SHARES = 1000000;
  wire qty_ok = (eff_qty != 0) && (eff_qty < OUCH_MAX_SHARES);

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      o_valid          <= 1'b0;
      for (int k = 0; k < NSYM; k++) begin
        prev_buy [k] <= 1'b0;
        prev_sell[k] <= 1'b0;
      end
      position         <= '0;
      inflight         <= '0;
      sent_cnt         <= '0;
      blk_pos_cnt      <= '0;
      blk_inflight_cnt <= '0;
      blk_txfull_cnt   <= '0;
      blk_qty_cnt      <= '0;
    end else begin
      o_valid <= 1'b0;

      // an ack retires one order; it is applied before this cycle's decision,
      // which is what lets the golden model acks by record index
      if (i_ack && (inflight != 0)) inflight <= inflight - 1'b1;

      if (s1_valid) begin
        prev_buy [s1_sym] <= s1_buy;    // advances even when the gate blocks
        prev_sell[s1_sym] <= s1_sell;
      end

      if (cfg_enable && want) begin
        // validity before risk: an order that cannot be legal is not a risk
        // decision, and checking it first keeps the risk counters meaningful
        if (!qty_ok) begin
          blk_qty_cnt <= blk_qty_cnt + 1;
        end else if (!inflight_ok) begin
          blk_inflight_cnt <= blk_inflight_cnt + 1;
        end else if (!pos_ok) begin
          blk_pos_cnt <= blk_pos_cnt + 1;
        end else if (!o_ready) begin
          blk_txfull_cnt <= blk_txfull_cnt + 1;
        end else begin
          o_valid  <= 1'b1;
          o_sym    <= eff_sym;
          o_ts     <= eff_ts;
          o_is_buy <= eff_buy;
          o_qty    <= eff_qty;
          o_price  <= eff_px;
          position[32*eff_sym +: 32] <= pos_new;
          sent_cnt <= sent_cnt + 1;
          // an ack in the same cycle as a send leaves the count unchanged
          if (!(i_ack && (inflight != 0))) inflight <= inflight + 1'b1;
        end
      end
    end
  end

endmodule
