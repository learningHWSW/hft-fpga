// Board-top integration: t2t_top behind an AXI4-Lite control plane.
//
// This is the module an OpenNIC user box instantiates. It joins three things
// the earlier steps built and verified in isolation:
//
//   axil_regfile  -- host config/status over the QDMA AXI-Lite BAR (axil_clk)
//   t2t_top       -- the tick-to-trade datapath (cmac_clk + core_clk)
//   igmp_join     -- multicast membership so the feed actually arrives
//
// and adds the two pieces that only exist once they are wired together:
//
//   cfg_cdc / pulse_sync -- cross the quasi-static config and the commit/ack
//                           pulses between the AXI-Lite clock and the core;
//   axis_tx_arb          -- merge the order stream and the IGMP reports onto
//                           the single CMAC TX port without interleaving.
//
// Three clocks, declared asynchronous to each other in the XDC: cmac_clk
// (322.265625 MHz, fixed by the MAC), core_clk (~216 MHz, the datapath), and
// axil_clk (the QDMA/PCIe side, ~250 MHz). Nothing here is on the hot path --
// config crosses once at setup, status is monitoring -- so the crossings are
// built for correctness, not speed.
`timescale 1ns/1ps
module t2t_axil #(
  parameter int DATA_W        = 512,
  parameter int OT_SETS_BITS  = 13,
  parameter int OT_WAYS       = 16,
  parameter int AXIL_AW       = 12
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

  // ---- AXI-Lite control plane (QDMA) ----
  input  logic                axil_clk,
  input  logic                axil_rst_n,
  input  logic [AXIL_AW-1:0]  s_axil_awaddr,
  input  logic                s_axil_awvalid,
  output logic                s_axil_awready,
  input  logic [31:0]         s_axil_wdata,
  input  logic [3:0]          s_axil_wstrb,
  input  logic                s_axil_wvalid,
  output logic                s_axil_wready,
  output logic [1:0]          s_axil_bresp,
  output logic                s_axil_bvalid,
  input  logic                s_axil_bready,
  input  logic [AXIL_AW-1:0]  s_axil_araddr,
  input  logic                s_axil_arvalid,
  output logic                s_axil_arready,
  output logic [31:0]         s_axil_rdata,
  output logic [1:0]          s_axil_rresp,
  output logic                s_axil_rvalid,
  input  logic                s_axil_rready
);
  localparam int CFGW = 895;      // sum of all cfg_* widths (checked at elab)
  localparam int STW  = 577;      // sum of all st_* widths

  // ================= AXI-Lite register file (axil_clk) =================
  logic [31:0] a_group_ip, a_band_base, a_max_spread, a_min_qty, a_order_qty;
  logic [31:0] a_pos_limit, a_sweep_min_levels, a_firm, a_tif, a_ouch_min_qty;
  logic [31:0] a_src_ip, a_dst_ip, a_init_seq, a_ack_num;
  logic [15:0] a_udp_port, a_track_locate, a_max_inflight, a_src_port;
  logic [15:0] a_dst_port, a_window, a_init_id;
  logic [47:0] a_sweep_gap, a_token_prefix, a_dst_mac, a_src_mac;
  logic [63:0] a_stock;
  logic [7:0]  a_display, a_capacity, a_sweep, a_cross, a_cust;
  logic [3:0]  a_ratio_shift;
  logic        a_enable, a_sweep_en, a_load, a_order_ack, a_igmp_en;
  logic [31:0] a_igmp_interval;

  // status, resynced into the axil domain for read-back
  logic [STW-1:0] st_bus_axil;

  axil_regfile #(.ADDR_W(AXIL_AW)) u_regs (
    .aclk(axil_clk), .aresetn(axil_rst_n),
    .s_axil_awaddr(s_axil_awaddr), .s_axil_awvalid(s_axil_awvalid), .s_axil_awready(s_axil_awready),
    .s_axil_wdata(s_axil_wdata), .s_axil_wstrb(s_axil_wstrb), .s_axil_wvalid(s_axil_wvalid), .s_axil_wready(s_axil_wready),
    .s_axil_bresp(s_axil_bresp), .s_axil_bvalid(s_axil_bvalid), .s_axil_bready(s_axil_bready),
    .s_axil_araddr(s_axil_araddr), .s_axil_arvalid(s_axil_arvalid), .s_axil_arready(s_axil_arready),
    .s_axil_rdata(s_axil_rdata), .s_axil_rresp(s_axil_rresp), .s_axil_rvalid(s_axil_rvalid), .s_axil_rready(s_axil_rready),
    .cfg_group_ip(a_group_ip), .cfg_udp_port(a_udp_port), .cfg_track_locate(a_track_locate),
    .cfg_band_base(a_band_base), .cfg_enable(a_enable), .cfg_max_spread(a_max_spread),
    .cfg_ratio_shift(a_ratio_shift), .cfg_min_qty(a_min_qty), .cfg_order_qty(a_order_qty),
    .cfg_pos_limit(a_pos_limit), .cfg_max_inflight(a_max_inflight), .cfg_sweep_en(a_sweep_en),
    .cfg_sweep_min_levels(a_sweep_min_levels), .cfg_sweep_gap(a_sweep_gap),
    .cfg_token_prefix(a_token_prefix), .cfg_stock(a_stock), .cfg_firm(a_firm), .cfg_tif(a_tif),
    .cfg_ouch_min_qty(a_ouch_min_qty), .cfg_display(a_display), .cfg_capacity(a_capacity),
    .cfg_sweep(a_sweep), .cfg_cross(a_cross), .cfg_cust(a_cust),
    .cfg_dst_mac(a_dst_mac), .cfg_src_mac(a_src_mac), .cfg_src_ip(a_src_ip), .cfg_dst_ip(a_dst_ip),
    .cfg_src_port(a_src_port), .cfg_dst_port(a_dst_port), .cfg_init_seq(a_init_seq),
    .cfg_ack_num(a_ack_num), .cfg_window(a_window), .cfg_init_id(a_init_id),
    .cfg_igmp_en(a_igmp_en), .cfg_igmp_interval(a_igmp_interval),
    .cfg_load(a_load), .cfg_order_ack(a_order_ack),
    .st_rx_drop(st_bus_axil[576:545]), .st_rx_hwm(st_bus_axil[544:513]),
    .st_init_done(st_bus_axil[512]), .st_frames_in(st_bus_axil[511:480]),
    .st_frames_kept(st_bus_axil[479:448]), .st_gap_total(st_bus_axil[447:416]),
    .st_ot_overflow(st_bus_axil[415:384]), .st_pl_oob(st_bus_axil[383:352]),
    .st_beat_drop(st_bus_axil[351:320]), .st_msg_drop(st_bus_axil[319:288]),
    .st_delta_drop(st_bus_axil[287:256]), .st_sent(st_bus_axil[255:224]),
    .st_blk_pos(st_bus_axil[223:192]), .st_blk_inflight(st_bus_axil[191:160]),
    .st_blk_txfull(st_bus_axil[159:128]), .st_position(st_bus_axil[127:96]),
    .st_seq_num(st_bus_axil[95:64]), .st_frame_cnt(st_bus_axil[63:32]),
    .st_tx_drop(st_bus_axil[31:0])
  );

  // pack every config word into one bus (order is the contract with the unpack)
  logic [CFGW-1:0] cfg_bus_axil, cfg_bus_core;
  assign cfg_bus_axil = {
    a_group_ip, a_udp_port, a_track_locate, a_band_base, a_enable, a_max_spread,
    a_ratio_shift, a_min_qty, a_order_qty, a_pos_limit, a_max_inflight, a_sweep_en,
    a_sweep_min_levels, a_sweep_gap, a_token_prefix, a_stock, a_firm, a_tif,
    a_ouch_min_qty, a_display, a_capacity, a_sweep, a_cross, a_cust,
    a_dst_mac, a_src_mac, a_src_ip, a_dst_ip, a_src_port, a_dst_port,
    a_init_seq, a_ack_num, a_window, a_init_id, a_igmp_en, a_igmp_interval
  };

  // ================= config crossing (axil -> core) =================
  logic load_core, ack_core;
  cfg_cdc #(.W(CFGW)) u_cfg_cdc (
    .src_clk(axil_clk), .src_rst_n(axil_rst_n), .src_data(cfg_bus_axil), .src_load(a_load),
    .dst_clk(core_clk), .dst_rst_n(core_rst_n), .dst_data(cfg_bus_core), .dst_load(load_core)
  );
  pulse_sync u_ack_sync (
    .src_clk(axil_clk), .src_rst_n(axil_rst_n), .src_pulse(a_order_ack),
    .dst_clk(core_clk), .dst_rst_n(core_rst_n), .dst_pulse(ack_core)
  );

  // unpack in the SAME order -> core-domain config
  logic [31:0] c_group_ip, c_band_base, c_max_spread, c_min_qty, c_order_qty;
  logic [31:0] c_pos_limit, c_sweep_min_levels, c_firm, c_tif, c_ouch_min_qty;
  logic [31:0] c_src_ip, c_dst_ip, c_init_seq, c_ack_num;
  logic [15:0] c_udp_port, c_track_locate, c_max_inflight, c_src_port;
  logic [15:0] c_dst_port, c_window, c_init_id;
  logic [47:0] c_sweep_gap, c_token_prefix, c_dst_mac, c_src_mac;
  logic [63:0] c_stock;
  logic [7:0]  c_display, c_capacity, c_sweep, c_cross, c_cust;
  logic [3:0]  c_ratio_shift;
  logic        c_enable, c_sweep_en, c_igmp_en;
  logic [31:0] c_igmp_interval;
  assign {
    c_group_ip, c_udp_port, c_track_locate, c_band_base, c_enable, c_max_spread,
    c_ratio_shift, c_min_qty, c_order_qty, c_pos_limit, c_max_inflight, c_sweep_en,
    c_sweep_min_levels, c_sweep_gap, c_token_prefix, c_stock, c_firm, c_tif,
    c_ouch_min_qty, c_display, c_capacity, c_sweep, c_cross, c_cust,
    c_dst_mac, c_src_mac, c_src_ip, c_dst_ip, c_src_port, c_dst_port,
    c_init_seq, c_ack_num, c_window, c_init_id, c_igmp_en, c_igmp_interval
  } = cfg_bus_core;

  // ================= the datapath (t2t_top) =================
  logic [DATA_W-1:0]   ord_tdata;
  logic [DATA_W/8-1:0] ord_tkeep;
  logic                ord_tvalid, ord_tlast, ord_tready;
  logic                igmp_query_core;
  logic [STW-1:0]      st_bus_core;

  t2t_top #(.DATA_W(DATA_W), .OT_SETS_BITS(OT_SETS_BITS), .OT_WAYS(OT_WAYS)) u_t2t (
    .cmac_clk(cmac_clk), .cmac_rst_n(cmac_rst_n),
    .rx_tdata(rx_tdata), .rx_tkeep(rx_tkeep), .rx_tvalid(rx_tvalid), .rx_tlast(rx_tlast),
    .tx_tdata(ord_tdata), .tx_tkeep(ord_tkeep), .tx_tvalid(ord_tvalid), .tx_tlast(ord_tlast),
    .tx_tready(ord_tready),
    .core_clk(core_clk), .core_rst_n(core_rst_n),
    .cfg_group_ip(c_group_ip), .cfg_udp_port(c_udp_port), .cfg_track_locate(c_track_locate),
    .cfg_band_base(c_band_base), .cfg_enable(c_enable), .cfg_max_spread(c_max_spread),
    .cfg_ratio_shift(c_ratio_shift), .cfg_min_qty(c_min_qty), .cfg_order_qty(c_order_qty),
    .cfg_pos_limit(c_pos_limit), .cfg_max_inflight(c_max_inflight), .cfg_order_ack(ack_core),
    .cfg_sweep_en(c_sweep_en), .cfg_sweep_min_levels(c_sweep_min_levels), .cfg_sweep_gap(c_sweep_gap),
    .cfg_token_prefix(c_token_prefix), .cfg_stock(c_stock), .cfg_firm(c_firm), .cfg_tif(c_tif),
    .cfg_ouch_min_qty(c_ouch_min_qty), .cfg_display(c_display), .cfg_capacity(c_capacity),
    .cfg_sweep(c_sweep), .cfg_cross(c_cross), .cfg_cust(c_cust),
    .cfg_dst_mac(c_dst_mac), .cfg_src_mac(c_src_mac), .cfg_src_ip(c_src_ip), .cfg_dst_ip(c_dst_ip),
    .cfg_src_port(c_src_port), .cfg_dst_port(c_dst_port), .cfg_init_seq(c_init_seq),
    .cfg_ack_num(c_ack_num), .cfg_window(c_window), .cfg_init_id(c_init_id), .cfg_load(load_core),
    .st_rx_drop(st_bus_core[576:545]), .st_rx_hwm(st_bus_core[544:513]),
    .st_init_done(st_bus_core[512]), .st_frames_in(st_bus_core[511:480]),
    .st_frames_kept(st_bus_core[479:448]), .st_gap_total(st_bus_core[447:416]),
    .st_ot_overflow(st_bus_core[415:384]), .st_pl_oob(st_bus_core[383:352]),
    .st_beat_drop(st_bus_core[351:320]), .st_msg_drop(st_bus_core[319:288]),
    .st_delta_drop(st_bus_core[287:256]), .st_sent(st_bus_core[255:224]),
    .st_blk_pos(st_bus_core[223:192]), .st_blk_inflight(st_bus_core[191:160]),
    .st_blk_txfull(st_bus_core[159:128]), .st_position(st_bus_core[127:96]),
    .st_seq_num(st_bus_core[95:64]), .st_frame_cnt(st_bus_core[63:32]),
    .st_tx_drop(st_bus_core[31:0]),
    .o_igmp_query(igmp_query_core)
  );

  // ================= status crossing (core -> axil) =================
  // Diagnostic counters, so a plain two-flop resync per word: a monitoring read
  // may catch a multi-bit counter mid-increment and be off by a little, which
  // is fine for drop/high-water diagnostics. st_init_done is one bit, so the
  // bring-up "is the table cleared" read is coherent.
  (* ASYNC_REG = "TRUE" *) logic [STW-1:0] st_sync0, st_sync1;
  always_ff @(posedge axil_clk or negedge axil_rst_n)
    if (!axil_rst_n) begin st_sync0 <= '0; st_sync1 <= '0; end
    else             begin st_sync0 <= st_bus_core; st_sync1 <= st_sync0; end
  assign st_bus_axil = st_sync1;

  // ================= IGMP join (core) =================
  // Enable and refresh period come from host config (cfg_igmp_en/_interval).
  // A config commit rejoins the group, but only when IGMP is enabled -- so a
  // deployment that does not want IGMP simply leaves cfg_igmp_en at 0 and no
  // report is ever sent. i_query stays low until an RX-side query detector
  // exists. c_igmp_en updates on the same load_core edge that pulses the join.
  wire igmp_join_now  = load_core       & c_igmp_en;
  wire igmp_query_now = igmp_query_core & c_igmp_en;   // answer queries once joined

  logic [DATA_W-1:0]   ig_tdata;
  logic [DATA_W/8-1:0] ig_tkeep;
  logic                ig_tvalid, ig_tlast, ig_core_ready;
  igmp_join #(.DATA_W(DATA_W)) u_igmp (
    .clk(core_clk), .rst_n(core_rst_n),
    .cfg_group_ip(c_group_ip), .cfg_src_mac(c_src_mac), .cfg_src_ip(c_src_ip),
    .cfg_igmp_en(c_igmp_en), .cfg_interval(c_igmp_interval),
    .i_join(igmp_join_now), .i_query(igmp_query_now),
    .m_tdata(ig_tdata), .m_tkeep(ig_tkeep), .m_tvalid(ig_tvalid), .m_tlast(ig_tlast),
    .m_tready(ig_core_ready), .report_cnt()
  );

  // cross the IGMP frames into the CMAC domain (rare -> a small FIFO)
  logic [DATA_W-1:0]   igc_tdata;
  logic [DATA_W/8-1:0] igc_tkeep;
  logic                igc_tvalid, igc_tlast, igc_tready;
  cdc_fifo #(.DATA_W(DATA_W), .DEPTH(16)) u_igmp_cdc (
    .w_clk(core_clk), .w_rst_n(core_rst_n),
    .s_tdata(ig_tdata), .s_tkeep(ig_tkeep), .s_tvalid(ig_tvalid), .s_tlast(ig_tlast),
    .drop_cnt(), .hwm(),
    .r_clk(cmac_clk), .r_rst_n(cmac_rst_n),
    .m_tdata(igc_tdata), .m_tkeep(igc_tkeep), .m_tvalid(igc_tvalid), .m_tlast(igc_tlast),
    .m_tready(igc_tready)
  );
  // igmp_join's core-side ready: the cdc_fifo has no write backpressure (it
  // drops on full), and reports are rare, so hold it ready.
  assign ig_core_ready = 1'b1;

  // ================= TX arbiter (CMAC): orders + IGMP -> one wire =========
  axis_tx_arb #(.DATA_W(DATA_W)) u_tx_arb (
    .clk(cmac_clk), .rst_n(cmac_rst_n),
    .s0_tdata(ord_tdata), .s0_tkeep(ord_tkeep), .s0_tvalid(ord_tvalid), .s0_tlast(ord_tlast), .s0_tready(ord_tready),
    .s1_tdata(igc_tdata), .s1_tkeep(igc_tkeep), .s1_tvalid(igc_tvalid), .s1_tlast(igc_tlast), .s1_tready(igc_tready),
    .m_tdata(tx_tdata), .m_tkeep(tx_tkeep), .m_tvalid(tx_tvalid), .m_tlast(tx_tlast), .m_tready(tx_tready)
  );

endmodule
