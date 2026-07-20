// Price ladder / top-of-book — step 4b. Consumes order_table's book-delta
// stream (rem/add price levels on one side) and maintains an L2 book: one
// aggregated qty per price level per side. Emits BBO (best bid / best ask
// price+qty) whenever it changes — the step-1 golden's BBO sequence.
//
// Price -> level index: idx = (price - BASE)/TICK. TICK is a compile-time
// constant so the divide degrades to a multiply-shift in synthesis. A fixed
// band of LEVELS levels covers the tracked symbol's day range; a price
// outside the band is dropped and counted (oob_cnt) — re-centering is the
// low-frequency path deferred per PLAN §2.1, and oob_cnt==0 confirms the band
// is wide enough for the run.
//
// Best bid = highest occupied level, best ask = lowest — found by a priority
// scan over the per-side occupancy bitmap (registers, so the scan is
// combinational). Correctness-first: qty is an async-read array and each
// record takes a few cycles (rem, add, evaluate). The input rate (one record
// per several cycles out of the order table) leaves ample budget.
`timescale 1ns/1ps
module price_ladder #(
  parameter int LEVELS = 4096,                    // 12-bit band
  parameter int TICK   = 100                      // $0.01 in 1e-4 units
)(
  input  logic         clk,
  input  logic         rst_n,

  input  logic [31:0]  cfg_base,    // band start price; software sets per symbol
                                     // (also the re-centering hook, PLAN §2.1)

  input  logic         i_valid,
  input  logic [47:0]  i_ts,
  input  logic [7:0]   i_side,      // 'B' bid / 'S' ask
  input  logic         i_has_rem,
  input  logic [31:0]  i_rem_price,
  input  logic [31:0]  i_rem_qty,
  input  logic         i_has_add,
  input  logic [31:0]  i_add_price,
  input  logic [31:0]  i_add_qty,
  output logic         i_ready,

  output logic         o_valid,     // BBO changed
  output logic [47:0]  o_ts,
  output logic         o_has_bid,
  output logic [31:0]  o_bid_price,
  output logic [31:0]  o_bid_qty,
  output logic         o_has_ask,
  output logic [31:0]  o_ask_price,
  output logic [31:0]  o_ask_qty,

  output logic [31:0]  oob_cnt      // prices outside the band (dropped)
);
  localparam int LEVW = $clog2(LEVELS);

  logic [31:0] bidq [LEVELS];
  logic [31:0] askq [LEVELS];
  logic [LEVELS-1:0] bidocc, askocc;
  initial begin
    for (int i = 0; i < LEVELS; i++) begin bidq[i] = '0; askq[i] = '0; end
  end

  // cfg_base is only read in procedural (always_ff) contexts below, so these
  // function-of-a-module-signal calls are safe (unlike in a continuous assign).
  function automatic logic in_band(input logic [31:0] price);
    return (price >= cfg_base) && (((price - cfg_base) / TICK) < LEVELS);
  endfunction
  function automatic logic [LEVW-1:0] to_idx(input logic [31:0] price);
    return (price - cfg_base) / TICK;
  endfunction
  function automatic logic [31:0] to_price(input logic [LEVW-1:0] idx);
    return cfg_base + 32'(idx) * TICK;
  endfunction

  // ---- combinational best-of-book from the occupancy bitmaps ----
  logic            has_bid, has_ask;
  logic [LEVW-1:0] bbi, bai;
  always_comb begin
    has_bid = 1'b0; bbi = '0;
    for (int i = 0; i < LEVELS; i++) if (bidocc[i]) begin has_bid = 1'b1; bbi = i[LEVW-1:0]; end
    has_ask = 1'b0; bai = '0;
    for (int i = LEVELS-1; i >= 0; i--) if (askocc[i]) begin has_ask = 1'b1; bai = i[LEVW-1:0]; end
  end

  typedef enum logic [1:0] { IDLE, REM, ADD, EVAL } state_t;
  state_t state;

  logic [47:0]     r_ts;
  logic [7:0]      r_side;
  logic            r_has_add;
  logic [31:0]     r_add_price, r_add_qty;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state   <= IDLE;
      o_valid <= 1'b0;
      oob_cnt <= '0;
      bidocc  <= '0;
      askocc  <= '0;
      o_has_bid <= 1'b0; o_bid_price <= '0; o_bid_qty <= '0;
      o_has_ask <= 1'b0; o_ask_price <= '0; o_ask_qty <= '0;
    end else begin
      o_valid <= 1'b0;

      unique case (state)
        IDLE: begin
          if (i_valid) begin
            r_ts        <= i_ts;
            r_side      <= i_side;
            r_has_add   <= i_has_add;
            r_add_price <= i_add_price;
            r_add_qty   <= i_add_qty;
            // remove first (if any), then add
            if (i_has_rem) begin
              if (in_band(i_rem_price)) begin
                automatic logic [LEVW-1:0] idx = to_idx(i_rem_price);
                if (i_side == "B") begin
                  automatic logic [31:0] nv = (bidq[idx] > i_rem_qty) ? bidq[idx] - i_rem_qty : 32'd0;
                  bidq[idx] <= nv; bidocc[idx] <= (nv != 0);
                end else begin
                  automatic logic [31:0] nv = (askq[idx] > i_rem_qty) ? askq[idx] - i_rem_qty : 32'd0;
                  askq[idx] <= nv; askocc[idx] <= (nv != 0);
                end
              end else oob_cnt <= oob_cnt + 1;
            end
            state <= ADD;
          end
        end

        ADD: begin
          if (r_has_add) begin
            if (in_band(r_add_price)) begin
              automatic logic [LEVW-1:0] idx = to_idx(r_add_price);
              if (r_side == "B") begin
                automatic logic [31:0] nv = bidq[idx] + r_add_qty;
                bidq[idx] <= nv; bidocc[idx] <= 1'b1;
              end else begin
                automatic logic [31:0] nv = askq[idx] + r_add_qty;
                askq[idx] <= nv; askocc[idx] <= 1'b1;
              end
            end else oob_cnt <= oob_cnt + 1;
          end
          state <= EVAL;
        end

        EVAL: begin
          // occupancy settled; read best qty (async) and emit BBO on change
          automatic logic        nb  = has_bid;
          automatic logic [31:0] nbp = has_bid ? to_price(bbi) : 32'd0;
          automatic logic [31:0] nbq = has_bid ? bidq[bbi] : 32'd0;
          automatic logic        na  = has_ask;
          automatic logic [31:0] nap = has_ask ? to_price(bai) : 32'd0;
          automatic logic [31:0] naq = has_ask ? askq[bai] : 32'd0;
          if (nb != o_has_bid || nbp != o_bid_price || nbq != o_bid_qty ||
              na != o_has_ask || nap != o_ask_price || naq != o_ask_qty) begin
            o_valid <= 1'b1; o_ts <= r_ts;
            o_has_bid <= nb; o_bid_price <= nbp; o_bid_qty <= nbq;
            o_has_ask <= na; o_ask_price <= nap; o_ask_qty <= naq;
          end
          state <= IDLE;
        end

        default: state <= IDLE;
      endcase
    end
  end

  assign i_ready = (state == IDLE);

endmodule
