// Tick-to-trade plugin for open-nic-shell's box_322mhz.
//
// Drop-in replacement for plugin/p2p/box_322mhz/user_plugin_322mhz_inst.vh:
// it instantiates t2t_user_322mhz (which wraps t2t_axil) in place of the p2p
// forwarder, using the same box signals the default plugin uses. The AXI-Lite
// slice `axil_p2p_*` comes from box_322mhz_address_map_inst.vh -- reuse the p2p
// address-map (one 4 KB slave) unchanged; t2t_axil's map fits in 4 KB.
localparam C_NUM_USER_BLOCK = 1;

// unused reset pairs tie their mod_rst_done bits high
assign mod_rst_done[7:C_NUM_USER_BLOCK] = {(8-C_NUM_USER_BLOCK){1'b1}};

t2t_user_322mhz #(
  .NUM_CMAC_PORT (NUM_CMAC_PORT)
) t2t_user_322mhz_inst (
  .s_axil_awvalid                  (axil_p2p_awvalid),
  .s_axil_awaddr                   (axil_p2p_awaddr),
  .s_axil_awready                  (axil_p2p_awready),
  .s_axil_wvalid                   (axil_p2p_wvalid),
  .s_axil_wdata                    (axil_p2p_wdata),
  .s_axil_wready                   (axil_p2p_wready),
  .s_axil_bvalid                   (axil_p2p_bvalid),
  .s_axil_bresp                    (axil_p2p_bresp),
  .s_axil_bready                   (axil_p2p_bready),
  .s_axil_arvalid                  (axil_p2p_arvalid),
  .s_axil_araddr                   (axil_p2p_araddr),
  .s_axil_arready                  (axil_p2p_arready),
  .s_axil_rvalid                   (axil_p2p_rvalid),
  .s_axil_rdata                    (axil_p2p_rdata),
  .s_axil_rresp                    (axil_p2p_rresp),
  .s_axil_rready                   (axil_p2p_rready),

  .s_axis_adap_tx_322mhz_tvalid    (s_axis_adap_tx_322mhz_tvalid),
  .s_axis_adap_tx_322mhz_tdata     (s_axis_adap_tx_322mhz_tdata),
  .s_axis_adap_tx_322mhz_tkeep     (s_axis_adap_tx_322mhz_tkeep),
  .s_axis_adap_tx_322mhz_tlast     (s_axis_adap_tx_322mhz_tlast),
  .s_axis_adap_tx_322mhz_tuser_err (s_axis_adap_tx_322mhz_tuser_err),
  .s_axis_adap_tx_322mhz_tready    (s_axis_adap_tx_322mhz_tready),

  .m_axis_adap_rx_322mhz_tvalid    (m_axis_adap_rx_322mhz_tvalid),
  .m_axis_adap_rx_322mhz_tdata     (m_axis_adap_rx_322mhz_tdata),
  .m_axis_adap_rx_322mhz_tkeep     (m_axis_adap_rx_322mhz_tkeep),
  .m_axis_adap_rx_322mhz_tlast     (m_axis_adap_rx_322mhz_tlast),
  .m_axis_adap_rx_322mhz_tuser_err (m_axis_adap_rx_322mhz_tuser_err),

  .m_axis_cmac_tx_tvalid           (m_axis_cmac_tx_tvalid),
  .m_axis_cmac_tx_tdata            (m_axis_cmac_tx_tdata),
  .m_axis_cmac_tx_tkeep            (m_axis_cmac_tx_tkeep),
  .m_axis_cmac_tx_tlast            (m_axis_cmac_tx_tlast),
  .m_axis_cmac_tx_tuser_err        (m_axis_cmac_tx_tuser_err),
  .m_axis_cmac_tx_tready           (m_axis_cmac_tx_tready),

  .s_axis_cmac_rx_tvalid           (s_axis_cmac_rx_tvalid),
  .s_axis_cmac_rx_tdata            (s_axis_cmac_rx_tdata),
  .s_axis_cmac_rx_tkeep            (s_axis_cmac_rx_tkeep),
  .s_axis_cmac_rx_tlast            (s_axis_cmac_rx_tlast),
  .s_axis_cmac_rx_tuser_err        (s_axis_cmac_rx_tuser_err),

  .mod_rstn                        (mod_rstn[0]),
  .mod_rst_done                    (mod_rst_done[0]),

  .axil_aclk                       (axil_aclk),
  .cmac_clk                        (cmac_clk)
);
