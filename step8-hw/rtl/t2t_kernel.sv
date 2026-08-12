// Vitis RTL kernel: the whole tick-to-trade datapath, on the card.
//
// WHAT THIS IS FOR. Everything up to step 7 was verified in simulation and taken
// through synthesis and place & route, but never executed on silicon -- the
// project's own README says so. This wraps t2t_axil in the shape the Alveo
// runtime can load (one AXI4-Lite control slave, AXI4 masters to HBM) so the
// design runs on the real U55C in this machine, driven by the same stimulus and
// checked against the same golden as the testbenches.
//
// WHY A KERNEL AND NOT AN OpenNIC SHELL. OpenNIC is the natural long-term host
// (t2t_axil was written for its 322 MHz user box) but it replaces the card's
// shell, which means programming over JTAG or writing the configuration flash.
// There is no JTAG cable on this machine, so a bad flash would be unrecoverable.
// An .xclbin loads into the shell's reconfigurable partition instead: worst case
// is a card reset. That is the whole reason for this file's existence -- it is
// the safe way onto real hardware, not the fastest-in-theory one.
//
// ADDRESS MAP on s_axi_control (13 bits, 8 KB):
//   0x0040..0x007F  kernel harness registers (replay/capture control, below)
//   0x1000..0x1FFF  t2t_axil's own register file, unchanged -- so
//                   step7-host/host/regmap.py offsets apply verbatim at +0x1000
// Nothing is placed below 0x0040: XRT reserves the first 16 bytes of a kernel's
// register space for the control protocol and refuses accesses there, and
// leaving a margin costs nothing.
//
// The control front end below terminates every host transaction itself and acts
// as a little AXI4-Lite *master* onto t2t_axil for the 0x1000 window, rather
// than muxing valid/ready between two slaves. Steering a shared bus would mean
// reasoning about which order the host's AW and W beats arrive in and how
// axil_regfile latches them; a four-state forwarder is more lines and no
// subtlety. Register access is one transaction at a time from the host, so the
// cost of the indirection is irrelevant.
//
// CLOCKS. ap_clk carries the control plane, the HBM masters, and the injector /
// capture pair -- i.e. it stands in for the CMAC domain. ap_clk_2 is the
// datapath core. That preserves the design's two-clock structure and keeps the
// cdc_fifo crossings genuinely asynchronous rather than optimising them away,
// which matters: a same-clock build would not exercise the CDC that a real card
// depends on. Phase B replaces ap_clk on the stream side with the CMAC's real
// 322.265625 MHz recovered clock.
`timescale 1ns/1ps
module t2t_kernel #(
  parameter int DATA_W       = 512,
  parameter int ADDR_W       = 64,
  parameter int OT_SETS_BITS = 13,
  parameter int OT_WAYS      = 16,
  // Tracked symbols. Moves together with OT_SETS_BITS by hand and not by
  // implication -- 2^13 x 16 holds exactly one name, and the resize is where
  // the timing difficulty is (FINDINGS 4.4), so a build must state both.
  parameter int NSYM         = 1
)(
  // ---- Vitis kernel clocks and resets ----
  input  logic         ap_clk,
  input  logic         ap_rst_n,
  input  logic         ap_clk_2,
  input  logic         ap_rst_n_2,

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

  // register offsets within the harness window
  localparam logic [12:0] R_ID        = 13'h040;   // "T2K1"
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
  // order-session inbound, merged into the same capture area
  localparam logic [12:0] R_SP_FRAMES = 13'h0A4;
  localparam logic [12:0] R_SP_DROP   = 13'h0A8;
  // latency probe (see rtl/lat_probe.sv)
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
  // loaded-latency probe (rtl/lat_loaded.sv), core-clock cycles
  localparam logic [12:0] R_M_MIN     = 13'h100;
  localparam logic [12:0] R_M_MAX     = 13'h104;
  localparam logic [12:0] R_M_LAST    = 13'h108;
  localparam logic [12:0] R_M_SUM_LO  = 13'h10C;
  localparam logic [12:0] R_M_SUM_HI  = 13'h110;
  localparam logic [12:0] R_M_SAMPLES = 13'h114;
  localparam logic [12:0] R_M_MISSES  = 13'h118;
  localparam logic [12:0] R_M_HIST    = 13'h180;   // 24 words, 0x180..0x1DC

  localparam int NBUCKET  = 16;
  localparam int MBUCKET  = 24;   // loaded probe: up to 8M core cycles

  localparam logic [31:0] KERNEL_ID = 32'h5432_4B31;   // "T2K1"

  // ================= harness registers =================
  logic [63:0] rp_base, cp_base;
  logic [31:0] rp_beats, cp_recs;
  logic [15:0] rp_gap;
  logic        rp_start, cp_clear;              // one-cycle pulses
  logic [7:0]  soft_rst_cnt;

  logic        rp_busy, rp_done;
  logic [31:0] rp_frames, rp_beats_out;
  logic [31:0] cp_frames, cp_beats, cp_ovf, cp_stall;
  logic [31:0] sp_frames, sp_drop;   // session frames captured / dropped

  logic [15:0] l_quiet;                         // idle cycles a sample requires
  logic        l_clear;
  logic [31:0] l_min, l_max, l_last, l_sum_lo, l_sum_hi;
  logic [31:0] l_samples, l_excluded, l_orphans;
  logic [31:0] l_hist [NBUCKET];

  // loaded-latency probe results, core domain then resynced to ap_clk
  logic [31:0] m_min_c, m_max_c, m_last_c, m_sum_lo_c, m_sum_hi_c,
               m_samples_c, m_misses_c;
  logic [31:0] m_hist_c [MBUCKET];
  logic [31:0] m_min, m_max, m_last, m_sum_lo, m_sum_hi, m_samples, m_misses;
  logic [31:0] m_hist [MBUCKET];

  // taps out of the datapath, core domain
  logic        dec_valid_c, ord_valid_c;
  logic [47:0] dec_ts_c, ord_ts_c;

  // the clear pulse is generated on ap_clk; stretch and resync it so the core
  // domain cannot miss a single-cycle pulse from a slower clock
  logic [3:0] l_clear_stretch;
  (* ASYNC_REG = "TRUE" *) logic [1:0] l_clear_sync;
  always_ff @(posedge ap_clk) begin
    if (!ap_rst_n)      l_clear_stretch <= '0;
    else if (l_clear)   l_clear_stretch <= 4'hF;
    else if (|l_clear_stretch) l_clear_stretch <= l_clear_stretch - 1'b1;
  end
  always_ff @(posedge ap_clk_2) begin
    if (!ap_rst_n_2) l_clear_sync <= 2'b00;
    else             l_clear_sync <= {l_clear_sync[0], |l_clear_stretch};
  end
  wire l_clear_core = l_clear_sync[1];

  wire soft_rst_active = (soft_rst_cnt != '0);

  // ================= AXI4-Lite control front end =================
  // t2t_axil's slave port, driven by this block as a master for the 0x1000 window
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

  wire wr_is_t2t = wr_addr[12];
  wire rd_is_t2t = rd_addr[12];

  // accept the address and data beats together: the host issues one register
  // access at a time, so this cannot deadlock on beat ordering
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

  // ---- write channel ----
  always_ff @(posedge ap_clk) begin
    if (!ap_rst_n) begin
      wst <= W_IDLE; wr_addr <= '0; wr_data <= '0;
      t_awvalid <= 1'b0; t_wvalid <= 1'b0;
      rp_base <= '0; cp_base <= '0; rp_beats <= '0; cp_recs <= '0; rp_gap <= '0;
      rp_start <= 1'b0; cp_clear <= 1'b0; soft_rst_cnt <= 8'hFF;
      l_quiet <= 16'd512; l_clear <= 1'b0;
    end else begin
      rp_start <= 1'b0;                          // pulses last one cycle
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
            // harness register: applied here, acknowledged next cycle
            case (s_axi_control_AWADDR)
              R_CTRL: begin
                // start is refused while a replay is running, so a stray write
                // cannot rewind the injector mid-stream
                if (s_axi_control_WDATA[0] && !rp_busy) rp_start <= 1'b1;
                if (s_axi_control_WDATA[1])             cp_clear <= 1'b1;
                if (s_axi_control_WDATA[2])             soft_rst_cnt <= 8'hFF;
                if (s_axi_control_WDATA[3])             l_clear  <= 1'b1;
              end
              R_L_QUIET:   l_quiet        <= s_axi_control_WDATA[15:0];
              R_RP_BASE_L: rp_base[31:0]  <= s_axi_control_WDATA;
              R_RP_BASE_H: rp_base[63:32] <= s_axi_control_WDATA;
              R_RP_BEATS:  rp_beats       <= s_axi_control_WDATA;
              R_RP_GAP:    rp_gap         <= s_axi_control_WDATA[15:0];
              R_CP_BASE_L: cp_base[31:0]  <= s_axi_control_WDATA;
              R_CP_BASE_H: cp_base[63:32] <= s_axi_control_WDATA;
              R_CP_RECS:   cp_recs        <= s_axi_control_WDATA;
              default: ;                         // read-only or unmapped: ignored
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
            // the histogram is a 16-word window, decoded as a range rather than
            // sixteen near-identical case arms
            rd_data <= l_hist[(s_axi_control_ARADDR - R_L_HIST) >> 2];
            rst_s   <= R_RESP;
          end else begin
            case (s_axi_control_ARADDR)
              R_ID:        rd_data <= KERNEL_ID;
              R_CTRL:      rd_data <= '0;
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
              R_SP_FRAMES: rd_data <= sp_frames;
              R_SP_DROP:   rd_data <= sp_drop;
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
              default:     rd_data <= 32'hDEAD_BEEF;   // unmapped, visibly so
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
  // The datapath can be reset without disturbing the register file, so config
  // written once survives the order table's re-initialisation sweep. A soft
  // reset does require the host to re-pulse CTRL load afterwards, because the
  // commit pulse is what hands the config across cfg_cdc into the core.
  wire dp_rst_n = ap_rst_n && !soft_rst_active;

  (* ASYNC_REG = "TRUE" *) logic [1:0] soft_sync_q;
  always_ff @(posedge ap_clk_2) begin
    if (!ap_rst_n_2) soft_sync_q <= 2'b00;
    else             soft_sync_q <= {soft_sync_q[0], soft_rst_active};
  end
  wire core_rst_n = ap_rst_n_2 && !soft_sync_q[1];

  // ================= replay injector =================
  logic [DATA_W-1:0] rx_tdata;
  logic [KEEP_W-1:0] rx_tkeep;
  logic              rx_tvalid, rx_tlast;

  eth_replay #(.DATA_W(DATA_W), .ADDR_W(ADDR_W)) u_replay (
    .clk(ap_clk), .rst_n(dp_rst_n),
    .cfg_base(rp_base), .cfg_beats(rp_beats), .cfg_gap(rp_gap),
    .start(rp_start), .busy(rp_busy), .done(rp_done),
    .frames_out(rp_frames), .beats_out(rp_beats_out),
    .m_axi_araddr(m_axi_gmem0_ARADDR), .m_axi_arlen(m_axi_gmem0_ARLEN),
    .m_axi_arvalid(m_axi_gmem0_ARVALID), .m_axi_arready(m_axi_gmem0_ARREADY),
    .m_axi_rdata(m_axi_gmem0_RDATA), .m_axi_rlast(m_axi_gmem0_RLAST),
    .m_axi_rvalid(m_axi_gmem0_RVALID), .m_axi_rready(m_axi_gmem0_RREADY),
    .m_tdata(rx_tdata), .m_tkeep(rx_tkeep), .m_tvalid(rx_tvalid), .m_tlast(rx_tlast),
    .m_tready(1'b1)                    // the datapath's RX port cannot backpressure
  );

  // gmem0 is read-only: tie the write side off
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
  assign m_axi_gmem0_ARSIZE  = 3'd6;             // 2^6 = 64 bytes per beat
  assign m_axi_gmem0_ARBURST = 2'b01;            // INCR

  // ================= datapath =================
  logic [DATA_W-1:0] tx_tdata;
  logic [KEEP_W-1:0] tx_tkeep;
  logic              tx_tvalid, tx_tlast, tx_tready;

  // the order session's inbound frames, core domain -- see the capture merge below
  logic [DATA_W-1:0] sx_tdata;
  logic [KEEP_W-1:0] sx_tkeep;
  logic              sx_tvalid, sx_tlast;

  t2t_axil #(
    .DATA_W(DATA_W), .OT_SETS_BITS(OT_SETS_BITS), .OT_WAYS(OT_WAYS), .AXIL_AW(12),
    .NSYM(NSYM)
  ) u_t2t (
    .cmac_clk(ap_clk), .cmac_rst_n(dp_rst_n),
    .rx_tdata(rx_tdata), .rx_tkeep(rx_tkeep), .rx_tvalid(rx_tvalid), .rx_tlast(rx_tlast),
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
    .o_ord_valid(ord_valid_c), .o_ord_ts(ord_ts_c),
    .rxs_tdata(sx_tdata), .rxs_tkeep(sx_tkeep),
    .rxs_tvalid(sx_tvalid), .rxs_tlast(sx_tlast)
  );

  // ================= order-session inbound -> the capture buffer =============
  // The venue's replies have nowhere to go inside the FPGA: the transmit side
  // already took what it needed (the acknowledgement number) straight from
  // tcp_rx, and the OUCH payload is for software. So they take the path the
  // order frames take -- into the same capture area, out through the same DMA,
  // and the host tells the two apart by direction, which it can do because an
  // inbound frame is addressed to us and an outbound one is not.
  //
  // ONE BUFFER, not two. A second eth_capture would need a second AXI write
  // master, a second kernel argument and an arbiter between them, to separate
  // two streams the host can separate with an IP-address compare.
  //
  // The crossing is a cdc_fifo, in its drop-and-count mode: tcp_rx's output has
  // no tready (it is the RX side, which cannot be stalled), so something here
  // has to absorb a burst and say so when it cannot. Replies are one per order
  // and orders are microseconds apart, so this should never fill -- and if it
  // does, sp_drop is a number the host prints rather than a hole in the capture
  // nobody notices.
  logic [DATA_W-1:0] sess_tdata;                  // ap_clk
  logic [KEEP_W-1:0] sess_tkeep;
  logic              sess_tvalid, sess_tlast, sess_tready;

  cdc_fifo #(.DATA_W(DATA_W), .DEPTH(64)) u_sess_cdc (
    .w_clk(ap_clk_2), .w_rst_n(core_rst_n),
    .s_tdata(sx_tdata), .s_tkeep(sx_tkeep),
    .s_tvalid(sx_tvalid), .s_tlast(sx_tlast),
    .drop_cnt(sp_drop), .hwm(),
    .r_clk(ap_clk), .r_rst_n(dp_rst_n),
    .m_tdata(sess_tdata), .m_tkeep(sess_tkeep), .m_tvalid(sess_tvalid),
    .m_tlast(sess_tlast), .m_tready(sess_tready)
  );

  // Orders on the priority port. Nothing about the capture is latency-critical,
  // but an order frame that waits behind a reply is an order frame whose capture
  // timestamp no longer means what it did, and the arbiter costs nothing to get
  // the right way round.
  logic [DATA_W-1:0] cap_tdata;
  logic [KEEP_W-1:0] cap_tkeep;
  logic              cap_tvalid, cap_tlast, cap_tready;

  axis_tx_arb #(.DATA_W(DATA_W)) u_cap_arb (
    .clk(ap_clk), .rst_n(dp_rst_n),
    .s0_tdata(tx_tdata), .s0_tkeep(tx_tkeep), .s0_tvalid(tx_tvalid),
    .s0_tlast(tx_tlast), .s0_tready(tx_tready),
    .s1_tdata(sess_tdata), .s1_tkeep(sess_tkeep), .s1_tvalid(sess_tvalid),
    .s1_tlast(sess_tlast), .s1_tready(sess_tready),
    .m_tdata(cap_tdata), .m_tkeep(cap_tkeep), .m_tvalid(cap_tvalid),
    .m_tlast(cap_tlast), .m_tready(cap_tready)
  );

  always_ff @(posedge ap_clk)
    if (!dp_rst_n)                                     sp_frames <= '0;
    else if (sess_tvalid && sess_tready && sess_tlast) sp_frames <= sp_frames + 1'b1;

  // ================= loaded-latency probe (core domain) =================
  // Correlates a decoded message with the order that later cites its ITCH
  // timestamp, which measures latency while the pipeline is BUSY -- the case
  // lat_probe must refuse. See rtl/lat_loaded.sv for why no tag had to be
  // threaded through the datapath to do this.
  lat_loaded #(.NBUCKET(MBUCKET)) u_lat_loaded (
    .clk(ap_clk_2), .rst_n(core_rst_n), .clear(l_clear_core),
    .msg_valid(dec_valid_c), .msg_ts(dec_ts_c),
    .ord_valid(ord_valid_c), .ord_ts(ord_ts_c),
    .lat_min(m_min_c), .lat_max(m_max_c), .lat_last(m_last_c),
    .lat_sum_lo(m_sum_lo_c), .lat_sum_hi(m_sum_hi_c),
    .samples(m_samples_c), .misses(m_misses_c), .hist(m_hist_c)
  );

  // Results cross core -> ap_clk on two flops, the same treatment t2t_axil gives
  // its status bus and for the same reason: a monitoring read may catch a
  // counter mid-increment and be off by one, which is fine for diagnostics and
  // not worth a handshake.
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

  // ================= capture =================
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

  // ================= latency probe =================
  // Taps the two stream ends only -- it never touches the datapath, so it cannot
  // perturb what it measures. Both taps are in the ap_clk domain, which is the
  // wire side, so a tick is one RX clock cycle and the host converts to ns.
  lat_probe #(.DATA_W(DATA_W), .NBUCKET(NBUCKET)) u_lat (
    .clk(ap_clk), .rst_n(dp_rst_n), .clear(l_clear), .cfg_quiet(l_quiet),
    .rx_tdata(rx_tdata), .rx_tvalid(rx_tvalid), .rx_tlast(rx_tlast),
    .tx_tdata(tx_tdata), .tx_tvalid(tx_tvalid), .tx_tlast(tx_tlast),
    .tx_tready(tx_tready),
    .lat_min(l_min), .lat_max(l_max), .lat_last(l_last),
    .lat_sum_lo(l_sum_lo), .lat_sum_hi(l_sum_hi),
    .samples(l_samples), .excluded(l_excluded), .orphans(l_orphans),
    .hist(l_hist)
  );

  // gmem1 is write-only: tie the read side off
  assign m_axi_gmem1_AWSIZE  = 3'd6;
  assign m_axi_gmem1_AWBURST = 2'b01;
  assign m_axi_gmem1_ARADDR  = '0;
  assign m_axi_gmem1_ARLEN   = '0;
  assign m_axi_gmem1_ARSIZE  = 3'd6;
  assign m_axi_gmem1_ARBURST = 2'b01;
  assign m_axi_gmem1_ARVALID = 1'b0;
  assign m_axi_gmem1_RREADY  = 1'b1;

endmodule
