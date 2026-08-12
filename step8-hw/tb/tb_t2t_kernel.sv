// End-to-end TB for the Vitis kernel: HBM in, HBM out, everything the card will
// do except the PCIe transport.
//
// WHY THIS EXISTS RATHER THAN GOING STRAIGHT TO A BUILD. A v++ link is hours,
// and it reports RTL mistakes late and obscurely. Everything the kernel adds on
// top of the already-verified datapath -- the AXI-Lite front end with its two
// address windows, the HBM read master, the frame-record format, the capture
// writer -- is exercised here first, against behavioural memory models, with the
// SAME golden the step 5/6 testbenches use. If this passes and the build closes
// timing, the only untested thing left on the card is PCIe and HBM themselves.
//
// The capture image is dumped byte-for-byte as the card's HBM buffer would look,
// and scripts/pack_eth.py parses it -- so the parser that reads hardware results
// is the parser proven here, not a second implementation of the record format.
//
// The two memory models are deliberately unhelpful: reads answer after
// AXI_LATENCY idle cycles rather than immediately, so the injector's credit logic
// has to actually cover the round trip instead of accidentally working because
// data came back in zero time.
//
// ONE TESTBENCH, TWO KERNELS. Defining PHASE_B swaps t2t_kernel for
// t2t_kernel_b -- the build with a real cmac_usplus and the GT in near-end
// loopback -- and nothing else here changes: same stimulus file, same
// configuration, same golden, same capture parser. That is the point of doing it
// with a switch rather than a second file. Phase B moves the streams through a
// MAC, an arbiter, two store-and-forward FIFOs and a protocol filter, and the
// claim being tested is that the frames coming out are STILL byte-identical to
// the ones the step 5/6 simulations produce. A separate testbench with its own
// expectations could not make that claim; a shared one that only substitutes the
// DUT can.
//
// Under PHASE_B the MAC is cmac_wrap's behavioural stand-in (see CMAC_SIM
// there): the real IP needs GT models and tens of microseconds of link training,
// and it is validated on the card by the golden diff, which is the only place it
// can be. What this exercises is the kernel logic Phase B adds around it.
//
// +eth=<packed image> replay stimulus (from pack_eth.py pack)
// +cap=<path> capture image out, +gap=<n> inter-frame idle cycles
`timescale 1ns/1ps
`ifdef PHASE_B
module tb_t2t_kernel_b;
`else
module tb_t2t_kernel;
`endif
  localparam int DATA_W = 512;
  localparam int KEEP_W = DATA_W / 8;
  localparam int ADDR_W = 64;

  // Simulation-only memory models. These are sized for the synthetic feed and a
  // SMALL real slice on purpose: the full 5 M-message AAPL replay is a 327 MB
  // image of 1.13 M frames, and simulating it is not the right tool. Orders are
  // rare in this feed -- 1 order in the first 1 M messages, 52 across 5 M -- so a
  // latency histogram worth having needs the whole replay, which is hours in
  // xsim and about two seconds on the card at 300 MHz. That asymmetry is the
  // argument for the hardware run, not a limitation to engineer around here.
  localparam int RMEM_BYTES   = 8 * 1024 * 1024;   // replay image space
  localparam int CMEM_BYTES   = 4 * 1024 * 1024;   // capture area
  localparam longint CAP_BASE = 64'h1000_0000;     // arbitrary, distinct window
  localparam int RECORD_BYTES = 32 * 64;           // mirrors eth_capture
  localparam int AXI_LATENCY  = 20;                // cycles before read data

  // harness register offsets (mirror t2t_kernel.sv)
  localparam logic [12:0] R_ID        = 13'h040;
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
  localparam logic [12:0] R_CP_FRAMES = 13'h070;
  localparam logic [12:0] R_CP_OVF    = 13'h078;
  localparam logic [12:0] R_CP_STALL  = 13'h07C;
  localparam logic [12:0] R_L_QUIET   = 13'h080;
  localparam logic [12:0] R_L_MIN     = 13'h084;
  localparam logic [12:0] R_L_MAX     = 13'h088;
  localparam logic [12:0] R_L_SUM_LO  = 13'h090;
  localparam logic [12:0] R_L_SAMPLES = 13'h098;
  localparam logic [12:0] R_L_EXCL    = 13'h09C;
  localparam logic [12:0] R_L_ORPHANS = 13'h0A0;
  localparam logic [12:0] R_L_HIST    = 13'h0C0;
  localparam logic [12:0] R_M_MIN     = 13'h100;
  localparam logic [12:0] R_M_MAX     = 13'h104;
  localparam logic [12:0] R_M_SUM_LO  = 13'h10C;
  localparam logic [12:0] R_M_SAMPLES = 13'h114;
  localparam logic [12:0] R_M_MISSES  = 13'h118;
`ifdef PHASE_B
  localparam logic [12:0] R_C_STATUS  = 13'h200;   // {link_up, rx_aligned}
  localparam logic [12:0] R_C_TXPKT   = 13'h204;
  localparam logic [12:0] R_C_RXPKT   = 13'h208;
  localparam logic [12:0] R_C_RXERR   = 13'h20C;
  localparam logic [12:0] R_C_UNF     = 13'h210;
  localparam logic [12:0] R_C_FLT_P   = 13'h218;
  localparam logic [12:0] R_C_FLT_D   = 13'h21C;
  localparam logic [12:0] R_C_CAPDROP = 13'h220;
  localparam logic [31:0] EXP_ID      = 32'h5432_4B32;   // "T2K2"
`else
  localparam logic [31:0] EXP_ID      = 32'h5432_4B31;   // "T2K1"
`endif

  localparam logic [12:0] T2T = 13'h1000;          // datapath register window
  localparam logic [31:0] GROUP = 32'hE9360C01;    // 233.54.12.1

  logic ap_clk = 0, ap_clk_2 = 0;
  logic ap_rst_n = 0, ap_rst_n_2 = 0;
  // Deliberately incommensurate and phase-offset, so the cdc_fifo crossings are
  // exercised the way they are on the card rather than in lockstep. These match
  // the frequencies the build requests (Makefile AP_CLK / CORE_CLK).
  initial forever #1.6665 ap_clk = ~ap_clk;                     // 300 MHz
  initial begin #0.7; forever #2.3256 ap_clk_2 = ~ap_clk_2; end // 215 MHz

  // ---------------- AXI-Lite control ----------------
  logic [12:0] awaddr, araddr;
  logic        awvalid, awready, wvalid, wready, bvalid, bready;
  logic        arvalid, arready, rvalid, rready;
  logic [31:0] wdata, rdata;
  logic [3:0]  wstrb;
  logic [1:0]  bresp, rresp;

  // ---------------- gmem0: read master ----------------
  logic [ADDR_W-1:0] araddr0;
  logic [7:0]        arlen0;
  logic [2:0]        arsize0;
  logic [1:0]        arburst0;
  logic              arvalid0, arready0;
  logic [DATA_W-1:0] rdata0;
  logic              rlast0, rvalid0, rready0;
  logic [1:0]        rresp0;
  logic [ADDR_W-1:0] awaddr0;
  logic [7:0]        awlen0;
  logic [2:0]        awsize0;
  logic [1:0]        awburst0;
  logic              awvalid0, awready0 = 1'b1;
  logic [DATA_W-1:0] wdata0;
  logic [KEEP_W-1:0] wstrb0;
  logic              wlast0, wvalid0, wready0 = 1'b1;
  logic              bvalid0 = 1'b0, bready0;
  logic [1:0]        bresp0 = 2'b00;

  // ---------------- gmem1: write master ----------------
  logic [ADDR_W-1:0] awaddr1;
  logic [7:0]        awlen1;
  logic [2:0]        awsize1;
  logic [1:0]        awburst1;
  logic              awvalid1, awready1;
  logic [DATA_W-1:0] wdata1;
  logic [KEEP_W-1:0] wstrb1;
  logic              wlast1, wvalid1, wready1;
  logic              bvalid1, bready1;
  logic [1:0]        bresp1 = 2'b00;
  logic [ADDR_W-1:0] araddr1;
  logic [7:0]        arlen1;
  logic [2:0]        arsize1;
  logic [1:0]        arburst1;
  logic              arvalid1, arready1 = 1'b1;
  logic [DATA_W-1:0] rdata1 = '0;
  logic              rlast1 = 1'b0, rvalid1 = 1'b0, rready1;
  logic [1:0]        rresp1 = 2'b00;

`ifdef PHASE_B
  // The GT pins go nowhere: the loopback that matters is inside the GT, set by
  // the CMAC's gt_loopback_in, and in simulation cmac_wrap models it directly.
  logic [3:0] gt_txp, gt_txn;

  t2t_kernel_b #(.DATA_W(DATA_W), .ADDR_W(ADDR_W)) dut (
    .gt_refclk_p(1'b0), .gt_refclk_n(1'b1),
    .gt_rxp_in(4'b0), .gt_rxn_in(4'hF),
    .gt_txp_out(gt_txp), .gt_txn_out(gt_txn),
`else
  t2t_kernel #(.DATA_W(DATA_W), .ADDR_W(ADDR_W)) dut (
`endif
    .ap_clk(ap_clk), .ap_rst_n(ap_rst_n),
    .ap_clk_2(ap_clk_2), .ap_rst_n_2(ap_rst_n_2),

    .s_axi_control_AWADDR(awaddr), .s_axi_control_AWVALID(awvalid),
    .s_axi_control_AWREADY(awready),
    .s_axi_control_WDATA(wdata), .s_axi_control_WSTRB(wstrb),
    .s_axi_control_WVALID(wvalid), .s_axi_control_WREADY(wready),
    .s_axi_control_BRESP(bresp), .s_axi_control_BVALID(bvalid),
    .s_axi_control_BREADY(bready),
    .s_axi_control_ARADDR(araddr), .s_axi_control_ARVALID(arvalid),
    .s_axi_control_ARREADY(arready),
    .s_axi_control_RDATA(rdata), .s_axi_control_RRESP(rresp),
    .s_axi_control_RVALID(rvalid), .s_axi_control_RREADY(rready),

    .m_axi_gmem0_AWADDR(awaddr0), .m_axi_gmem0_AWLEN(awlen0),
    .m_axi_gmem0_AWSIZE(awsize0), .m_axi_gmem0_AWBURST(awburst0),
    .m_axi_gmem0_AWVALID(awvalid0), .m_axi_gmem0_AWREADY(awready0),
    .m_axi_gmem0_WDATA(wdata0), .m_axi_gmem0_WSTRB(wstrb0),
    .m_axi_gmem0_WLAST(wlast0), .m_axi_gmem0_WVALID(wvalid0),
    .m_axi_gmem0_WREADY(wready0),
    .m_axi_gmem0_BRESP(bresp0), .m_axi_gmem0_BVALID(bvalid0),
    .m_axi_gmem0_BREADY(bready0),
    .m_axi_gmem0_ARADDR(araddr0), .m_axi_gmem0_ARLEN(arlen0),
    .m_axi_gmem0_ARSIZE(arsize0), .m_axi_gmem0_ARBURST(arburst0),
    .m_axi_gmem0_ARVALID(arvalid0), .m_axi_gmem0_ARREADY(arready0),
    .m_axi_gmem0_RDATA(rdata0), .m_axi_gmem0_RLAST(rlast0),
    .m_axi_gmem0_RRESP(rresp0), .m_axi_gmem0_RVALID(rvalid0),
    .m_axi_gmem0_RREADY(rready0),

    .m_axi_gmem1_AWADDR(awaddr1), .m_axi_gmem1_AWLEN(awlen1),
    .m_axi_gmem1_AWSIZE(awsize1), .m_axi_gmem1_AWBURST(awburst1),
    .m_axi_gmem1_AWVALID(awvalid1), .m_axi_gmem1_AWREADY(awready1),
    .m_axi_gmem1_WDATA(wdata1), .m_axi_gmem1_WSTRB(wstrb1),
    .m_axi_gmem1_WLAST(wlast1), .m_axi_gmem1_WVALID(wvalid1),
    .m_axi_gmem1_WREADY(wready1),
    .m_axi_gmem1_BRESP(bresp1), .m_axi_gmem1_BVALID(bvalid1),
    .m_axi_gmem1_BREADY(bready1),
    .m_axi_gmem1_ARADDR(araddr1), .m_axi_gmem1_ARLEN(arlen1),
    .m_axi_gmem1_ARSIZE(arsize1), .m_axi_gmem1_ARBURST(arburst1),
    .m_axi_gmem1_ARVALID(arvalid1), .m_axi_gmem1_ARREADY(arready1),
    .m_axi_gmem1_RDATA(rdata1), .m_axi_gmem1_RLAST(rlast1),
    .m_axi_gmem1_RRESP(rresp1), .m_axi_gmem1_RVALID(rvalid1),
    .m_axi_gmem1_RREADY(rready1)
  );

  // ================= memory models =================
  byte unsigned rmem [0:RMEM_BYTES-1];
  byte unsigned cmem [0:CMEM_BYTES-1];

  // ---- gmem0: read. Answers after a delay, one beat per cycle thereafter ----
  // +rjit=<n> makes the model deliver beats RAGGEDLY: up to n idle cycles
  // between beats of a burst, pseudo-randomly. Default 0, so every existing run
  // is bit-for-bit unchanged.
  //
  // This exists because the card and this testbench disagreed. At an injector
  // gap of 512 the card emits 6 order frames where the golden and this model
  // both say 4, and no counter distinguishes the two runs -- same frames in,
  // same frames kept, same recovered-gap count. The suspicion is that real HBM
  // does not behave like this model: it answers late and unevenly, so beats
  // arrive with holes in them and the injector's output stream is not the clean
  // back-to-back burst simulated here. A model that is unrealistically prompt
  // cannot reproduce a bug caused by a source that is not.
  int  rd_beats_left = 0;
  longint rd_addr = 0;
  int  rd_delay = 0;
  int  rjit = 0;
  int unsigned jlfsr = 32'hACE1_2345;

  function automatic int unsigned jrnd();
    jlfsr = (jlfsr >> 1) ^ (-(jlfsr & 32'd1) & 32'hD000_0000);
    return jlfsr;
  endfunction

  assign arready0 = (rd_beats_left == 0) && (rd_delay == 0);

  always_ff @(posedge ap_clk) begin
    if (!ap_rst_n) begin
      rd_beats_left <= 0; rd_delay <= 0; rvalid0 <= 1'b0; rlast0 <= 1'b0;
    end else begin
      if (arvalid0 && arready0) begin
        rd_addr       <= araddr0;
        rd_beats_left <= int'(arlen0) + 1;
        rd_delay      <= AXI_LATENCY;          // make the credit logic earn it
        rvalid0       <= 1'b0;
      end else if (rd_delay > 0) begin
        rd_delay <= rd_delay - 1;
        rvalid0  <= 1'b0;
      end else if (rd_beats_left > 0 && rjit > 0 && (jrnd() % 3) == 0) begin
        // a hole in the middle of a burst, which real HBM produces and the
        // clean model never did
        rd_delay <= 1 + int'(jrnd() % rjit);
        rvalid0  <= 1'b0;
        rlast0   <= 1'b0;
      end else if (rd_beats_left > 0) begin
        automatic logic [DATA_W-1:0] beat = '0;
        for (int b = 0; b < KEEP_W; b++)
          beat[8*b +: 8] = rmem[(rd_addr + b) % RMEM_BYTES];
        rdata0        <= beat;
        rvalid0       <= 1'b1;
        rlast0        <= (rd_beats_left == 1);
        rd_addr       <= rd_addr + KEEP_W;
        rd_beats_left <= rd_beats_left - 1;
      end else begin
        rvalid0 <= 1'b0;
        rlast0  <= 1'b0;
      end
    end
  end

  // ---- gmem1: write. Accepts a burst, honours wstrb, then responds ----
  longint wr_addr = 0;
  bit     wr_open = 0;

  assign awready1 = !wr_open;
  assign wready1  = wr_open;

  always_ff @(posedge ap_clk) begin
    if (!ap_rst_n) begin
      wr_open <= 0; bvalid1 <= 1'b0;
    end else begin
      if (bvalid1 && bready1) bvalid1 <= 1'b0;
      if (awvalid1 && awready1) begin
        wr_addr <= awaddr1 - CAP_BASE;         // model covers the capture window
        wr_open <= 1;
      end else if (wvalid1 && wready1) begin
        for (int b = 0; b < KEEP_W; b++)
          if (wstrb1[b]) cmem[(wr_addr + b) % CMEM_BYTES] <= wdata1[8*b +: 8];
        wr_addr <= wr_addr + KEEP_W;
        if (wlast1) begin
          wr_open <= 0;
          bvalid1 <= 1'b1;
        end
      end
    end
  end

  // ================= AXI-Lite master =================
  task automatic axil_write(input [12:0] a, input [31:0] d);
    @(negedge ap_clk);
    awaddr = a; wdata = d; wstrb = 4'hF; awvalid = 1; wvalid = 1; bready = 1;
    do @(posedge ap_clk); while (!(awready && wready));
    @(negedge ap_clk); awvalid = 0; wvalid = 0;
    do @(posedge ap_clk); while (!bvalid);
    @(negedge ap_clk); bready = 0;
  endtask

  task automatic axil_read(input [12:0] a, output [31:0] d);
    @(negedge ap_clk);
    araddr = a; arvalid = 1; rready = 1;
    do @(posedge ap_clk); while (!arready);
    @(negedge ap_clk); arvalid = 0;
    do @(posedge ap_clk); while (!rvalid);
    d = rdata;
    @(negedge ap_clk); rready = 0;
  endtask

  // The datapath's own registers, at +0x1000. Values are copied from
  // tb_t2t_axil_full.sv so the golden is identical to the simulation's, and the
  // network/OUCH fields below match step 6's golden script defaults exactly
  // (stock AAPL, firm HFT1, token FPGA01, 10.0.0.2 -> 10.0.0.9). Only the
  // tracked symbol and price band vary between the synthetic and real feeds.
  logic [31:0] rto = 0;
  logic [31:0] nstore, nresent, ndrop;
  logic [31:0] cfg_loc     = 32'd13;
  logic [31:0] cfg_band_px = 32'd2800000;

  task automatic configure_t2t;
    axil_write(T2T + 13'h00, GROUP);            // cfg_group_ip
    axil_write(T2T + 13'h04, 32'h0000_676D);    // cfg_udp_port 26477
    axil_write(T2T + 13'h08, cfg_loc);          // cfg_track_locate
    axil_write(T2T + 13'h0C, cfg_band_px);      // cfg_band_base
    axil_write(T2T + 13'h10, 32'h0000_0001);    // cfg_enable
    axil_write(T2T + 13'h14, 32'd2000);         // cfg_max_spread
    axil_write(T2T + 13'h18, 32'h0000_0001);    // cfg_ratio_shift
    axil_write(T2T + 13'h1C, 32'd100);          // cfg_min_qty
    axil_write(T2T + 13'h20, 32'd100);          // cfg_order_qty
    axil_write(T2T + 13'h24, 32'd1000);         // cfg_pos_limit
    axil_write(T2T + 13'h28, 32'h0000_FFFF);    // cfg_max_inflight (limiter off)
    axil_write(T2T + 13'h2C, 32'h0000_0000);    // cfg_sweep_en
    axil_write(T2T + 13'h30, 32'h0000_0003);    // cfg_sweep_min_levels
    axil_write(T2T + 13'h34, 32'd1000000);      // cfg_sweep_gap lo
    axil_write(T2T + 13'h38, 32'h0000_0000);    // cfg_sweep_gap hi
    axil_write(T2T + 13'h3C, 32'h4147_5046);    // cfg_token_prefix lo "AGPF"
    axil_write(T2T + 13'h40, 32'h0000_3130);    // cfg_token_prefix hi "10"
    axil_write(T2T + 13'h44, 32'h4C50_4141);    // cfg_stock lo "LPAA"
    axil_write(T2T + 13'h48, 32'h2020_2020);    // cfg_stock hi
    axil_write(T2T + 13'h4C, 32'h3154_4648);    // cfg_firm "1TFH"
    axil_write(T2T + 13'h50, 32'h0000_0000);    // cfg_tif
    axil_write(T2T + 13'h54, 32'h0000_0000);    // cfg_ouch_min_qty
    axil_write(T2T + 13'h58, 32'h0000_0041);    // cfg_display "A" (0x41)
    axil_write(T2T + 13'h5C, 32'h0000_0050);    // cfg_capacity "P"
    axil_write(T2T + 13'h60, 32'h0000_004E);    // cfg_sweep "N"
    axil_write(T2T + 13'h64, 32'h0000_004E);    // cfg_cross "N"
    axil_write(T2T + 13'h68, 32'h0000_004E);    // cfg_cust "N"
    axil_write(T2T + 13'h6C, 32'hCCDD_EEFF);    // cfg_dst_mac lo
    axil_write(T2T + 13'h70, 32'h0000_AABB);    // cfg_dst_mac hi
    axil_write(T2T + 13'h74, 32'h2233_4455);    // cfg_src_mac lo
    axil_write(T2T + 13'h78, 32'h0000_0011);    // cfg_src_mac hi
    axil_write(T2T + 13'h7C, 32'h0A00_0002);    // cfg_src_ip
    axil_write(T2T + 13'h80, 32'h0A00_0009);    // cfg_dst_ip
    axil_write(T2T + 13'h84, 32'h0000_9C41);    // cfg_src_port 40001
    axil_write(T2T + 13'h88, 32'h0000_0FA1);    // cfg_dst_port 4001
    axil_write(T2T + 13'h8C, 32'h1000_0000);    // cfg_init_seq
    axil_write(T2T + 13'h90, 32'h2000_0000);    // cfg_ack_num
    axil_write(T2T + 13'h94, 32'h0000_FFFF);    // cfg_window
    axil_write(T2T + 13'h98, 32'h0000_1000);    // cfg_init_id
    axil_write(T2T + 13'h9C, 32'h0000_0001);    // cfg_igmp_en
    axil_write(T2T + 13'hA0, 32'h4000_0000);    // cfg_igmp_interval (no periodic)
    axil_write(T2T + 13'hA4, GROUP);            // cfg_group_ip_b (single feed)
    if (rto != 0) begin
      axil_write(T2T + 13'hB0, 32'h0000_0001); // cfg_rto_en
      axil_write(T2T + 13'hB4, rto);           // cfg_rto_cycles
      axil_write(T2T + 13'hB8, 32'h0000_0002); // cfg_rto_retries
    end
    axil_write(T2T + 13'hA8, 32'h0000_0001);    // CTRL: commit
  endtask

  // ================= sequence =================
  int      fd, fo, c, nbytes;
  string   fname, capname;
  int      gap, quiet;
  logic [31:0] v, id, st, ncap, ntx, nsess;
  logic [31:0] nlat, lexcl, lmin, lmax, lsum;
  logic [31:0] nload, lmiss, lmax2, lsum2;
  int      guard;

  initial begin
    awvalid = 0; wvalid = 0; bready = 0; arvalid = 0; rready = 0;
    wstrb = 4'hF; awaddr = '0; araddr = '0; wdata = '0;

    fname = "replay.bin"; void'($value$plusargs("eth=%s", fname));
    capname = "capture.bin"; void'($value$plusargs("cap=%s", capname));
    gap = 48; void'($value$plusargs("gap=%d", gap));
    quiet = 256; void'($value$plusargs("quiet=%d", quiet));
    rjit = 0; void'($value$plusargs("rjit=%d", rjit));
    // +rto=<cycles> turns the automatic retransmission on with that timeout.
    // Zero -- the default -- leaves it off, which is how every other test in
    // this file runs and why their goldens are unaffected by its existence.
    rto = 0; void'($value$plusargs("rto=%d", rto));
    void'($value$plusargs("loc=%d", cfg_loc));
    void'($value$plusargs("base=%d", cfg_band_px));

    for (int i = 0; i < CMEM_BYTES; i++) cmem[i] = 8'h00;

    // load the packed replay image into the read model's memory
    fd = $fopen(fname, "rb");
    if (fd == 0) begin $display("FATAL: cannot open %s", fname); $finish; end
    nbytes = 0;
    forever begin
      c = $fgetc(fd);
      if (c == -1) break;
      rmem[nbytes] = byte'(c);
      nbytes++;
      if (nbytes >= RMEM_BYTES) begin
        $display("FATAL: %s exceeds the %0d MB simulation memory model.",
                 fname, RMEM_BYTES / (1024*1024));
        $display("       Use a smaller slice for simulation; the full real replay");
        $display("       belongs on the card (make run-card-latency).");
        $finish;
      end
    end
    $fclose(fd);
    $display("TB: loaded %0d bytes (%0d beats) from %s", nbytes, nbytes/64, fname);

    repeat (8) @(negedge ap_clk);   ap_rst_n   = 1;
    repeat (8) @(negedge ap_clk_2); ap_rst_n_2 = 1;
    repeat (8) @(negedge ap_clk);

    // the kernel must identify itself before anything else is trusted
    axil_read(R_ID, id);
    $display("TB: kernel id = %08x (expect %08x)", id, EXP_ID);
    if (id !== EXP_ID) $display("FAIL: kernel ID register wrong");

    // harness setup. cfg_beats is only a safety bound -- the zero-length
    // terminator in the image is what actually ends the run.
    axil_write(R_RP_BASE_L, 32'h0000_0000);
    axil_write(R_RP_BASE_H, 32'h0000_0000);
    axil_write(R_RP_BEATS,  32'(RMEM_BYTES / 64));
    axil_write(R_RP_GAP,    32'(gap));
    axil_write(R_CP_BASE_L, CAP_BASE[31:0]);
    axil_write(R_CP_BASE_H, CAP_BASE[63:32]);
    axil_write(R_CP_RECS,   32'(CMEM_BYTES / RECORD_BYTES));
    // A latency sample counts only if its frame arrived into a provably empty
    // pipe, so the quiet window must exceed the pipeline depth. FINDINGS 7.1
    // puts the imbalance path at ~28 core cycles; 256 RX cycles is ample. The
    // injector's gap must therefore be at least this for samples to be accepted
    // -- at the default gap of 48 they are all excluded, which is the guard
    // working, not a failure. `make test-latency` runs with a gap that qualifies.
    axil_write(R_L_QUIET,   32'(quiet));
    axil_write(R_CTRL,      32'h0000_000A);     // clear capture + latency

    // read one back, to prove the harness window is not write-only
    axil_read(R_RP_GAP, v);
    if (v !== 32'(gap)) $display("FAIL: harness readback %08x != %08x", v, gap);

    configure_t2t();

    // UltraRAM has no initial contents, so the order table clears itself after
    // reset; enabling the feed before that finishes corrupts the table.
    guard = 0;
    do begin
      axil_read(T2T + 13'h108, st);             // st_init_done
      guard++;
    end while (st[0] !== 1'b1 && guard < 20000);
    if (st[0] !== 1'b1) $display("FAIL: st_init_done never asserted");
    $display("TB: order table initialised after %0d polls", guard);

`ifdef PHASE_B
    // The MAC has to be up before the injector runs. The kernel refuses a start
    // while the link is down (frames offered to a disabled transmitter are
    // dropped inside the IP), so without this the run would look like a datapath
    // that produced nothing rather than a link that had not come up yet.
    guard = 0;
    do begin
      axil_read(R_C_STATUS, st);
      guard++;
    end while (st[1] !== 1'b1 && guard < 20000);
    if (st[1] !== 1'b1) $display("FAIL: CMAC link never came up");
    $display("TB: CMAC link up (aligned=%0d) after %0d polls", st[0], guard);
`endif

    axil_write(R_CTRL, 32'h0000_0001);          // start the replay

    // wait for the injector to reach the terminator
    guard = 0;
    do begin
      axil_read(R_STATUS, st);
      guard++;
    end while (st[1] !== 1'b1 && guard < 2000000);
    if (st[1] !== 1'b1) $display("FAIL: replay never completed");

    // let the tail of the pipeline drain and the last capture burst land
    repeat (20000) @(posedge ap_clk);

    axil_read(R_RP_FRAMES, v); $display("TB: frames injected = %0d", v);
    if (v == 0) $display("FAIL: injector produced no frames");
    axil_read(R_CP_FRAMES, ncap); $display("TB: frames captured = %0d", ncap);
    // The empty-capture check waits until st_frame_cnt has been read, below:
    // Phase A captures the IGMP report too, so empty is always wrong there, but
    // Phase B filters the capture to TCP and a stimulus that fires no orders
    // legitimately captures nothing.
    axil_read(R_CP_OVF,   v); $display("TB: capture overflow = %0d", v);
    if (v != 0) $display("FAIL: capture overflowed");
    axil_read(R_CP_STALL, v); $display("TB: capture stalls   = %0d", v);

    // Datapath counters, through the forwarded window. Offsets are
    // STATUS_BASE(0x100) + 4*index over regmap.py's STATUS list, in t2t_top's
    // st_* order -- st_sent is entry 11, st_frame_cnt entry 17.
    axil_read(T2T + 13'h100, v); $display("TB: st_rx_drop     = %0d", v);
    axil_read(T2T + 13'h10C, v); $display("TB: st_frames_in   = %0d", v);
    axil_read(T2T + 13'h110, v); $display("TB: st_frames_kept = %0d", v);
    axil_read(T2T + 13'h118, v); $display("TB: st_ot_overflow = %0d", v);
    axil_read(T2T + 13'h12C, v); $display("TB: st_sent        = %0d", v);
    axil_read(T2T + 13'h144, ntx); $display("TB: st_frame_cnt   = %0d", ntx);
`ifdef PHASE_B
    if (ncap == 0 && ntx != 0)
      $display("FAIL: %0d orders built and the capture wrote no frames", ntx);
`else
    if (ncap == 0) $display("FAIL: capture wrote no frames");
`endif
    axil_read(T2T + 13'h148, v); $display("TB: st_tx_drop     = %0d", v);
    if (v != 0) $display("FAIL: TX CDC dropped %0d beats", v);
    // The counters published after st_tx_drop, read the same way -- through the
    // AXI window rather than hierarchically, which is what proves the register
    // map and not just the RTL. st_bbo_mismatch must be zero: it counts fast_bbo
    // claiming certainty and price_ladder then disagreeing, and a nonzero value
    // means the book the orders came from was not the book the ladder computed.
    axil_read(T2T + 13'h14C, v);   $display("TB: st_bbo_early   = %0d", v);
    axil_read(T2T + 13'h150, v);   $display("TB: st_bbo_late    = %0d", v);
    axil_read(T2T + 13'h154, v);   $display("TB: st_bbo_mismatch= %0d", v);
    if (v != 0) $display("FAIL: fast_bbo disagreed with the ladder %0d times", v);
    axil_read(T2T + 13'h164, v);   $display("TB: st_rx_sess_frm = %0d", v);
    axil_read(T2T + 13'h168, v);   $display("TB: st_rto_fired   = %0d", v);
    if (rto != 0 && v == 0)
      $display("FAIL: automatic retransmission was enabled and never fired");
    axil_read(T2T + 13'h16C, v);   $display("TB: st_rto_gaveup  = %0d", v);

    // The replay buffer, and the last rejection reason to reach the map. These
    // are worth reading through the window rather than displaying from the RTL
    // because each has an invariant the run can check:
    //   stored == st_frame_cnt   every frame the engine built entered the ring.
    //                            A shortfall means a frame went out unrecorded
    //                            and could never be re-sent.
    //   resent + drop == fired   every request the RTO detector raised was
    //                            either served or refused; neither counter
    //                            moving on a fired request means one vanished.
    //   drop == 0                a refusal means the ring was asked for a slot
    //                            it never held -- with the detector driving the
    //                            age itself, that is a bug, not a workload.
    axil_read(T2T + 13'h170, nstore); $display("TB: st_rb_stored   = %0d", nstore);
    if (nstore != ntx)
      $display("FAIL: engine built %0d frames, replay buffer stored %0d",
               ntx, nstore);
    axil_read(T2T + 13'h174, nresent); $display("TB: st_rb_resent   = %0d", nresent);
    axil_read(T2T + 13'h178, ndrop);   $display("TB: st_rb_drop     = %0d", ndrop);
    if (ndrop != 0)
      $display("FAIL: %0d resend request(s) refused by the replay buffer", ndrop);
    axil_read(T2T + 13'h168, v);       // st_rto_fired again, to compare against
    if (nresent + ndrop != v)
      $display("FAIL: %0d resends requested, %0d served + %0d refused",
               v, nresent, ndrop);
    // Blocked for shares outside OUCH's legal range. The configured order_qty
    // is inside it, so anything here means the strategy asked for a size it
    // never should have computed.
    axil_read(T2T + 13'h130, v);   $display("TB: st_blk_pos     = %0d", v);
    axil_read(T2T + 13'h134, v);   $display("TB: st_blk_inflight= %0d", v);
    axil_read(T2T + 13'h138, v);   $display("TB: st_blk_txfull  = %0d", v);
    axil_read(T2T + 13'h190, v);   $display("TB: st_bbo_arb_drop= %0d", v);
    axil_read(T2T + 13'h180, v);   $display("TB: st_position_1  = %0d", $signed(v));
    axil_read(T2T + 13'h17C, v);   $display("TB: st_blk_qty     = %0d", v);
    if (v != 0) $display("FAIL: %0d order(s) blocked on an illegal share count", v);
    // What geometry did this build actually elaborate? Read, not assumed: the
    // knobs reach the kernel through `defines, and a define that did not arrive
    // produces a single-symbol design that runs perfectly and tracks one name.
    // Read AFTER the check above, not before it -- putting it between a read
    // and the `if` that tests it made this testbench report a million blocked
    // orders that were really the geometry word.
    axil_read(T2T + 13'h194, v);
    $display("TB: build geom     = NSYM=%0d OT=2^%0dx%0d",
             v[7:0], v[15:8], v[23:16]);
    if (v[7:0] != `T2T_NSYM)
      $display("FAIL: built NSYM=%0d, expected %0d", v[7:0], `T2T_NSYM);
    // st_frame_cnt counts the ORDER frames tcp_tx built; capture records
    // everything on the TX port, so the surplus is the IGMP reports (and any
    // ARP replies) the arbiter merged in. Capture may therefore exceed it, but
    // never fall short -- that would mean a frame was emitted and lost.
    if (ncap < ntx)
      $display("FAIL: engine built %0d frames, capture recorded only %0d", ntx, ncap);
    $display("TB: captured %0d frames = %0d orders + %0d other (IGMP/ARP)",
             ncap, ntx, ncap - ntx);

`ifdef PHASE_B
    // ---- what the MAC saw, and what the loopback path did with it ----
    axil_read(R_C_TXPKT, v);   $display("TB: MAC tx frames  = %0d", v);
    axil_read(R_C_RXPKT, v);   $display("TB: MAC rx frames  = %0d", v);
    axil_read(R_C_RXERR, v);   $display("TB: MAC rx errors  = %0d", v);
    if (v != 0) $display("FAIL: %0d frames came back damaged", v);
    // A TX underrun means a frame was started and then starved -- exactly what
    // axis_sf_fifo exists to prevent. If this is non-zero the captured frames
    // cannot be trusted, whatever the diff says.
    axil_read(R_C_UNF, v);     $display("TB: MAC tx underrun= %0d", v);
    if (v != 0) $display("FAIL: MAC underran on %0d frames", v);
    axil_read(R_C_FLT_P, v);   $display("TB: filter passed  = %0d", v);
    axil_read(R_C_FLT_D, v);   $display("TB: filter dropped = %0d (feed + IGMP/ARP)", v);
    axil_read(R_C_CAPDROP, v); $display("TB: capture CDC drops = %0d", v);
    if (v != 0) $display("FAIL: capture CDC dropped %0d beats", v);
    // In Phase B the capture path is protocol-filtered, so only TCP reaches it --
    // unlike Phase A, where IGMP and ARP were captured too. TCP is BOTH
    // directions of the order session, though: the loopback returns the frames
    // the card sent, and the venue's replies are TCP arriving the other way. So
    // the exact count is the orders built plus the session frames tcp_rx kept,
    // and a stimulus with no replies still gives the old ncap == ntx.
    axil_read(T2T + 13'h164, nsess);
    if (ncap != ntx + nsess)
      $display("FAIL: %0d order frames + %0d session frames, %0d captured",
               ntx, nsess, ncap);
`endif

    // ---- latency probe: the measurement that replaces FINDINGS 7.1's sum ----
    axil_read(R_L_SAMPLES, nlat);
    axil_read(R_L_EXCL,    lexcl);
    axil_read(R_L_ORPHANS, v);
    $display("TB: latency samples=%0d excluded=%0d orphans=%0d", nlat, lexcl, v);
    if (nlat == 0) begin
      // Only a failure when the run actually qualified: with gap >= quiet every
      // order is attributable, so zero samples then means the probe is not
      // seeing the streams. Below that, exclusion is the guard doing its job --
      // and with no orders at all there was never anything to sample, which is a
      // property of the stimulus (the real feed fires none this early) rather
      // than of the probe.
      if (gap >= quiet && ntx != 0)
        $display("FAIL: latency probe recorded no samples at gap=%0d quiet=%0d",
                 gap, quiet);
      else
        $display("TB: no latency samples, as expected (gap=%0d < quiet=%0d)",
                 gap, quiet);
    end else begin
      axil_read(R_L_MIN,    lmin);
      axil_read(R_L_MAX,    lmax);
      axil_read(R_L_SUM_LO, lsum);
      $display("TB: latency (RX cycles) min=%0d max=%0d avg=%0d",
               lmin, lmax, lsum / nlat);
      // Sanity, not a golden: the imbalance path is ~28 core cycles plus the
      // frame's own beats and both CDC crossings. Single digits would mean the
      // probe is stamping the wrong event; thousands would mean the gap leaked
      // into the measurement.
      if (lmin < 10)    $display("FAIL: latency min=%0d implausibly small", lmin);
      if (lmax > 20000) $display("FAIL: latency max=%0d implausibly large", lmax);
      if (nlat != ntx)
        $display("NOTE: %0d samples for %0d order frames (%0d unattributable)",
                 nlat, ntx, ntx - nlat);
      for (int b = 0; b < 16; b++) begin
        axil_read(R_L_HIST + 13'(4*b), v);
        if (v != 0) $display("TB:   hist[2^%0d..] = %0d", b, v);
      end
    end
    // ---- loaded-latency probe: works regardless of the gap ----
    // This is the one that answers FINDINGS 7.2. It needs no quiet window
    // because it correlates on the ITCH timestamp the datapath already carries,
    // so it produces samples at gaps where lat_probe correctly refuses to.
    axil_read(R_M_SAMPLES, nload);
    axil_read(R_M_MISSES,  lmiss);
    $display("TB: loaded-latency samples=%0d misses=%0d", nload, lmiss);
    // Only a failure if there was something to measure. The real feed's first
    // hundred thousand messages fire no orders at all (they are rare that early),
    // and a probe with nothing to correlate is then the correct answer rather
    // than a broken instrument.
    if (nload == 0) begin
      // A probe with nothing to correlate is the right answer when nothing was
      // sent, and reading its min/max in that state is how a stimulus with no
      // orders used to report "max 0 below min 4294967295" -- the reset values,
      // and a division by zero one line later.
      if (ntx != 0)
        $display("FAIL: %0d orders sent and the loaded probe recorded no samples", ntx);
      else
        $display("TB: no loaded-latency samples: this stimulus fires no orders");
    end else begin
      axil_read(R_M_MIN,    v);
      axil_read(R_M_MAX,    lmax2);
      axil_read(R_M_SUM_LO, lsum2);
      $display("TB: loaded latency (core cycles) min=%0d max=%0d avg=%0d",
               v, lmax2, lsum2 / nload);
      if (lmax2 < v) $display("FAIL: loaded max %0d below min %0d", lmax2, v);
    end

    if (lexcl != 0 && gap >= quiet)
      $display("FAIL: %0d samples excluded even though gap=%0d >= quiet=%0d",
               lexcl, gap, quiet);

    // Dump the capture area exactly as the host will read it back off the card.
    // Only the records actually written are emitted -- dumping the whole 4 MB
    // window one byte at a time is minutes of simulator time for no information,
    // and the parser stops at the first empty record anyway.
    fo = $fopen(capname, "wb");
    for (int i = 0; i < int'(ncap) * RECORD_BYTES && i < CMEM_BYTES; i++)
      $fwrite(fo, "%c", cmem[i]);
    $fclose(fo);
    $display("TB done: capture image written to %s", capname);
    $finish;
  end

  // safety net; the replay terminates on its own well before this
  initial begin
    repeat (400000000) @(posedge ap_clk);
    $display("FAIL: timeout");
    $finish;
  end
endmodule
