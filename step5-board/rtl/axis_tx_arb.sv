// Two-into-one AXI-Stream arbiter for the single CMAC TX port.
//
// The design now has two transmit sources sharing one 100G TX: the order path
// (tcp_tx, inside t2t_top) and the multicast-join path (igmp_join). They must
// never interleave beats on the wire, so this arbiter is FRAME-LOCKED: once it
// grants a source it holds the grant until that frame's tlast, then re-arbitrates.
//
// Priority is fixed to s0 (orders). IGMP reports are rare (one every tens of
// seconds) and not latency-critical, so they wait for a gap between order
// frames; an order never waits behind a report except the one beat already in
// flight. Both frames are short (orders 2 beats, reports 1), so the head-of-line
// blocking either way is a couple of CMAC cycles.
`timescale 1ns/1ps
module axis_tx_arb #(
  parameter int DATA_W = 512
)(
  input  logic                clk,
  input  logic                rst_n,

  // s0: order frames (priority)
  input  logic [DATA_W-1:0]   s0_tdata,
  input  logic [DATA_W/8-1:0] s0_tkeep,
  input  logic                s0_tvalid,
  input  logic                s0_tlast,
  output logic                s0_tready,

  // s1: IGMP membership reports
  input  logic [DATA_W-1:0]   s1_tdata,
  input  logic [DATA_W/8-1:0] s1_tkeep,
  input  logic                s1_tvalid,
  input  logic                s1_tlast,
  output logic                s1_tready,

  // merged output to the CMAC
  output logic [DATA_W-1:0]   m_tdata,
  output logic [DATA_W/8-1:0] m_tkeep,
  output logic                m_tvalid,
  output logic                m_tlast,
  input  logic                m_tready
);
  logic busy;      // a frame is in flight
  logic sel;       // 0 = s0 granted, 1 = s1 granted

  // current grant: locked source while busy, else priority pick among offered
  logic       cur_valid;
  logic       pick;                 // which source is being driven this cycle
  always_comb begin
    if (busy)               pick = sel;
    else if (s0_tvalid)     pick = 1'b0;
    else                    pick = 1'b1;   // s1 (or nothing, gated by cur_valid)
    cur_valid = busy ? (sel ? s1_tvalid : s0_tvalid)
                     : (s0_tvalid | s1_tvalid);
  end

  always_comb begin
    if (pick == 1'b0) begin
      m_tdata = s0_tdata; m_tkeep = s0_tkeep; m_tlast = s0_tlast;
    end else begin
      m_tdata = s1_tdata; m_tkeep = s1_tkeep; m_tlast = s1_tlast;
    end
    m_tvalid  = cur_valid;
    s0_tready = (pick == 1'b0) && cur_valid && m_tready;
    s1_tready = (pick == 1'b1) && cur_valid && m_tready;
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      busy <= 1'b0;
      sel  <= 1'b0;
    end else begin
      if (!busy && cur_valid) begin
        busy <= 1'b1;
        sel  <= pick;
      end
      if (m_tvalid && m_tready && m_tlast) busy <= 1'b0;  // frame done
    end
  end
endmodule
