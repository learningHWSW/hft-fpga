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
// Risk gate, applied before anything leaves:
//   * cfg_enable       kill switch
//   * cfg_pos_limit    |position| after the order may not exceed it
//   * cfg_max_inflight orders sent but not yet acknowledged
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
module strategy (
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

  // BBO stream from price_ladder
  input  logic         i_valid,
  input  logic [47:0]  i_ts,
  input  logic         i_has_bid,
  input  logic [31:0]  i_bid_price,
  input  logic [31:0]  i_bid_qty,
  input  logic         i_has_ask,
  input  logic [31:0]  i_ask_price,
  input  logic [31:0]  i_ask_qty,

  // one acknowledgement pulse per order the host/exchange has confirmed
  input  logic         i_ack,

  // order intent
  output logic         o_valid,
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
  output logic signed [31:0] position,
  output logic [15:0]  inflight
);
  // Comparisons are done at 48 bits. cfg_ratio_shift can reach 15 and the
  // quantities are 32 bits, so a 32-bit compare could wrap and turn a huge
  // shifted value into a small one — i.e. invent a signal. The golden is
  // Python, where integers never wrap, so the RTL has to not wrap either.
  localparam int CW = 48;

  // ---- stage 1: evaluate the rule ----
  logic        s1_valid, s1_buy, s1_sell;
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

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      s1_valid <= 1'b0;
    end else begin
      s1_valid    <= i_valid;
      s1_ts       <= i_ts;
      s1_buy      <= buy_sig;
      s1_sell     <= sell_sig;
      s1_buy_qty  <= buy_qty;
      s1_buy_px   <= i_ask_price;   // lift the offer
      s1_sell_qty <= sell_qty;
      s1_sell_px  <= i_bid_price;   // hit the bid
    end
  end

  // ---- stage 2: edge detect, risk gate, emit ----
  // buy_sig and sell_sig cannot both hold: that would need
  // bid_qty >= 2^k * ask_qty and ask_qty >= 2^k * bid_qty at once.
  logic prev_buy, prev_sell;

  wire fire_buy  = s1_valid && s1_buy  && !prev_buy;
  wire fire_sell = s1_valid && s1_sell && !prev_sell;

  wire signed [31:0] qty_s   = fire_buy ? signed'(s1_buy_qty) : signed'(s1_sell_qty);
  wire signed [31:0] pos_new = fire_buy ? (position + qty_s) : (position - qty_s);
  wire pos_ok      = (pos_new <= signed'(cfg_pos_limit)) &&
                     (pos_new >= -signed'(cfg_pos_limit));
  wire inflight_ok = (inflight < cfg_max_inflight);

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      o_valid          <= 1'b0;
      prev_buy         <= 1'b0;
      prev_sell        <= 1'b0;
      position         <= '0;
      inflight         <= '0;
      sent_cnt         <= '0;
      blk_pos_cnt      <= '0;
      blk_inflight_cnt <= '0;
      blk_txfull_cnt   <= '0;
    end else begin
      o_valid <= 1'b0;

      // an ack retires one order; it is applied before this cycle's decision,
      // which is what lets the golden model acks by record index
      if (i_ack && (inflight != 0)) inflight <= inflight - 1'b1;

      if (s1_valid) begin
        prev_buy  <= s1_buy;        // advances even when the gate blocks
        prev_sell <= s1_sell;
      end

      if (cfg_enable && (fire_buy || fire_sell)) begin
        if (!inflight_ok) begin
          blk_inflight_cnt <= blk_inflight_cnt + 1;
        end else if (!pos_ok) begin
          blk_pos_cnt <= blk_pos_cnt + 1;
        end else if (!o_ready) begin
          blk_txfull_cnt <= blk_txfull_cnt + 1;
        end else begin
          o_valid  <= 1'b1;
          o_ts     <= s1_ts;
          o_is_buy <= fire_buy;
          o_qty    <= fire_buy ? s1_buy_qty : s1_sell_qty;
          o_price  <= fire_buy ? s1_buy_px  : s1_sell_px;
          position <= pos_new;
          sent_cnt <= sent_cnt + 1;
          // an ack in the same cycle as a send leaves the count unchanged
          if (!(i_ack && (inflight != 0))) inflight <= inflight + 1'b1;
        end
      end
    end
  end

endmodule
