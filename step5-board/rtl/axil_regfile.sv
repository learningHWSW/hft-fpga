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
//   0x00..0xA4  configuration, one word each, in regmap.py REG order
//               (48/64-bit fields split into _lo then _hi words)
//   0xA8        CTRL  -- write bit0 pulses cfg_load, bit1 pulses cfg_order_ack
//   0x100..     status counters (read-only), append-only: the first 19 are in
//               t2t_top st_* order, later ones are appended in the order they
//               were published, because an offset once shipped cannot move
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
  // Tracked symbols. Symbol 0's locate/base/stock keep the registers they have
  // always had; symbols 1..NSYM-1 come from the per-symbol block below. That
  // asymmetry is deliberate -- moving symbol 0 into a uniform block would move
  // four shipped offsets to make the map prettier.
  parameter int NSYM   = 1,
  // Reported read-only at A_STAT+37 so a host can ask the bitstream what
  // geometry it is. Purely informational to the RTL; see the register below.
  parameter int OT_SETS_BITS = 13,
  parameter int OT_WAYS      = 16,
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
  output logic [NSYM*16-1:0]  cfg_track_locate,
  output logic [NSYM*32-1:0]  cfg_band_base,
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
  output logic [NSYM*64-1:0]  cfg_stock,
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
  output logic [31:0]         cfg_group_ip_b,

  // ---- commit pulses (one aclk cycle) ----
  output logic                cfg_load,
  output logic                cfg_order_ack,
  output logic                cfg_resend_req,     // pulse, A_CTRL bit 2
  output logic [3:0]          cfg_resend_age,
  output logic                cfg_rto_en,
  output logic [31:0]         cfg_rto_cycles,
  output logic [3:0]          cfg_rto_retries,

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
  // One signed position per symbol, packed. The readmux publishes symbol 0 at
  // the offset it has always had, and symbols 1..4 in a block appended at the
  // end -- see A_STAT+32 below.
  input  logic [NSYM*32-1:0]  st_position_all,
  input  logic [31:0]         st_seq_num,
  input  logic [31:0]         st_frame_cnt,
  input  logic [31:0]         st_tx_drop,
  // Appended after st_tx_drop, not slotted in beside the counters they belong
  // with: a status offset is a published contract (regmap.py, t2t_regs.h, any
  // script a run left behind), so the list only ever grows at the end.
  input  logic [31:0]         st_bbo_early,      // BBO records answered by fast_bbo
  input  logic [31:0]         st_bbo_late,       // ... and by price_ladder
  input  logic [31:0]         st_bbo_mismatch,   // the two disagreeing: must be 0
  input  logic [31:0]         st_rx_peer_ack,    // last ack the venue sent us
  input  logic [31:0]         st_rx_ooo,
  input  logic [31:0]         st_rx_dup,
  input  logic [31:0]         st_rx_sess_frames,
  input  logic [31:0]         st_rto_fired,      // resends the card asked for itself
  input  logic [31:0]         st_rto_gaveup,     // frames abandoned at the retry cap
  input  logic [31:0]         st_rb_stored,      // frames the replay buffer kept
  input  logic [31:0]         st_rb_resent,      // ... and handed back out again
  input  logic [31:0]         st_rb_drop,        // resend asked for a slot never filled
  input  logic [31:0]         st_blk_qty,        // orders blocked: shares out of range
  input  logic [31:0]         st_bbo_arb_drop    // BBO records lost merging K books
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
                 A_IGMP_EN=39,   A_IGMP_INTERVAL=40, A_GROUP_IP_B=41;
  localparam int NCFG   = 47;
  localparam int A_RESEND_AGE = 43;   // 0xAC  which stored frame to re-send
  // Automatic retransmission (tx_rto). These sit ABOVE ctrl rather than inside
  // the config block for the same reason A_RESEND_AGE does: the block is packed
  // from word 0 and ctrl sits immediately after it, so adding a word there would
  // move ctrl, the status base and the ID -- offsets that have shipped.
  localparam int A_RTO_EN      = 44;  // 0xB0  bit0: enable the detector
  localparam int A_RTO_CYCLES  = 45;  // 0xB4  idle core cycles before a resend
  localparam int A_RTO_RETRIES = 46;  // 0xB8  attempts per unacknowledged frame
  localparam int A_CTRL = 42;         // 0xA8
  // Per-symbol config block, four words per symbol for symbols 1 and up:
  //   +0 track locate, +1 band base, +2 stock lo, +3 stock hi
  // It sits at 0x0C0 (word 48), in the gap between the RTO words and the
  // status base, so nothing that has shipped moves. Sixteen words is four
  // symbols, i.e. NSYM up to 5; beyond that the map needs extending, and so
  // does the order table (FINDINGS §4.4 sizes it).
  localparam int A_SYM  = 48;         // 0x0C0
  localparam int SYM_MAX = 5;         // symbol 0 + four in the block (regmap.py)
  localparam int A_STAT = 64;         // 0x100 status base
  localparam int A_ID   = 127;        // 0x1FC

  // Padded to a power of two so an out-of-range write index can never touch it.
  logic [31:0] cfgw [64];

  // Which word indices are backed by cfgw. The config block proper is 0..NCFG-1,
  // and the per-symbol block is a SECOND range above it -- so this cannot be the
  // single `idx < NCFG` comparison it used to be. It was, and the consequence was
  // that every write to the per-symbol block was silently dropped: the address
  // decoded, the bus returned OKAY, and symbol 1 stayed unconfigured. The write
  // enable and the read mux both call this, so they cannot disagree about what
  // is a register.
  function automatic logic is_cfg(input logic [ADDR_W-3:0] idx);
    return (idx < NCFG) || (idx >= A_SYM && idx < A_SYM + 4*(SYM_MAX-1));
  endfunction

  // Positions widened to the map's fixed five slots, so the read mux can name
  // any of them whatever NSYM the build has and no part-select is out of range.
  //
  // This was a function returning st_position[32*k +: 32], called from four
  // continuous assigns, and it did not work: a function that reads a MODULE
  // SIGNAL rather than taking it as an argument has no sensitivity to that
  // signal in a continuous assign, so it evaluates once at time zero -- when
  // st_position is still X -- and never again. step 3b hit the identical bug
  // (mold_splitter.sv's note about w_be16 and `win`), which is why an
  // always_comb is used here instead: it is sensitive to what it reads.
  logic [SYM_MAX*32-1:0] pos_padded;
  always_comb begin
    pos_padded = '0;
    pos_padded[NSYM*32-1:0] = st_position_all;
  end
  // Named rather than sliced inline in the read mux, because step7's
  // test_regmap.py parses those lines to check the RTL's offsets against the
  // host's list, and `pos_padded[32*2 +: 32]` would be an offset the contract
  // test cannot see.
  // Named, like the positions below and for the same reason: test_regmap.py
  // parses these lines, so an offset the RTL does not say out loud is an offset
  // the contract test cannot check.
  wire [31:0] st_build_geom = {8'd0, 8'(OT_WAYS), 8'(OT_SETS_BITS), 8'(NSYM)};
  // symbol 0, at the offset it has always had -- named so the read mux says it
  wire [31:0] st_position   = pos_padded[32*0 +: 32];
  wire [31:0] st_position_1 = pos_padded[32*1 +: 32];
  wire [31:0] st_position_2 = pos_padded[32*2 +: 32];
  wire [31:0] st_position_3 = pos_padded[32*3 +: 32];
  wire [31:0] st_position_4 = pos_padded[32*4 +: 32];

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
      cfg_load       <= 1'b0;
      cfg_order_ack  <= 1'b0;
      cfg_resend_req <= 1'b0;
    end else begin
      cfg_load       <= 1'b0;          // default: pulses are one cycle
      cfg_order_ack  <= 1'b0;
      cfg_resend_req <= 1'b0;
      if (do_wr) begin
        if (is_cfg(widx))
          cfgw[widx[5:0]] <= wmask(cfgw[widx[5:0]], s_axil_wdata, s_axil_wstrb);
        if (widx == A_CTRL) begin
          cfg_load       <= s_axil_wdata[0];
          cfg_order_ack  <= s_axil_wdata[1];
          cfg_resend_req <= s_axil_wdata[2];
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
    if (is_cfg(idx))         readmux = cfgw[idx[5:0]];
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
      A_STAT+15: readmux = st_position;         // symbol 0, its shipped offset
      A_STAT+16: readmux = st_seq_num;
      A_STAT+17: readmux = st_frame_cnt;
      A_STAT+18: readmux = st_tx_drop;
      A_STAT+19: readmux = st_bbo_early;
      A_STAT+20: readmux = st_bbo_late;
      A_STAT+21: readmux = st_bbo_mismatch;
      A_STAT+22: readmux = st_rx_peer_ack;
      A_STAT+23: readmux = st_rx_ooo;
      A_STAT+24: readmux = st_rx_dup;
      A_STAT+25: readmux = st_rx_sess_frames;
      A_STAT+26: readmux = st_rto_fired;
      A_STAT+27: readmux = st_rto_gaveup;
      A_STAT+28: readmux = st_rb_stored;
      A_STAT+29: readmux = st_rb_resent;
      A_STAT+30: readmux = st_rb_drop;
      A_STAT+31: readmux = st_blk_qty;
      // Per-symbol positions for symbols 1..4. Always four entries whatever
      // NSYM is: a read mux whose LENGTH depended on a parameter would make the
      // address map a function of the build, and the map is a contract with
      // hosts that were compiled against it. Symbols the build does not have
      // read as zero, which is also their position.
      A_STAT+32: readmux = st_position_1;
      A_STAT+33: readmux = st_position_2;
      A_STAT+34: readmux = st_position_3;
      A_STAT+35: readmux = st_position_4;
      A_STAT+36: readmux = st_bbo_arb_drop;
      // BUILD GEOMETRY, read-only and constant: {8'0, OT_WAYS, OT_SETS_BITS, NSYM}.
      // A bitstream that cannot say what it is gets configured as something it
      // is not. That happened: a kernel packaged with the geometry set the wrong
      // way produced a single-symbol build, accepted a second symbol's config
      // without complaint, ran clean, and traded one name -- and the only reason
      // it was caught was someone reading URAM counts out of a utilization
      // report. One constant word makes it a question the host can just ask.
      A_STAT+37: readmux = st_build_geom;
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
  // symbol 0 from its shipped registers, symbols 1.. from the per-symbol block
  assign cfg_track_locate[15:0] = cfgw[A_TRACK_LOCATE][15:0];
  assign cfg_band_base[31:0]    = cfgw[A_BAND_BASE];
  for (genvar k = 1; k < NSYM; k++) begin : g_sym_cfg
    assign cfg_track_locate[16*k +: 16] = cfgw[A_SYM + 4*(k-1) + 0][15:0];
    assign cfg_band_base   [32*k +: 32] = cfgw[A_SYM + 4*(k-1) + 1];
    assign cfg_stock       [64*k +: 64] = {cfgw[A_SYM + 4*(k-1) + 3],
                                           cfgw[A_SYM + 4*(k-1) + 2]};
  end
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
  assign cfg_stock[63:0]      = {cfgw[A_STOCK_HI],           cfgw[A_STOCK_LO]};
  assign cfg_firm             = cfgw[A_FIRM];
  assign cfg_tif              = cfgw[A_TIF];
  assign cfg_ouch_min_qty     = cfgw[A_OUCH_MINQ];
  assign cfg_resend_age       = cfgw[A_RESEND_AGE][3:0];
  assign cfg_rto_en           = cfgw[A_RTO_EN][0];
  assign cfg_rto_cycles       = cfgw[A_RTO_CYCLES];
  assign cfg_rto_retries      = cfgw[A_RTO_RETRIES][3:0];
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
  assign cfg_group_ip_b       = cfgw[A_GROUP_IP_B];

endmodule
