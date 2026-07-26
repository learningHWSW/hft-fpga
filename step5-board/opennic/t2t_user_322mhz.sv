// OpenNIC user-box adapter for the tick-to-trade engine.
//
// This is what drops into open-nic-shell's box_322mhz in place of the default
// p2p_322mhz: it wires t2t_axil to the box's interfaces and supplies the one
// thing the box does not -- a core clock at the datapath's frequency.
//
// The box hands the user two clocks: cmac_clk (322.265625 MHz, the 100G MAC)
// and axil_aclk (the register clock). t2t_axil needs a THIRD, core_clk, at the
// datapath rate: cmac (322) is above its post-route Fmax (~226 MHz) and axil is
// below the 100 Gb/s floor (195.3 MHz), so neither can clock the core. An MMCM
// derives core_clk (200 MHz here -- comfortably between the floor and the Fmax)
// from cmac_clk. That is the only clocking this integration adds.
//
// Datapath: this is a bump-in-the-wire feed handler. CMAC RX (the exchange
// feed) goes straight into t2t_axil; t2t_axil's order frames go straight out
// CMAC TX. The QDMA/host path through the box (adap_tx/adap_rx) is NOT used --
// host TX is accepted and dropped, host RX is held idle -- because orders are
// generated on the FPGA, not forwarded from the host. Configuration and status
// still reach the host over AXI-Lite (axil_regfile inside t2t_axil).
//
// AU55C has a single CMAC, so NUM_CMAC_PORT is 1 and the streams are 512b/64b.
`timescale 1ns/1ps
module t2t_user_322mhz #(
  parameter int NUM_CMAC_PORT = 1
)(
  // ---- per-user AXI-Lite (axil_aclk), from the box address-map crossbar ----
  input  logic         s_axil_awvalid,
  input  logic [31:0]  s_axil_awaddr,
  output logic         s_axil_awready,
  input  logic         s_axil_wvalid,
  input  logic [31:0]  s_axil_wdata,
  output logic         s_axil_wready,
  output logic         s_axil_bvalid,
  output logic [1:0]   s_axil_bresp,
  input  logic         s_axil_bready,
  input  logic         s_axil_arvalid,
  input  logic [31:0]  s_axil_araddr,
  output logic         s_axil_arready,
  output logic         s_axil_rvalid,
  output logic [31:0]  s_axil_rdata,
  output logic [1:0]   s_axil_rresp,
  input  logic         s_axil_rready,

  // ---- host TX (QDMA -> wire): unused, accepted and dropped ----
  input  logic         s_axis_adap_tx_322mhz_tvalid,
  input  logic [512-1:0] s_axis_adap_tx_322mhz_tdata,
  input  logic [64-1:0]  s_axis_adap_tx_322mhz_tkeep,
  input  logic         s_axis_adap_tx_322mhz_tlast,
  input  logic         s_axis_adap_tx_322mhz_tuser_err,
  output logic         s_axis_adap_tx_322mhz_tready,

  // ---- host RX (wire -> QDMA): unused, held idle ----
  output logic         m_axis_adap_rx_322mhz_tvalid,
  output logic [512-1:0] m_axis_adap_rx_322mhz_tdata,
  output logic [64-1:0]  m_axis_adap_rx_322mhz_tkeep,
  output logic         m_axis_adap_rx_322mhz_tlast,
  output logic         m_axis_adap_rx_322mhz_tuser_err,

  // ---- order frames -> CMAC TX ----
  output logic         m_axis_cmac_tx_tvalid,
  output logic [512-1:0] m_axis_cmac_tx_tdata,
  output logic [64-1:0]  m_axis_cmac_tx_tkeep,
  output logic         m_axis_cmac_tx_tlast,
  output logic         m_axis_cmac_tx_tuser_err,
  input  logic         m_axis_cmac_tx_tready,

  // ---- exchange feed <- CMAC RX ----
  input  logic         s_axis_cmac_rx_tvalid,
  input  logic [512-1:0] s_axis_cmac_rx_tdata,
  input  logic [64-1:0]  s_axis_cmac_rx_tkeep,
  input  logic         s_axis_cmac_rx_tlast,
  input  logic         s_axis_cmac_rx_tuser_err,

  // ---- box reset handshake (mod_rstn synchronised to axil_aclk) ----
  input  logic         mod_rstn,
  output logic         mod_rst_done,

  input  logic         axil_aclk,
  input  logic         cmac_clk
);
  // ---------------- core clock (200 MHz) from cmac_clk via MMCM ----------
  logic core_clk, core_locked;
  t2t_core_clk u_core_clk (
    .clk_in1 (cmac_clk),
    .reset   (~mod_rstn),      // active-high reset for the clk_wiz
    .clk_out1(core_clk),
    .locked  (core_locked)
  );

  // ---------------- per-domain resets (active low) ----------------
  // axil is already in the mod_rstn domain; resync into cmac and core, and hold
  // core in reset until the MMCM locks.
  logic axil_rst_n;
  assign axil_rst_n = mod_rstn;

  (* ASYNC_REG="TRUE" *) logic [1:0] cmac_rs;
  always_ff @(posedge cmac_clk or negedge mod_rstn)
    if (!mod_rstn) cmac_rs <= 2'b00; else cmac_rs <= {cmac_rs[0], 1'b1};
  wire cmac_rst_n = cmac_rs[1];

  wire core_arst_n = mod_rstn & core_locked;
  (* ASYNC_REG="TRUE" *) logic [1:0] core_rs;
  always_ff @(posedge core_clk or negedge core_arst_n)
    if (!core_arst_n) core_rs <= 2'b00; else core_rs <= {core_rs[0], 1'b1};
  wire core_rst_n = core_rs[1];

  // module is "reset done" once its clock is up and its resets released
  assign mod_rst_done = core_locked & cmac_rst_n & core_rst_n;

  // ---------------- host path unused (kernel bypass) ----------------
  assign s_axis_adap_tx_322mhz_tready = 1'b1;   // accept + drop host TX
  assign m_axis_adap_rx_322mhz_tvalid    = 1'b0;
  assign m_axis_adap_rx_322mhz_tdata     = '0;
  assign m_axis_adap_rx_322mhz_tkeep     = '0;
  assign m_axis_adap_rx_322mhz_tlast     = 1'b0;
  assign m_axis_adap_rx_322mhz_tuser_err = 1'b0;
  assign m_axis_cmac_tx_tuser_err        = 1'b0;

  // ---------------- the tick-to-trade engine ----------------
  t2t_axil #(.DATA_W(512), .AXIL_AW(12)) u_t2t_axil (
    .cmac_clk   (cmac_clk),
    .cmac_rst_n (cmac_rst_n),
    .rx_tdata   (s_axis_cmac_rx_tdata),
    .rx_tkeep   (s_axis_cmac_rx_tkeep),
    .rx_tvalid  (s_axis_cmac_rx_tvalid),
    .rx_tlast   (s_axis_cmac_rx_tlast),
    .tx_tdata   (m_axis_cmac_tx_tdata),
    .tx_tkeep   (m_axis_cmac_tx_tkeep),
    .tx_tvalid  (m_axis_cmac_tx_tvalid),
    .tx_tlast   (m_axis_cmac_tx_tlast),
    .tx_tready  (m_axis_cmac_tx_tready),

    .core_clk   (core_clk),
    .core_rst_n (core_rst_n),

    .axil_clk       (axil_aclk),
    .axil_rst_n     (axil_rst_n),
    .s_axil_awaddr  (s_axil_awaddr[11:0]),
    .s_axil_awvalid (s_axil_awvalid),
    .s_axil_awready (s_axil_awready),
    .s_axil_wdata   (s_axil_wdata),
    .s_axil_wstrb   (4'hF),               // the box crossbar issues full-word writes
    .s_axil_wvalid  (s_axil_wvalid),
    .s_axil_wready  (s_axil_wready),
    .s_axil_bresp   (s_axil_bresp),
    .s_axil_bvalid  (s_axil_bvalid),
    .s_axil_bready  (s_axil_bready),
    .s_axil_araddr  (s_axil_araddr[11:0]),
    .s_axil_arvalid (s_axil_arvalid),
    .s_axil_arready (s_axil_arready),
    .s_axil_rdata   (s_axil_rdata),
    .s_axil_rresp   (s_axil_rresp),
    .s_axil_rvalid  (s_axil_rvalid),
    .s_axil_rready  (s_axil_rready)
  );

endmodule
