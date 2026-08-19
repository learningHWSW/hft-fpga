// Tick-to-trade top — the whole chain, wire to wire.
//
//   CMAC RX @322.265625 MHz
//     -> cdc_fifo        cross into the core clock domain
//     -> eth_ip_udp_rx   strip Ethernet/IPv4/UDP, filter to the feed's group
//     -> fh_core         MoldUDP64 split, ITCH decode, order table, price ladder
//     -> strategy        imbalance rule + risk gate
//     -> ouch_builder    SoupBinTCP + OUCH 4.2 enter order
//     -> tcp_tx          TCP/IPv4/Ethernet framing
//     -> cdc_fifo        cross back out
//   CMAC TX @322.265625 MHz
//
// TWO CLOCKS ON PURPOSE. The core does not run at the CMAC's 322 MHz and does
// not need to: 512 bits at 322.265625 MHz is 165 Gb/s of interface bandwidth
// for a 100 Gb/s wire, so what the core must sustain is 12.5 GB/s / 64 B =
// 195.3 MHz. It measures 216.5 MHz post-route, so the crossing is what makes
// the design correct rather than a faster core. Both crossings are the same
// verified cdc_fifo (Gray pointers, guard bit, ASYNC_REG), and the two domains
// must be declared asynchronous to each other in the XDC.
//
// The receive path never backpressures — the wire cannot be stalled, so
// overflow is absorbed in FIFOs and counted. The transmit path is different:
// it is allowed to backpressure the strategy, which drops the order and counts
// it rather than queueing a stale one.
`timescale 1ns/1ps
module t2t_top #(
  parameter int DATA_W        = 512,
  // 2^13 x 16: measured zero-overflow design point, chosen for URAM cascade
  // depth rather than capacity (see order_table). Instantiated as URAM, so
  // synthesis builds the size simulation verifies.
  parameter int OT_SETS_BITS  = 13,
  parameter int OT_WAYS       = 16,
  // Answer the common book delta from fast_bbo instead of waiting for the
  // ladder's scan. The emitted BBO stream is identical either way -- bbo_merge
  // is what guarantees that -- so 0 exists to bisect, not to trade off.
  parameter bit USE_FAST_BBO  = 1,
  // Cut-through ITCH decode -- see itch_decoder.sv. Off by default: it trades
  // one core cycle for combinational depth in the domain that closes tightest.
  parameter bit CUT_THROUGH   = 1,
  // Tracked symbols. One order table holds all of them; everything downstream
  // of it is replicated per name (fh_core's header, FINDINGS §4.4). NSYM moves
  // together with OT_SETS_BITS -- raising it alone is a choice to drop orders.
  parameter int NSYM          = 1,
  parameter int SYMW          = (NSYM > 1) ? $clog2(NSYM) : 1
)(
  // ---- CMAC domain ----
  input  logic                cmac_clk,
  input  logic                cmac_rst_n,
  input  logic [DATA_W-1:0]   rx_tdata,
  input  logic [DATA_W/8-1:0] rx_tkeep,
  input  logic                rx_tvalid,
  input  logic                rx_tlast,
  output logic [DATA_W-1:0]   tx_tdata,
  output logic [DATA_W/8-1:0] tx_tkeep,
  output logic                tx_tvalid,
  output logic                tx_tlast,
  input  logic                tx_tready,

  // ---- core domain ----
  input  logic                core_clk,
  input  logic                core_rst_n,

  // feed configuration
  input  logic [31:0]         cfg_group_ip,
  input  logic [31:0]         cfg_group_ip_b,   // B line (A/B gap recovery); =A for single feed
  input  logic [15:0]         cfg_udp_port,
  // packed per symbol: symbol k is [W*k +: W]. The band base is per name
  // because two stocks do not trade near the same price.
  input  logic [NSYM*16-1:0]  cfg_track_locate,
  input  logic [NSYM*32-1:0]  cfg_band_base,

  // strategy configuration
  input  logic                cfg_enable,
  input  logic [31:0]         cfg_max_spread,
  input  logic [3:0]          cfg_ratio_shift,
  input  logic [31:0]         cfg_min_qty,
  input  logic [31:0]         cfg_order_qty,
  input  logic [31:0]         cfg_pos_limit,
  input  logic [15:0]         cfg_max_inflight,
  input  logic                cfg_order_ack,
  // transmit replay buffer: pulse cfg_resend_req with an age (0 = most recent
  // frame stored) to push a previously sent order frame back onto the wire.
  input  logic                cfg_resend_req,
  input  logic [3:0]          cfg_resend_age,
  // Automatic retransmission (tx_rto). Off by default: with cfg_rto_en low the
  // transmit path is exactly what it was before the detector existed.
  input  logic                cfg_rto_en,
  input  logic [31:0]         cfg_rto_cycles,   // idle core cycles before a resend
  input  logic [3:0]          cfg_rto_retries,  // attempts per unacknowledged frame
  input  logic                cfg_sweep_en,
  input  logic [31:0]         cfg_sweep_min_levels,
  input  logic [47:0]         cfg_sweep_gap,

  // OUCH configuration
  input  logic [47:0]         cfg_token_prefix,
  input  logic [NSYM*64-1:0]  cfg_stock,       // 8 ASCII bytes per symbol
  input  logic [31:0]         cfg_firm,
  input  logic [31:0]         cfg_tif,
  input  logic [31:0]         cfg_ouch_min_qty,
  input  logic [7:0]          cfg_display,
  input  logic [7:0]          cfg_capacity,
  input  logic [7:0]          cfg_sweep,
  input  logic [7:0]          cfg_cross,
  input  logic [7:0]          cfg_cust,

  // TCP connection state, written by software after the handshake
  input  logic [47:0]         cfg_dst_mac,
  input  logic [47:0]         cfg_src_mac,
  input  logic [31:0]         cfg_src_ip,
  input  logic [31:0]         cfg_dst_ip,
  input  logic [15:0]         cfg_src_port,
  input  logic [15:0]         cfg_dst_port,
  input  logic [31:0]         cfg_init_seq,
  input  logic [31:0]         cfg_ack_num,
  input  logic [15:0]         cfg_window,
  input  logic [15:0]         cfg_init_id,
  input  logic                cfg_load,

  // ---- status (host reads these over AXI-Lite in the real design) ----
  output logic [31:0]         st_rx_drop,
  output logic [31:0]         st_rx_hwm,
  output logic                st_init_done,  // order table cleared; feed may start
  output logic [31:0]         st_frames_in,
  output logic [31:0]         st_frames_kept,
  output logic [31:0]         st_gap_total,
  output logic [31:0]         st_ot_overflow,
  output logic [31:0]         st_pl_oob,
  // How the BBO stream was answered: early by fast_bbo, late by the ladder, and
  // the two disagreeing, which must never happen (bbo_merge's header says why).
  output logic [31:0]         st_bbo_early,
  output logic [31:0]         st_bbo_late,
  output logic [31:0]         st_bbo_mismatch,
  output logic [31:0]         st_bbo_arb_drop,   // BBO records lost in the merge
  output logic [31:0]         st_beat_drop,
  output logic [31:0]         st_msg_drop,
  output logic [31:0]         st_delta_drop,
  output logic [31:0]         st_sent,
  output logic [31:0]         st_blk_pos,
  output logic [31:0]         st_blk_inflight,
  output logic [31:0]         st_blk_txfull,
  output logic [31:0]         st_blk_qty,
  // One signed position per symbol, packed. t2t_axil publishes symbol 0 at the
  // offset st_position always had and the rest in a block above it -- a summed
  // "net position" across names would be a number with no meaning (long one
  // name and short another is not flat).
  output logic [NSYM*32-1:0]  st_position,
  output logic [31:0]         st_seq_num,
  output logic [31:0]         st_frame_cnt,
  output logic [31:0]         st_tx_drop,
  output logic [31:0]         st_rb_stored,
  output logic [31:0]         st_rb_resent,
  output logic [31:0]         st_rb_drop,
  output logic [31:0]         st_rto_fired,     // resends the card asked for itself
  output logic [31:0]         st_rto_gaveup,    // frames abandoned at the retry cap

  // RX-side IGMP query -> drives igmp_join.i_query in the wrapper (RFC 2236)
  output logic                o_igmp_query,

  // ---- observation taps for the loaded-latency probe (step 8) ----
  // Purely additive: a decoded message with its ITCH timestamp, and an order
  // with the timestamp of the message that caused it. Correlating the two
  // measures latency while the pipeline is busy, which the unloaded probe
  // cannot do. Nothing here feeds back into the datapath.
  output logic                o_dec_valid,
  output logic [47:0]         o_dec_ts,
  output logic                o_ord_valid,
  output logic [47:0]         o_ord_ts,

  // ---- order-session inbound (tcp_rx) ----
  // Session frames only, for the host to read the OUCH payload out of. The
  // payload is not realigned; o_rx_pay_off/len say where it sits in the frame.
  output logic [DATA_W-1:0]   rxs_tdata,
  output logic [DATA_W/8-1:0] rxs_tkeep,
  output logic                rxs_tvalid,
  output logic                rxs_tlast,
  output logic [15:0]         o_rx_pay_off,
  output logic [15:0]         o_rx_pay_len,
  output logic [31:0]         st_rx_peer_ack,
  output logic [31:0]         st_rx_ooo,
  output logic [31:0]         st_rx_dup,
  output logic [31:0]         st_rx_sess_frames,

  // ---- how long the venue takes to acknowledge an order ----
  // Core cycles, kernel to kernel. The number tx_rto's timeout should have been
  // chosen from and could not be, because nothing has ever acknowledged these
  // orders. See ack_latency.sv for exactly what the two endpoints are; on a
  // bench with no counterparty st_ack_samples stays 0, which is the honest
  // answer rather than a small number that looks like a measurement.
  output logic [31:0]         st_ack_last,
  output logic [31:0]         st_ack_min,
  output logic [31:0]         st_ack_max,
  output logic [31:0]         st_ack_samples,
  output logic [63:0]         st_ack_sum,
  output logic [31:0]         st_ack_lost
);
  localparam int KEEP_W = DATA_W / 8;

  // ---- CMAC -> core ----
  logic [DATA_W-1:0] rxc_tdata;
  logic [KEEP_W-1:0] rxc_tkeep;
  logic              rxc_tvalid, rxc_tlast;

  cdc_fifo #(.DATA_W(DATA_W), .DEPTH(256)) u_rx_cdc (
    .w_clk(cmac_clk), .w_rst_n(cmac_rst_n),
    .s_tdata(rx_tdata), .s_tkeep(rx_tkeep), .s_tvalid(rx_tvalid), .s_tlast(rx_tlast),
    .drop_cnt(st_rx_drop), .hwm(st_rx_hwm),
    .r_clk(core_clk), .r_rst_n(core_rst_n),
    .m_tdata(rxc_tdata), .m_tkeep(rxc_tkeep), .m_tvalid(rxc_tvalid), .m_tlast(rxc_tlast),
    .m_tready(1'b1)                       // the feed path never stalls
  );

  // ---- RX-side IGMP query detector (taps the raw stream before the UDP
  // filter, since IGMP is IP protocol 2, not UDP) ----
  igmp_query_detect #(.DATA_W(DATA_W)) u_igmp_q (
    .clk(core_clk), .rst_n(core_rst_n), .cfg_group_ip(cfg_group_ip),
    .s_tdata(rxc_tdata), .s_tvalid(rxc_tvalid), .s_tlast(rxc_tlast),
    .o_query(o_igmp_query), .query_cnt()
  );

  // ---- order-session inbound ----
  // Taps the same raw stream as the IGMP detector, for the same reason: this is
  // TCP, and the UDP filter below would drop it. It maintains the acknowledgement
  // number the transmit side needs, which used to be a static shadow register
  // that could only ever be stale once the card sends its own orders.
  //
  // cfg_ack_num is its INITIAL value rather than its permanent one: software
  // still hands over what it saw during the handshake, and the hardware advances
  // from there. With no inbound session traffic rcv_nxt stays at cfg_ack_num, so
  // a design that never receives behaves exactly as it did before -- which is
  // what keeps every existing golden byte-identical.
  logic [31:0] rx_rcv_nxt;
  logic [15:0] rx_peer_window;
  logic        rx_seen_fin, rx_seen_rst;
  logic [31:0] rx_not_tcp, rx_tuple_drop, rx_pay_bytes;

  tcp_rx #(.DATA_W(DATA_W)) u_tcp_rx (
    .clk(core_clk), .rst_n(core_rst_n),
    .cfg_local_ip(cfg_src_ip),   .cfg_peer_ip(cfg_dst_ip),
    .cfg_local_port(cfg_src_port), .cfg_peer_port(cfg_dst_port),
    .cfg_irs(cfg_ack_num), .cfg_load(cfg_load),
    .s_tdata(rxc_tdata), .s_tkeep(rxc_tkeep),
    .s_tvalid(rxc_tvalid), .s_tlast(rxc_tlast),
    .m_tdata(rxs_tdata), .m_tkeep(rxs_tkeep),
    .m_tvalid(rxs_tvalid), .m_tlast(rxs_tlast),
    .o_pay_off(o_rx_pay_off), .o_pay_len(o_rx_pay_len),
    .rcv_nxt(rx_rcv_nxt), .peer_ack(st_rx_peer_ack),
    .peer_window(rx_peer_window),
    .seen_fin(rx_seen_fin), .seen_rst(rx_seen_rst),
    .frames_in(), .frames_kept(st_rx_sess_frames),
    .drop_not_tcp(rx_not_tcp), .drop_tuple(rx_tuple_drop),
    .drop_ooo(st_rx_ooo), .drop_dup(st_rx_dup),
    .payload_bytes(rx_pay_bytes)
  );

  // ---- strip Ethernet/IPv4/UDP ----
  logic [DATA_W-1:0] pay_tdata;
  logic [KEEP_W-1:0] pay_tkeep;
  logic              pay_tvalid, pay_tlast;
  logic [31:0]       drop_not_ipv4, drop_not_udp, drop_group;

  eth_ip_udp_rx #(.DATA_W(DATA_W)) u_rx (
    .clk(core_clk), .rst_n(core_rst_n),
    .cfg_group_ip(cfg_group_ip), .cfg_udp_port(cfg_udp_port),
    .s_tdata(rxc_tdata), .s_tkeep(rxc_tkeep), .s_tvalid(rxc_tvalid), .s_tlast(rxc_tlast),
    .m_tdata(pay_tdata), .m_tkeep(pay_tkeep), .m_tvalid(pay_tvalid), .m_tlast(pay_tlast),
    .frames_in(st_frames_in), .frames_kept(st_frames_kept),
    .drop_not_ipv4(drop_not_ipv4), .drop_not_udp(drop_not_udp), .drop_group(drop_group)
  );

  // ---- B line: same raw RX, filtered to the B multicast group ----
  logic [DATA_W-1:0] payb_tdata;
  logic [KEEP_W-1:0] payb_tkeep;
  logic              payb_tvalid, payb_tlast;
  eth_ip_udp_rx #(.DATA_W(DATA_W)) u_rx_b (
    .clk(core_clk), .rst_n(core_rst_n),
    .cfg_group_ip(cfg_group_ip_b), .cfg_udp_port(cfg_udp_port),
    .s_tdata(rxc_tdata), .s_tkeep(rxc_tkeep), .s_tvalid(rxc_tvalid), .s_tlast(rxc_tlast),
    .m_tdata(payb_tdata), .m_tkeep(payb_tkeep), .m_tvalid(payb_tvalid), .m_tlast(payb_tlast),
    .frames_in(), .frames_kept(),
    .drop_not_ipv4(), .drop_not_udp(), .drop_group()
  );

  // ---- A/B line arbiter: merge the two into one clean, in-order stream ----
  // Elastic FIFOs adapt the free-running rx outputs to the arb's backpressure
  // (drop on full; A/B packets are well under an MTU and the arb drains fast).
  // With B unconfigured (cfg_group_ip_b = cfg_group_ip) the B filter mirrors A,
  // so both lines carry the same packets and the arb dedups to a pass-through;
  // point B at the real second group to actually recover single-line drops.
  localparam int PAYW = DATA_W + KEEP_W + 1;
  logic            fa_pv, fa_pr, fb_pv, fb_pr;
  logic [PAYW-1:0] fa_pd, fb_pd;
  drop_fifo #(.WIDTH(PAYW), .DEPTH(256)) u_afifo (
    .clk(core_clk), .rst_n(core_rst_n),
    .push_valid(pay_tvalid), .push_data({pay_tlast, pay_tkeep, pay_tdata}),
    .pop_valid(fa_pv), .pop_data(fa_pd), .pop_ready(fa_pr),
    .drop_cnt(), .level(), .level_max()
  );
  drop_fifo #(.WIDTH(PAYW), .DEPTH(256)) u_bfifo (
    .clk(core_clk), .rst_n(core_rst_n),
    .push_valid(payb_tvalid), .push_data({payb_tlast, payb_tkeep, payb_tdata}),
    .pop_valid(fb_pv), .pop_data(fb_pd), .pop_ready(fb_pr),
    .drop_cnt(), .level(), .level_max()
  );

  logic [DATA_W-1:0] mrg_tdata;
  logic [KEEP_W-1:0] mrg_tkeep;
  logic              mrg_tvalid, mrg_tlast;
  feed_ab_arb #(.DATA_W(DATA_W)) u_ab (
    .clk(core_clk), .rst_n(core_rst_n),
    .a_tdata(fa_pd[DATA_W-1:0]), .a_tkeep(fa_pd[DATA_W +: KEEP_W]),
    .a_tvalid(fa_pv), .a_tlast(fa_pd[PAYW-1]), .a_tready(fa_pr),
    .b_tdata(fb_pd[DATA_W-1:0]), .b_tkeep(fb_pd[DATA_W +: KEEP_W]),
    .b_tvalid(fb_pv), .b_tlast(fb_pd[PAYW-1]), .b_tready(fb_pr),
    .m_tdata(mrg_tdata), .m_tkeep(mrg_tkeep), .m_tvalid(mrg_tvalid), .m_tlast(mrg_tlast),
    .m_tready(1'b1),                      // fh_core's beat FIFO never backpressures
    .ev_gap(), .fwd_cnt(), .dup_cnt(), .gap_cnt(), .a_src_cnt(), .b_src_cnt()
  );

  // ---- feed handler: MoldUDP64 -> ITCH -> order table -> book ----
  logic        bbo_valid, bbo_has_bid, bbo_has_ask;
  logic [SYMW-1:0] bbo_sym, sweep_sym;
  logic [47:0] bbo_ts;
  logic [31:0] bbo_bid_price, bbo_bid_qty, bbo_ask_price, bbo_ask_qty;
  logic        ev_gap, ev_hb, ev_eos;
  logic [63:0] ev_seq, ev_expected;
  logic [31:0] st_dup_cnt, st_frame_err, st_ot_miss, st_sweep_cnt;
  logic        sweep_pulse, sweep_is_buy;

  fh_core #(.DATA_W(DATA_W), .OT_SETS_BITS(OT_SETS_BITS), .OT_WAYS(OT_WAYS),
            .USE_FAST_BBO(USE_FAST_BBO), .CUT_THROUGH(CUT_THROUGH),
            .NSYM(NSYM)) u_fh (
    .clk(core_clk), .rst_n(core_rst_n),
    .track_locate(cfg_track_locate), .cfg_base(cfg_band_base),
    .s_tdata(mrg_tdata), .s_tkeep(mrg_tkeep), .s_tvalid(mrg_tvalid), .s_tlast(mrg_tlast),
    .init_done(st_init_done),
    .cfg_sweep_min_levels(cfg_sweep_min_levels), .cfg_sweep_gap(cfg_sweep_gap),
    .o_sweep(sweep_pulse), .o_sweep_sym(sweep_sym),
    .o_sweep_is_buy(sweep_is_buy), .st_sweep_cnt(st_sweep_cnt),
    .bbo_valid(bbo_valid), .bbo_sym(bbo_sym), .bbo_ts(bbo_ts),
    .bbo_has_bid(bbo_has_bid), .bbo_bid_price(bbo_bid_price), .bbo_bid_qty(bbo_bid_qty),
    .bbo_has_ask(bbo_has_ask), .bbo_ask_price(bbo_ask_price), .bbo_ask_qty(bbo_ask_qty),
    .ev_gap(ev_gap), .ev_hb(ev_hb), .ev_eos(ev_eos),
    .ev_seq(ev_seq), .ev_expected(ev_expected),
    .st_gap_total(st_gap_total), .st_dup_cnt(st_dup_cnt), .st_frame_err(st_frame_err),
    .st_ot_overflow(st_ot_overflow), .st_ot_miss(st_ot_miss), .st_pl_oob(st_pl_oob),
    .st_beat_drop(st_beat_drop), .st_msg_drop(st_msg_drop), .st_delta_drop(st_delta_drop),
    .st_beat_level_max(), .st_msg_level_max(), .st_delta_level_max(),
    .st_bbo_early(st_bbo_early), .st_bbo_late(st_bbo_late),
    .st_bbo_mismatch(st_bbo_mismatch), .st_bbo_arb_drop(st_bbo_arb_drop),
    .o_dec_valid(o_dec_valid), .o_dec_ts(o_dec_ts)
  );

  // ---- decide ----
  logic        ord_valid, ord_is_buy, ord_ready;
  logic [SYMW-1:0] ord_sym;
  logic [47:0] ord_ts;
  // the order and the ITCH timestamp it cites, taken straight to the taps
  assign o_ord_valid = ord_valid;
  assign o_ord_ts    = ord_ts;
  logic [31:0] ord_qty, ord_price;
  logic [15:0] inflight;

  strategy #(.NSYM(NSYM)) u_strat (
    .clk(core_clk), .rst_n(core_rst_n),
    .cfg_enable(cfg_enable), .cfg_max_spread(cfg_max_spread),
    .cfg_ratio_shift(cfg_ratio_shift), .cfg_min_qty(cfg_min_qty),
    .cfg_order_qty(cfg_order_qty), .cfg_pos_limit(cfg_pos_limit),
    .cfg_max_inflight(cfg_max_inflight),
    .i_valid(bbo_valid), .i_sym(bbo_sym), .i_ts(bbo_ts),
    .i_has_bid(bbo_has_bid), .i_bid_price(bbo_bid_price), .i_bid_qty(bbo_bid_qty),
    .i_has_ask(bbo_has_ask), .i_ask_price(bbo_ask_price), .i_ask_qty(bbo_ask_qty),
    .cfg_sweep_en(cfg_sweep_en), .i_sweep(sweep_pulse),
    .i_sweep_sym(sweep_sym), .i_sweep_is_buy(sweep_is_buy),
    .i_ack(cfg_order_ack),
    .o_valid(ord_valid), .o_sym(ord_sym), .o_ts(ord_ts), .o_is_buy(ord_is_buy),
    .o_qty(ord_qty), .o_price(ord_price), .o_ready(ord_ready),
    .sent_cnt(st_sent), .blk_pos_cnt(st_blk_pos),
    .blk_inflight_cnt(st_blk_inflight), .blk_txfull_cnt(st_blk_txfull),
    .blk_qty_cnt(st_blk_qty),
    .position(st_position), .inflight(inflight)
  );

  // ---- encode ----
  logic [DATA_W-1:0] ouch_tdata;
  logic [KEEP_W-1:0] ouch_tkeep;
  logic              ouch_tvalid, ouch_tlast, ouch_tready;
  logic [31:0]       pkt_cnt, token_seq;

  ouch_builder #(.DATA_W(DATA_W), .NSYM(NSYM)) u_ouch (
    .clk(core_clk), .rst_n(core_rst_n),
    .cfg_token_prefix(cfg_token_prefix), .cfg_stock(cfg_stock), .cfg_firm(cfg_firm),
    .cfg_tif(cfg_tif), .cfg_min_qty(cfg_ouch_min_qty),
    .cfg_display(cfg_display), .cfg_capacity(cfg_capacity), .cfg_sweep(cfg_sweep),
    .cfg_cross(cfg_cross), .cfg_cust(cfg_cust),
    .i_valid(ord_valid), .i_sym(ord_sym), .i_is_buy(ord_is_buy),
    .i_qty(ord_qty), .i_price(ord_price),
    .i_ready(ord_ready),
    .m_tdata(ouch_tdata), .m_tkeep(ouch_tkeep), .m_tvalid(ouch_tvalid),
    .m_tlast(ouch_tlast), .m_tready(ouch_tready),
    .pkt_cnt(pkt_cnt), .token_seq(token_seq)
  );

  // ---- frame ----
  logic [DATA_W-1:0] frm_tdata;
  logic [KEEP_W-1:0] frm_tkeep;
  logic              frm_tvalid, frm_tlast;
  // declared here rather than beside u_replay: tcp_tx's m_tready reads it, and
  // xvlog rejects a forward reference even where synthesis tolerates one. Third
  // time this pattern has bitten in this repo.
  logic              rb_s_tready;

  tcp_tx #(.DATA_W(DATA_W), .PAYLD_B(52)) u_tcp (
    .clk(core_clk), .rst_n(core_rst_n),
    .cfg_dst_mac(cfg_dst_mac), .cfg_src_mac(cfg_src_mac),
    .cfg_src_ip(cfg_src_ip), .cfg_dst_ip(cfg_dst_ip),
    .cfg_src_port(cfg_src_port), .cfg_dst_port(cfg_dst_port),
    .cfg_init_seq(cfg_init_seq), .cfg_ack_num(rx_rcv_nxt),
    .cfg_window(cfg_window), .cfg_init_id(cfg_init_id), .cfg_load(cfg_load),
    .s_tdata(ouch_tdata), .s_tvalid(ouch_tvalid), .s_tready(ouch_tready),
    .m_tdata(frm_tdata), .m_tkeep(frm_tkeep), .m_tvalid(frm_tvalid),
    .m_tlast(frm_tlast), .m_tready(rb_s_tready),
    .seq_num(st_seq_num), .frame_cnt(st_frame_cnt)
  );

  // ---- transmit replay buffer ----
  // Keeps the last SLOTS assembled order frames so the host can ask for one to be
  // re-sent. It is transparent when idle: the live frame passes straight through
  // while the ring is written in parallel, so with no resend outstanding the byte
  // stream is exactly what tcp_tx produced. A replay is only ever emitted when
  // the live path is idle, so retransmission cannot delay a new order.
  //
  // tcp_tx's m_tready used to be tied high. It now honours the buffer, which
  // holds it low only for the couple of cycles a replay occupies.
  logic [DATA_W-1:0] rb_tdata;
  logic [KEEP_W-1:0] rb_tkeep;
  logic              rb_tvalid, rb_tlast;

  // ---- who asks for a resend ----
  // Two sources, and the hardware one exists because the software one turned out
  // to be theoretical: the venue's replies reach the host through a capture
  // buffer read in batches, so "the host decides when to resend" means a decision
  // some milliseconds after the loss, about an order that has stopped being worth
  // sending. tx_rto watches the acknowledgement number tcp_rx already tracks and
  // asks for the oldest unacknowledged frame when it stops advancing.
  //
  // The host keeps its button. A hardware request is ORed with it rather than
  // replacing it, because a resend is idempotent -- same TCP sequence number,
  // same OUCH token -- so two requests for the same frame cost a duplicate
  // segment the venue discards, and neither source has to know about the other.
  //
  // cfg_rto_en defaults to 0. With it low this module drives nothing and the
  // transmit path is bit-for-bit what it was before it existed.
  logic       rto_req;
  logic [3:0] rto_age;

  tx_rto #(.SLOTS(16), .PAYLD_B(52)) u_rto (
    .clk(core_clk), .rst_n(core_rst_n),
    .cfg_en(cfg_rto_en), .cfg_rto_cycles(cfg_rto_cycles),
    .cfg_max_retries(cfg_rto_retries),
    .seq_num(st_seq_num), .peer_ack(st_rx_peer_ack),
    .o_resend_req(rto_req), .o_resend_age(rto_age),
    .st_fired(st_rto_fired), .st_gaveup(st_rto_gaveup)
  );

  wire       resend_req_any = cfg_resend_req | rto_req;
  wire [3:0] resend_age_any = rto_req ? rto_age : cfg_resend_age;

  // The instrument for the two constants above. It taps nothing new: seq_num
  // and peer_ack are the same pair tx_rto watches, and resend_req_any is how it
  // learns that the frame it is timing was sent twice -- an ack after that
  // answers one of two copies and is not a round trip.
  ack_latency #(.PAYLD_B(52)) u_ack_lat (
    .clk(core_clk), .rst_n(core_rst_n),
    .seq_num(st_seq_num), .peer_ack(st_rx_peer_ack),
    .cfg_load(cfg_load), .i_resend(resend_req_any),
    .st_last(st_ack_last), .st_min(st_ack_min), .st_max(st_ack_max),
    .st_samples(st_ack_samples), .st_sum(st_ack_sum), .st_lost(st_ack_lost)
  );

  tx_replay_buf #(.DATA_W(DATA_W), .SLOTS(16), .BEATS(2)) u_replay (
    .clk(core_clk), .rst_n(core_rst_n),
    .s_tdata(frm_tdata), .s_tkeep(frm_tkeep), .s_tvalid(frm_tvalid),
    .s_tlast(frm_tlast), .s_tready(rb_s_tready),
    .m_tdata(rb_tdata), .m_tkeep(rb_tkeep), .m_tvalid(rb_tvalid),
    .m_tlast(rb_tlast), .m_tready(1'b1),
    .resend_req(resend_req_any), .resend_age(resend_age_any),
    .stored_cnt(st_rb_stored), .resent_cnt(st_rb_resent),
    .resend_drop(st_rb_drop)
  );

  // ---- core -> CMAC ----
  // Same FIFO, opposite direction. It counts drops for symmetry with the
  // receive side, but the transmit side cannot realistically overflow: orders
  // are capped at 4 in flight and the CMAC drains 512 bits per 3.1 ns.
  logic [31:0] tx_hwm_unused;

  cdc_fifo #(.DATA_W(DATA_W), .DEPTH(64)) u_tx_cdc (
    .w_clk(core_clk), .w_rst_n(core_rst_n),
    .s_tdata(rb_tdata), .s_tkeep(rb_tkeep), .s_tvalid(rb_tvalid), .s_tlast(rb_tlast),
    .drop_cnt(st_tx_drop), .hwm(tx_hwm_unused),
    .r_clk(cmac_clk), .r_rst_n(cmac_rst_n),
    .m_tdata(tx_tdata), .m_tkeep(tx_tkeep), .m_tvalid(tx_tvalid), .m_tlast(tx_tlast),
    .m_tready(tx_tready)
  );

endmodule
