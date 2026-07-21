// Price ladder / top-of-book — step 4b. Consumes order_table's book-delta
// stream (rem/add price levels on one side) and maintains an L2 book: one
// aggregated qty per price level per side. Emits BBO (best bid / best ask
// price+qty) whenever it changes — the step-1 golden's BBO sequence.
//
// Price -> level index: idx = (price - base)/TICK. TICK is a compile-time
// constant so the divide degrades to a multiply-shift in synthesis. A fixed
// band of LEVELS levels covers the tracked symbol's day range; a price
// outside the band is dropped and counted (oob_cnt) — re-centering is the
// low-frequency path deferred per PLAN §2.1, and the BBO diff is what proves
// the band is wide enough (an out-of-band price that should have been the
// inside market would fail it).
//
// Quantities live in memories read SYNCHRONOUSLY. Asynchronous reads are what
// force distributed RAM: measured, the ladder burned 15 k LUTRAMs and helped
// put a one-cycle FIFO-read -> divide -> occupancy-update path on the critical
// path (step5-board/README.md). Each record therefore walks a short pipeline:
//   IDLE  latch, issue read of the first touched level
//   S_REM apply the removal, issue read of the added level
//   S_ADD apply the addition (forwarded if it is the same level)
//   S_BQ  occupancy settled -> resolve the best levels into registers
//   S_RDQ issue the reads of those two levels from the registered indices
//   S_PX  index -> price, quantities land
//   S_OUT compare against the current BBO, emit if it changed
// Best bid/ask come from a two-level priority scan over the per-side occupancy
// bitmaps. That scan gets its own cycle and ends at a flop: letting it reach
// the quantity memory's address pins in the same cycle was the design's worst
// post-route path (see the read-address mux below).
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

  // `base` is an explicit argument, never read as a module signal from inside
  // a function: a function that closes over a module signal has no sensitivity
  // to it in a continuous assign, which silently pins the result at X under
  // xsim (the step-3b bug). Passing it keeps every caller correct.
  // Band check needs no division: (price-base)/TICK < LEVELS is the same as
  // (price-base) < LEVELS*TICK, and that bound is a compile-time constant.
  // It also means an in-band difference fits in BANDW bits, so the divide that
  // does produce the index only has to be BANDW wide instead of 32.
  localparam int BANDW = $clog2(LEVELS * TICK);
  function automatic logic in_band(input logic [31:0] price, input logic [31:0] base);
    return (price >= base) && ((price - base) < (LEVELS * TICK));
  endfunction
  function automatic logic [BANDW-1:0] to_diff(input logic [31:0] price, input logic [31:0] base);
    return (price - base);
  endfunction
  function automatic logic [LEVW-1:0] div_tick(input logic [BANDW-1:0] diff);
    return diff / TICK;
  endfunction
  function automatic logic [31:0] to_price(input logic [LEVW-1:0] idx, input logic [31:0] base);
    return base + 32'(idx) * TICK;
  endfunction

  // ---- quantity storage: 1 write port + 1 registered read port per side ----
  logic [31:0] bidq [LEVELS];
  logic [31:0] askq [LEVELS];
  initial for (int i = 0; i < LEVELS; i++) begin bidq[i] = '0; askq[i] = '0; end

  logic [LEVW-1:0] bq_raddr, aq_raddr;
  logic [31:0]     bq_rdata, aq_rdata;
  logic            bq_we,    aq_we;
  logic [LEVW-1:0] bq_waddr, aq_waddr;
  logic [31:0]     bq_wdata, aq_wdata;

  always_ff @(posedge clk) begin
    bq_rdata <= bidq[bq_raddr];
    if (bq_we) bidq[bq_waddr] <= bq_wdata;
    aq_rdata <= askq[aq_raddr];
    if (aq_we) askq[aq_waddr] <= aq_wdata;
  end

  // ---- occupancy, with a per-group summary for a two-level best scan ----
  // A flat priority scan over all LEVELS bits is a LEVELS-deep chain: it was
  // the dominant timing path and made synthesis take ~40 min. Instead the
  // bitmap is cut into NGRP groups of GRP levels and a registered `gany` bit
  // per group says whether that group holds anything. Finding the best level
  // is then two small encodes (group, then bit within the group) instead of
  // one huge one, and the group OR-reduce is off the critical path because it
  // is computed when the bit is written, not when the best is read.
  localparam int GRP  = 64;
  localparam int NGRP = LEVELS / GRP;
  localparam int GRPW = $clog2(GRP);
  localparam int NGW  = $clog2(NGRP);

  logic [LEVELS-1:0] bidocc, askocc;
  logic [NGRP-1:0]   bid_gany, ask_gany;

  function automatic logic [GRPW-1:0] hi_in_grp(input logic [GRP-1:0] v);
    hi_in_grp = '0;
    for (int i = 0; i < GRP; i++) if (v[i]) hi_in_grp = i[GRPW-1:0];
  endfunction
  function automatic logic [GRPW-1:0] lo_in_grp(input logic [GRP-1:0] v);
    lo_in_grp = '0;
    for (int i = GRP-1; i >= 0; i--) if (v[i]) lo_in_grp = i[GRPW-1:0];
  endfunction
  function automatic logic [NGW-1:0] hi_grp(input logic [NGRP-1:0] v);
    hi_grp = '0;
    for (int i = 0; i < NGRP; i++) if (v[i]) hi_grp = i[NGW-1:0];
  endfunction
  function automatic logic [NGW-1:0] lo_grp(input logic [NGRP-1:0] v);
    lo_grp = '0;
    for (int i = NGRP-1; i >= 0; i--) if (v[i]) lo_grp = i[NGW-1:0];
  endfunction

  // group-occupancy after writing one bit — evaluated at write time
  function automatic logic gany_after(input logic [LEVELS-1:0] occ,
                                      input logic [LEVW-1:0]   idx,
                                      input logic              bit_val);
    automatic logic [NGW-1:0] g = idx[LEVW-1:GRPW];
    automatic logic [GRP-1:0] w = occ[g*GRP +: GRP];
    w[idx[GRPW-1:0]] = bit_val;
    return |w;
  endfunction

  // ---- best-of-book: two-level scan ----
  logic            has_bid, has_ask;
  logic [LEVW-1:0] bbi, bai;
  always_comb begin
    automatic logic [NGW-1:0] gb, ga;
    has_bid = |bid_gany;
    gb      = hi_grp(bid_gany);
    bbi     = {gb, hi_in_grp(bidocc[gb*GRP +: GRP])};
    has_ask = |ask_gany;
    ga      = lo_grp(ask_gany);
    bai     = {ga, lo_in_grp(askocc[ga*GRP +: GRP])};
  end

  typedef enum logic [3:0] { IDLE, S_SUB, S_IDX, S_RD, S_REM, S_ADD, S_BQ, S_RDQ, S_PX, S_OUT } state_t;
  state_t state;

  // best-of-book resolved in stages so no single cycle carries
  // encode -> part-select -> encode -> price arithmetic -> compare.
  // S_BQ registers the index, S_PX the price and quantity, S_OUT only compares.
  logic            q_has_bid, q_has_ask;
  logic [LEVW-1:0] q_bbi, q_bai;
  logic [31:0]     q_bid_price, q_bid_qty, q_ask_price, q_ask_qty;

  // latched record
  logic [47:0]     r_ts;
  logic            r_is_bid;
  logic            r_rem_ok, r_add_ok;
  logic [LEVW-1:0] r_rem_idx, r_add_idx;
  logic [31:0]     r_rem_qty, r_add_qty;
  logic            r_fwd;             // add level == rem level
  logic [31:0]     r_rem_new;         // qty written by the removal step

  // raw record, captured straight off the input before any arithmetic
  logic [31:0] r_rem_price, r_add_price;
  logic        r_has_rem,   r_has_add;
  logic [BANDW-1:0] r_rem_diff, r_add_diff;

  // ---- read address muxing ----
  // EVERY address driven here comes from a register — including the best-level
  // probe, which is the point of q_bbi/q_bai. An earlier version used the raw
  // combinational `bbi`/`bai` as the default address, so the two-level scan
  // (gany encode -> part-select -> in-group encode) drove the quantity memory's
  // address pins directly. Post-route that was the worst path in the whole
  // design: bid_gany_reg -> bidq URAM ADDR_A, 15 logic levels, 1.458 ns of
  // logic against 4.014 ns of route. URAM sites are fixed, so logic feeding
  // their address pins gets stretched across the die; the fix is to hand the
  // pins a flop output and let the scan have its own cycle (S_BQ).
  always_comb begin
    bq_raddr = q_bbi;                  // default: probe the best levels
    aq_raddr = q_bai;
    unique case (state)
      S_RD:  if (r_is_bid) bq_raddr = r_rem_ok ? r_rem_idx : r_add_idx;
             else          aq_raddr = r_rem_ok ? r_rem_idx : r_add_idx;
      S_REM: if (r_is_bid) bq_raddr = r_add_idx; else aq_raddr = r_add_idx;
      default: ;                       // S_RDQ takes the best-level probe
    endcase
  end

  // ---- write port ----
  logic [31:0] rem_new, add_cur, add_new;
  always_comb begin
    rem_new = '0; add_cur = '0; add_new = '0;
    bq_we = 1'b0; bq_waddr = '0; bq_wdata = '0;
    aq_we = 1'b0; aq_waddr = '0; aq_wdata = '0;
    unique case (state)
      S_REM: if (r_rem_ok) begin
        automatic logic [31:0] cur = r_is_bid ? bq_rdata : aq_rdata;
        rem_new = (cur > r_rem_qty) ? (cur - r_rem_qty) : 32'd0;
        if (r_is_bid) begin bq_we = 1'b1; bq_waddr = r_rem_idx; bq_wdata = rem_new; end
        else          begin aq_we = 1'b1; aq_waddr = r_rem_idx; aq_wdata = rem_new; end
      end
      S_ADD: if (r_add_ok) begin
        // the removal's write is still in flight when this level was read, so
        // forward it when both steps touch the same level
        add_cur = r_fwd ? r_rem_new : (r_is_bid ? bq_rdata : aq_rdata);
        add_new = add_cur + r_add_qty;
        if (r_is_bid) begin bq_we = 1'b1; bq_waddr = r_add_idx; bq_wdata = add_new; end
        else          begin aq_we = 1'b1; aq_waddr = r_add_idx; aq_wdata = add_new; end
      end
      default: ;
    endcase
  end

  assign i_ready = (state == IDLE);

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state     <= IDLE;
      o_valid   <= 1'b0;
      oob_cnt   <= '0;
      bidocc    <= '0;
      askocc    <= '0;
      bid_gany  <= '0;
      ask_gany  <= '0;
      o_has_bid <= 1'b0; o_bid_price <= '0; o_bid_qty <= '0;
      o_has_ask <= 1'b0; o_ask_price <= '0; o_ask_qty <= '0;
    end else begin
      o_valid <= 1'b0;

      unique case (state)
        // capture the record only — no arithmetic on the FIFO's output
        IDLE: if (i_valid) begin
          r_ts        <= i_ts;
          r_is_bid    <= (i_side == "B");
          r_has_rem   <= i_has_rem;   r_rem_price <= i_rem_price; r_rem_qty <= i_rem_qty;
          r_has_add   <= i_has_add;   r_add_price <= i_add_price; r_add_qty <= i_add_qty;
          state <= S_SUB;
        end

        // subtract the band base and range-check — no division here
        S_SUB: begin
          automatic logic ok_r = r_has_rem && in_band(r_rem_price, cfg_base);
          automatic logic ok_a = r_has_add && in_band(r_add_price, cfg_base);
          r_rem_ok   <= ok_r;  r_rem_diff <= to_diff(r_rem_price, cfg_base);
          r_add_ok   <= ok_a;  r_add_diff <= to_diff(r_add_price, cfg_base);
          if (r_has_rem && !ok_r) oob_cnt <= oob_cnt + 1;
          if (r_has_add && !ok_a) oob_cnt <= oob_cnt + 1;
          state <= S_IDX;
        end

        // the divide, on the narrowed difference, alone in its cycle
        S_IDX: begin
          automatic logic [LEVW-1:0] ix_r = div_tick(r_rem_diff);
          automatic logic [LEVW-1:0] ix_a = div_tick(r_add_diff);
          r_rem_idx <= ix_r;
          r_add_idx <= ix_a;
          r_fwd     <= r_rem_ok && r_add_ok && (ix_r == ix_a);
          state <= S_RD;
        end

        // issue the first read from the registered index
        S_RD: state <= S_REM;

        S_REM: begin
          if (r_rem_ok) begin
            automatic logic nz = (rem_new != 0);
            r_rem_new <= rem_new;
            if (r_is_bid) begin
              bidocc[r_rem_idx] <= nz;
              bid_gany[r_rem_idx[LEVW-1:GRPW]] <= gany_after(bidocc, r_rem_idx, nz);
            end else begin
              askocc[r_rem_idx] <= nz;
              ask_gany[r_rem_idx[LEVW-1:GRPW]] <= gany_after(askocc, r_rem_idx, nz);
            end
          end
          state <= S_ADD;
        end

        // bidocc/askocc already reflect S_REM's write here, so the group
        // summary stays correct even when both steps hit the same group
        S_ADD: begin
          if (r_add_ok) begin
            if (r_is_bid) begin
              bidocc[r_add_idx] <= 1'b1;
              bid_gany[r_add_idx[LEVW-1:GRPW]] <= 1'b1;
            end else begin
              askocc[r_add_idx] <= 1'b1;
              ask_gany[r_add_idx[LEVW-1:GRPW]] <= 1'b1;
            end
          end
          state <= S_BQ;
        end

        // occupancy has settled: resolve the best levels. Only the two-level
        // encode lands in this cycle — it ends at a flop, not at a memory.
        S_BQ: begin
          q_has_bid <= has_bid; q_bbi <= bbi;
          q_has_ask <= has_ask; q_bai <= bai;
          state <= S_RDQ;
        end

        // the quantity reads, issued from the registered best indices
        S_RDQ: state <= S_PX;

        // index -> price, and the quantities read in S_BQ land here
        S_PX: begin
          q_bid_price <= q_has_bid ? to_price(q_bbi, cfg_base) : 32'd0;
          q_bid_qty   <= q_has_bid ? bq_rdata : 32'd0;
          q_ask_price <= q_has_ask ? to_price(q_bai, cfg_base) : 32'd0;
          q_ask_qty   <= q_has_ask ? aq_rdata : 32'd0;
          state <= S_OUT;
        end

        // nothing left but the comparison against the current BBO
        S_OUT: begin
          if (q_has_bid != o_has_bid || q_bid_price != o_bid_price || q_bid_qty != o_bid_qty ||
              q_has_ask != o_has_ask || q_ask_price != o_ask_price || q_ask_qty != o_ask_qty) begin
            o_valid   <= 1'b1; o_ts <= r_ts;
            o_has_bid <= q_has_bid; o_bid_price <= q_bid_price; o_bid_qty <= q_bid_qty;
            o_has_ask <= q_has_ask; o_ask_price <= q_ask_price; o_ask_qty <= q_ask_qty;
          end
          state <= IDLE;
        end

        default: state <= IDLE;
      endcase
    end
  end

endmodule
