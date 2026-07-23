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
//   track_locate — the symbol whose orders enter the table
//   cfg_base     — price-ladder band start for that symbol
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
  parameter int PL_TICK      = 100
)(
  input  logic                clk,
  input  logic                rst_n,

  // config
  input  logic [15:0]         track_locate,
  input  logic [31:0]         cfg_base,

  // MoldUDP64 payload beats from the UDP/IP front end (no backpressure)
  input  logic [DATA_W-1:0]   s_tdata,
  input  logic [DATA_W/8-1:0] s_tkeep,
  input  logic                s_tvalid,
  input  logic                s_tlast,

  // BBO stream
  output logic                bbo_valid,
  output logic [47:0]         bbo_ts,
  output logic                bbo_has_bid,
  output logic [31:0]         bbo_bid_price,
  output logic [31:0]         bbo_bid_qty,
  output logic                bbo_has_ask,
  output logic [31:0]         bbo_ask_price,
  output logic [31:0]         bbo_ask_qty,

  // sweep / momentum-ignition trigger, tapped off the order-table delta stream
  input  logic [31:0]         cfg_sweep_min_levels,
  input  logic [47:0]         cfg_sweep_gap,
  output logic                o_sweep,
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
  output logic [$clog2(DELTA_FIFO):0] st_delta_level_max
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

  itch_decoder #(.DATA_W(DATA_W)) u_dec (
    .clk(clk), .rst_n(rst_n),
    .s_tdata(sp_tdata), .s_tkeep(sp_tkeep), .s_tvalid(sp_tvalid), .s_tlast(sp_tlast),
    .s_tready(dec_ready_unused),
    .m_msg(dec_msg), .m_valid(dec_valid), .m_len_err(dec_len_err)
  );

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
  logic        ot_has_rem, ot_has_add;
  logic [31:0] ot_rem_price, ot_rem_qty, ot_add_price, ot_add_qty;

  order_table #(.SETS_BITS(OT_SETS_BITS), .WAYS(OT_WAYS)) u_otab (
    .clk(clk), .rst_n(rst_n), .track_locate(track_locate),
    .s_msg(itch_msg_t'(mf_pop_data)), .s_valid(mf_pop_valid), .s_ready(ot_ready),
    .o_valid(ot_valid), .o_type(ot_type), .o_ts(ot_ts),
    .o_locate(ot_locate), .o_side(ot_side),
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
  sweep_detect u_sweep (
    .clk(clk), .rst_n(rst_n),
    .cfg_min_levels(cfg_sweep_min_levels), .cfg_gap(cfg_sweep_gap),
    .i_valid(ot_valid), .i_type(ot_type), .i_side(ot_side),
    .i_has_rem(ot_has_rem), .i_price(ot_rem_price), .i_qty(ot_rem_qty), .i_ts(ot_ts),
    .i_flush(1'b0),
    .o_sweep(o_sweep), .o_is_buy(o_sweep_is_buy),
    .o_levels(), .o_shares(), .o_ts_end(),
    .sweep_cnt(st_sweep_cnt)
  );

  // ---------------- delta FIFO -> price ladder ----------------
  localparam int DELW = 48 + 8 + 1 + 32 + 32 + 1 + 32 + 32;   // 186
  logic            df_pop_valid, df_pop_ready;
  logic [DELW-1:0] df_pop_data;
  logic [$clog2(DELTA_FIFO):0] df_level;

  drop_fifo #(.WIDTH(DELW), .DEPTH(DELTA_FIFO)) u_delta_fifo (
    .clk(clk), .rst_n(rst_n),
    .push_valid(ot_valid),
    .push_data({ot_ts, ot_side, ot_has_rem, ot_rem_price, ot_rem_qty,
                ot_has_add, ot_add_price, ot_add_qty}),
    .pop_valid(df_pop_valid), .pop_data(df_pop_data), .pop_ready(df_pop_ready),
    .drop_cnt(st_delta_drop), .level(df_level), .level_max(st_delta_level_max)
  );

  price_ladder #(.LEVELS(PL_LEVELS), .TICK(PL_TICK)) u_ladder (
    .clk(clk), .rst_n(rst_n), .cfg_base(cfg_base),
    .i_valid    (df_pop_valid),
    .i_ts       (df_pop_data[185:138]),
    .i_side     (df_pop_data[137:130]),
    .i_has_rem  (df_pop_data[129]),
    .i_rem_price(df_pop_data[128:97]),
    .i_rem_qty  (df_pop_data[96:65]),
    .i_has_add  (df_pop_data[64]),
    .i_add_price(df_pop_data[63:32]),
    .i_add_qty  (df_pop_data[31:0]),
    .i_ready    (df_pop_ready),
    .o_valid(bbo_valid), .o_ts(bbo_ts),
    .o_has_bid(bbo_has_bid), .o_bid_price(bbo_bid_price), .o_bid_qty(bbo_bid_qty),
    .o_has_ask(bbo_has_ask), .o_ask_price(bbo_ask_price), .o_ask_qty(bbo_ask_qty),
    .oob_cnt(st_pl_oob)
  );

endmodule
