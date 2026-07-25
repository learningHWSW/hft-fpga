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
  parameter int OT_WAYS       = 16
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
  input  logic [15:0]         cfg_udp_port,
  input  logic [15:0]         cfg_track_locate,
  input  logic [31:0]         cfg_band_base,

  // strategy configuration
  input  logic                cfg_enable,
  input  logic [31:0]         cfg_max_spread,
  input  logic [3:0]          cfg_ratio_shift,
  input  logic [31:0]         cfg_min_qty,
  input  logic [31:0]         cfg_order_qty,
  input  logic [31:0]         cfg_pos_limit,
  input  logic [15:0]         cfg_max_inflight,
  input  logic                cfg_order_ack,
  input  logic                cfg_sweep_en,
  input  logic [31:0]         cfg_sweep_min_levels,
  input  logic [47:0]         cfg_sweep_gap,

  // OUCH configuration
  input  logic [47:0]         cfg_token_prefix,
  input  logic [63:0]         cfg_stock,
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
  output logic [31:0]         st_beat_drop,
  output logic [31:0]         st_msg_drop,
  output logic [31:0]         st_delta_drop,
  output logic [31:0]         st_sent,
  output logic [31:0]         st_blk_pos,
  output logic [31:0]         st_blk_inflight,
  output logic [31:0]         st_blk_txfull,
  output logic signed [31:0]  st_position,
  output logic [31:0]         st_seq_num,
  output logic [31:0]         st_frame_cnt,
  output logic [31:0]         st_tx_drop,

  // RX-side IGMP query -> drives igmp_join.i_query in the wrapper (RFC 2236)
  output logic                o_igmp_query
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

  // ---- feed handler: MoldUDP64 -> ITCH -> order table -> book ----
  logic        bbo_valid, bbo_has_bid, bbo_has_ask;
  logic [47:0] bbo_ts;
  logic [31:0] bbo_bid_price, bbo_bid_qty, bbo_ask_price, bbo_ask_qty;
  logic        ev_gap, ev_hb, ev_eos;
  logic [63:0] ev_seq, ev_expected;
  logic [31:0] st_dup_cnt, st_frame_err, st_ot_miss, st_sweep_cnt;
  logic        sweep_pulse, sweep_is_buy;

  fh_core #(.DATA_W(DATA_W), .OT_SETS_BITS(OT_SETS_BITS), .OT_WAYS(OT_WAYS)) u_fh (
    .clk(core_clk), .rst_n(core_rst_n),
    .track_locate(cfg_track_locate), .cfg_base(cfg_band_base),
    .s_tdata(pay_tdata), .s_tkeep(pay_tkeep), .s_tvalid(pay_tvalid), .s_tlast(pay_tlast),
    .init_done(st_init_done),
    .cfg_sweep_min_levels(cfg_sweep_min_levels), .cfg_sweep_gap(cfg_sweep_gap),
    .o_sweep(sweep_pulse), .o_sweep_is_buy(sweep_is_buy), .st_sweep_cnt(st_sweep_cnt),
    .bbo_valid(bbo_valid), .bbo_ts(bbo_ts),
    .bbo_has_bid(bbo_has_bid), .bbo_bid_price(bbo_bid_price), .bbo_bid_qty(bbo_bid_qty),
    .bbo_has_ask(bbo_has_ask), .bbo_ask_price(bbo_ask_price), .bbo_ask_qty(bbo_ask_qty),
    .ev_gap(ev_gap), .ev_hb(ev_hb), .ev_eos(ev_eos),
    .ev_seq(ev_seq), .ev_expected(ev_expected),
    .st_gap_total(st_gap_total), .st_dup_cnt(st_dup_cnt), .st_frame_err(st_frame_err),
    .st_ot_overflow(st_ot_overflow), .st_ot_miss(st_ot_miss), .st_pl_oob(st_pl_oob),
    .st_beat_drop(st_beat_drop), .st_msg_drop(st_msg_drop), .st_delta_drop(st_delta_drop),
    .st_beat_level_max(), .st_msg_level_max(), .st_delta_level_max()
  );

  // ---- decide ----
  logic        ord_valid, ord_is_buy, ord_ready;
  logic [47:0] ord_ts;
  logic [31:0] ord_qty, ord_price;
  logic [15:0] inflight;

  strategy u_strat (
    .clk(core_clk), .rst_n(core_rst_n),
    .cfg_enable(cfg_enable), .cfg_max_spread(cfg_max_spread),
    .cfg_ratio_shift(cfg_ratio_shift), .cfg_min_qty(cfg_min_qty),
    .cfg_order_qty(cfg_order_qty), .cfg_pos_limit(cfg_pos_limit),
    .cfg_max_inflight(cfg_max_inflight),
    .i_valid(bbo_valid), .i_ts(bbo_ts),
    .i_has_bid(bbo_has_bid), .i_bid_price(bbo_bid_price), .i_bid_qty(bbo_bid_qty),
    .i_has_ask(bbo_has_ask), .i_ask_price(bbo_ask_price), .i_ask_qty(bbo_ask_qty),
    .cfg_sweep_en(cfg_sweep_en), .i_sweep(sweep_pulse), .i_sweep_is_buy(sweep_is_buy),
    .i_ack(cfg_order_ack),
    .o_valid(ord_valid), .o_ts(ord_ts), .o_is_buy(ord_is_buy),
    .o_qty(ord_qty), .o_price(ord_price), .o_ready(ord_ready),
    .sent_cnt(st_sent), .blk_pos_cnt(st_blk_pos),
    .blk_inflight_cnt(st_blk_inflight), .blk_txfull_cnt(st_blk_txfull),
    .position(st_position), .inflight(inflight)
  );

  // ---- encode ----
  logic [DATA_W-1:0] ouch_tdata;
  logic [KEEP_W-1:0] ouch_tkeep;
  logic              ouch_tvalid, ouch_tlast, ouch_tready;
  logic [31:0]       pkt_cnt, token_seq;

  ouch_builder #(.DATA_W(DATA_W)) u_ouch (
    .clk(core_clk), .rst_n(core_rst_n),
    .cfg_token_prefix(cfg_token_prefix), .cfg_stock(cfg_stock), .cfg_firm(cfg_firm),
    .cfg_tif(cfg_tif), .cfg_min_qty(cfg_ouch_min_qty),
    .cfg_display(cfg_display), .cfg_capacity(cfg_capacity), .cfg_sweep(cfg_sweep),
    .cfg_cross(cfg_cross), .cfg_cust(cfg_cust),
    .i_valid(ord_valid), .i_is_buy(ord_is_buy), .i_qty(ord_qty), .i_price(ord_price),
    .i_ready(ord_ready),
    .m_tdata(ouch_tdata), .m_tkeep(ouch_tkeep), .m_tvalid(ouch_tvalid),
    .m_tlast(ouch_tlast), .m_tready(ouch_tready),
    .pkt_cnt(pkt_cnt), .token_seq(token_seq)
  );

  // ---- frame ----
  logic [DATA_W-1:0] frm_tdata;
  logic [KEEP_W-1:0] frm_tkeep;
  logic              frm_tvalid, frm_tlast;

  tcp_tx #(.DATA_W(DATA_W), .PAYLD_B(52)) u_tcp (
    .clk(core_clk), .rst_n(core_rst_n),
    .cfg_dst_mac(cfg_dst_mac), .cfg_src_mac(cfg_src_mac),
    .cfg_src_ip(cfg_src_ip), .cfg_dst_ip(cfg_dst_ip),
    .cfg_src_port(cfg_src_port), .cfg_dst_port(cfg_dst_port),
    .cfg_init_seq(cfg_init_seq), .cfg_ack_num(cfg_ack_num),
    .cfg_window(cfg_window), .cfg_init_id(cfg_init_id), .cfg_load(cfg_load),
    .s_tdata(ouch_tdata), .s_tvalid(ouch_tvalid), .s_tready(ouch_tready),
    .m_tdata(frm_tdata), .m_tkeep(frm_tkeep), .m_tvalid(frm_tvalid),
    .m_tlast(frm_tlast), .m_tready(1'b1),
    .seq_num(st_seq_num), .frame_cnt(st_frame_cnt)
  );

  // ---- core -> CMAC ----
  // Same FIFO, opposite direction. It counts drops for symmetry with the
  // receive side, but the transmit side cannot realistically overflow: orders
  // are capped at 4 in flight and the CMAC drains 512 bits per 3.1 ns.
  logic [31:0] tx_hwm_unused;

  cdc_fifo #(.DATA_W(DATA_W), .DEPTH(64)) u_tx_cdc (
    .w_clk(core_clk), .w_rst_n(core_rst_n),
    .s_tdata(frm_tdata), .s_tkeep(frm_tkeep), .s_tvalid(frm_tvalid), .s_tlast(frm_tlast),
    .drop_cnt(st_tx_drop), .hwm(tx_hwm_unused),
    .r_clk(cmac_clk), .r_rst_n(cmac_rst_n),
    .m_tdata(tx_tdata), .m_tkeep(tx_tkeep), .m_tvalid(tx_tvalid), .m_tlast(tx_tlast),
    .m_tready(tx_tready)
  );

endmodule
