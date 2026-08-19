// Feed-handler core — step 5 board integration.
//
// The whole parse -> order-book chain wired at CMAC width (512-bit), ready to
// sit behind a 100G MAC + UDP/IP front end. Input is a stream of MoldUDP64
// payload beats; output is the BBO stream plus a status block.
//
//   in(512b) -> [beat FIFO] -> mold_splitter -> itch_decoder
//            -> [msg FIFO]  -> order_table   -> [delta FIFO] -> price_ladder -> BBO
//
// Why the FIFOs: at CMAC width the splitter sustains 1 msg/cycle, but the
// order table is a correctness-first FSM (2 cy/msg, 3 for 'U') and the ladder
// takes 3 cy/record. The 64-bit testbenches never exposed this because the
// decoder was the bottleneck there; at 512-bit the producer is faster than the
// consumers, so every no-backpressure boundary gets an elastic FIFO that drops
// and counts on overflow rather than stalling the wire. The drop counters and
// high-water marks are the evidence for whether the depths are right — see the
// step-5 README for measured level_max on a real replay.
//
// Config (software-set, shadow/commit is the front end's job):
//   track_locate — the symbols whose orders enter the table, packed 16 bits per
//                  symbol; symbol k is track_locate[16*k +: 16]
//   cfg_base     — price-ladder band start, packed 32 bits per symbol, because
//                  the band is per-name: two stocks do not trade near the same
//                  price and one shared base would put one of them out of band
//
// MULTI-SYMBOL (NSYM > 1). One order table holds every tracked name (it is set-
// associative on order_ref, which is unique across symbols, so sharing costs
// only capacity -- FINDINGS §4.4 sizes it). Everything downstream of the table
// is PER SYMBOL and replicated: a book is a book of one instrument, so there is
// nothing for K names to share in a price ladder, a fast-BBO tracker or a sweep
// detector. The delta stream is demultiplexed by the table's o_sym, the K BBO
// streams are merged back into one tagged stream by bbo_arb, and the sweep
// pulses are merged the same way. NSYM = 1 collapses every generate here to
// exactly the single-symbol structure that shipped, wire for wire.
`timescale 1ns/1ps
module fh_core
  import itch5_pkg::*;
#(
  parameter int DATA_W      = 512,
  parameter int BEAT_FIFO   = 512,   // 512b payload beats
  parameter int MSG_FIFO    = 512,   // decoded messages
  parameter int DELTA_FIFO  = 512,   // book deltas
  parameter int OT_SETS_BITS = 13,   // see order_table: cascade depth, not size
  parameter int OT_WAYS      = 16,
  parameter int PL_LEVELS    = 4096,
  parameter int PL_TICK      = 100,
  parameter bit USE_FAST_BBO = 1,    // 0 = ladder only, the pre-integration path
  // Decode the splitter's beat combinationally rather than the cycle after it
  // (itch_decoder.sv). One core cycle off every message, paid for in
  // combinational depth ahead of a register in this domain -- off until a
  // directive sweep prices it.
  parameter bit CUT_THROUGH  = 1,
  // Tracked symbols. Moves together with OT_SETS_BITS -- see order_table, and
  // FINDINGS §4.4 for the measured zero-overflow geometry at each K.
  parameter int NSYM         = 1,
  parameter int SYMW         = (NSYM > 1) ? $clog2(NSYM) : 1
)(
  input  logic                clk,
  input  logic                rst_n,

  // config, packed per symbol (symbol k is [W*k +: W]) -- the shape every
  // wrapper on the way up to the register file already uses
  input  logic [NSYM*16-1:0]  track_locate,
  input  logic [NSYM*32-1:0]  cfg_base,

  // MoldUDP64 payload beats from the UDP/IP front end (no backpressure)
  input  logic [DATA_W-1:0]   s_tdata,
  input  logic [DATA_W/8-1:0] s_tkeep,
  input  logic                s_tvalid,
  input  logic                s_tlast,

  // BBO stream, tagged. bbo_sym says whose book moved; per-symbol order is
  // preserved and cross-symbol order is not (bbo_arb's header says why).
  output logic                bbo_valid,
  output logic [SYMW-1:0]     bbo_sym,
  output logic [47:0]         bbo_ts,
  output logic                bbo_has_bid,
  output logic [31:0]         bbo_bid_price,
  output logic [31:0]         bbo_bid_qty,
  output logic                bbo_has_ask,
  output logic [31:0]         bbo_ask_price,
  output logic [31:0]         bbo_ask_qty,

  // sweep / momentum-ignition trigger, tapped off the order-table delta stream.
  // Per symbol, because a sweep is a run of same-direction executions in ONE
  // book: interleaving two names into one detector would break runs that are
  // continuing and join runs that are not.
  input  logic [31:0]         cfg_sweep_min_levels,
  input  logic [47:0]         cfg_sweep_gap,
  output logic                o_sweep,
  output logic [SYMW-1:0]     o_sweep_sym,
  output logic                o_sweep_is_buy,
  output logic [31:0]         st_sweep_cnt,

  // sequence / integrity events from the splitter
  output logic                ev_gap,
  output logic                ev_hb,
  output logic                ev_eos,
  output logic [63:0]         ev_seq,
  output logic [63:0]         ev_expected,

  // status block (all free-running counters)
  output logic                init_done,     // order table's clear sweep is done
  output logic [31:0]         st_gap_total,
  output logic [31:0]         st_dup_cnt,
  output logic [31:0]         st_frame_err,
  output logic [31:0]         st_ot_overflow,
  output logic [31:0]         st_ot_miss,
  output logic [31:0]         st_pl_oob,
  output logic [31:0]         st_beat_drop,
  output logic [31:0]         st_msg_drop,
  output logic [31:0]         st_delta_drop,
  output logic [$clog2(BEAT_FIFO):0]  st_beat_level_max,
  output logic [$clog2(MSG_FIFO):0]   st_msg_level_max,
  output logic [$clog2(DELTA_FIFO):0] st_delta_level_max,

  // ---- fast top-of-book: how the emitted BBO records were answered ----
  // early + late is the whole BBO stream. Their ratio is the realized saving,
  // which is lower than fast_bbo's own certain/defer split because a record
  // following a deferral waits for it. st_bbo_mismatch must read zero: it counts
  // the ladder contradicting an early answer, which fast_bbo's contract forbids.
  output logic [31:0]                 st_bbo_early,
  output logic [31:0]                 st_bbo_late,
  output logic [31:0]                 st_bbo_mismatch,
  // BBO records lost because a symbol's merge queue was full. Zero by
  // construction at every NSYM this design would build (bbo_arb's header does
  // the arithmetic); counted because the alternative is a silent hole in one
  // symbol's stream.
  output logic [31:0]                 st_bbo_arb_drop,

  // ---- observation tap: a decoded message, and its ITCH timestamp ----
  // Read-only, drives nothing inside this module. It exists so a latency probe
  // can note WHEN a message entered the queueing part of the machine; the
  // message's identity is already carried to the far end as strategy.o_ts, so
  // the pair is enough to measure latency under load without threading a tag
  // through every stage. Adding an output cannot change behaviour, which is the
  // point -- this module is verified and stays that way.
  output logic                        o_dec_valid,
  output logic [47:0]                 o_dec_ts
);
  localparam int KEEP_W = DATA_W/8;

  // ---------------- input beat FIFO ----------------
  logic                  bf_pop_valid, bf_pop_ready;
  logic [DATA_W+KEEP_W:0] bf_pop_data;
  logic [$clog2(BEAT_FIFO):0] bf_level;

  drop_fifo #(.WIDTH(DATA_W+KEEP_W+1), .DEPTH(BEAT_FIFO)) u_beat_fifo (
    .clk(clk), .rst_n(rst_n),
    .push_valid(s_tvalid), .push_data({s_tlast, s_tkeep, s_tdata}),
    .pop_valid(bf_pop_valid), .pop_data(bf_pop_data), .pop_ready(bf_pop_ready),
    .drop_cnt(st_beat_drop), .level(bf_level), .level_max(st_beat_level_max)
  );

  // ---------------- MoldUDP64 splitter (512b realignment) ----------------
  logic [DATA_W-1:0]  sp_tdata;
  logic [KEEP_W-1:0]  sp_tkeep;
  logic               sp_tvalid, sp_tlast;

  mold_splitter #(.DATA_W(DATA_W)) u_split (
    .clk(clk), .rst_n(rst_n),
    .s_tdata (bf_pop_data[DATA_W-1:0]),
    .s_tkeep (bf_pop_data[DATA_W+KEEP_W-1:DATA_W]),
    .s_tvalid(bf_pop_valid),
    .s_tlast (bf_pop_data[DATA_W+KEEP_W]),
    .s_tready(bf_pop_ready),
    .m_tdata(sp_tdata), .m_tkeep(sp_tkeep), .m_tvalid(sp_tvalid), .m_tlast(sp_tlast),
    .ev_gap(ev_gap), .ev_hb(ev_hb), .ev_eos(ev_eos),
    .ev_seq(ev_seq), .ev_expected(ev_expected),
    .gap_total(st_gap_total), .dup_cnt(st_dup_cnt), .frame_err_cnt(st_frame_err)
  );

  // ---------------- ITCH decoder (one message per beat at 512b) ------------
  itch_msg_t dec_msg;
  logic      dec_valid, dec_len_err, dec_ready_unused;

  itch_decoder #(.DATA_W(DATA_W), .CUT_THROUGH(CUT_THROUGH)) u_dec (
    .clk(clk), .rst_n(rst_n),
    .s_tdata(sp_tdata), .s_tkeep(sp_tkeep), .s_tvalid(sp_tvalid), .s_tlast(sp_tlast),
    .s_tready(dec_ready_unused),
    .m_msg(dec_msg), .m_valid(dec_valid), .m_len_err(dec_len_err)
  );

  // observation tap (see the port declaration): the decoder's output is where
  // queueing begins -- the message FIFO is immediately downstream.
  assign o_dec_valid = dec_valid;
  assign o_dec_ts    = dec_msg.timestamp;

  // ---------------- message FIFO -> order table ----------------
  localparam int MSGW = $bits(itch_msg_t);
  logic            mf_pop_valid, mf_pop_ready;
  logic [MSGW-1:0] mf_pop_data;
  logic [$clog2(MSG_FIFO):0] mf_level;

  drop_fifo #(.WIDTH(MSGW), .DEPTH(MSG_FIFO)) u_msg_fifo (
    .clk(clk), .rst_n(rst_n),
    .push_valid(dec_valid), .push_data(dec_msg),
    .pop_valid(mf_pop_valid), .pop_data(mf_pop_data), .pop_ready(mf_pop_ready),
    .drop_cnt(st_msg_drop), .level(mf_level), .level_max(st_msg_level_max)
  );

  logic        ot_valid, ot_ready;
  logic [7:0]  ot_type, ot_side;
  logic [47:0] ot_ts;
  logic [15:0] ot_locate;
  logic [SYMW-1:0] ot_sym;          // which tracked book this delta belongs to
  logic        ot_has_rem, ot_has_add;
  logic [31:0] ot_rem_price, ot_rem_qty, ot_add_price, ot_add_qty;

  // Select the II=1 pipelined table with +define+OT_PIPE; both are verified
  // drop-ins with identical ports and byte-identical output (step4a).
`ifdef OT_PIPE
  order_table_pipe #(.SETS_BITS(OT_SETS_BITS), .WAYS(OT_WAYS), .NSYM(NSYM)) u_otab (
`else
  order_table #(.SETS_BITS(OT_SETS_BITS), .WAYS(OT_WAYS), .NSYM(NSYM)) u_otab (
`endif
    .clk(clk), .rst_n(rst_n), .track_locate(track_locate),
    .s_msg(itch_msg_t'(mf_pop_data)), .s_valid(mf_pop_valid), .s_ready(ot_ready),
    .o_valid(ot_valid), .o_type(ot_type), .o_ts(ot_ts),
    .o_locate(ot_locate), .o_side(ot_side), .o_sym(ot_sym),
    .o_has_rem(ot_has_rem), .o_rem_price(ot_rem_price), .o_rem_qty(ot_rem_qty),
    .o_has_add(ot_has_add), .o_add_price(ot_add_price), .o_add_qty(ot_add_qty),
    .init_done(init_done), .overflow_cnt(st_ot_overflow), .miss_cnt(st_ot_miss)
  );
  assign mf_pop_ready = ot_ready;

  // ---------------- sweep detector (taps the delta stream) ----------------
  // Runs directly off the order table's execution deltas, in parallel with the
  // delta FIFO that feeds the ladder. i_flush is tied low: on the wire a run
  // closes when the next execution breaks it, so no end-of-stream flush is
  // needed (a testbench drives one; there is always more feed here).
  //
  // One detector per symbol, each gated on the deltas that belong to it. A
  // shared detector would see two names' executions as one run: same-direction
  // executions in DIFFERENT books would extend a run that is not continuing,
  // and an execution in the other name would break one that is.
  //
  // The merge below needs no arbitration, and that is a property rather than an
  // assumption. o_sweep is only ever raised the cycle after `is_exec`, which
  // requires i_valid; the deltas are one serialized stream, so at most one
  // detector sees a delta on any cycle and at most one can fire on the next.
  logic [NSYM-1:0] sw_fire, sw_is_buy;
  logic [31:0]     sw_cnt [NSYM];

  for (genvar k = 0; k < NSYM; k++) begin : g_sweep
    sweep_detect u_sweep (
      .clk(clk), .rst_n(rst_n),
      .cfg_min_levels(cfg_sweep_min_levels), .cfg_gap(cfg_sweep_gap),
      .i_valid(ot_valid && (ot_sym == SYMW'(k))),
      .i_type(ot_type), .i_side(ot_side),
      .i_has_rem(ot_has_rem), .i_price(ot_rem_price), .i_qty(ot_rem_qty), .i_ts(ot_ts),
      .i_flush(1'b0),
      .o_sweep(sw_fire[k]), .o_is_buy(sw_is_buy[k]),
      .o_levels(), .o_shares(), .o_ts_end(),
      .sweep_cnt(sw_cnt[k])
    );
  end

  always_comb begin
    o_sweep      = |sw_fire;
    o_sweep_sym  = '0;
    o_sweep_is_buy = 1'b0;
    st_sweep_cnt = '0;
    for (int k = 0; k < NSYM; k++) begin
      if (sw_fire[k]) begin
        o_sweep_sym    = SYMW'(k);
        o_sweep_is_buy = sw_is_buy[k];
      end
      // the published count is the total across books, which is what the
      // single-symbol register meant and still means
      st_sweep_cnt = st_sweep_cnt + sw_cnt[k];
    end
  end

  // ---------------- delta FIFO -> price ladder ----------------
  // The record is 186 bits, plus the symbol index ABOVE it. Above rather than
  // interleaved so the field offsets the ladders slice out are the same numbers
  // they always were -- [185:138] is still the timestamp whatever NSYM is, and
  // at NSYM=1 the extra bit is a constant zero the synthesiser removes.
  // The tag rides the FIFO only when there is more than one book to tell apart.
  // At NSYM=1 SYMW is still 1 (a zero-width field cannot go in a packed vector),
  // so including it unconditionally widened a 512-deep FIFO by a bit for no
  // information -- and measurably: the single-symbol build lost 5.5 MHz across
  // the multi-symbol refactor, and this was the only change inside t2t_top that
  // added hardware rather than renaming it.
  localparam int SYMB = (NSYM > 1) ? SYMW : 0;
  localparam int DELW = 48 + 8 + 1 + 32 + 32 + 1 + 32 + 32 + SYMB;   // 186 + SYMB
  logic [DELW-1:0] df_push;
  localparam int   DELB = 48 + 8 + 1 + 32 + 32 + 1 + 32 + 32;   // the record itself
  wire [DELB-1:0]  df_rec = {ot_ts, ot_side, ot_has_rem, ot_rem_price, ot_rem_qty,
                             ot_has_add, ot_add_price, ot_add_qty};
  generate
    if (NSYM > 1) assign df_push = {ot_sym, df_rec};
    else          assign df_push = df_rec;
  endgenerate

  logic            df_pop_valid, df_pop_ready;
  logic [DELW-1:0] df_pop_data;
  logic [$clog2(DELTA_FIFO):0] df_level;

  drop_fifo #(.WIDTH(DELW), .DEPTH(DELTA_FIFO)) u_delta_fifo (
    .clk(clk), .rst_n(rst_n),
    .push_valid(ot_valid),
    .push_data(df_push),
    .pop_valid(df_pop_valid), .pop_data(df_pop_data), .pop_ready(df_pop_ready),
    .drop_cnt(st_delta_drop), .level(df_level), .level_max(st_delta_level_max)
  );

  // ---------------- delta demux -> K price ladders ----------------
  // The FIFO is popped when the ladder that OWNS the delta is ready, not when
  // all of them are. That is what makes the ladders parallel: a delta for
  // symbol B is issued while symbol A's ladder is still working, so K names
  // cost K times the ladder throughput rather than sharing one ladder's worth.
  // The ladder is the slowest stage in the chain (5-7 cycles per delta against
  // the order table's 2-3 per message), so this is the difference between K
  // symbols working and K symbols dropping deltas.
  //
  // The delta FIFO carries the symbol index alongside the record. It has to:
  // the demux reads it to route, and by then the order table has moved on.
  logic [SYMW-1:0] df_sym;
  // one book means every delta belongs to it, so there is no tag to read
  assign df_sym = (NSYM > 1) ? df_pop_data[DELW-1 -: SYMW] : '0;

  logic [NSYM-1:0]  lad_valid, lad_has_bid, lad_has_ask, lad_ready;
  logic [47:0]      lad_ts        [NSYM];
  logic [31:0]      lad_bid_price [NSYM], lad_bid_qty [NSYM];
  logic [31:0]      lad_ask_price [NSYM], lad_ask_qty [NSYM];
  logic [31:0]      lad_oob       [NSYM];

  // BBO stream out of each symbol's rejoin, packed for bbo_arb
  localparam int BBOW = 48 + 1 + 32 + 32 + 1 + 32 + 32;
  logic [NSYM-1:0]      sb_valid;
  logic [NSYM*BBOW-1:0] sb_data;
  logic [31:0]          sb_early [NSYM], sb_late [NSYM], sb_mismatch [NSYM];

  assign df_pop_ready = lad_ready[df_sym];

  for (genvar k = 0; k < NSYM; k++) begin : g_sym
    // this ladder's slice of the delta stream
    wire sel   = (df_sym == SYMW'(k));
    wire issue = df_pop_valid && sel;

    price_ladder #(.LEVELS(PL_LEVELS), .TICK(PL_TICK)) u_ladder (
      .clk(clk), .rst_n(rst_n),
      // the band is per symbol: two names do not trade near the same price
      .cfg_base   (cfg_base[32*k +: 32]),
      .i_valid    (issue),
      .i_ts       (df_pop_data[185:138]),
      .i_side     (df_pop_data[137:130]),
      .i_has_rem  (df_pop_data[129]),
      .i_rem_price(df_pop_data[128:97]),
      .i_rem_qty  (df_pop_data[96:65]),
      .i_has_add  (df_pop_data[64]),
      .i_add_price(df_pop_data[63:32]),
      .i_add_qty  (df_pop_data[31:0]),
      .i_ready    (lad_ready[k]),
      .o_valid(lad_valid[k]), .o_ts(lad_ts[k]),
      .o_has_bid(lad_has_bid[k]), .o_bid_price(lad_bid_price[k]),
      .o_bid_qty(lad_bid_qty[k]),
      .o_has_ask(lad_has_ask[k]), .o_ask_price(lad_ask_price[k]),
      .o_ask_qty(lad_ask_qty[k]),
      .oob_cnt(lad_oob[k])
    );

    // ---------------- fast top-of-book, and the rejoin ----------------
    // fast_bbo answers the common delta from two registers instead of a scan
    // over the occupancy bitmap; bbo_merge decides which answer reaches the
    // strategy and is where the ordering argument lives (see its header, and
    // step4b's README).
    //
    // i_valid is THIS ladder's ACCEPT, not the delta FIFO's output. Feeding the
    // fast path earlier would let it run ahead of a ladder still working on an
    // older delta, and a record that overtakes its predecessor moves the
    // strategy's rising edges -- different orders, same book. Gating on the
    // handshake keeps the two in lockstep, one delta apart at most, which is
    // what makes the rejoin a single comparison rather than a reorder buffer.
    // With K ladders the handshake is per ladder, which is the same argument
    // applied per book: the pair that must stay in step is this ladder and its
    // own fast path, and a delta for another symbol is not an event for either.
    //
    // USE_FAST_BBO = 0 restores the ladder as the only source, one parameter
    // away, for bisecting a golden diff that appears after this was wired in.
    logic        m_valid, m_has_bid, m_has_ask;
    logic [47:0] m_ts;
    logic [31:0] m_bid_price, m_bid_qty, m_ask_price, m_ask_qty;

    if (USE_FAST_BBO) begin : g_fast
      logic        fb_valid, fb_certain, fb_has_bid, fb_has_ask;
      logic [47:0] fb_ts;
      logic [31:0] fb_bid_price, fb_bid_qty, fb_ask_price, fb_ask_qty;

      fast_bbo u_fast (
        .clk(clk), .rst_n(rst_n),
        .i_valid    (issue && lad_ready[k]),
        .i_ts       (df_pop_data[185:138]),
        .i_side     (df_pop_data[137:130]),
        .i_has_rem  (df_pop_data[129]),
        .i_rem_price(df_pop_data[128:97]),
        .i_rem_qty  (df_pop_data[96:65]),
        .i_has_add  (df_pop_data[64]),
        .i_add_price(df_pop_data[63:32]),
        .i_add_qty  (df_pop_data[31:0]),
        .i_lad_valid(lad_valid[k]),
        .i_lad_has_bid(lad_has_bid[k]), .i_lad_bid_price(lad_bid_price[k]),
        .i_lad_bid_qty(lad_bid_qty[k]),
        .i_lad_has_ask(lad_has_ask[k]), .i_lad_ask_price(lad_ask_price[k]),
        .i_lad_ask_qty(lad_ask_qty[k]),
        .o_valid(fb_valid), .o_certain(fb_certain), .o_ts(fb_ts),
        .o_has_bid(fb_has_bid), .o_bid_price(fb_bid_price), .o_bid_qty(fb_bid_qty),
        .o_has_ask(fb_has_ask), .o_ask_price(fb_ask_price), .o_ask_qty(fb_ask_qty),
        .certain_cnt(), .defer_cnt()
      );

      bbo_merge u_merge (
        .clk(clk), .rst_n(rst_n),
        .i_fast_valid(fb_valid), .i_fast_certain(fb_certain), .i_fast_ts(fb_ts),
        .i_fast_has_bid(fb_has_bid), .i_fast_bid_price(fb_bid_price),
        .i_fast_bid_qty(fb_bid_qty),
        .i_fast_has_ask(fb_has_ask), .i_fast_ask_price(fb_ask_price),
        .i_fast_ask_qty(fb_ask_qty),
        .i_lad_valid(lad_valid[k]), .i_lad_ts(lad_ts[k]),
        .i_lad_has_bid(lad_has_bid[k]), .i_lad_bid_price(lad_bid_price[k]),
        .i_lad_bid_qty(lad_bid_qty[k]),
        .i_lad_has_ask(lad_has_ask[k]), .i_lad_ask_price(lad_ask_price[k]),
        .i_lad_ask_qty(lad_ask_qty[k]),
        .o_valid(m_valid), .o_ts(m_ts),
        .o_has_bid(m_has_bid), .o_bid_price(m_bid_price), .o_bid_qty(m_bid_qty),
        .o_has_ask(m_has_ask), .o_ask_price(m_ask_price), .o_ask_qty(m_ask_qty),
        .early_cnt(sb_early[k]), .late_cnt(sb_late[k]),
        .mismatch_cnt(sb_mismatch[k])
      );
    end else begin : g_slow
      assign m_valid     = lad_valid[k];
      assign m_ts        = lad_ts[k];
      assign m_has_bid   = lad_has_bid[k];
      assign m_bid_price = lad_bid_price[k];
      assign m_bid_qty   = lad_bid_qty[k];
      assign m_has_ask   = lad_has_ask[k];
      assign m_ask_price = lad_ask_price[k];
      assign m_ask_qty   = lad_ask_qty[k];
      assign sb_early[k]    = '0;
      assign sb_late[k]     = '0;
      assign sb_mismatch[k] = '0;
    end

    assign sb_valid[k] = m_valid;
    assign sb_data[BBOW*k +: BBOW] = {m_ts, m_has_bid, m_bid_price, m_bid_qty,
                                      m_has_ask, m_ask_price, m_ask_qty};
  end

  // ---------------- tagged merge of the K BBO streams ----------------
  bbo_arb #(.NSYM(NSYM), .SYMW(SYMW), .BBOW(BBOW)) u_bbo_arb (
    .clk(clk), .rst_n(rst_n),
    .i_valid(sb_valid), .i_data(sb_data),
    .o_valid(bbo_valid), .o_sym(bbo_sym),
    .o_data({bbo_ts, bbo_has_bid, bbo_bid_price, bbo_bid_qty,
             bbo_has_ask, bbo_ask_price, bbo_ask_qty}),
    .drop_cnt(st_bbo_arb_drop)
  );

  // Per-symbol counters summed for the register map. One number per counter is
  // what the map has always carried and what the host tool prints; a per-symbol
  // breakdown would be NSYM times as many registers for a diagnostic whose
  // question ("is the fast path disagreeing with the ladder?") is answered by
  // the total. st_bbo_mismatch in particular must be zero, and a sum is zero
  // exactly when every term is.
  always_comb begin
    st_pl_oob       = '0;
    st_bbo_early    = '0;
    st_bbo_late     = '0;
    st_bbo_mismatch = '0;
    for (int k = 0; k < NSYM; k++) begin
      st_pl_oob       = st_pl_oob       + lad_oob[k];
      st_bbo_early    = st_bbo_early    + sb_early[k];
      st_bbo_late     = st_bbo_late     + sb_late[k];
      st_bbo_mismatch = st_bbo_mismatch + sb_mismatch[k];
    end
  end

endmodule
