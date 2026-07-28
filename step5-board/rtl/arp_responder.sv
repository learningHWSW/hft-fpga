// ARP responder -- answers "who has <our IP>?" so a switch or peer can find us.
//
// The order path sends TCP to a destination MAC the host writes into
// cfg_dst_mac (static, which is the normal colo arrangement with a fixed
// cross-connect). But for the peer or gateway to send anything BACK to us --
// TCP acks, or just to keep our entry in its ARP cache -- it must be able to
// resolve our IP. This block answers those ARP requests in hardware.
//
// Like igmp_query_detect it taps the raw RX stream before eth_ip_udp_rx (ARP is
// ethertype 0x0806, not IP, so the feed's UDP/group filter would drop it), and
// like igmp_join it emits a single-beat frame to the TX arbiter. Detect and
// reply are one module because the reply carries the requester's own MAC/IP
// back, so those have to be latched from the request.
//
// SCOPE. This answers requests; it does not itself ARP for others (cfg_dst_mac
// stays host-set) and keeps no cache. That resolver half is a small addition on
// top if a routed, non-static destination is ever needed.
`timescale 1ns/1ps
module arp_responder #(
  parameter int DATA_W = 512
)(
  input  logic                clk,
  input  logic                rst_n,

  input  logic [47:0]         cfg_src_mac,
  input  logic [31:0]         cfg_src_ip,

  // raw RX stream (tap of what feeds eth_ip_udp_rx), byte 0 in bits[7:0]
  input  logic [DATA_W-1:0]   s_tdata,
  input  logic                s_tvalid,
  input  logic                s_tlast,

  // ARP reply frame to the MAC (shares the TX path via the arbiter)
  output logic [DATA_W-1:0]   m_tdata,
  output logic [DATA_W/8-1:0] m_tkeep,
  output logic                m_tvalid,
  output logic                m_tlast,
  input  logic                m_tready,

  output logic [31:0]         reply_cnt
);
  localparam int BEATB   = DATA_W / 8;      // 64
  localparam int FRAME_B = 60;              // 14 Eth + 28 ARP, padded to minimum

  // ---- start-of-frame (the feed path never backpressures) ----
  logic sof;
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n)        sof <= 1'b1;
    else if (s_tvalid) sof <= s_tlast;

  // ---- ARP request fields (fixed layout, no IP options) ----
  //  eth: dst 0..5, src 6..11, type 12..13
  //  arp: htype 14, ptype 16, hlen 18, plen 19, oper 20, sha 22, spa 28,
  //       tha 32, tpa 38
  wire is_arp = (s_tdata[8*12 +: 8] == 8'h08) && (s_tdata[8*13 +: 8] == 8'h06);
  wire is_req = (s_tdata[8*20 +: 8] == 8'h00) && (s_tdata[8*21 +: 8] == 8'h01);
  wire [31:0] tpa = {s_tdata[8*38 +: 8], s_tdata[8*39 +: 8],
                     s_tdata[8*40 +: 8], s_tdata[8*41 +: 8]};
  wire for_us = (tpa == cfg_src_ip);
  wire hit    = sof && s_tvalid && is_arp && is_req && for_us;

  // requester address, latched from the request for the reply
  wire [47:0] req_mac = {s_tdata[8*22 +: 8], s_tdata[8*23 +: 8], s_tdata[8*24 +: 8],
                         s_tdata[8*25 +: 8], s_tdata[8*26 +: 8], s_tdata[8*27 +: 8]};
  wire [31:0] req_ip  = {s_tdata[8*28 +: 8], s_tdata[8*29 +: 8],
                         s_tdata[8*30 +: 8], s_tdata[8*31 +: 8]};

  logic [47:0] dst_mac;      // = requester's MAC
  logic [31:0] dst_ip;       // = requester's IP
  logic        pending;

  // ---- assemble the 60-byte reply (byte 0 in bits[7:0]) ----
  logic [8*FRAME_B-1:0] frame;
  always_comb begin
    frame = '0;
    for (int k = 0; k < 6; k++) frame[8*k       +: 8] = dst_mac    [8*(5-k) +: 8]; // eth dst = requester
    for (int k = 0; k < 6; k++) frame[8*(6 + k) +: 8] = cfg_src_mac[8*(5-k) +: 8]; // eth src = us
    frame[8*12 +: 8] = 8'h08; frame[8*13 +: 8] = 8'h06;                            // ethertype ARP
    frame[8*14 +: 8] = 8'h00; frame[8*15 +: 8] = 8'h01;                            // htype Ethernet
    frame[8*16 +: 8] = 8'h08; frame[8*17 +: 8] = 8'h00;                            // ptype IPv4
    frame[8*18 +: 8] = 8'h06; frame[8*19 +: 8] = 8'h04;                            // hlen 6, plen 4
    frame[8*20 +: 8] = 8'h00; frame[8*21 +: 8] = 8'h02;                            // oper reply
    for (int k = 0; k < 6; k++) frame[8*(22 + k) +: 8] = cfg_src_mac[8*(5-k) +: 8]; // sha = us
    for (int k = 0; k < 4; k++) frame[8*(28 + k) +: 8] = cfg_src_ip [8*(3-k) +: 8]; // spa = us
    for (int k = 0; k < 6; k++) frame[8*(32 + k) +: 8] = dst_mac    [8*(5-k) +: 8]; // tha = requester
    for (int k = 0; k < 4; k++) frame[8*(38 + k) +: 8] = dst_ip     [8*(3-k) +: 8]; // tpa = requester
    // bytes 42..59 stay zero: Ethernet padding to the 60-byte minimum
  end

  wire emit = pending && (!m_tvalid || m_tready);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      pending    <= 1'b0;
      dst_mac    <= '0;
      dst_ip     <= '0;
      m_tvalid   <= 1'b0;
      m_tlast    <= 1'b0;
      m_tkeep    <= '0;
      m_tdata    <= '0;
      reply_cnt  <= 32'd0;
    end else begin
      if (m_tvalid && m_tready) m_tvalid <= 1'b0;

      if (hit) begin                     // latch the requester and arm a reply
        dst_mac <= req_mac;
        dst_ip  <= req_ip;
        pending <= 1'b1;
      end else if (emit) begin
        pending <= 1'b0;
      end

      if (emit) begin
        m_tdata    <= DATA_W'(frame);
        m_tkeep    <= {BEATB{1'b1}} >> (BEATB - FRAME_B);
        m_tvalid   <= 1'b1;
        m_tlast    <= 1'b1;
        reply_cnt  <= reply_cnt + 32'd1;
      end
    end
  end

endmodule
