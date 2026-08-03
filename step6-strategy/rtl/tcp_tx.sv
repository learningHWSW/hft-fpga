// Minimal TCP transmit engine — puts an OUCH packet on the wire.
//
// SCOPE, because the name promises more than this delivers. This is a
// transmit-only data path for an ALREADY ESTABLISHED connection. The three-way
// handshake, retransmission, window probing, RST handling and teardown all
// live in software, which writes the resulting connection state into the
// cfg_* shadow registers below. The hardware does one thing: put a segment on
// the wire the instant the strategy produces one.
//
// The cost of that, stated rather than hidden: there is NO RETRANSMISSION.
// A dropped segment is a dropped order and recovery is the host's problem.
// This is a deliberate trade — a retransmit buffer means holding every sent
// segment and a timer per segment, which is state and latency on the one path
// that exists to be fast — but it is the reason this cannot be pointed at an
// exchange and left unattended.
//
// Flow control is satisfied by construction rather than by logic. The
// strategy's in-flight limiter caps outstanding orders at cfg_max_inflight
// (4), i.e. 4 x 52 = 208 bytes of unacknowledged payload, which is far below
// any TCP window a peer would advertise. The risk gate doubles as flow
// control, so this block does not need to track the window to be safe.
//
// Frame: 106 bytes = 14 Ethernet + 20 IPv4 + 20 TCP + 52 payload, emitted as
// two 512-bit beats (64 + 42). Byte 0 sits in tdata[7:0], as everywhere else.
//
// Checksums are one's complement adder trees over fixed-size inputs, so there
// is no accumulator loop and no per-word state machine. They do NOT fit in one
// cycle, though: the TCP checksum covers 42 words (12 of pseudo header, 10 of
// header, 26 of payload) and folding that plus assembling the frame in a single
// cycle missed 4.618 ns by 0.107 ns. The payload sum therefore gets its own
// cycle (CALC), which costs one cycle of latency on the hot path.
//
// The alternative, if that cycle ever matters: the OUCH builder already
// assembles the payload combinationally and has 3.9 ns of slack, so it could
// emit the payload's one's complement sum alongside the packet for free. That
// was not done here because it spreads TCP's checksum into a module that
// otherwise knows nothing about TCP, and one cycle out of the ~25 in this path
// is not yet worth the coupling.
`timescale 1ns/1ps
module tcp_tx #(
  parameter int DATA_W  = 512,
  parameter int PAYLD_B = 52                  // SoupBinTCP + OUCH enter order
)(
  input  logic         clk,
  input  logic         rst_n,

  // connection state, written by software once the handshake completes
  input  logic [47:0]  cfg_dst_mac,
  input  logic [47:0]  cfg_src_mac,
  input  logic [31:0]  cfg_src_ip,
  input  logic [31:0]  cfg_dst_ip,
  input  logic [15:0]  cfg_src_port,
  input  logic [15:0]  cfg_dst_port,
  input  logic [31:0]  cfg_init_seq,
  input  logic [31:0]  cfg_ack_num,           // shadow: last ack seen by software
  input  logic [15:0]  cfg_window,
  input  logic [15:0]  cfg_init_id,
  input  logic         cfg_load,              // pulse to (re)load seq and id

  // payload from the OUCH builder, one beat
  input  logic [DATA_W-1:0]   s_tdata,
  input  logic                s_tvalid,
  output logic                s_tready,

  // Ethernet frame to the MAC
  output logic [DATA_W-1:0]   m_tdata,
  output logic [DATA_W/8-1:0] m_tkeep,
  output logic                m_tvalid,
  output logic                m_tlast,
  input  logic                m_tready,

  output logic [31:0]  seq_num,               // next sequence number, for software
  output logic [31:0]  frame_cnt
);
  localparam int BEATB   = DATA_W / 8;        // 64
  localparam int HDR_B   = 54;                // 14 + 20 + 20
  localparam int FRAME_B = HDR_B + PAYLD_B;   // 106
  localparam int TAIL_B  = FRAME_B - BEATB;   // 42

  logic [15:0] ip_id;

  // ---- one's complement sum helpers ----
  function automatic logic [15:0] fold(input logic [31:0] s);
    logic [31:0] t;
    t = (s & 32'hFFFF) + (s >> 16);
    t = (t & 32'hFFFF) + (t >> 16);
    return ~t[15:0];
  endfunction

  // ---- IPv4 header, checksum field left zero for now ----
  localparam logic [15:0] TOTAL_LEN = 16'(20 + 20 + PAYLD_B);
  logic [15:0] ip_w [10];
  always_comb begin
    ip_w[0] = 16'h4500;
    ip_w[1] = TOTAL_LEN;
    ip_w[2] = ip_id;
    ip_w[3] = 16'h4000;                        // don't fragment
    ip_w[4] = 16'h4006;                        // TTL 64, protocol 6
    ip_w[5] = 16'h0000;                        // checksum placeholder
    ip_w[6] = cfg_src_ip[31:16];
    ip_w[7] = cfg_src_ip[15:0];
    ip_w[8] = cfg_dst_ip[31:16];
    ip_w[9] = cfg_dst_ip[15:0];
  end

  logic [31:0] ip_acc;
  always_comb begin
    ip_acc = '0;
    for (int i = 0; i < 10; i++) ip_acc += 32'(ip_w[i]);
  end
  wire [15:0] ip_csum = fold(ip_acc);

  // ---- TCP header + pseudo header, checksum field left zero ----
  localparam logic [15:0] TCP_LEN = 16'(20 + PAYLD_B);
  logic [15:0] tcp_w [10];
  always_comb begin
    tcp_w[0] = cfg_src_port;
    tcp_w[1] = cfg_dst_port;
    tcp_w[2] = seq_num[31:16];
    tcp_w[3] = seq_num[15:0];
    tcp_w[4] = cfg_ack_num[31:16];
    tcp_w[5] = cfg_ack_num[15:0];
    tcp_w[6] = 16'h5018;                       // data offset 5, PSH|ACK
    tcp_w[7] = cfg_window;
    tcp_w[8] = 16'h0000;                       // checksum placeholder
    tcp_w[9] = 16'h0000;                       // urgent pointer
  end

  // payload words, big-endian pairs out of the little-endian-byte beat.
  // Summed in its own cycle and registered as pl_sum; see the header comment.
  logic [15:0] pl_w [PAYLD_B/2];
  always_comb
    for (int i = 0; i < PAYLD_B/2; i++)
      pl_w[i] = {s_tdata[8*(2*i) +: 8], s_tdata[8*(2*i+1) +: 8]};

  logic [31:0] pl_acc;
  always_comb begin
    pl_acc = '0;
    for (int i = 0; i < PAYLD_B/2; i++) pl_acc += 32'(pl_w[i]);
  end

  logic [31:0] pl_sum;                         // registered payload sum
  logic [31:0] tcp_acc;
  always_comb begin
    tcp_acc = pl_sum
            + 32'(cfg_src_ip[31:16]) + 32'(cfg_src_ip[15:0])
            + 32'(cfg_dst_ip[31:16]) + 32'(cfg_dst_ip[15:0])
            + 32'(16'h0006) + 32'(TCP_LEN);
    for (int i = 0; i < 10; i++) tcp_acc += 32'(tcp_w[i]);
  end
  wire [15:0] tcp_csum = fold(tcp_acc);

  // ---- assemble the frame ----
  // `hold` belongs to the output state machine below, but the frame assembly
  // reads it, and xvlog rejects a forward reference even though synthesis
  // tolerates it -- so it is declared here, ahead of its first use.
  logic [DATA_W-1:0]    hold;                  // payload held while it is summed
  logic [8*FRAME_B-1:0] frame;
  always_comb begin
    frame = '0;
    for (int k = 0; k < 6; k++) frame[8*k       +: 8] = cfg_dst_mac[8*(5-k) +: 8];
    for (int k = 0; k < 6; k++) frame[8*(6 + k) +: 8] = cfg_src_mac[8*(5-k) +: 8];
    frame[8*12 +: 8] = 8'h08;
    frame[8*13 +: 8] = 8'h00;
    // IPv4: big-endian words at byte 14, with the real checksum spliced in
    for (int i = 0; i < 10; i++) begin
      automatic logic [15:0] w = (i == 5) ? ip_csum : ip_w[i];
      frame[8*(14 + 2*i)     +: 8] = w[15:8];
      frame[8*(14 + 2*i + 1) +: 8] = w[7:0];
    end
    // TCP at byte 34
    for (int i = 0; i < 10; i++) begin
      automatic logic [15:0] w = (i == 8) ? tcp_csum : tcp_w[i];
      frame[8*(34 + 2*i)     +: 8] = w[15:8];
      frame[8*(34 + 2*i + 1) +: 8] = w[7:0];
    end
    // payload at byte 54, straight through from the held beat
    for (int k = 0; k < PAYLD_B; k++)
      frame[8*(HDR_B + k) +: 8] = hold[8*k +: 8];
  end

  // ---- two-beat output ----
  typedef enum logic [1:0] { IDLE, CALC, BEAT1 } state_t;
  state_t state;
  logic [8*TAIL_B-1:0] tail;                   // (hold is declared above)

  assign s_tready = (state == IDLE) && (!m_tvalid || m_tready);

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state     <= IDLE;
      m_tvalid  <= 1'b0;
      m_tlast   <= 1'b0;
      m_tkeep   <= '0;
      m_tdata   <= '0;
      seq_num   <= '0;
      ip_id     <= '0;
      frame_cnt <= '0;
    end else begin
      if (cfg_load) begin
        seq_num <= cfg_init_seq;
        ip_id   <= cfg_init_id;
      end

      if (m_tvalid && m_tready) m_tvalid <= 1'b0;

      unique case (state)
        // take the payload and sum it; nothing else fits in this cycle
        IDLE: if (s_tvalid && s_tready) begin
          hold   <= s_tdata;
          pl_sum <= pl_acc;
          state  <= CALC;
        end

        // checksums fold, the frame assembles, and the first beat goes out
        CALC: begin
          m_tdata   <= frame[0 +: DATA_W];         // first 64 bytes
          m_tkeep   <= '1;
          m_tvalid  <= 1'b1;
          m_tlast   <= 1'b0;
          tail      <= frame[8*BEATB +: 8*TAIL_B];
          state     <= BEAT1;
          if (!cfg_load) begin
            seq_num <= seq_num + 32'(PAYLD_B);
            ip_id   <= ip_id + 16'd1;
          end
          frame_cnt <= frame_cnt + 1;
        end

        BEAT1: if (!m_tvalid || m_tready) begin
          m_tdata  <= DATA_W'(tail);
          m_tkeep  <= {BEATB{1'b1}} >> (BEATB - TAIL_B);
          m_tvalid <= 1'b1;
          m_tlast  <= 1'b1;
          state    <= IDLE;
        end

        default: state <= IDLE;
      endcase
    end
  end

endmodule
