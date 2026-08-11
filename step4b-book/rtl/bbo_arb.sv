// Tagged BBO merge across symbols — step 4b.
//
// With NSYM tracked symbols there are NSYM price ladders, each with its own
// occupancy bitmaps and its own pipeline, and each emitting a BBO record when
// ITS book's top of book changes. This turns those NSYM independent streams
// into the one tagged stream the strategy consumes.
//
// WHY THE LADDERS CAN COLLIDE AT ALL, since they are fed from a single
// serialized delta FIFO. The demux hands each delta to the ladder that owns it
// and pops as soon as THAT ladder is ready, so a delta for symbol B is issued
// while symbol A's ladder is still working. That is deliberate -- the ladder is
// the slowest stage in the chain (5-7 cycles per delta against the order
// table's 2-3 per message), so serializing the ladders would divide the feed
// rate the design can absorb by NSYM. The price of that parallelism is that two
// ladders can finish on the same cycle, and one output port cannot carry both.
//
// WHAT IS AND IS NOT ORDERED, because this is the part that is easy to assume
// wrongly:
//
//   * PER SYMBOL, order is preserved exactly. One ladder is an in-order
//     pipeline and its records enter one queue and leave it in the same order.
//     This is the invariant the strategy depends on: its edge detector, its
//     latched BBO and its position are per-symbol, so per-symbol order is the
//     whole of what correctness needs.
//
//   * ACROSS SYMBOLS, order is NOT preserved, and no consumer may assume it.
//     Ladder pipelines are not fixed-length (a record that touches one level
//     skips a state that a two-level record does not), so symbol B's later
//     delta can produce an earlier record than symbol A's. The merged stream's
//     timestamps are therefore not monotonic. Nothing downstream compares
//     timestamps ACROSS symbols; a future consumer that wants to would need a
//     reorder buffer here, and would need to bound how long to wait for it.
//
// DEPTH. A ladder cannot produce two records closer together than its pipeline
// is long -- five cycles at the very least -- and the arbiter drains one record
// per cycle, so with NSYM <= DEPTH * 5 a queue can never be asked to hold more
// than DEPTH. DEPTH = 2 therefore covers every NSYM this design would build.
// The overflow is counted anyway: a dropped BBO record would otherwise be a
// silent hole in one symbol's stream, which is exactly the failure that a diff
// against a single-symbol golden is there to catch, and a counter says which.
//
// NSYM = 1 IS A WIRE. Not a one-deep queue that happens to be transparent -- a
// literal passthrough, so the record arrives on the cycle it always did. The
// strategy's sweep path reads a REGISTERED BBO, so inserting a cycle here would
// re-time sweep against imbalance and change which orders fire. Every existing
// golden is a single-symbol golden, so that has to cost nothing.
`timescale 1ns/1ps
module bbo_arb #(
  parameter int NSYM  = 1,
  parameter int SYMW  = (NSYM > 1) ? $clog2(NSYM) : 1,
  parameter int DEPTH = 2,
  // Payload width: ts(48) + has_bid + bid_px(32) + bid_qty(32)
  //                      + has_ask + ask_px(32) + ask_qty(32)
  parameter int BBOW  = 48 + 1 + 32 + 32 + 1 + 32 + 32
)(
  input  logic                clk,
  input  logic                rst_n,

  // one valid per symbol, payloads packed: symbol k is i_data[BBOW*k +: BBOW]
  input  logic [NSYM-1:0]      i_valid,
  input  logic [NSYM*BBOW-1:0] i_data,

  output logic                 o_valid,
  output logic [SYMW-1:0]      o_sym,
  output logic [BBOW-1:0]      o_data,

  output logic [31:0]          drop_cnt     // records lost to a full queue
);
  generate if (NSYM == 1) begin : g_one
    // The deployed design point. No queue, no arbiter, no added cycle.
    assign o_valid  = i_valid[0];
    assign o_sym    = '0;
    assign o_data   = i_data;
    assign drop_cnt = '0;

  end else begin : g_many
    localparam int PTRW = (DEPTH > 1) ? $clog2(DEPTH) : 1;

    logic [BBOW-1:0]  q     [NSYM][DEPTH];
    logic [PTRW:0]    wptr  [NSYM];
    logic [PTRW:0]    rptr  [NSYM];
    logic [NSYM-1:0]  ne;                       // queue k is non-empty
    logic [31:0]      drops;

    for (genvar k = 0; k < NSYM; k++) begin : g_ne
      assign ne[k] = (wptr[k] != rptr[k]);
    end

    // Round-robin over the non-empty queues, starting one past whoever went
    // last. Round-robin rather than a fixed priority because a fixed priority
    // starves the high-numbered symbols exactly when the feed is busiest, which
    // is when their BBO matters most.
    logic [SYMW-1:0] last, pick;
    logic            any;
    always_comb begin
      any  = 1'b0;
      pick = '0;
      for (int i = 1; i <= NSYM; i++) begin
        automatic int c = (int'(last) + i) % NSYM;
        if (!any && ne[c]) begin
          any  = 1'b1;
          pick = SYMW'(c);
        end
      end
    end

    always_ff @(posedge clk) begin
      if (!rst_n) begin
        for (int k = 0; k < NSYM; k++) begin
          wptr[k] <= '0;
          rptr[k] <= '0;
        end
        last    <= '0;
        o_valid <= 1'b0;
        drops   <= '0;
      end else begin
        // writes: one per symbol per cycle, independent of the read. The drop
        // count is accumulated into a local first and added once -- NSYM
        // separate `drops <= drops + 1` statements in a loop are NSYM
        // assignments to the same flop, and only the last would survive, so two
        // symbols overflowing on one cycle would count as one.
        begin
          automatic int ndrop = 0;
          for (int k = 0; k < NSYM; k++) begin
            if (i_valid[k]) begin
              // full when the pointers differ only in their wrap bit
              if ((wptr[k] - rptr[k]) == (PTRW+1)'(DEPTH)) begin
                ndrop++;
              end else begin
                q[k][wptr[k][PTRW-1:0]] <= i_data[BBOW*k +: BBOW];
                wptr[k] <= wptr[k] + 1'b1;
              end
            end
          end
          if (ndrop != 0) drops <= drops + 32'(ndrop);
        end

        // read: at most one record leaves per cycle
        o_valid <= any;
        if (any) begin
          o_sym      <= pick;
          o_data     <= q[pick][rptr[pick][PTRW-1:0]];
          rptr[pick] <= rptr[pick] + 1'b1;
          last       <= pick;
        end
      end
    end

    assign drop_cnt = drops;
  end endgenerate

endmodule
