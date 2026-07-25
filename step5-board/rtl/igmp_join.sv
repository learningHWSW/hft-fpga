// IGMPv2 membership-report generator -- the piece that makes the feed actually
// arrive on a real card.
//
// eth_ip_udp_rx filters incoming frames to the feed's multicast group, but a
// switch will not forward that group to this port until the port announces it
// wants it. That announcement is an IGMP membership report; without one the
// filter is correct and the wire is silent. This module emits the report.
//
// It builds an IGMPv2 Membership Report (type 0x16) for cfg_group_ip:
//   Ethernet | IPv4 (+Router Alert option) | IGMP, padded to the 60-byte
//   minimum Ethernet frame, one 512-bit beat. The destination MAC is the
//   standard multicast mapping 01:00:5E : {1'b0, group[22:16]} : group[15:0],
//   the IP destination is the group itself, TTL is 1 (link-local), and the
//   Router Alert option (0x94 0x04 0x00 0x00) is present because IGMP snooping
//   routers expect it.
//
// Three things make a report go out:
//   i_join   -- (re)join now; sends REPORTS_ON_JOIN reports back-to-back, the
//               robustness repeat RFC 2236 asks for so a single lost report
//               does not cost the whole membership.
//   periodic -- every cfg_interval core-clock cycles (0 disables), so the
//               membership is refreshed well inside a switch's group timeout
//               (~260 s) even if no query is heard. At ~216 MHz the 32-bit
//               interval tops out near 19.8 s, which is the intended ballpark.
//   i_query  -- a membership query was seen on the RX side; answer it. Wired
//               low until an RX-side query detector drives it; periodic
//               refresh covers liveness on its own until then.
//
// SCOPE. This is transmit-only, like tcp_tx: it announces membership, it does
// not run the full IGMP state machine (no per-group random response timers, no
// leave/report suppression, no v3 source filtering). For a single well-known
// group that is joined once and held, an unsolicited report plus periodic
// refresh is what keeps the feed flowing; the query input is there for the
// RFC-correct path when the RX detector exists.
`timescale 1ns/1ps
module igmp_join #(
  parameter int DATA_W          = 512,
  parameter int REPORTS_ON_JOIN = 2         // RFC 2236 robustness repeats
)(
  input  logic         clk,
  input  logic         rst_n,

  // configuration (quasi-static)
  input  logic [31:0]  cfg_group_ip,        // the multicast group to join
  input  logic [47:0]  cfg_src_mac,
  input  logic [31:0]  cfg_src_ip,
  input  logic         cfg_igmp_en,         // enable periodic refresh
  input  logic [31:0]  cfg_interval,        // refresh period in clk cycles (0=off)

  // triggers
  input  logic         i_join,              // pulse: (re)join now
  input  logic         i_query,             // pulse: a query was received

  // Ethernet frame to the MAC (shares the TX path with tcp_tx via an arbiter)
  output logic [DATA_W-1:0]   m_tdata,
  output logic [DATA_W/8-1:0] m_tkeep,
  output logic                m_tvalid,
  output logic                m_tlast,
  input  logic                m_tready,

  output logic [31:0]  report_cnt
);
  localparam int BEATB   = DATA_W / 8;      // 64
  localparam int FRAME_B = 60;              // 14 Eth + 24 IPv4(+RA) + 8 IGMP, padded

  // ---- one's complement fold (same as tcp_tx) ----
  function automatic logic [15:0] fold(input logic [31:0] s);
    logic [31:0] t;
    t = (s & 32'hFFFF) + (s >> 16);
    t = (t & 32'hFFFF) + (t >> 16);
    return ~t[15:0];
  endfunction

  // ---- multicast destination MAC from the group IP (low 23 bits) ----
  wire [47:0] mcast_mac = {8'h01, 8'h00, 8'h5e,
                           1'b0, cfg_group_ip[22:16],
                           cfg_group_ip[15:8], cfg_group_ip[7:0]};

  // ---- IPv4 header with Router Alert option (IHL=6, 24 bytes), csum=0 ----
  logic [15:0] ip_w [12];
  always_comb begin
    ip_w[0]  = 16'h4600;                    // ver 4, IHL 6, TOS 0
    ip_w[1]  = 16'h0020;                    // total length 32 = 24 IP + 8 IGMP
    ip_w[2]  = 16'h0000;                    // identification (IGMP is never fragmented)
    ip_w[3]  = 16'h0000;                    // flags/frag offset
    ip_w[4]  = 16'h0102;                    // TTL 1, protocol 2 (IGMP)
    ip_w[5]  = 16'h0000;                    // header checksum placeholder
    ip_w[6]  = cfg_src_ip[31:16];
    ip_w[7]  = cfg_src_ip[15:0];
    ip_w[8]  = cfg_group_ip[31:16];         // destination = the group
    ip_w[9]  = cfg_group_ip[15:0];
    ip_w[10] = 16'h9404;                    // Router Alert: type 148, len 4
    ip_w[11] = 16'h0000;                    // Router Alert value 0
  end
  logic [31:0] ip_acc;
  always_comb begin
    ip_acc = '0;
    for (int i = 0; i < 12; i++) ip_acc += 32'(ip_w[i]);
  end
  wire [15:0] ip_csum = fold(ip_acc);

  // ---- IGMPv2 message (8 bytes), csum=0 ----
  logic [15:0] ig_w [4];
  always_comb begin
    ig_w[0] = 16'h1600;                     // type 0x16 (v2 report), max resp 0
    ig_w[1] = 16'h0000;                     // checksum placeholder
    ig_w[2] = cfg_group_ip[31:16];
    ig_w[3] = cfg_group_ip[15:0];
  end
  logic [31:0] ig_acc;
  always_comb begin
    ig_acc = '0;
    for (int i = 0; i < 4; i++) ig_acc += 32'(ig_w[i]);
  end
  wire [15:0] ig_csum = fold(ig_acc);

  // ---- assemble the 60-byte frame (byte 0 in bits[7:0]) ----
  logic [8*FRAME_B-1:0] frame;
  always_comb begin
    frame = '0;
    for (int k = 0; k < 6; k++) frame[8*k       +: 8] = mcast_mac  [8*(5-k) +: 8];
    for (int k = 0; k < 6; k++) frame[8*(6 + k) +: 8] = cfg_src_mac[8*(5-k) +: 8];
    frame[8*12 +: 8] = 8'h08;               // ethertype 0x0800
    frame[8*13 +: 8] = 8'h00;
    for (int i = 0; i < 12; i++) begin      // IPv4 at byte 14, csum spliced
      automatic logic [15:0] w = (i == 5) ? ip_csum : ip_w[i];
      frame[8*(14 + 2*i)     +: 8] = w[15:8];
      frame[8*(14 + 2*i + 1) +: 8] = w[7:0];
    end
    for (int i = 0; i < 4; i++) begin       // IGMP at byte 38, csum spliced
      automatic logic [15:0] w = (i == 1) ? ig_csum : ig_w[i];
      frame[8*(38 + 2*i)     +: 8] = w[15:8];
      frame[8*(38 + 2*i + 1) +: 8] = w[7:0];
    end
    // bytes 46..59 stay zero: Ethernet padding to the 60-byte minimum
  end

  // ---- trigger accounting and single-beat emit ----
  logic [2:0]  pending;                     // reports still to send (saturating)
  logic [31:0] timer;
  wire tick_fire = cfg_igmp_en && (cfg_interval != 0) && (timer == 32'd0);
  wire emit      = (pending != 0) && (!m_tvalid || m_tready);

  // how many reports each source asks for this cycle
  logic [3:0] add;
  always_comb begin
    add = 4'd0;
    if (i_join)    add += REPORTS_ON_JOIN[3:0];
    if (tick_fire) add += 4'd1;
    if (i_query)   add += 4'd1;
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      pending    <= 3'd0;
      timer      <= 32'd0;
      m_tvalid   <= 1'b0;
      m_tlast    <= 1'b0;
      m_tkeep    <= '0;
      m_tdata    <= '0;
      report_cnt <= 32'd0;
    end else begin
      if (m_tvalid && m_tready) m_tvalid <= 1'b0;

      // periodic timer: reload on fire, else count down while enabled
      if (tick_fire || i_join)
        timer <= cfg_interval;              // (re)start the refresh window
      else if (cfg_igmp_en && cfg_interval != 0 && timer != 0)
        timer <= timer - 32'd1;

      // pending = pending + requested - emitted, saturating at 7
      begin
        automatic logic [4:0] nxt = {2'b0, pending} + {1'b0, add} - {4'b0, emit};
        pending <= (nxt > 5'd7) ? 3'd7 : nxt[2:0];
      end

      if (emit) begin
        m_tdata    <= DATA_W'(frame);   // 60-byte frame zero-extended; keep marks 60
        m_tkeep    <= {BEATB{1'b1}} >> (BEATB - FRAME_B);
        m_tvalid   <= 1'b1;
        m_tlast    <= 1'b1;
        report_cnt <= report_cnt + 32'd1;
      end
    end
  end

endmodule
