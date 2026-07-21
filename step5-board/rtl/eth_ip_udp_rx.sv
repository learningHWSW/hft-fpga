// Ethernet / IPv4 / UDP receive front end — strips the headers off a market
// data multicast frame and hands the UDP payload (a MoldUDP64 packet) to the
// feed handler.
//
// Deliberately NOT a general network stack. A receive-only multicast feed needs
// exactly three checks and a header strip; a general stack would add buffering
// and latency, which is the opposite of what this design is for. Fragment
// reassembly, TCP, checksum offload and socket state are all absent on purpose
// (ITCH MoldUDP64 packets are well under an MTU and never fragmented).
//
// Frame layout accepted (the only one a feed uses):
//   0..5   dst MAC      14     version/IHL (must be 0x45)
//   6..11  src MAC      23     protocol    (must be 17, UDP)
//   12..13 EtherType    30..33 dst IP      (must equal cfg_group_ip)
//          (must be 0x0800)
//                       36..37 UDP dst port (must equal cfg_udp_port)
//   42..   payload
// Anything else — VLAN tags, IHL != 5, non-UDP, a different group or port — is
// dropped and counted. Because the accepted layout has a FIXED 42-byte header,
// realigning the payload to byte 0 is a constant concatenation of the previous
// beat's top 22 bytes with this beat's low 42, i.e. pure wiring. That is the
// whole reason for pinning the layout: the splitter's variable barrel shift is
// what dominates routing there, and this stage avoids needing one at all.
//
// No backpressure: the wire cannot be stalled. Downstream is fh_core, whose
// input FIFO absorbs and counts.
`timescale 1ns/1ps
module eth_ip_udp_rx #(
  parameter int DATA_W = 512
)(
  input  logic                clk,
  input  logic                rst_n,

  // configuration (host-written; multicast group and port to subscribe to)
  input  logic [31:0]         cfg_group_ip,
  input  logic [15:0]         cfg_udp_port,

  // raw Ethernet frames from the MAC, one frame per tlast group
  input  logic [DATA_W-1:0]   s_tdata,
  input  logic [DATA_W/8-1:0] s_tkeep,
  input  logic                s_tvalid,
  input  logic                s_tlast,

  // UDP payload (MoldUDP64 packets), realigned to byte 0
  output logic [DATA_W-1:0]   m_tdata,
  output logic [DATA_W/8-1:0] m_tkeep,
  output logic                m_tvalid,
  output logic                m_tlast,

  output logic [31:0]         frames_in,
  output logic [31:0]         frames_kept,
  output logic [31:0]         drop_not_ipv4,
  output logic [31:0]         drop_not_udp,
  output logic [31:0]         drop_group      // right protocol, wrong group/port
);
  localparam int BEATB = DATA_W / 8;
  localparam int HDR_B = 42;                 // 14 + 20 + 8
  localparam int TAILB = BEATB - HDR_B;      // 22 payload bytes in the first beat

  function automatic logic [7:0] bt(input logic [DATA_W-1:0] d, input int k);
    return d[8*k +: 8];
  endfunction
  function automatic int keep_len(input logic [BEATB-1:0] k);
    int c = 0;
    for (int i = 0; i < BEATB; i++) c += int'(k[i]);
    return c;
  endfunction

  // ---- header checks on the first beat ----
  wire [15:0] ethertype = {bt(s_tdata,12), bt(s_tdata,13)};
  wire [7:0]  ver_ihl   =  bt(s_tdata,14);
  wire [7:0]  ipproto   =  bt(s_tdata,23);
  wire [31:0] dst_ip    = {bt(s_tdata,30), bt(s_tdata,31), bt(s_tdata,32), bt(s_tdata,33)};
  wire [15:0] dst_port  = {bt(s_tdata,36), bt(s_tdata,37)};

  wire is_ipv4  = (ethertype == 16'h0800) && (ver_ihl == 8'h45);
  wire is_udp   = (ipproto  == 8'd17);
  wire is_group = (dst_ip == cfg_group_ip) && (dst_port == cfg_udp_port);

  typedef enum logic [1:0] { FIRST, BODY, LAST, DISCARD } state_t;
  state_t state;

  logic [DATA_W-1:0] prev;                   // previous beat, for the fixed shift
  logic [BEATB-1:0]  prev_keep;

  function automatic logic [BEATB-1:0] keep_mask(input int n);
    logic [BEATB-1:0] m;
    m = '0;
    for (int i = 0; i < BEATB; i++) m[i] = (i < n);
    return m;
  endfunction

  // payload beat = previous beat's top TAILB bytes ++ this beat's low HDR_B
  function automatic logic [DATA_W-1:0] realign(input logic [DATA_W-1:0] p,
                                                input logic [DATA_W-1:0] c);
    logic [DATA_W-1:0] o;
    o = '0;
    for (int k = 0; k < TAILB; k++) o[8*k +: 8]           = bt(p, HDR_B + k);
    for (int k = 0; k < HDR_B; k++) o[8*(TAILB + k) +: 8] = bt(c, k);
    return o;
  endfunction

  // tail of one beat, from byte HDR_B on (used when a frame ends early)
  function automatic logic [DATA_W-1:0] tail_of(input logic [DATA_W-1:0] d);
    logic [DATA_W-1:0] o;
    o = '0;
    for (int k = 0; k < BEATB - HDR_B; k++) o[8*k +: 8] = bt(d, HDR_B + k);
    return o;
  endfunction

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state         <= FIRST;
      m_tvalid      <= 1'b0;
      m_tlast       <= 1'b0;
      m_tkeep       <= '0;
      prev_keep     <= '0;
      frames_in     <= '0;
      frames_kept   <= '0;
      drop_not_ipv4 <= '0;
      drop_not_udp  <= '0;
      drop_group    <= '0;
    end else begin
      m_tvalid <= 1'b0;
      m_tlast  <= 1'b0;
      m_tkeep  <= '0;

      unique case (state)
        FIRST: if (s_tvalid) begin
          automatic int kl = keep_len(s_tkeep);
          frames_in <= frames_in + 1;
          if (!is_ipv4) begin
            drop_not_ipv4 <= drop_not_ipv4 + 1;
            state <= s_tlast ? FIRST : DISCARD;
          end else if (!is_udp) begin
            drop_not_udp <= drop_not_udp + 1;
            state <= s_tlast ? FIRST : DISCARD;
          end else if (!is_group) begin
            drop_group <= drop_group + 1;
            state <= s_tlast ? FIRST : DISCARD;
          end else begin
            frames_kept <= frames_kept + 1;
            prev      <= s_tdata;
            prev_keep <= s_tkeep;
            if (s_tlast) begin
              if (kl > HDR_B) begin           // single-beat frame with payload
                m_tdata  <= tail_of(s_tdata);
                m_tkeep  <= keep_mask(kl - HDR_B);
                m_tvalid <= 1'b1;
                m_tlast  <= 1'b1;
              end
              state <= FIRST;
            end else state <= BODY;
          end
        end

        // one payload beat per input beat, running one beat behind
        BODY: if (s_tvalid) begin
          automatic int kl = keep_len(s_tkeep);
          m_tdata   <= realign(prev, s_tdata);
          m_tvalid  <= 1'b1;
          prev      <= s_tdata;
          prev_keep <= s_tkeep;
          if (s_tlast) begin
            if (kl <= HDR_B) begin            // remainder fits in this beat
              m_tkeep <= keep_mask(TAILB + kl);
              m_tlast <= 1'b1;
              state   <= FIRST;
            end else begin
              m_tkeep <= '1;                  // full beat; leftover follows
              state   <= LAST;
            end
          end else m_tkeep <= '1;
        end

        // leftover bytes of the frame's final beat
        LAST: begin
          m_tdata  <= tail_of(prev);
          m_tkeep  <= keep_mask(keep_len(prev_keep) - HDR_B);
          m_tvalid <= 1'b1;
          m_tlast  <= 1'b1;
          state    <= FIRST;
        end

        // swallow the rest of a frame we rejected
        DISCARD: if (s_tvalid && s_tlast) state <= FIRST;

        default: state <= FIRST;
      endcase
    end
  end

endmodule
