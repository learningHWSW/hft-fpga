// AXI4-Lite slave register file for the tick-to-trade top.
//
// t2t_top exposes its whole configuration as individual cfg_* ports and its
// counters as st_* ports (see t2t_top.sv). On the real board those are not
// wires a host can reach -- they arrive as AXI4-Lite writes over OpenNIC's
// QDMA BAR. This module is that translation: an AXI4-Lite slave whose write
// registers drive the cfg_* outputs and whose read mux returns the st_* inputs.
//
// It is the piece that lets host software (step7 regmap.py) configure the
// design the same way with or without silicon -- off a card the host writes a
// dict, on a card it writes these registers, and the address map here is the
// contract both sides agree on.
//
// ADDRESS MAP (byte offsets, 32-bit words; word index = addr[8:2]):
//   0x00..0xA0  configuration, one word each, in regmap.py REG order
//               (48/64-bit fields split into _lo then _hi words)
//   0xA4        CTRL  -- write bit0 pulses cfg_load, bit1 pulses cfg_order_ack
//   0x100..     status counters (read-only), in t2t_top st_* order
//   0x1FC       ID = "T2T0" (read-only), a bring-up sanity read
//
// Config words read back the value written, so a host -- or the testbench --
// can write then read and diff, which is how this is verified without a card.
//
// ONE CLOCK. The slave runs on aclk; config values are quasi-static (written
// once at setup, guarded by the cfg_load/enable commit), so this is meant to
// sit on the core clock with an upstream AXI clock converter between it and
// QDMA's 250 MHz, rather than carrying a per-bit CDC here. That wrapper is the
// integration step; this file is the slave and is self-contained.
`timescale 1ns/1ps
module axil_regfile #(
  parameter int ADDR_W = 12,          // 4 KB register page
  parameter logic [31:0] ID_VALUE = 32'h5432_5430  // "T2T0"
)(
  input  logic                aclk,
  input  logic                aresetn,

  // ---- AXI4-Lite slave ----
  input  logic [ADDR_W-1:0]   s_axil_awaddr,
  input  logic                s_axil_awvalid,
  output logic                s_axil_awready,
  input  logic [31:0]         s_axil_wdata,
  input  logic [3:0]          s_axil_wstrb,
  input  logic                s_axil_wvalid,
  output logic                s_axil_wready,
  output logic [1:0]          s_axil_bresp,
  output logic                s_axil_bvalid,
  input  logic                s_axil_bready,
  input  logic [ADDR_W-1:0]   s_axil_araddr,
  input  logic                s_axil_arvalid,
  output logic                s_axil_arready,
  output logic [31:0]         s_axil_rdata,
  output logic [1:0]          s_axil_rresp,
  output logic                s_axil_rvalid,
  input  logic                s_axil_rready,

  // ---- configuration outputs (drive t2t_top cfg_* ports) ----
  output logic [31:0]         cfg_group_ip,
  output logic [15:0]         cfg_udp_port,
  output logic [15:0]         cfg_track_locate,
  output logic [31:0]         cfg_band_base,
  output logic                cfg_enable,
  output logic [31:0]         cfg_max_spread,
  output logic [3:0]          cfg_ratio_shift,
  output logic [31:0]         cfg_min_qty,
  output logic [31:0]         cfg_order_qty,
  output logic [31:0]         cfg_pos_limit,
  output logic [15:0]         cfg_max_inflight,
  output logic                cfg_sweep_en,
  output logic [31:0]         cfg_sweep_min_levels,
  output logic [47:0]         cfg_sweep_gap,
  output logic [47:0]         cfg_token_prefix,
  output logic [63:0]         cfg_stock,
  output logic [31:0]         cfg_firm,
  output logic [31:0]         cfg_tif,
  output logic [31:0]         cfg_ouch_min_qty,
  output logic [7:0]          cfg_display,
  output logic [7:0]          cfg_capacity,
  output logic [7:0]          cfg_sweep,
  output logic [7:0]          cfg_cross,
  output logic [7:0]          cfg_cust,
  output logic [47:0]         cfg_dst_mac,
  output logic [47:0]         cfg_src_mac,
  output logic [31:0]         cfg_src_ip,
  output logic [31:0]         cfg_dst_ip,
  output logic [15:0]         cfg_src_port,
  output logic [15:0]         cfg_dst_port,
  output logic [31:0]         cfg_init_seq,
  output logic [31:0]         cfg_ack_num,
  output logic [15:0]         cfg_window,
  output logic [15:0]         cfg_init_id,
  output logic                cfg_igmp_en,
  output logic [31:0]         cfg_igmp_interval,

  // ---- commit pulses (one aclk cycle) ----
  output logic                cfg_load,
  output logic                cfg_order_ack,

  // ---- status inputs (from t2t_top st_* ports) ----
  input  logic [31:0]         st_rx_drop,
  input  logic [31:0]         st_rx_hwm,
  input  logic                st_init_done,
  input  logic [31:0]         st_frames_in,
  input  logic [31:0]         st_frames_kept,
  input  logic [31:0]         st_gap_total,
  input  logic [31:0]         st_ot_overflow,
  input  logic [31:0]         st_pl_oob,
  input  logic [31:0]         st_beat_drop,
  input  logic [31:0]         st_msg_drop,
  input  logic [31:0]         st_delta_drop,
  input  logic [31:0]         st_sent,
  input  logic [31:0]         st_blk_pos,
  input  logic [31:0]         st_blk_inflight,
  input  logic [31:0]         st_blk_txfull,
  input  logic signed [31:0]  st_position,
  input  logic [31:0]         st_seq_num,
  input  logic [31:0]         st_frame_cnt,
  input  logic [31:0]         st_tx_drop
);
  // ---- config word indices (match regmap.py REG order) ----
  localparam int A_GROUP_IP=0,  A_UDP_PORT=1,  A_TRACK_LOCATE=2, A_BAND_BASE=3,
                 A_ENABLE=4,     A_MAX_SPREAD=5, A_RATIO_SHIFT=6,  A_MIN_QTY=7,
                 A_ORDER_QTY=8,  A_POS_LIMIT=9,  A_MAX_INFLIGHT=10,A_SWEEP_EN=11,
                 A_SWEEP_MINLV=12,A_SWEEP_GAP_LO=13,A_SWEEP_GAP_HI=14,
                 A_TOKEN_LO=15,  A_TOKEN_HI=16, A_STOCK_LO=17,   A_STOCK_HI=18,
                 A_FIRM=19,      A_TIF=20,      A_OUCH_MINQ=21,  A_DISPLAY=22,
                 A_CAPACITY=23,  A_SWEEP=24,    A_CROSS=25,      A_CUST=26,
                 A_DSTMAC_LO=27, A_DSTMAC_HI=28,A_SRCMAC_LO=29,  A_SRCMAC_HI=30,
                 A_SRC_IP=31,    A_DST_IP=32,   A_SRC_PORT=33,   A_DST_PORT=34,
                 A_INIT_SEQ=35,  A_ACK_NUM=36,  A_WINDOW=37,     A_INIT_ID=38,
                 A_IGMP_EN=39,   A_IGMP_INTERVAL=40;
  localparam int NCFG   = 41;
  localparam int A_CTRL = 41;         // 0xA4
  localparam int A_STAT = 64;         // 0x100 status base
  localparam int A_ID   = 127;        // 0x1FC

  // Padded to a power of two so an out-of-range write index can never touch it.
  logic [31:0] cfgw [64];

  // ---- write channel: accept when AW+W both offered and B is free ----
  logic [ADDR_W-3:0] widx;
  assign widx = s_axil_awaddr[ADDR_W-1:2];
  wire do_wr = s_axil_awvalid & s_axil_wvalid & ~s_axil_bvalid;
  assign s_axil_awready = do_wr;
  assign s_axil_wready  = do_wr;
  assign s_axil_bresp   = 2'b00;      // always OKAY

  function automatic logic [31:0] wmask(input logic [31:0] old,
                                        input logic [31:0] wd,
                                        input logic [3:0]  strb);
    for (int i = 0; i < 4; i++)
      wmask[i*8 +: 8] = strb[i] ? wd[i*8 +: 8] : old[i*8 +: 8];
  endfunction

  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      for (int i = 0; i < 64; i++) cfgw[i] <= 32'd0;
      s_axil_bvalid <= 1'b0;
      cfg_load      <= 1'b0;
      cfg_order_ack <= 1'b0;
    end else begin
      cfg_load      <= 1'b0;          // default: pulses are one cycle
      cfg_order_ack <= 1'b0;
      if (do_wr) begin
        if (widx < NCFG)
          cfgw[widx[5:0]] <= wmask(cfgw[widx[5:0]], s_axil_wdata, s_axil_wstrb);
        if (widx == A_CTRL) begin
          cfg_load      <= s_axil_wdata[0];
          cfg_order_ack <= s_axil_wdata[1];
        end
        s_axil_bvalid <= 1'b1;
      end else if (s_axil_bvalid & s_axil_bready) begin
        s_axil_bvalid <= 1'b0;
      end
    end
  end

  // ---- read channel ----
  logic [ADDR_W-3:0] ridx;
  assign ridx = s_axil_araddr[ADDR_W-1:2];
  wire do_rd = s_axil_arvalid & ~s_axil_rvalid;
  assign s_axil_arready = do_rd;
  assign s_axil_rresp   = 2'b00;

  function automatic logic [31:0] readmux(input logic [ADDR_W-3:0] idx);
    if (idx < NCFG)          readmux = cfgw[idx[5:0]];
    else if (idx == A_ID)    readmux = ID_VALUE;
    else case (idx)
      A_STAT+0:  readmux = st_rx_drop;
      A_STAT+1:  readmux = st_rx_hwm;
      A_STAT+2:  readmux = {31'd0, st_init_done};
      A_STAT+3:  readmux = st_frames_in;
      A_STAT+4:  readmux = st_frames_kept;
      A_STAT+5:  readmux = st_gap_total;
      A_STAT+6:  readmux = st_ot_overflow;
      A_STAT+7:  readmux = st_pl_oob;
      A_STAT+8:  readmux = st_beat_drop;
      A_STAT+9:  readmux = st_msg_drop;
      A_STAT+10: readmux = st_delta_drop;
      A_STAT+11: readmux = st_sent;
      A_STAT+12: readmux = st_blk_pos;
      A_STAT+13: readmux = st_blk_inflight;
      A_STAT+14: readmux = st_blk_txfull;
      A_STAT+15: readmux = st_position;
      A_STAT+16: readmux = st_seq_num;
      A_STAT+17: readmux = st_frame_cnt;
      A_STAT+18: readmux = st_tx_drop;
      default:   readmux = 32'd0;
    endcase
  endfunction

  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      s_axil_rvalid <= 1'b0;
      s_axil_rdata  <= 32'd0;
    end else begin
      if (do_rd) begin
        s_axil_rdata  <= readmux(ridx);
        s_axil_rvalid <= 1'b1;
      end else if (s_axil_rvalid & s_axil_rready) begin
        s_axil_rvalid <= 1'b0;
      end
    end
  end

  // ---- assemble typed config outputs from the word array ----
  assign cfg_group_ip         = cfgw[A_GROUP_IP];
  assign cfg_udp_port         = cfgw[A_UDP_PORT][15:0];
  assign cfg_track_locate     = cfgw[A_TRACK_LOCATE][15:0];
  assign cfg_band_base        = cfgw[A_BAND_BASE];
  assign cfg_enable           = cfgw[A_ENABLE][0];
  assign cfg_max_spread       = cfgw[A_MAX_SPREAD];
  assign cfg_ratio_shift      = cfgw[A_RATIO_SHIFT][3:0];
  assign cfg_min_qty          = cfgw[A_MIN_QTY];
  assign cfg_order_qty        = cfgw[A_ORDER_QTY];
  assign cfg_pos_limit        = cfgw[A_POS_LIMIT];
  assign cfg_max_inflight     = cfgw[A_MAX_INFLIGHT][15:0];
  assign cfg_sweep_en         = cfgw[A_SWEEP_EN][0];
  assign cfg_sweep_min_levels = cfgw[A_SWEEP_MINLV];
  assign cfg_sweep_gap        = {cfgw[A_SWEEP_GAP_HI][15:0], cfgw[A_SWEEP_GAP_LO]};
  assign cfg_token_prefix     = {cfgw[A_TOKEN_HI][15:0],     cfgw[A_TOKEN_LO]};
  assign cfg_stock            = {cfgw[A_STOCK_HI],           cfgw[A_STOCK_LO]};
  assign cfg_firm             = cfgw[A_FIRM];
  assign cfg_tif              = cfgw[A_TIF];
  assign cfg_ouch_min_qty     = cfgw[A_OUCH_MINQ];
  assign cfg_display          = cfgw[A_DISPLAY][7:0];
  assign cfg_capacity         = cfgw[A_CAPACITY][7:0];
  assign cfg_sweep            = cfgw[A_SWEEP][7:0];
  assign cfg_cross            = cfgw[A_CROSS][7:0];
  assign cfg_cust             = cfgw[A_CUST][7:0];
  assign cfg_dst_mac          = {cfgw[A_DSTMAC_HI][15:0], cfgw[A_DSTMAC_LO]};
  assign cfg_src_mac          = {cfgw[A_SRCMAC_HI][15:0], cfgw[A_SRCMAC_LO]};
  assign cfg_src_ip           = cfgw[A_SRC_IP];
  assign cfg_dst_ip           = cfgw[A_DST_IP];
  assign cfg_src_port         = cfgw[A_SRC_PORT][15:0];
  assign cfg_dst_port         = cfgw[A_DST_PORT][15:0];
  assign cfg_init_seq         = cfgw[A_INIT_SEQ];
  assign cfg_ack_num          = cfgw[A_ACK_NUM];
  assign cfg_window           = cfgw[A_WINDOW][15:0];
  assign cfg_init_id          = cfgw[A_INIT_ID][15:0];
  assign cfg_igmp_en          = cfgw[A_IGMP_EN][0];
  assign cfg_igmp_interval    = cfgw[A_IGMP_INTERVAL];

endmodule
