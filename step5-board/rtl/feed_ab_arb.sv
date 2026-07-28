// A/B line arbiter -- gap recovery for the redundant MoldUDP64 feed.
//
// NASDAQ (and most exchange multicast) sends the feed twice, on two independent
// multicast groups (the A and B lines), identical packets with identical
// sequence numbers on independent network paths. A packet dropped on one line
// almost always arrives on the other. This block merges the two into one clean,
// in-order, de-duplicated packet stream for mold_splitter -- so a single-line
// drop is filled from the other line instead of corrupting the book.
//
// It works at the PACKET level: each MoldUDP64 packet is one UDP datagram, which
// eth_ip_udp_rx delivers as one tlast-terminated frame, and the header (seq at
// bytes 10..17, count at 18..19) is in the first beat. It tracks next_seq and,
// per pair of packet heads, picks:
//     exact  (seq == next_seq)  -> forward, next_seq += count
//     dup    (seq <  next_seq)  -> drop (already forwarded, from either line)
//     ahead  (seq >  next_seq)  -> HOLD (backpressure) -- the packet we need is
//                                  coming on the other line in order
// Preferring an EXACT line over an ahead one is what makes recovery work when
// the lines interleave: whichever line has next_seq wins, the other's copy is a
// dup. No reorder buffer is needed because both lines carry every packet in
// order; ahead packets are simply held in the upstream elastic FIFO until they
// become next_seq, never dropped.
//
// The one thing A/B cannot fix is a packet dropped on BOTH lines (a true gap).
// If both heads are ahead for AHEAD_STALL cycles with no packet filling
// next_seq, it is a double gap: emit ev_gap, jump next_seq to the smallest ahead
// packet, and continue -- losing only the packet that was lost on both lines,
// not the good ones behind it. That is the boundary where MoldUDP64 rewind (a
// request to the retransmit server) would take over -- out of scope here.
//
// No backpressure on the wire, so elastic input FIFOs (drop-on-full) belong
// upstream; this block backpressures its inputs while it services one packet or
// waits out a gap.
`timescale 1ns/1ps
module feed_ab_arb #(
  parameter int DATA_W      = 512,
  parameter int AHEAD_STALL = 16     // cycles held on a gap before declaring it
)(
  input  logic                clk,
  input  logic                rst_n,

  input  logic [DATA_W-1:0]   a_tdata,
  input  logic [DATA_W/8-1:0] a_tkeep,
  input  logic                a_tvalid,
  input  logic                a_tlast,
  output logic                a_tready,

  input  logic [DATA_W-1:0]   b_tdata,
  input  logic [DATA_W/8-1:0] b_tkeep,
  input  logic                b_tvalid,
  input  logic                b_tlast,
  output logic                b_tready,

  output logic [DATA_W-1:0]   m_tdata,
  output logic [DATA_W/8-1:0] m_tkeep,
  output logic                m_tvalid,
  output logic                m_tlast,
  input  logic                m_tready,

  output logic                ev_gap,        // double-line gap: pulse on jump
  output logic [31:0]         fwd_cnt,       // packets forwarded
  output logic [31:0]         dup_cnt,       // duplicate packets dropped
  output logic [31:0]         gap_cnt,       // double-line gaps skipped
  output logic [31:0]         a_src_cnt,     // forwards sourced from line A
  output logic [31:0]         b_src_cnt      // forwards sourced from line B
);
  function automatic logic [63:0] hseq(input logic [DATA_W-1:0] d);
    return {d[8*10 +:8], d[8*11 +:8], d[8*12 +:8], d[8*13 +:8],
            d[8*14 +:8], d[8*15 +:8], d[8*16 +:8], d[8*17 +:8]};
  endfunction
  function automatic logic [15:0] hcnt(input logic [DATA_W-1:0] d);
    return {d[8*18 +:8], d[8*19 +:8]};
  endfunction

  logic [63:0] next_seq;
  logic [15:0] wait_cnt;                      // cycles stalled on a suspected gap
  logic        synced;                        // next_seq locked to the first packet

  typedef enum logic [1:0] { IDLE, FWD, DROP } state_t;
  state_t state;
  logic        sel;                           // 0 = A, 1 = B (valid when busy)
  logic [63:0] cur_target;                    // next_seq after this forward

  // ---- classify the two heads relative to next_seq ----
  wire [63:0] a_seq = hseq(a_tdata);
  wire [63:0] b_seq = hseq(b_tdata);
  wire a_ex = a_tvalid && (a_seq == next_seq);
  wire b_ex = b_tvalid && (b_seq == next_seq);
  wire a_du = a_tvalid && (a_seq <  next_seq);
  wire b_du = b_tvalid && (b_seq <  next_seq);
  wire a_ah = a_tvalid && (a_seq >  next_seq);
  wire b_ah = b_tvalid && (b_seq >  next_seq);

  // pick order: exact > dup > ahead(smaller seq). AHEAD only acts once stalled.
  typedef enum logic [1:0] { K_NONE, K_FWD, K_DUP, K_AHEAD } kind_t;
  kind_t p_kind;
  logic  p_sel;
  always_comb begin
    p_kind = K_NONE; p_sel = 1'b0;
    if (a_ex)       begin p_sel = 1'b0; p_kind = K_FWD;   end
    else if (b_ex)  begin p_sel = 1'b1; p_kind = K_FWD;   end
    else if (a_du)  begin p_sel = 1'b0; p_kind = K_DUP;   end
    else if (b_du)  begin p_sel = 1'b1; p_kind = K_DUP;   end
    else if (a_ah || b_ah) begin
      p_sel  = (a_ah && (!b_ah || a_seq <= b_seq)) ? 1'b0 : 1'b1;   // smaller seq
      p_kind = K_AHEAD;
    end
  end

  wire [DATA_W-1:0] p_data = p_sel ? b_tdata : a_tdata;
  wire [63:0]       p_seq  = p_sel ? b_seq   : a_seq;
  wire [15:0]       p_cnt  = hcnt(p_data);
  wire              gap_now = (p_kind == K_AHEAD) && (wait_cnt >= AHEAD_STALL[15:0]);

  // ---- selected-line stream muxing ----
  wire lv = sel ? b_tvalid : a_tvalid;
  wire ll = sel ? b_tlast  : a_tlast;
  always_comb begin
    m_tdata  = sel ? b_tdata : a_tdata;
    m_tkeep  = sel ? b_tkeep : a_tkeep;
    m_tlast  = ll;
    m_tvalid = (state == FWD) && lv;
    a_tready = (state == FWD) ? (!sel && m_tready) : (state == DROP) ? !sel : 1'b0;
    b_tready = (state == FWD) ? ( sel && m_tready) : (state == DROP) ?  sel : 1'b0;
  end
  wire sel_ready = sel ? b_tready : a_tready;
  wire beat_go   = lv && sel_ready;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state <= IDLE; sel <= 1'b0; next_seq <= 64'd1; wait_cnt <= 16'd0;
      synced <= 1'b0; cur_target <= 64'd1; ev_gap <= 1'b0;
      fwd_cnt <= 0; dup_cnt <= 0; gap_cnt <= 0; a_src_cnt <= 0; b_src_cnt <= 0;
    end else begin
      ev_gap <= 1'b0;
      case (state)
        // lock next_seq to the first packet seen (no startup gap), then merge
        IDLE: if (!synced) begin
          if (p_kind != K_NONE) begin
            sel <= p_sel; cur_target <= p_seq + 64'(p_cnt);
            synced <= 1'b1; wait_cnt <= 16'd0; state <= FWD;
          end
        end else begin
          case (p_kind)
            K_FWD: begin
              sel <= p_sel; cur_target <= next_seq + 64'(p_cnt);
              wait_cnt <= 16'd0; state <= FWD;
            end
            K_DUP: begin sel <= p_sel; state <= DROP; end
            K_AHEAD: if (gap_now) begin              // double gap: jump past it
              sel <= p_sel; cur_target <= p_seq + 64'(p_cnt);
              ev_gap <= 1'b1; gap_cnt <= gap_cnt + 1; wait_cnt <= 16'd0;
              state <= FWD;
            end else wait_cnt <= wait_cnt + 16'd1;   // hold, count toward the gap
            default: ;                               // K_NONE: nothing offered
          endcase
        end

        FWD: if (beat_go && ll) begin                // last beat of the packet
          next_seq <= cur_target;
          fwd_cnt  <= fwd_cnt + 1;
          if (sel) b_src_cnt <= b_src_cnt + 1; else a_src_cnt <= a_src_cnt + 1;
          state    <= IDLE;
        end

        DROP: if (beat_go && ll) begin               // last beat of the dup
          dup_cnt <= dup_cnt + 1;
          state   <= IDLE;
        end

        default: state <= IDLE;
      endcase
    end
  end

endmodule
