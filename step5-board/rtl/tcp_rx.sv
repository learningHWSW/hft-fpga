// TCP receive for the order session — the inbound half of tick-to-trade.
//
// THE GAP THIS CLOSES. The card sends OUCH orders from its own MAC, so NASDAQ's
// replies — TCP ACKs, and SoupBinTCP/OUCH Order Accepted / Executed / Rejected —
// come back to the CARD, not to the host. Until now nothing looked at them:
// eth_ip_udp_rx filters UDP for the market-data feed and drops everything else,
// and tcp_tx took its acknowledgement number from `cfg_ack_num`, a static shadow
// register software wrote by hand. That works in a test where the host owns the
// socket. On hardware it cannot: every segment the card transmits would carry a
// stale ACK, and nothing would ever release the in-flight limiter.
//
// WHAT THIS IS NOT, and the omissions are the design. There is no reassembly, no
// out-of-order buffering and no retransmission:
//
//   in-order segment      payload forwarded, rcv_nxt advances
//   out-of-order (gap)    counted and DROPPED -- the sender retransmits
//   duplicate / old       counted and dropped
//   pure ACK, no payload  peer_ack updates, nothing forwarded
//   FIN / RST             flagged and counted; teardown is software's business
//
// Dropping an out-of-order segment is legitimate TCP receiver behaviour, not a
// shortcut: a receiver that declines to buffer simply costs the sender a
// retransmission. What it buys is the absence of a reassembly buffer, which would
// otherwise be the largest thing in this module and would exist to optimise a
// path carrying a few acknowledgements per second. The property that matters --
// never deliver bytes out of order, never deliver the same byte twice -- is kept.
//
// THE PAYLOAD IS NOT REALIGNED, on purpose. A TCP header is 20 bytes plus
// options, so the payload starts somewhere between byte 54 and byte 74 of the
// frame and can land in either of the first two 512-bit beats. Realigning it to
// byte 0 needs a two-beat window and a barrel shift -- mold_splitter, the hardest
// block in this project, rebuilt for a path that is not hot. Instead the frame is
// passed through unmodified and `o_pay_off` / `o_pay_len` say where the payload
// sits inside it. The host already reads these frames out of the capture buffer
// and slicing at an offset is one line of Python there.
//
// WHAT THE HARDWARE ACTUALLY NEEDS from inbound is only the header: `rcv_nxt` so
// its own segments carry a valid ACK, and `peer_ack` so the in-flight limiter and
// the replay buffer know what the venue has taken. Decoding OUCH stays in
// software, which already does it (step7-host).
`timescale 1ns/1ps
module tcp_rx #(
  parameter int DATA_W = 512
)(
  input  logic                clk,
  input  logic                rst_n,

  // the session's 4-tuple, written by software when it establishes the
  // connection and hands it over (the same cfg_load that arms tcp_tx)
  input  logic [31:0]         cfg_local_ip,
  input  logic [31:0]         cfg_peer_ip,
  input  logic [15:0]         cfg_local_port,
  input  logic [15:0]         cfg_peer_port,
  // initial receive sequence, from the SYN-ACK software already parsed
  input  logic [31:0]         cfg_irs,
  input  logic                cfg_load,          // pulse: adopt cfg_irs

  // raw Ethernet frames from the MAC
  input  logic [DATA_W-1:0]   s_tdata,
  input  logic [DATA_W/8-1:0] s_tkeep,
  input  logic                s_tvalid,
  input  logic                s_tlast,

  // frames belonging to the session, passed through unmodified
  output logic [DATA_W-1:0]   m_tdata,
  output logic [DATA_W/8-1:0] m_tkeep,
  output logic                m_tvalid,
  output logic                m_tlast,

  // where the TCP payload sits inside the frame just emitted, valid with tlast
  output logic [15:0]         o_pay_off,
  output logic [15:0]         o_pay_len,

  // session state for the transmit side
  output logic [31:0]         rcv_nxt,           // -> tcp_tx cfg_ack_num
  output logic [31:0]         peer_ack,          // what the venue has taken
  output logic [15:0]         peer_window,
  output logic                seen_fin,
  output logic                seen_rst,

  output logic [31:0]         frames_in,
  output logic [31:0]         frames_kept,
  output logic [31:0]         drop_not_tcp,      // not IPv4/TCP, or VLAN, or IHL!=5
  output logic [31:0]         drop_tuple,        // TCP, but a different connection
  output logic [31:0]         drop_ooo,          // gap ahead of rcv_nxt
  output logic [31:0]         drop_dup,          // entirely behind rcv_nxt
  output logic [31:0]         payload_bytes
);
  // ---- byte accessors over the first beat ----------------------------------
  // Everything this module needs is inside the first 64 bytes: Ethernet (14) +
  // IPv4 (20) + TCP through the flags (20) ends at byte 54. Options, if any,
  // extend past that but only their LENGTH matters, and the data offset that
  // gives it is at byte 46.
  function automatic logic [7:0] b(input logic [DATA_W-1:0] d, input int i);
    return d[8*i +: 8];
  endfunction
  function automatic logic [15:0] be16(input logic [DATA_W-1:0] d, input int i);
    return {b(d,i), b(d,i+1)};
  endfunction
  function automatic logic [31:0] be32(input logic [DATA_W-1:0] d, input int i);
    return {b(d,i), b(d,i+1), b(d,i+2), b(d,i+3)};
  endfunction

  localparam int ETH_HDR = 14;
  localparam int IP_HDR  = 20;
  localparam int TCP_OFF = ETH_HDR + IP_HDR;      // 34

  // ---- per-frame state -----------------------------------------------------
  logic        in_frame;      // past the first beat of a frame
  logic        accept;        // this frame is ours
  logic [15:0] beat_cnt;
  logic [15:0] frm_bytes;

  logic [31:0] seg_seq;
  logic [31:0] seg_ack;
  logic [15:0] seg_win;
  logic [15:0] seg_pay_off;
  logic        seg_fin, seg_rst, seg_ack_f;
  logic [15:0] seg_ip_total;

  // keep count of the bytes actually presented, since tkeep marks the tail
  function automatic int unsigned keep_bytes(input logic [DATA_W/8-1:0] k);
    int unsigned n = 0;
    for (int i = 0; i < DATA_W/8; i++) if (k[i]) n++;
    return n;
  endfunction

  wire first_beat = s_tvalid && !in_frame;

  // ---- first-beat decode ---------------------------------------------------
  wire        h_ipv4   = (be16(s_tdata,12) == 16'h0800);
  wire        h_ihl5   = (b(s_tdata,14) == 8'h45);       // IPv4, no IP options
  wire        h_tcp    = (b(s_tdata,23) == 8'd6);
  wire [31:0] h_src_ip = be32(s_tdata,26);
  wire [31:0] h_dst_ip = be32(s_tdata,30);
  wire [15:0] h_sport  = be16(s_tdata,34);
  wire [15:0] h_dport  = be16(s_tdata,36);
  wire [31:0] h_seq    = be32(s_tdata,38);
  wire [31:0] h_ack    = be32(s_tdata,42);
  // NOTE: the part-select is on a WIRE, not on the function call. Writing
  // `b(s_tdata,46)[7:4]` parses but evaluates to zero under xvlog, which made
  // every data offset read as 0: the payload offset came out as 34 instead of 54
  // and the payload length as the whole TCP header plus payload. Nothing warned.
  wire [7:0]  h_off_byte = b(s_tdata,46);
  wire [3:0]  h_doff   = h_off_byte[7:4];                // in 32-bit words
  wire [7:0]  h_flags  = b(s_tdata,47);
  wire [15:0] h_win    = be16(s_tdata,48);
  wire [15:0] h_iplen  = be16(s_tdata,16);               // IP total length

  wire h_proto_ok = h_ipv4 && h_ihl5 && h_tcp;
  wire h_tuple_ok = (h_src_ip == cfg_peer_ip)  && (h_dst_ip == cfg_local_ip) &&
                    (h_sport  == cfg_peer_port) && (h_dport == cfg_local_port);

  // payload offset within the frame, and payload length from the IP total length
  wire [15:0] h_pay_off = 16'(TCP_OFF) + 16'({h_doff, 2'b00});
  wire [15:0] h_tcp_hdr = 16'({h_doff, 2'b00});
  wire [15:0] h_pay_len = (h_iplen >= (16'(IP_HDR) + h_tcp_hdr))
                          ? (h_iplen - 16'(IP_HDR) - h_tcp_hdr) : 16'd0;

  // ---- sequence acceptance -------------------------------------------------
  // Serial-number comparison, so the 32-bit space wrapping is not a special case:
  // a difference is "ahead" if its signed interpretation is positive.
  wire signed [31:0] seq_delta = $signed(h_seq) - $signed(rcv_nxt);
  wire in_order  = (seq_delta == 0);
  wire ahead     = (seq_delta > 0);                      // gap: we missed some
  wire behind    = (seq_delta < 0);

  // A retransmission that starts behind rcv_nxt but reaches past it still carries
  // bytes we need; without this it would be counted as a duplicate forever and
  // the connection would wedge.
  wire covers_next = behind &&
        ($signed(h_seq + 32'(h_pay_len) + 32'(h_flags[1]) + 32'(h_flags[0]))
         - $signed(rcv_nxt) > 0);

  // SEQUENCE-CONSUMING length, which is not the same as the payload length: SYN
  // and FIN each occupy one sequence number even with no data. Folding them in
  // here rather than patching rcv_nxt afterwards is what keeps the acceptance
  // test and the advance consistent -- an earlier version advanced rcv_nxt on a
  // FIN unconditionally, so a DUPLICATE FIN moved it and desynchronised the
  // connection permanently.
  wire [31:0] seg_len = 32'(h_pay_len) + 32'(h_flags[1]) + 32'(h_flags[0]);

  wire seg_ok    = h_proto_ok && h_tuple_ok;
  wire accept_seg = (seg_len != 0) && (in_order || covers_next);
  wire pay_drop_ooo = (seg_len != 0) && ahead;
  wire pay_drop_dup = (seg_len != 0) && behind && !covers_next;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      in_frame <= 1'b0; accept <= 1'b0; beat_cnt <= '0; frm_bytes <= '0;
      rcv_nxt <= '0; peer_ack <= '0; peer_window <= '0;
      seen_fin <= 1'b0; seen_rst <= 1'b0;
      frames_in <= '0; frames_kept <= '0;
      drop_not_tcp <= '0; drop_tuple <= '0; drop_ooo <= '0; drop_dup <= '0;
      payload_bytes <= '0;
      seg_seq <= '0; seg_ack <= '0; seg_win <= '0; seg_pay_off <= '0;
      seg_fin <= 1'b0; seg_rst <= 1'b0; seg_ack_f <= 1'b0; seg_ip_total <= '0;
      o_pay_off <= '0; o_pay_len <= '0;
    end else begin
      // software hands over the connection: adopt the peer's initial sequence
      if (cfg_load) begin
        rcv_nxt  <= cfg_irs;
        seen_fin <= 1'b0;
        seen_rst <= 1'b0;
      end

      if (s_tvalid) begin
        if (first_beat) begin
          frames_in <= frames_in + 1'b1;
          beat_cnt  <= 16'd1;
          frm_bytes <= 16'(keep_bytes(s_tkeep));
          in_frame  <= !s_tlast;

          accept      <= seg_ok;
          seg_seq     <= h_seq;
          seg_ack     <= h_ack;
          seg_win     <= h_win;
          seg_pay_off <= h_pay_off;
          seg_fin     <= h_flags[0];
          seg_rst     <= h_flags[2];
          seg_ack_f   <= h_flags[4];
          seg_ip_total<= h_pay_len;

          if (!h_proto_ok)      drop_not_tcp <= drop_not_tcp + 1'b1;
          else if (!h_tuple_ok) drop_tuple   <= drop_tuple   + 1'b1;
          else begin
            frames_kept <= frames_kept + 1'b1;

            // ACK field is only meaningful with the ACK flag set
            if (h_flags[4]) peer_ack <= h_ack;
            peer_window <= h_win;
            if (h_flags[0]) seen_fin <= 1'b1;
            if (h_flags[2]) seen_rst <= 1'b1;

            if (accept_seg) begin
              // One assignment, covering data, SYN and FIN alike. A partially
              // overlapping retransmission lands here too and contributes only
              // its new tail, because the advance is absolute (seq + len) rather
              // than incremental.
              rcv_nxt       <= h_seq + seg_len;
              payload_bytes <= payload_bytes + 32'(h_pay_len);
            end else begin
              if (pay_drop_ooo) drop_ooo <= drop_ooo + 1'b1;
              if (pay_drop_dup) drop_dup <= drop_dup + 1'b1;
            end
          end
        end else begin
          beat_cnt  <= beat_cnt + 1'b1;
          frm_bytes <= frm_bytes + 16'(keep_bytes(s_tkeep));
          in_frame  <= !s_tlast;
        end

        if (s_tlast) begin
          in_frame  <= 1'b0;
          o_pay_off <= (first_beat ? h_pay_off : seg_pay_off);
          o_pay_len <= (first_beat ? h_pay_len : seg_ip_total);
        end
      end
    end
  end

  // ---- pass-through --------------------------------------------------------
  // Session frames only. Everything else never existed downstream, which is what
  // keeps the capture buffer readable: without this the host would be sifting the
  // venue's segments out of a million feed frames.
  wire pass = first_beat ? seg_ok : accept;
  assign m_tdata  = s_tdata;
  assign m_tkeep  = s_tkeep;
  assign m_tvalid = s_tvalid && pass;
  assign m_tlast  = s_tlast;
endmodule
