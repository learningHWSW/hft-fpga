// The 100G MAC, wrapped: bring-up sequencing, near-end loopback, and a stream
// interface the rest of the design already speaks.
//
// WHAT PHASE B CHANGES. Phase A proved the datapath on silicon with eth_replay
// standing in for the MAC -- the frames were real, the golden diff was real, but
// nothing ever became a signal. Here the same frames go out through a
// cmac_usplus, down the GT's serializer, back up through its receiver in near-end
// PMA loopback, through PCS alignment and FCS checking, and into the datapath.
// Everything the design would meet on a wire except the wire.
//
// WHY NEAR-END PMA and not PCS. Near-end PCS loopback turns back before the
// serializer, so it proves the encoder and nothing analogue. PMA loopback goes
// through the full transmit and receive PMA -- the same 25.78125 Gb/s serdes, the
// same CDR, the same elastic buffer -- so block lock, lane alignment and the
// alignment-marker machinery all have to actually work. It is the strongest test
// available with the cages empty, which the operator has confirmed they are.
//
// FCS. The IP is generated with FCS insertion on TX and FCS stripping on RX
// (C_TX_FCS_INS_ENABLE=1, C_RX_DELETE_FCS=1), so a frame handed in here comes
// back out byte-identical. That is not a detail -- it is what keeps the Phase A
// golden valid in Phase B. If RX kept the FCS every captured order frame would
// carry four extra bytes and every diff would fail for a reason that has nothing
// to do with the design.
//
// BRING-UP, in the order the MAC requires it. The receiver cannot align until
// the transmitter is sending something, and in loopback the only transmitter is
// this one, so the sequence is not optional:
//
//   1. usr_tx_reset / usr_rx_reset drop when the GT's own reset FSM finishes
//   2. ctl_tx_send_rfi drives remote-fault ordered sets -- valid line traffic,
//      but not data -- which is what the receiver locks and aligns to
//   3. stat_rx_aligned rises
//   4. only then ctl_tx_enable rises and ctl_tx_send_rfi drops
//
// Data offered before step 4 would be dropped by the MAC, so s_tready is held
// low until the link is up rather than accepting frames into a hole.
//
// SIMULATION. cmac_usplus cannot usefully be simulated here: it needs the
// unisim GT models and secure-IP libraries, and a 100G link takes tens of
// microseconds of wall-clock alignment before the first frame moves. Under
// `CMAC_SIM the instantiation is replaced by a behavioural loopback with the same
// interface and the same bring-up handshake, so the testbench exercises the
// kernel's own logic -- arbiter, store-and-forward FIFOs, RX split, probes --
// and the MAC itself is validated on hardware, by the golden diff, which is the
// only place it can be.
`timescale 1ns/1ps
module cmac_wrap #(
  parameter int DATA_W = 512
)(
  // ---- GT quad ----
  input  logic              gt_refclk_p,
  input  logic              gt_refclk_n,
  input  logic [3:0]        gt_rxp_in,
  input  logic [3:0]        gt_rxn_in,
  output logic [3:0]        gt_txp_out,
  output logic [3:0]        gt_txn_out,

  // ---- housekeeping ----
  input  logic              init_clk,       // free-running 100 MHz, also DRP
  input  logic              sys_rst,        // active high
  input  logic [2:0]        loopback_mode,  // GT loopback, per lane: 000 off,
                                            // 001 near-end PCS, 010 near-end PMA

  // ---- the stream clock the MAC produces; everything below is in it ----
  output logic              tx_clk,         // gt_txusrclk2, 322.265625 MHz
  output logic              tx_rst_n,

  // ---- TX: frames onto the wire ----
  input  logic [DATA_W-1:0] s_tdata,
  input  logic [DATA_W/8-1:0] s_tkeep,
  input  logic              s_tvalid,
  input  logic              s_tlast,
  output logic              s_tready,

  // ---- RX: frames off the wire (no backpressure, like any MAC) ----
  output logic [DATA_W-1:0] m_tdata,
  output logic [DATA_W/8-1:0] m_tkeep,
  output logic              m_tvalid,
  output logic              m_tlast,
  output logic              m_terr,         // frame arrived damaged

  // ---- status, in tx_clk ----
  output logic              rx_aligned,
  output logic              link_up,        // aligned AND transmitting data
  output logic [31:0]       c_tx_pkts,
  output logic [31:0]       c_rx_pkts,
  output logic [31:0]       c_rx_err,
  output logic [31:0]       c_underflow,
  output logic [31:0]       c_overflow
);
  localparam int KEEP_W = DATA_W / 8;

  logic usr_tx_reset, usr_rx_reset;
  logic stat_rx_aligned_raw;
  logic ctl_tx_enable, ctl_tx_send_rfi;
  logic tx_unfout, tx_ovfout;
  logic s_tready_mac;

  // ---- bring-up FSM (see the sequence in the header) ----
  (* ASYNC_REG = "TRUE" *) logic [1:0] align_sync;
  always_ff @(posedge tx_clk) begin
    if (usr_tx_reset) align_sync <= 2'b00;
    else              align_sync <= {align_sync[0], stat_rx_aligned_raw};
  end
  assign rx_aligned = align_sync[1];

  always_ff @(posedge tx_clk) begin
    if (usr_tx_reset) begin
      ctl_tx_enable   <= 1'b0;
      ctl_tx_send_rfi <= 1'b1;      // fault ordered sets: what the RX locks to
    end else if (rx_aligned) begin
      ctl_tx_enable   <= 1'b1;
      ctl_tx_send_rfi <= 1'b0;
    end
  end

  assign tx_rst_n = !usr_tx_reset;
  assign link_up  = rx_aligned && ctl_tx_enable;

  // ---- counters ----
  // tx_unfout is the one that matters: it says a frame was started and then
  // starved, which is precisely the failure axis_sf_fifo exists to prevent. A
  // non-zero underflow count on the card means the store-and-forward assumption
  // is broken somewhere, and the captured frames cannot be trusted.
  always_ff @(posedge tx_clk) begin
    if (!tx_rst_n) begin
      c_tx_pkts <= '0; c_rx_pkts <= '0; c_rx_err <= '0;
      c_underflow <= '0; c_overflow <= '0;
    end else begin
      if (s_tvalid && s_tready && s_tlast) c_tx_pkts <= c_tx_pkts + 1'b1;
      if (m_tvalid && m_tlast) begin
        c_rx_pkts <= c_rx_pkts + 1'b1;
        if (m_terr) c_rx_err <= c_rx_err + 1'b1;
      end
      if (tx_unfout) c_underflow <= c_underflow + 1'b1;
      if (tx_ovfout) c_overflow  <= c_overflow  + 1'b1;
    end
  end

`ifndef CMAC_SIM
  // ================= the real MAC =================
  // gt_loopback_in is three bits per lane, four lanes: the mode repeated.
  //
  // 010 near-end PMA is what every Phase B measurement uses -- it goes through
  // the full transmit and receive PMA, so the SerDes, the CDR and the elastic
  // buffer are all inside the number. 001 near-end PCS turns back BEFORE the
  // serializer, so the same measurement taken both ways brackets the PMA:
  // (PMA round trip) - (PCS round trip) is the serializer, deserializer, CDR and
  // elastic buffer, which is the part of the MAC term no custom PCS/MAC could
  // ever recover. That is the point of making this selectable rather than fixed
  // -- see step8-hw/PCS_MAC_SCOPE.md.
  wire [11:0] loopback = {4{loopback_mode}};

  // rx_clk is driven from gt_txusrclk2 because the IP is generated with the RX
  // elastic buffer enabled (RX_GT_BUFFER=1); that is what puts the RX stream in
  // the transmit clock domain and lets the whole wire side be one domain instead
  // of two. Unconnected outputs below are the statistics and OTN ports the IP
  // exposes unconditionally and this design does not use.
  cmac_usplus_0 u_cmac (
    .gt_txp_out              (gt_txp_out),
    .gt_txn_out              (gt_txn_out),
    .gt_rxp_in               (gt_rxp_in),
    .gt_rxn_in               (gt_rxn_in),
    .gt_txusrclk2            (tx_clk),
    .gt_loopback_in          (loopback),
    .gtwiz_reset_tx_datapath (1'b0),
    .gtwiz_reset_rx_datapath (1'b0),
    .sys_reset               (sys_rst),
    .gt_ref_clk_p            (gt_refclk_p),
    .gt_ref_clk_n            (gt_refclk_n),
    .init_clk                (init_clk),

    .rx_axis_tvalid          (m_tvalid),
    .rx_axis_tdata           (m_tdata),
    .rx_axis_tlast           (m_tlast),
    .rx_axis_tkeep           (m_tkeep),
    .rx_axis_tuser           (m_terr),
    .rx_preambleout          (),
    .usr_rx_reset            (usr_rx_reset),
    .stat_rx_aligned         (stat_rx_aligned_raw),
    .ctl_rx_enable           (1'b1),
    .ctl_rx_force_resync     (1'b0),
    .ctl_rx_test_pattern     (1'b0),
    .core_rx_reset           (1'b0),
    .rx_clk                  (tx_clk),

    .ctl_tx_enable           (ctl_tx_enable),
    .ctl_tx_send_idle        (1'b0),
    .ctl_tx_send_rfi         (ctl_tx_send_rfi),
    .ctl_tx_send_lfi         (1'b0),
    .ctl_tx_test_pattern     (1'b0),
    .core_tx_reset           (1'b0),
    .tx_axis_tready          (s_tready_mac),
    .tx_axis_tvalid          (s_tvalid && ctl_tx_enable),
    .tx_axis_tdata           (s_tdata),
    .tx_axis_tlast           (s_tlast),
    .tx_axis_tkeep           (s_tkeep),
    .tx_axis_tuser           (1'b0),
    .tx_ovfout               (tx_ovfout),
    .tx_unfout               (tx_unfout),
    .tx_preamblein           (56'd0),
    .usr_tx_reset            (usr_tx_reset),

    .core_drp_reset          (1'b0),
    .drp_clk                 (init_clk),
    .drp_addr                (10'd0),
    .drp_di                  (16'd0),
    .drp_en                  (1'b0),
    .drp_do                  (),
    .drp_rdy                 (),
    .drp_we                  (1'b0)
  );

  // Refusing data before the link is up is deliberate: the MAC would discard it
  // silently, and a silently discarded feed frame is a golden-diff failure with
  // no evidence attached.
  assign s_tready = s_tready_mac && ctl_tx_enable;

`else
  // ================= behavioural stand-in =================
  // Same interface, same handshake, same bring-up ordering; no GT, no PCS. It
  // reproduces the two things the kernel's own logic has to cope with -- a TX
  // port that deasserts ready, and an RX port that delivers a whole frame back
  // some cycles later with no backpressure -- and nothing else.
  // 322.265625 MHz: half-period 1.5515 ns, the same number the Phase B XDC uses
  localparam int MAC_LAT = 40;              // cycles from TX beat to RX beat

  logic tclk = 1'b0;
  always #1.5515 tclk = ~tclk;
  assign tx_clk = tclk;

  assign gt_txp_out = 4'b0;
  assign gt_txn_out = 4'b0;

  // up_cnt models the GT's own reset and alignment time, compressed from the
  // tens of microseconds the real thing takes to something a testbench can wait
  // for. The ORDER is what matters and is preserved: reset releases first, then
  // alignment, then the FSM above enables the transmitter.
  int unsigned cyc = 0;
  int unsigned up_cnt = 0;

  assign usr_tx_reset        = (up_cnt < 100);
  assign usr_rx_reset        = (up_cnt < 100);
  assign stat_rx_aligned_raw = (up_cnt >= 200);
  assign tx_unfout           = 1'b0;
  assign tx_ovfout           = 1'b0;
  assign s_tready_mac        = 1'b1;

  always_ff @(posedge tclk) begin
    cyc <= cyc + 1;
    if (sys_rst)          up_cnt <= 0;
    else if (up_cnt < 300) up_cnt <= up_cnt + 1;
  end

  // A modest, repeating stall on TX ready: enough to prove the source honours
  // it, not so much that it changes the offered load materially.
  logic [3:0] stall_ph = 4'd0;
  always_ff @(posedge tclk) stall_ph <= stall_ph + 1'b1;
  assign s_tready = ctl_tx_enable && (stall_ph != 4'd7);

  typedef struct {
    logic [DATA_W-1:0] d;
    logic [KEEP_W-1:0] k;
    logic              l;
    int unsigned       due;
  } sim_beat_t;
  sim_beat_t sim_q [$];

  always_ff @(posedge tclk) begin
    if (s_tvalid && s_tready)
      sim_q.push_back('{d: s_tdata, k: s_tkeep, l: s_tlast, due: cyc + MAC_LAT});

    m_tvalid <= 1'b0;
    m_tlast  <= 1'b0;
    m_terr   <= 1'b0;
    if (sim_q.size() > 0 && sim_q[0].due <= cyc) begin
      m_tdata  <= sim_q[0].d;
      m_tkeep  <= sim_q[0].k;
      m_tlast  <= sim_q[0].l;
      m_tvalid <= 1'b1;
      void'(sim_q.pop_front());
    end
  end
`endif

endmodule
