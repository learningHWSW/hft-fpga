// Phase B kernel: the same datapath, but the frames become signals.
//
// WHAT CHANGES FROM t2t_kernel.sv, and what deliberately does not. Phase A put
// eth_replay directly on the datapath's RX port and eth_capture directly on its
// TX port. Everything in between was real -- real decode, real order table, real
// strategy, byte-identical order frames against the simulation golden -- but the
// stream never left the fabric. Here it does:
//
//     HBM -> eth_replay -> [S&F] --\
//                                   >-- arb -> CMAC TX -> GT serializer
//     t2t_axil TX ------> [S&F] --/                          |
//                                                     near-end PMA loopback
//                                                            |
//     t2t_axil RX <---------------------------- CMAC RX <----/
//     eth_capture <- [CDC] <- TCP filter <-----------'
//
// So each feed frame is 64b/66b encoded, serialized at 25.78125 Gb/s on four
// lanes, recovered by the GT's CDR, block-locked, lane-aligned, FCS-checked and
// handed back -- and the order frames the strategy produces make the same trip
// outward. The golden diff then means something stronger than it did in Phase A:
// not "the datapath computes the right orders" but "the right orders come off a
// 100 Gb/s MAC".
//
// The datapath itself is untouched. t2t_axil is instantiated with exactly the
// clocks it was designed for -- a 322.265625 MHz wire side, a slower core, a
// separate AXI-Lite domain -- which Phase A had to fake with ap_clk. This build
// is the first time the CMAC clock in the design is an actual CMAC clock.
//
// THREE CLOCK DOMAINS, and why the third is not optional:
//   ap_clk    300 MHz, from the platform: control plane, both HBM masters,
//             eth_replay and eth_capture. HBM lives here and cannot move.
//   ap_clk_2  215 MHz: the datapath core. Set by what the order table's URAM
//             closes at, measured, not chosen.
//   wire_clk  322.265625 MHz, gt_txusrclk2 out of the MAC. Not a platform clock
//             at all -- it is recovered from the GT's own reference, so it is
//             asynchronous to both of the above no matter what their frequencies
//             are, and every crossing to it is a real CDC.
//
// init_clk is a fourth clock but not a fourth domain: the CMAC's GT reset
// controller and DRP need a free-running ~100 MHz reference, and the IP is
// generated for exactly 100.00 MHz (GT_DRP_CLK), which sizes its internal reset
// timers. Feeding it ap_clk's 300 MHz would make every one of those timers three
// times too short -- the sort of thing that produces a GT that sometimes comes
// up. A BUFGCE_DIV of three off ap_clk gives 100.000 MHz exactly, with no MMCM
// and no extra IP in the kernel.
//
// WHY THE STORE-AND-FORWARD FIFOs EXIST is in axis_sf_fifo.sv, and why the RX
// path needs a protocol filter is in axis_frame_filter.sv. Both are consequences
// of loopback rather than of the MAC: in loopback our own transmissions come
// back at us, and the design has to be honest about which returning frames are
// the feed and which are its own.
`timescale 1ns/1ps
import t2t_geom_pkg::*;
module t2t_kernel_b #(
  parameter int DATA_W       = 512,
  parameter int ADDR_W       = 64,
  // Geometry defaults come from a GENERATED PACKAGE, not from literals and not
  // from `defines. Neither of the other two reaches v++: ipx::package_project
  // packages SOURCES, so a `generic` on the fileset is not carried, the packager
  // strips user parameters, and a verilog_define set on the packaging project is
  // not seen by v++'s own synthesis of the kernel. A generated source file IS
  // packaged into the .xo, so it travels with the design -- and the same file
  // feeds the simulation, so there is one mechanism rather than two.
  parameter int OT_SETS_BITS = t2t_geom_pkg::OT_SETS_BITS,
  parameter int OT_WAYS      = t2t_geom_pkg::OT_WAYS,
  // Tracked symbols. Moves together with OT_SETS_BITS by hand and not by
  // implication -- 2^13 x 16 holds exactly one name, and the resize is where
  // the timing difficulty is (FINDINGS 4.4), so a build must state both.
  parameter int NSYM         = t2t_geom_pkg::NSYM
)(
  // ---- Vitis kernel clocks and resets ----
  input  logic         ap_clk,
  input  logic         ap_rst_n,
  input  logic         ap_clk_2,
  input  logic         ap_rst_n_2,

  // ---- QSFP0 quad: four lanes and their reference clock ----
  input  logic         gt_refclk_p,
  input  logic         gt_refclk_n,
  input  logic [3:0]   gt_rxp_in,
  input  logic [3:0]   gt_rxn_in,
  output logic [3:0]   gt_txp_out,
  output logic [3:0]   gt_txn_out,

  // ---- AXI4-Lite control slave ----
  input  logic [12:0]  s_axi_control_AWADDR,
  input  logic         s_axi_control_AWVALID,
  output logic         s_axi_control_AWREADY,
  input  logic [31:0]  s_axi_control_WDATA,
  input  logic [3:0]   s_axi_control_WSTRB,
  input  logic         s_axi_control_WVALID,
  output logic         s_axi_control_WREADY,
  output logic [1:0]   s_axi_control_BRESP,
  output logic         s_axi_control_BVALID,
  input  logic         s_axi_control_BREADY,
  input  logic [12:0]  s_axi_control_ARADDR,
  input  logic         s_axi_control_ARVALID,
  output logic         s_axi_control_ARREADY,
  output logic [31:0]  s_axi_control_RDATA,
  output logic [1:0]   s_axi_control_RRESP,
  output logic         s_axi_control_RVALID,
  input  logic         s_axi_control_RREADY,

  // ---- AXI4 master 0: replay source (read only) ----
  output logic [ADDR_W-1:0]   m_axi_gmem0_AWADDR,
  output logic [7:0]          m_axi_gmem0_AWLEN,
  output logic [2:0]          m_axi_gmem0_AWSIZE,
  output logic [1:0]          m_axi_gmem0_AWBURST,
  output logic                m_axi_gmem0_AWVALID,
  input  logic                m_axi_gmem0_AWREADY,
  output logic [DATA_W-1:0]   m_axi_gmem0_WDATA,
  output logic [DATA_W/8-1:0] m_axi_gmem0_WSTRB,
  output logic                m_axi_gmem0_WLAST,
  output logic                m_axi_gmem0_WVALID,
  input  logic                m_axi_gmem0_WREADY,
  input  logic [1:0]          m_axi_gmem0_BRESP,
  input  logic                m_axi_gmem0_BVALID,
  output logic                m_axi_gmem0_BREADY,
  output logic [ADDR_W-1:0]   m_axi_gmem0_ARADDR,
  output logic [7:0]          m_axi_gmem0_ARLEN,
  output logic [2:0]          m_axi_gmem0_ARSIZE,
  output logic [1:0]          m_axi_gmem0_ARBURST,
  output logic                m_axi_gmem0_ARVALID,
  input  logic                m_axi_gmem0_ARREADY,
  input  logic [DATA_W-1:0]   m_axi_gmem0_RDATA,
  input  logic                m_axi_gmem0_RLAST,
  input  logic [1:0]          m_axi_gmem0_RRESP,
  input  logic                m_axi_gmem0_RVALID,
  output logic                m_axi_gmem0_RREADY,

  // ---- AXI4 master 1: capture sink (write only) ----
  output logic [ADDR_W-1:0]   m_axi_gmem1_AWADDR,
  output logic [7:0]          m_axi_gmem1_AWLEN,
  output logic [2:0]          m_axi_gmem1_AWSIZE,
  output logic [1:0]          m_axi_gmem1_AWBURST,
  output logic                m_axi_gmem1_AWVALID,
  input  logic                m_axi_gmem1_AWREADY,
  output logic [DATA_W-1:0]   m_axi_gmem1_WDATA,
  output logic [DATA_W/8-1:0] m_axi_gmem1_WSTRB,
  output logic                m_axi_gmem1_WLAST,
  output logic                m_axi_gmem1_WVALID,
  input  logic                m_axi_gmem1_WREADY,
  input  logic [1:0]          m_axi_gmem1_BRESP,
  input  logic                m_axi_gmem1_BVALID,
  output logic                m_axi_gmem1_BREADY,
  output logic [ADDR_W-1:0]   m_axi_gmem1_ARADDR,
  output logic [7:0]          m_axi_gmem1_ARLEN,
  output logic [2:0]          m_axi_gmem1_ARSIZE,
  output logic [1:0]          m_axi_gmem1_ARBURST,
  output logic                m_axi_gmem1_ARVALID,
  input  logic                m_axi_gmem1_ARREADY,
  input  logic [DATA_W-1:0]   m_axi_gmem1_RDATA,
  input  logic                m_axi_gmem1_RLAST,
  input  logic [1:0]          m_axi_gmem1_RRESP,
  input  logic                m_axi_gmem1_RVALID,
  output logic                m_axi_gmem1_RREADY
);
  localparam int KEEP_W = DATA_W / 8;

  // register offsets within the harness window (0x0040..0x0FFF; 0x1000+ is
  // t2t_axil's own file, unchanged, so step7-host/host/regmap.py still applies)
  localparam logic [12:0] R_ID        = 13'h040;   // "T2K2"
  localparam logic [12:0] R_CTRL      = 13'h044;
  localparam logic [12:0] R_RP_BASE_L = 13'h048;
  localparam logic [12:0] R_RP_BASE_H = 13'h04C;
  localparam logic [12:0] R_RP_BEATS  = 13'h050;
  localparam logic [12:0] R_RP_GAP    = 13'h054;
  localparam logic [12:0] R_CP_BASE_L = 13'h058;
  localparam logic [12:0] R_CP_BASE_H = 13'h05C;
  localparam logic [12:0] R_CP_RECS   = 13'h060;
  localparam logic [12:0] R_STATUS    = 13'h064;
  localparam logic [12:0] R_RP_FRAMES = 13'h068;
  localparam logic [12:0] R_RP_BEATSO = 13'h06C;
  localparam logic [12:0] R_CP_FRAMES = 13'h070;
  localparam logic [12:0] R_CP_BEATS  = 13'h074;
  localparam logic [12:0] R_CP_OVF    = 13'h078;
  localparam logic [12:0] R_CP_STALL  = 13'h07C;
  localparam logic [12:0] R_L_QUIET   = 13'h080;
  localparam logic [12:0] R_L_MIN     = 13'h084;
  localparam logic [12:0] R_L_MAX     = 13'h088;
  localparam logic [12:0] R_L_LAST    = 13'h08C;
  localparam logic [12:0] R_L_SUM_LO  = 13'h090;
  localparam logic [12:0] R_L_SUM_HI  = 13'h094;
  localparam logic [12:0] R_L_SAMPLES = 13'h098;
  localparam logic [12:0] R_L_EXCL    = 13'h09C;
  localparam logic [12:0] R_L_ORPHANS = 13'h0A0;
  localparam logic [12:0] R_L_HIST    = 13'h0C0;   // 16 words, 0x0C0..0x0FC
  localparam logic [12:0] R_M_MIN     = 13'h100;
  localparam logic [12:0] R_M_MAX     = 13'h104;
  localparam logic [12:0] R_M_LAST    = 13'h108;
  localparam logic [12:0] R_M_SUM_LO  = 13'h10C;
  localparam logic [12:0] R_M_SUM_HI  = 13'h110;
  localparam logic [12:0] R_M_SAMPLES = 13'h114;
  localparam logic [12:0] R_M_MISSES  = 13'h118;
  localparam logic [12:0] R_M_HIST    = 13'h180;   // 24 words, 0x180..0x1DC
  // ---- Phase B only: the MAC and the paths around it ----
  localparam logic [12:0] R_C_STATUS  = 13'h200;   // {.., link_up, rx_aligned}
  localparam logic [12:0] R_C_TXPKT   = 13'h204;
  localparam logic [12:0] R_C_RXPKT   = 13'h208;
  localparam logic [12:0] R_C_RXERR   = 13'h20C;
  localparam logic [12:0] R_C_UNF     = 13'h210;   // TX underrun: see cmac_wrap
  localparam logic [12:0] R_C_OVFL    = 13'h214;
  localparam logic [12:0] R_C_FLT_P   = 13'h218;   // frames kept for capture
  localparam logic [12:0] R_C_FLT_D   = 13'h21C;   // frames dropped (feed, ARP)
  localparam logic [12:0] R_C_CAPDROP = 13'h220;   // lost in the capture CDC
  localparam logic [12:0] R_C_FEEDHWM = 13'h224;
  localparam logic [12:0] R_C_ORDHWM  = 13'h228;

  localparam int NBUCKET  = 16;
  localparam int MBUCKET  = 24;

  localparam logic [31:0] KERNEL_ID = 32'h5432_4B32;   // "T2K2"

  // ================= harness registers =================
  logic [63:0] rp_base, cp_base;
  logic [31:0] rp_beats, cp_recs;
  logic [15:0] rp_gap;
  logic        rp_start, cp_clear;
  logic [7:0]  soft_rst_cnt;
  logic        loopback_en;

  logic        rp_busy, rp_done;
  logic [31:0] rp_frames, rp_beats_out;
  logic [31:0] cp_frames, cp_beats, cp_ovf, cp_stall;

  logic [15:0] l_quiet;
  logic        l_clear;
  logic [31:0] l_min, l_max, l_last, l_sum_lo, l_sum_hi;
  logic [31:0] l_samples, l_excluded, l_orphans;
  logic [31:0] l_hist [NBUCKET];

  logic [31:0] m_min_c, m_max_c, m_last_c, m_sum_lo_c, m_sum_hi_c,
               m_samples_c, m_misses_c;
  logic [31:0] m_hist_c [MBUCKET];
  logic [31:0] m_min, m_max, m_last, m_sum_lo, m_sum_hi, m_samples, m_misses;
  logic [31:0] m_hist [MBUCKET];

  logic        dec_valid_c, ord_valid_c;
  logic [47:0] dec_ts_c, ord_ts_c;

  // ================= init_clk: 100 MHz, free-running =================
  // BUFGCE_DIV rather than an MMCM because the ratio is exact and integral, and
  // because a divider is one primitive with no lock time and no extra IP to
  // package into the .xo. Vivado infers the generated clock from the primitive,
  // so the CMAC's own timing constraints on init_clk resolve without help.
  logic init_clk;
`ifndef CMAC_SIM
  BUFGCE_DIV #(
    .BUFGCE_DIVIDE  (3),
    .IS_CE_INVERTED (1'b0),
    .IS_CLR_INVERTED(1'b0),
    .IS_I_INVERTED  (1'b0)
  ) u_init_div (
    .O(init_clk), .CE(1'b1), .CLR(1'b0), .I(ap_clk)
  );
`else
  // The behavioural CMAC does not use init_clk for anything, and pulling the
  // unisim libraries into the testbench elaboration to model one primitive is
  // not worth it. A divide-by-three counter keeps the net alive.
  logic [1:0] init_div_q = 2'd0;
  always_ff @(posedge ap_clk) init_div_q <= (init_div_q == 2'd2) ? 2'd0 : init_div_q + 2'd1;
  assign init_clk = (init_div_q == 2'd0);
`endif

  // ================= the MAC =================
  logic              wire_clk, wire_rst_n_raw;
  logic [DATA_W-1:0] mac_tx_tdata, mac_rx_tdata;
  logic [KEEP_W-1:0] mac_tx_tkeep, mac_rx_tkeep;
  logic              mac_tx_tvalid, mac_tx_tlast, mac_tx_tready;
  logic              mac_rx_tvalid, mac_rx_tlast, mac_rx_terr;
  logic              cm_aligned, cm_link_up;
  logic [31:0]       cm_txpkt, cm_rxpkt, cm_rxerr, cm_unf, cm_ovf;

  cmac_wrap #(.DATA_W(DATA_W)) u_cmac (
    .gt_refclk_p(gt_refclk_p), .gt_refclk_n(gt_refclk_n),
    .gt_rxp_in(gt_rxp_in), .gt_rxn_in(gt_rxn_in),
    .gt_txp_out(gt_txp_out), .gt_txn_out(gt_txn_out),
    .init_clk(init_clk), .sys_rst(!ap_rst_n), .loopback_en(loopback_en),
    .tx_clk(wire_clk), .tx_rst_n(wire_rst_n_raw),
    .s_tdata(mac_tx_tdata), .s_tkeep(mac_tx_tkeep),
    .s_tvalid(mac_tx_tvalid), .s_tlast(mac_tx_tlast), .s_tready(mac_tx_tready),
    .m_tdata(mac_rx_tdata), .m_tkeep(mac_rx_tkeep),
    .m_tvalid(mac_rx_tvalid), .m_tlast(mac_rx_tlast), .m_terr(mac_rx_terr),
    .rx_aligned(cm_aligned), .link_up(cm_link_up),
    .c_tx_pkts(cm_txpkt), .c_rx_pkts(cm_rxpkt), .c_rx_err(cm_rxerr),
    .c_underflow(cm_unf), .c_overflow(cm_ovf)
  );

  // ================= AXI4-Lite control front end =================
  logic [11:0] t_awaddr, t_araddr;
  logic        t_awvalid, t_awready, t_wvalid, t_wready, t_bvalid, t_bready;
  logic        t_arvalid, t_arready, t_rvalid, t_rready;
  logic [31:0] t_wdata, t_rdata;
  logic [3:0]  t_wstrb;
  logic [1:0]  t_bresp, t_rresp;

  typedef enum logic [1:0] { W_IDLE, W_FWD, W_WAITB, W_RESP } wst_t;
  typedef enum logic [1:0] { R_IDLE, R_FWD, R_WAITR, R_RESP } rst_t;
  wst_t wst;
  rst_t rst_s;

  logic [12:0] wr_addr, rd_addr;
  logic [31:0] wr_data, rd_data;

  wire w_accept = (wst == W_IDLE) && s_axi_control_AWVALID && s_axi_control_WVALID;

  assign s_axi_control_AWREADY = w_accept;
  assign s_axi_control_WREADY  = w_accept;
  assign s_axi_control_BRESP   = 2'b00;
  assign s_axi_control_BVALID  = (wst == W_RESP);

  assign s_axi_control_ARREADY = (rst_s == R_IDLE);
  assign s_axi_control_RRESP   = 2'b00;
  assign s_axi_control_RVALID  = (rst_s == R_RESP);
  assign s_axi_control_RDATA   = rd_data;

  assign t_awaddr = wr_addr[11:0];
  assign t_araddr = rd_addr[11:0];
  assign t_wdata  = wr_data;
  assign t_wstrb  = 4'hF;
  assign t_bready = 1'b1;
  assign t_rready = 1'b1;

  wire soft_rst_active = (soft_rst_cnt != '0);

  // ---- CMAC status, resynchronised to ap_clk for readback ----
  // Free-running counters read for diagnostics: two flops, no handshake, the
  // same treatment t2t_axil gives its own status bus. A read may catch a counter
  // mid-increment and be off by one, which does not matter for any of them.
  // EVERYTHING GENERATED IN wire_clk GOES THROUGH HERE, including the two that
  // are easy to miss because they belong to FIFOs rather than to the MAC:
  // u_cap_cdc's drop count and u_ord_fifo's high-water mark are both maintained
  // in those FIFOs' WRITE domains, which is wire_clk, not ap_clk. Reading them
  // straight into the AXI-Lite mux would be an unsynchronised crossing on the
  // one path whose whole job is to tell the operator whether the run can be
  // believed -- a torn cap_drop reads as either a phantom failure or, worse, a
  // real one hidden. u_feed_fifo's hwm is NOT here: its write domain is ap_clk.
  (* ASYNC_REG = "TRUE" *) logic [31:0] cs0 [9];
  (* ASYNC_REG = "TRUE" *) logic [31:0] cs1 [9];
  (* ASYNC_REG = "TRUE" *) logic [1:0]  cst0, cst1;
  logic [31:0] flt_pass_w, flt_drop_w, cap_drop_w, feed_hwm, ord_hwm_w;

  always_ff @(posedge ap_clk) begin
    cs0[0] <= cm_txpkt;   cs0[1] <= cm_rxpkt;   cs0[2] <= cm_rxerr;
    cs0[3] <= cm_unf;     cs0[4] <= cm_ovf;
    cs0[5] <= flt_pass_w; cs0[6] <= flt_drop_w;
    cs0[7] <= cap_drop_w; cs0[8] <= ord_hwm_w;
    for (int i = 0; i < 9; i++) cs1[i] <= cs0[i];
    cst0 <= {cm_link_up, cm_aligned};
    cst1 <= cst0;
  end

  // ---- write channel ----
  always_ff @(posedge ap_clk) begin
    if (!ap_rst_n) begin
      wst <= W_IDLE; wr_addr <= '0; wr_data <= '0;
      t_awvalid <= 1'b0; t_wvalid <= 1'b0;
      rp_base <= '0; cp_base <= '0; rp_beats <= '0; cp_recs <= '0; rp_gap <= '0;
      rp_start <= 1'b0; cp_clear <= 1'b0; soft_rst_cnt <= 8'hFF;
      l_quiet <= 16'd512; l_clear <= 1'b0;
      loopback_en <= 1'b1;                      // cages are empty: loopback by default
    end else begin
      rp_start <= 1'b0;
      cp_clear <= 1'b0;
      l_clear  <= 1'b0;
      if (soft_rst_active) soft_rst_cnt <= soft_rst_cnt - 1'b1;

      case (wst)
        W_IDLE: if (w_accept) begin
          wr_addr <= s_axi_control_AWADDR;
          wr_data <= s_axi_control_WDATA;
          if (s_axi_control_AWADDR[12]) begin
            t_awvalid <= 1'b1;
            t_wvalid  <= 1'b1;
            wst       <= W_FWD;
          end else begin
            case (s_axi_control_AWADDR)
              R_CTRL: begin
                // Phase A refused a start while busy. Phase B refuses it while
                // the link is down as well: frames offered to a MAC that is not
                // transmitting are dropped inside the IP, and the run would look
                // like a datapath failure instead of a link that never came up.
                if (s_axi_control_WDATA[0] && !rp_busy && cst1[1]) rp_start <= 1'b1;
                if (s_axi_control_WDATA[1])             cp_clear <= 1'b1;
                if (s_axi_control_WDATA[2])             soft_rst_cnt <= 8'hFF;
                if (s_axi_control_WDATA[3])             l_clear  <= 1'b1;
                if (s_axi_control_WDATA[5])             loopback_en <= s_axi_control_WDATA[4];
              end
              R_L_QUIET:   l_quiet        <= s_axi_control_WDATA[15:0];
              R_RP_BASE_L: rp_base[31:0]  <= s_axi_control_WDATA;
              R_RP_BASE_H: rp_base[63:32] <= s_axi_control_WDATA;
              R_RP_BEATS:  rp_beats       <= s_axi_control_WDATA;
              R_RP_GAP:    rp_gap         <= s_axi_control_WDATA[15:0];
              R_CP_BASE_L: cp_base[31:0]  <= s_axi_control_WDATA;
              R_CP_BASE_H: cp_base[63:32] <= s_axi_control_WDATA;
              R_CP_RECS:   cp_recs        <= s_axi_control_WDATA;
              default: ;
            endcase
            wst <= W_RESP;
          end
        end

        W_FWD: begin
          if (t_awvalid && t_awready) t_awvalid <= 1'b0;
          if (t_wvalid  && t_wready)  t_wvalid  <= 1'b0;
          if ((!t_awvalid || t_awready) && (!t_wvalid || t_wready)) wst <= W_WAITB;
        end

        W_WAITB: if (t_bvalid) wst <= W_RESP;

        W_RESP: if (s_axi_control_BREADY) wst <= W_IDLE;

        default: wst <= W_IDLE;
      endcase
    end
  end

  // ---- read channel ----
  always_ff @(posedge ap_clk) begin
    if (!ap_rst_n) begin
      rst_s <= R_IDLE; rd_addr <= '0; rd_data <= '0; t_arvalid <= 1'b0;
    end else begin
      case (rst_s)
        R_IDLE: if (s_axi_control_ARVALID) begin
          rd_addr <= s_axi_control_ARADDR;
          if (s_axi_control_ARADDR[12]) begin
            t_arvalid <= 1'b1;
            rst_s     <= R_FWD;
          end else if (s_axi_control_ARADDR >= R_M_HIST &&
                       s_axi_control_ARADDR <  R_M_HIST + 13'(4*MBUCKET)) begin
            rd_data <= m_hist[(s_axi_control_ARADDR - R_M_HIST) >> 2];
            rst_s   <= R_RESP;
          end else if (s_axi_control_ARADDR >= R_L_HIST &&
                       s_axi_control_ARADDR <  R_L_HIST + 13'(4*NBUCKET)) begin
            rd_data <= l_hist[(s_axi_control_ARADDR - R_L_HIST) >> 2];
            rst_s   <= R_RESP;
          end else begin
            case (s_axi_control_ARADDR)
              R_ID:        rd_data <= KERNEL_ID;
              R_CTRL:      rd_data <= {27'b0, loopback_en, 4'b0};
              R_RP_BASE_L: rd_data <= rp_base[31:0];
              R_RP_BASE_H: rd_data <= rp_base[63:32];
              R_RP_BEATS:  rd_data <= rp_beats;
              R_RP_GAP:    rd_data <= {16'b0, rp_gap};
              R_CP_BASE_L: rd_data <= cp_base[31:0];
              R_CP_BASE_H: rd_data <= cp_base[63:32];
              R_CP_RECS:   rd_data <= cp_recs;
              R_STATUS:    rd_data <= {29'b0, soft_rst_active, rp_done, rp_busy};
              R_RP_FRAMES: rd_data <= rp_frames;
              R_RP_BEATSO: rd_data <= rp_beats_out;
              R_CP_FRAMES: rd_data <= cp_frames;
              R_CP_BEATS:  rd_data <= cp_beats;
              R_CP_OVF:    rd_data <= cp_ovf;
              R_CP_STALL:  rd_data <= cp_stall;
              R_L_QUIET:   rd_data <= {16'b0, l_quiet};
              R_L_MIN:     rd_data <= l_min;
              R_L_MAX:     rd_data <= l_max;
              R_L_LAST:    rd_data <= l_last;
              R_L_SUM_LO:  rd_data <= l_sum_lo;
              R_L_SUM_HI:  rd_data <= l_sum_hi;
              R_L_SAMPLES: rd_data <= l_samples;
              R_L_EXCL:    rd_data <= l_excluded;
              R_L_ORPHANS: rd_data <= l_orphans;
              R_M_MIN:     rd_data <= m_min;
              R_M_MAX:     rd_data <= m_max;
              R_M_LAST:    rd_data <= m_last;
              R_M_SUM_LO:  rd_data <= m_sum_lo;
              R_M_SUM_HI:  rd_data <= m_sum_hi;
              R_M_SAMPLES: rd_data <= m_samples;
              R_M_MISSES:  rd_data <= m_misses;
              R_C_STATUS:  rd_data <= {30'b0, cst1};
              R_C_TXPKT:   rd_data <= cs1[0];
              R_C_RXPKT:   rd_data <= cs1[1];
              R_C_RXERR:   rd_data <= cs1[2];
              R_C_UNF:     rd_data <= cs1[3];
              R_C_OVFL:    rd_data <= cs1[4];
              R_C_FLT_P:   rd_data <= cs1[5];
              R_C_FLT_D:   rd_data <= cs1[6];
              R_C_CAPDROP: rd_data <= cs1[7];
              R_C_FEEDHWM: rd_data <= feed_hwm;
              R_C_ORDHWM:  rd_data <= cs1[8];
              default:     rd_data <= 32'hDEAD_BEEF;
            endcase
            rst_s <= R_RESP;
          end
        end

        R_FWD: begin
          if (t_arvalid && t_arready) begin
            t_arvalid <= 1'b0;
            rst_s     <= R_WAITR;
          end
        end

        R_WAITR: if (t_rvalid) begin
          rd_data <= t_rdata;
          rst_s   <= R_RESP;
        end

        R_RESP: if (s_axi_control_RREADY) rst_s <= R_IDLE;

        default: rst_s <= R_IDLE;
      endcase
    end
  end

  // ================= resets =================
  wire dp_rst_n = ap_rst_n && !soft_rst_active;

  (* ASYNC_REG = "TRUE" *) logic [1:0] soft_sync_q;
  always_ff @(posedge ap_clk_2) begin
    if (!ap_rst_n_2) soft_sync_q <= 2'b00;
    else             soft_sync_q <= {soft_sync_q[0], soft_rst_active};
  end
  wire core_rst_n = ap_rst_n_2 && !soft_sync_q[1];

  // The wire domain's reset has two sources: the MAC's own (the GT is not up
  // yet) and the host's soft reset, which has to reach here too or a re-run
  // would leave the datapath's CMAC-side state from the previous run.
  (* ASYNC_REG = "TRUE" *) logic [1:0] soft_sync_w;
  always_ff @(posedge wire_clk) begin
    if (!wire_rst_n_raw) soft_sync_w <= 2'b00;
    else                 soft_sync_w <= {soft_sync_w[0], soft_rst_active};
  end
  wire wire_rst_n = wire_rst_n_raw && !soft_sync_w[1];

  // clear pulses, stretched so a slower domain cannot miss them
  logic [3:0] l_clear_stretch;
  always_ff @(posedge ap_clk) begin
    if (!ap_rst_n)             l_clear_stretch <= '0;
    else if (l_clear)          l_clear_stretch <= 4'hF;
    else if (|l_clear_stretch) l_clear_stretch <= l_clear_stretch - 1'b1;
  end
  (* ASYNC_REG = "TRUE" *) logic [1:0] l_clear_sync_c, l_clear_sync_w;
  always_ff @(posedge ap_clk_2) begin
    if (!ap_rst_n_2) l_clear_sync_c <= 2'b00;
    else             l_clear_sync_c <= {l_clear_sync_c[0], |l_clear_stretch};
  end
  always_ff @(posedge wire_clk) begin
    if (!wire_rst_n) l_clear_sync_w <= 2'b00;
    else             l_clear_sync_w <= {l_clear_sync_w[0], |l_clear_stretch};
  end
  wire l_clear_core = l_clear_sync_c[1];
  wire l_clear_wire = l_clear_sync_w[1];

  // ================= replay injector -> MAC TX =================
  logic [DATA_W-1:0] rp_tdata;
  logic [KEEP_W-1:0] rp_tkeep;
  logic              rp_tvalid, rp_tlast, rp_tready;

  eth_replay #(.DATA_W(DATA_W), .ADDR_W(ADDR_W)) u_replay (
    .clk(ap_clk), .rst_n(dp_rst_n),
    .cfg_base(rp_base), .cfg_beats(rp_beats), .cfg_gap(rp_gap),
    .start(rp_start), .busy(rp_busy), .done(rp_done),
    .frames_out(rp_frames), .beats_out(rp_beats_out),
    .m_axi_araddr(m_axi_gmem0_ARADDR), .m_axi_arlen(m_axi_gmem0_ARLEN),
    .m_axi_arvalid(m_axi_gmem0_ARVALID), .m_axi_arready(m_axi_gmem0_ARREADY),
    .m_axi_rdata(m_axi_gmem0_RDATA), .m_axi_rlast(m_axi_gmem0_RLAST),
    .m_axi_rvalid(m_axi_gmem0_RVALID), .m_axi_rready(m_axi_gmem0_RREADY),
    .m_tdata(rp_tdata), .m_tkeep(rp_tkeep), .m_tvalid(rp_tvalid),
    .m_tlast(rp_tlast), .m_tready(rp_tready)
  );

  // ap_clk -> wire_clk, and the store-and-forward that keeps the MAC fed
  logic [DATA_W-1:0] feed_tdata;
  logic [KEEP_W-1:0] feed_tkeep;
  logic              feed_tvalid, feed_tlast, feed_tready;
  logic [31:0]       feed_pkts;

  axis_sf_fifo #(.DATA_W(DATA_W), .DEPTH(512)) u_feed_fifo (
    .w_clk(ap_clk), .w_rst_n(dp_rst_n),
    .s_tdata(rp_tdata), .s_tkeep(rp_tkeep), .s_tvalid(rp_tvalid),
    .s_tlast(rp_tlast), .s_tready(rp_tready),
    .pkts_in(feed_pkts), .hwm(feed_hwm),
    .r_clk(wire_clk), .r_rst_n(wire_rst_n),
    .m_tdata(feed_tdata), .m_tkeep(feed_tkeep), .m_tvalid(feed_tvalid),
    .m_tlast(feed_tlast), .m_tready(feed_tready)
  );

  // gmem0 is read-only
  assign m_axi_gmem0_AWADDR  = '0;
  assign m_axi_gmem0_AWLEN   = '0;
  assign m_axi_gmem0_AWSIZE  = 3'd6;
  assign m_axi_gmem0_AWBURST = 2'b01;
  assign m_axi_gmem0_AWVALID = 1'b0;
  assign m_axi_gmem0_WDATA   = '0;
  assign m_axi_gmem0_WSTRB   = '0;
  assign m_axi_gmem0_WLAST   = 1'b0;
  assign m_axi_gmem0_WVALID  = 1'b0;
  assign m_axi_gmem0_BREADY  = 1'b1;
  assign m_axi_gmem0_ARSIZE  = 3'd6;
  assign m_axi_gmem0_ARBURST = 2'b01;

  // ================= datapath =================
  // Fed from the MAC's RX port. It gets everything the loopback returns; its own
  // eth_ip_udp_rx front end discards what is not the subscribed multicast feed,
  // which on this link means the order frames we just sent.
  logic [DATA_W-1:0] tx_tdata;
  logic [KEEP_W-1:0] tx_tkeep;
  logic              tx_tvalid, tx_tlast, tx_tready;

  t2t_axil #(
    .DATA_W(DATA_W), .OT_SETS_BITS(OT_SETS_BITS), .OT_WAYS(OT_WAYS), .AXIL_AW(12),
    .NSYM(NSYM)
  ) u_t2t (
    .cmac_clk(wire_clk), .cmac_rst_n(wire_rst_n),
    .rx_tdata(mac_rx_tdata), .rx_tkeep(mac_rx_tkeep),
    .rx_tvalid(mac_rx_tvalid), .rx_tlast(mac_rx_tlast),
    .tx_tdata(tx_tdata), .tx_tkeep(tx_tkeep), .tx_tvalid(tx_tvalid),
    .tx_tlast(tx_tlast), .tx_tready(tx_tready),
    .core_clk(ap_clk_2), .core_rst_n(core_rst_n),
    .axil_clk(ap_clk), .axil_rst_n(ap_rst_n),
    .s_axil_awaddr(t_awaddr), .s_axil_awvalid(t_awvalid), .s_axil_awready(t_awready),
    .s_axil_wdata(t_wdata), .s_axil_wstrb(t_wstrb), .s_axil_wvalid(t_wvalid),
    .s_axil_wready(t_wready),
    .s_axil_bresp(t_bresp), .s_axil_bvalid(t_bvalid), .s_axil_bready(t_bready),
    .s_axil_araddr(t_araddr), .s_axil_arvalid(t_arvalid), .s_axil_arready(t_arready),
    .s_axil_rdata(t_rdata), .s_axil_rresp(t_rresp), .s_axil_rvalid(t_rvalid),
    .s_axil_rready(t_rready),
    .o_dec_valid(dec_valid_c), .o_dec_ts(dec_ts_c),
    .o_ord_valid(ord_valid_c), .o_ord_ts(ord_ts_c)
  );

  // The order path gets a store-and-forward stage too, same clock in and out.
  // Two beats of latency (~6 ns) buys the guarantee that once the arbiter grants
  // this source the MAC will never be starved mid-frame -- and the arbiter is
  // frame-locked, so a starved order frame would stall the feed behind it as
  // well as corrupting itself.
  logic [DATA_W-1:0] ord_tdata;
  logic [KEEP_W-1:0] ord_tkeep;
  logic              ord_tvalid, ord_tlast, ord_tready;
  logic [31:0]       ord_pkts;

  axis_sf_fifo #(.DATA_W(DATA_W), .DEPTH(64)) u_ord_fifo (
    .w_clk(wire_clk), .w_rst_n(wire_rst_n),
    .s_tdata(tx_tdata), .s_tkeep(tx_tkeep), .s_tvalid(tx_tvalid),
    .s_tlast(tx_tlast), .s_tready(tx_tready),
    .pkts_in(ord_pkts), .hwm(ord_hwm_w),
    .r_clk(wire_clk), .r_rst_n(wire_rst_n),
    .m_tdata(ord_tdata), .m_tkeep(ord_tkeep), .m_tvalid(ord_tvalid),
    .m_tlast(ord_tlast), .m_tready(ord_tready)
  );

  // Orders take priority over the feed, which is the right way round: an order
  // waits at most for the beats of a feed frame already in flight, whereas the
  // reverse would put a 1518-byte frame in front of every order.
  axis_tx_arb #(.DATA_W(DATA_W)) u_txarb (
    .clk(wire_clk), .rst_n(wire_rst_n),
    .s0_tdata(ord_tdata), .s0_tkeep(ord_tkeep), .s0_tvalid(ord_tvalid),
    .s0_tlast(ord_tlast), .s0_tready(ord_tready),
    .s1_tdata(feed_tdata), .s1_tkeep(feed_tkeep), .s1_tvalid(feed_tvalid),
    .s1_tlast(feed_tlast), .s1_tready(feed_tready),
    .m_tdata(mac_tx_tdata), .m_tkeep(mac_tx_tkeep), .m_tvalid(mac_tx_tvalid),
    .m_tlast(mac_tx_tlast), .m_tready(mac_tx_tready)
  );

  // ================= capture path =================
  // The loopback returns everything, so the order frames are picked out of the
  // RX stream by protocol before anything is written to HBM.
  logic [DATA_W-1:0] flt_tdata;
  logic [KEEP_W-1:0] flt_tkeep;
  logic              flt_tvalid, flt_tlast;

  axis_frame_filter #(.DATA_W(DATA_W), .PROTO(8'd6)) u_capflt (
    .clk(wire_clk), .rst_n(wire_rst_n),
    .s_tdata(mac_rx_tdata), .s_tkeep(mac_rx_tkeep),
    .s_tvalid(mac_rx_tvalid), .s_tlast(mac_rx_tlast),
    .m_tdata(flt_tdata), .m_tkeep(flt_tkeep),
    .m_tvalid(flt_tvalid), .m_tlast(flt_tlast),
    .passed(flt_pass_w), .dropped(flt_drop_w)
  );

  // wire_clk -> ap_clk. cdc_fifo rather than axis_sf_fifo because this side
  // cannot backpressure the MAC: a full FIFO here drops and counts, and cap_drop
  // is read out so a drop is a number on the console rather than a silent hole
  // in the golden diff. With only the order frames surviving the filter -- 70 in
  // the real-feed run -- it should never fill, and if it does the count says so.
  logic [DATA_W-1:0] cap_tdata;
  logic [KEEP_W-1:0] cap_tkeep;
  logic              cap_tvalid, cap_tlast, cap_tready;
  logic [31:0]       cap_hwm;

  cdc_fifo #(.DATA_W(DATA_W), .DEPTH(256)) u_cap_cdc (
    .w_clk(wire_clk), .w_rst_n(wire_rst_n),
    .s_tdata(flt_tdata), .s_tkeep(flt_tkeep),
    .s_tvalid(flt_tvalid), .s_tlast(flt_tlast),
    .drop_cnt(cap_drop_w), .hwm(cap_hwm),
    .r_clk(ap_clk), .r_rst_n(dp_rst_n),
    .m_tdata(cap_tdata), .m_tkeep(cap_tkeep), .m_tvalid(cap_tvalid),
    .m_tlast(cap_tlast), .m_tready(cap_tready)
  );

  eth_capture #(.DATA_W(DATA_W), .ADDR_W(ADDR_W)) u_capture (
    .clk(ap_clk), .rst_n(dp_rst_n),
    .cfg_base(cp_base), .cfg_records(cp_recs), .clear(cp_clear),
    .frames_out(cp_frames), .beats_out(cp_beats),
    .overflow(cp_ovf), .stall_cnt(cp_stall),
    .s_tdata(cap_tdata), .s_tkeep(cap_tkeep), .s_tvalid(cap_tvalid),
    .s_tlast(cap_tlast), .s_tready(cap_tready),
    .m_axi_awaddr(m_axi_gmem1_AWADDR), .m_axi_awlen(m_axi_gmem1_AWLEN),
    .m_axi_awvalid(m_axi_gmem1_AWVALID), .m_axi_awready(m_axi_gmem1_AWREADY),
    .m_axi_wdata(m_axi_gmem1_WDATA), .m_axi_wstrb(m_axi_gmem1_WSTRB),
    .m_axi_wlast(m_axi_gmem1_WLAST), .m_axi_wvalid(m_axi_gmem1_WVALID),
    .m_axi_wready(m_axi_gmem1_WREADY),
    .m_axi_bvalid(m_axi_gmem1_BVALID), .m_axi_bready(m_axi_gmem1_BREADY)
  );

  assign m_axi_gmem1_AWSIZE  = 3'd6;
  assign m_axi_gmem1_AWBURST = 2'b01;
  assign m_axi_gmem1_ARADDR  = '0;
  assign m_axi_gmem1_ARLEN   = '0;
  assign m_axi_gmem1_ARSIZE  = 3'd6;
  assign m_axi_gmem1_ARBURST = 2'b01;
  assign m_axi_gmem1_ARVALID = 1'b0;
  assign m_axi_gmem1_RREADY  = 1'b1;

  // ================= probes =================
  // BOTH TAPS ARE ON THE MAC'S RX PORT, and that is what makes this number
  // wire-to-wire rather than fabric-to-fabric.
  //
  // The loopback is what allows it. Write T_rx for the MAC's receive latency,
  // T_tx for its transmit latency, and D for everything this design does between
  // them. Stamping when the FEED frame emerges from MAC RX and resolving when the
  // ORDER frame comes back in through MAC RX measures
  //
  //     D + T_tx + T_rx
  //
  // because the order has to traverse the transmitter, the serial loop and the
  // receiver to get back here. On a real network, wire-to-wire is
  //
  //     T_rx + D + T_tx
  //
  // -- the feed frame's trip in, plus the design, plus the order's trip out. The
  // same three terms. So this measures the number the project has only ever
  // summed, including both halves of a real 100G MAC, with the only overcount
  // being the SerDes round trip inside the GT.
  //
  // The alternative tap -- resolve on the beat the MAC ACCEPTS for transmission
  // -- was tried first and is strictly weaker: it excludes T_tx and T_rx both,
  // and so measures the fabric, which Phase A already measured. lat_probe needs
  // no change to do this, because it already distinguishes the two frame types
  // by protocol: rx_is_feed stamps on UDP, tx_is_ord resolves on TCP, and in
  // loopback both arrive on the same port.
  //
  // A tick is one wire_clk cycle, 3.10303 ns, and the host converts.
  logic [31:0] l_min_w, l_max_w, l_last_w, l_sum_lo_w, l_sum_hi_w;
  logic [31:0] l_samples_w, l_excluded_w, l_orphans_w;
  logic [31:0] l_hist_w [NBUCKET];

  lat_probe #(.DATA_W(DATA_W), .NBUCKET(NBUCKET)) u_lat (
    .clk(wire_clk), .rst_n(wire_rst_n), .clear(l_clear_wire), .cfg_quiet(l_quiet),
    .rx_tdata(mac_rx_tdata), .rx_tvalid(mac_rx_tvalid), .rx_tlast(mac_rx_tlast),
    .tx_tdata(mac_rx_tdata), .tx_tvalid(mac_rx_tvalid), .tx_tlast(mac_rx_tlast),
    .tx_tready(1'b1),                  // a MAC's RX port cannot be backpressured
    .lat_min(l_min_w), .lat_max(l_max_w), .lat_last(l_last_w),
    .lat_sum_lo(l_sum_lo_w), .lat_sum_hi(l_sum_hi_w),
    .samples(l_samples_w), .excluded(l_excluded_w), .orphans(l_orphans_w),
    .hist(l_hist_w)
  );

  (* ASYNC_REG = "TRUE" *) logic [31:0] ls0 [8];
  (* ASYNC_REG = "TRUE" *) logic [31:0] ls1 [8];
  (* ASYNC_REG = "TRUE" *) logic [31:0] lh0 [NBUCKET];
  (* ASYNC_REG = "TRUE" *) logic [31:0] lh1 [NBUCKET];

  always_ff @(posedge ap_clk) begin
    ls0[0] <= l_min_w;      ls0[1] <= l_max_w;
    ls0[2] <= l_last_w;     ls0[3] <= l_sum_lo_w;
    ls0[4] <= l_sum_hi_w;   ls0[5] <= l_samples_w;
    ls0[6] <= l_excluded_w; ls0[7] <= l_orphans_w;
    for (int i = 0; i < 8; i++)       ls1[i] <= ls0[i];
    for (int i = 0; i < NBUCKET; i++) lh0[i] <= l_hist_w[i];
    for (int i = 0; i < NBUCKET; i++) lh1[i] <= lh0[i];
  end

  assign l_min      = ls1[0];
  assign l_max      = ls1[1];
  assign l_last     = ls1[2];
  assign l_sum_lo   = ls1[3];
  assign l_sum_hi   = ls1[4];
  assign l_samples  = ls1[5];
  assign l_excluded = ls1[6];
  assign l_orphans  = ls1[7];
  always_comb for (int i = 0; i < NBUCKET; i++) l_hist[i] = lh1[i];

  lat_loaded #(.NBUCKET(MBUCKET)) u_lat_loaded (
    .clk(ap_clk_2), .rst_n(core_rst_n), .clear(l_clear_core),
    .msg_valid(dec_valid_c), .msg_ts(dec_ts_c),
    .ord_valid(ord_valid_c), .ord_ts(ord_ts_c),
    .lat_min(m_min_c), .lat_max(m_max_c), .lat_last(m_last_c),
    .lat_sum_lo(m_sum_lo_c), .lat_sum_hi(m_sum_hi_c),
    .samples(m_samples_c), .misses(m_misses_c), .hist(m_hist_c)
  );

  (* ASYNC_REG = "TRUE" *) logic [31:0] m_sync0 [7];
  (* ASYNC_REG = "TRUE" *) logic [31:0] m_sync1 [7];
  (* ASYNC_REG = "TRUE" *) logic [31:0] mh_sync0 [MBUCKET];
  (* ASYNC_REG = "TRUE" *) logic [31:0] mh_sync1 [MBUCKET];

  always_ff @(posedge ap_clk) begin
    m_sync0[0] <= m_min_c;     m_sync0[1] <= m_max_c;
    m_sync0[2] <= m_last_c;    m_sync0[3] <= m_sum_lo_c;
    m_sync0[4] <= m_sum_hi_c;  m_sync0[5] <= m_samples_c;
    m_sync0[6] <= m_misses_c;
    for (int i = 0; i < 7; i++)       m_sync1[i]  <= m_sync0[i];
    for (int i = 0; i < MBUCKET; i++) mh_sync0[i] <= m_hist_c[i];
    for (int i = 0; i < MBUCKET; i++) mh_sync1[i] <= mh_sync0[i];
  end

  assign m_min     = m_sync1[0];
  assign m_max     = m_sync1[1];
  assign m_last    = m_sync1[2];
  assign m_sum_lo  = m_sync1[3];
  assign m_sum_hi  = m_sync1[4];
  assign m_samples = m_sync1[5];
  assign m_misses  = m_sync1[6];
  always_comb for (int i = 0; i < MBUCKET; i++) m_hist[i] = mh_sync1[i];

endmodule
