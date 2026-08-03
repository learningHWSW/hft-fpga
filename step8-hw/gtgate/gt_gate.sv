// Feasibility gate for Phase B: will v++ connect a kernel's GT interface to the
// platform's QSFP serial port?
//
// This is a throwaway, and deliberately so. Phase B means instantiating a
// cmac_usplus, deriving the 322.265625 MHz stream clock from it, rebuilding the
// injector to drive the MAC's TX, splitting the returning RX stream, and
// reworking the clocking -- hours of work that is all wasted if v++ turns out not
// to connect a user kernel to io_gt_qsfp0_00 on this platform. So the connection
// itself is tested first, with the smallest thing that can carry a GT interface:
// a control slave (Vitis requires one) and the four differential lane groups.
//
// The same cheap-gate-first approach found the answers to the clock binding and
// the constraint delivery earlier in this step; each cost a minute and saved a
// build. `--to_step vpl.create_bd` stops right after the block design is built,
// which is where the connection either happens or does not.
//
// The GT pins are intentionally not driven by anything. This gate asks whether
// the platform will WIRE them, not whether a MAC works.
`timescale 1ns/1ps
module gt_gate (
  input  logic        ap_clk,
  input  logic        ap_rst_n,

  // ---- AXI4-Lite control slave: Vitis requires one on every kernel ----
  input  logic [11:0] s_axi_control_AWADDR,
  input  logic        s_axi_control_AWVALID,
  output logic        s_axi_control_AWREADY,
  input  logic [31:0] s_axi_control_WDATA,
  input  logic [3:0]  s_axi_control_WSTRB,
  input  logic        s_axi_control_WVALID,
  output logic        s_axi_control_WREADY,
  output logic [1:0]  s_axi_control_BRESP,
  output logic        s_axi_control_BVALID,
  input  logic        s_axi_control_BREADY,
  input  logic [11:0] s_axi_control_ARADDR,
  input  logic        s_axi_control_ARVALID,
  output logic        s_axi_control_ARREADY,
  output logic [31:0] s_axi_control_RDATA,
  output logic [1:0]  s_axi_control_RRESP,
  output logic        s_axi_control_RVALID,
  input  logic        s_axi_control_RREADY,

  // ---- the point of the exercise: a 4-lane GT serial port + its refclk ----
  input  logic        gt_refclk_p,
  input  logic        gt_refclk_n,
  input  logic [3:0]  gt_rxp_in,
  input  logic [3:0]  gt_rxn_in,
  output logic [3:0]  gt_txp_out,
  output logic [3:0]  gt_txn_out
);
  // A trivial always-ready register slave. Enough for Vitis to accept the kernel;
  // nothing here is meant to be useful.
  logic [31:0] scratch;
  logic        wr_seen;

  assign s_axi_control_BRESP  = 2'b00;
  assign s_axi_control_RRESP  = 2'b00;
  assign s_axi_control_RDATA  = scratch;

  always_ff @(posedge ap_clk) begin
    if (!ap_rst_n) begin
      scratch <= 32'h4754_4741;              // "GTGA"
      s_axi_control_AWREADY <= 1'b0; s_axi_control_WREADY <= 1'b0;
      s_axi_control_BVALID  <= 1'b0; s_axi_control_ARREADY <= 1'b0;
      s_axi_control_RVALID  <= 1'b0; wr_seen <= 1'b0;
    end else begin
      s_axi_control_AWREADY <= s_axi_control_AWVALID && !s_axi_control_AWREADY;
      s_axi_control_WREADY  <= s_axi_control_WVALID  && !s_axi_control_WREADY;
      wr_seen <= s_axi_control_WVALID && s_axi_control_WREADY;
      if (s_axi_control_WVALID && s_axi_control_WREADY) scratch <= s_axi_control_WDATA;
      if (wr_seen)                                s_axi_control_BVALID <= 1'b1;
      else if (s_axi_control_BREADY)              s_axi_control_BVALID <= 1'b0;
      s_axi_control_ARREADY <= s_axi_control_ARVALID && !s_axi_control_ARREADY;
      if (s_axi_control_ARVALID && s_axi_control_ARREADY) s_axi_control_RVALID <= 1'b1;
      else if (s_axi_control_RREADY)                      s_axi_control_RVALID <= 1'b0;
    end
  end

  // Loop the lanes straight back so the ports are not optimised away entirely.
  // This is not the near-end loopback Phase B wants -- that happens inside the
  // GT, configured through the CMAC -- it just keeps the pins alive.
  assign gt_txp_out = gt_rxp_in;
  assign gt_txn_out = gt_rxn_in;

endmodule
