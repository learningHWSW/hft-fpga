// MoldUDP64 stripper — step 3a reference implementation (64-bit).
//
// Input : AXI-Stream, one UDP payload (= one MoldUDP64 packet) per tlast
//         frame. Byte 0 rides tdata[7:0] of the first beat.
// Output: AXI-Stream, one ITCH message per tlast frame — exactly the
//         itch_decoder input contract. No m_tready: downstream never stalls
//         (decoder is always-ready by design).
// Events: single-cycle pulses, valid the same cycle the packet header is
//         consumed and always before that packet's messages are emitted.
//
// Store-and-forward: the whole packet is buffered, then messages are walked
// and re-framed. s_tready is LOW while draining — at the wire this module
// sits behind an absorbing FIFO (drop + counter on overflow), never
// backpressuring the MAC. Per-message output padding means drain can be
// slower than arrival (~1.14x for small messages), so that FIFO is not
// optional at line rate. The 512-bit step 3b version replaces this design;
// this one is the behavioral reference (wide byte muxes, sim-focused).
//
// Sequence tracking (mirrors scripts/dump_mold.py):
//   expected_seq resets to 1 (session assumed to start at 1).
//   gap: seq > expected on any packet (data or heartbeat) -> ev_gap pulse,
//        gap_total += seq - expected, stream continues from new seq.
//   duplicate: data packet with seq < expected -> dropped, dup_cnt++.
//   Recovery (retransmission requests) is software's job, not ours.
`timescale 1ns/1ps
module mold_stripper #(
  parameter int DATA_W = 64
)(
  input  logic                clk,
  input  logic                rst_n,

  input  logic [DATA_W-1:0]   s_tdata,
  input  logic [DATA_W/8-1:0] s_tkeep,
  input  logic                s_tvalid,
  input  logic                s_tlast,
  output logic                s_tready,

  output logic [DATA_W-1:0]   m_tdata,
  output logic [DATA_W/8-1:0] m_tkeep,
  output logic                m_tvalid,
  output logic                m_tlast,

  output logic                ev_gap,       // pulse; ev_expected/ev_seq valid
  output logic                ev_hb,        // pulse; ev_seq valid
  output logic                ev_eos,       // pulse; ev_seq valid
  output logic [63:0]         ev_seq,       // seq of the packet raising events
  output logic [63:0]         ev_expected,  // expected seq at gap detection

  output logic [31:0]         gap_total,    // cumulative missing messages
  output logic [31:0]         dup_cnt,      // dropped duplicate packets
  output logic [31:0]         frame_err_cnt // malformed packet framing
);
  localparam int KEEP_W = DATA_W / 8;
  localparam int BUFB   = 2048;             // > max UDP payload
  localparam int HDR_B  = 20;               // session 10 + seq 8 + count 2
  localparam logic [15:0] EOS_COUNT = 16'hFFFF;

  typedef enum logic [1:0] { COLLECT, HDR, MLEN, EMIT } state_t;
  state_t state;

  logic [7:0]  pbuf [BUFB];
  int          wr_ptr, plen;    // collect side
  int          rd_ptr;          // drain side
  int          emit_rem;        // bytes left in current message
  logic [15:0] msgs_left;
  logic [63:0] expected_seq;

  assign s_tready = (state == COLLECT);

  function automatic int count_keep(input logic [KEEP_W-1:0] k);
    int c = 0;
    for (int i = 0; i < KEEP_W; i++) c += int'(k[i]);
    return c;
  endfunction

  function automatic logic [15:0] p_be16(input int off);
    return {pbuf[off], pbuf[off+1]};
  endfunction

  function automatic logic [63:0] p_be64(input int off);
    return {pbuf[off],   pbuf[off+1], pbuf[off+2], pbuf[off+3],
            pbuf[off+4], pbuf[off+5], pbuf[off+6], pbuf[off+7]};
  endfunction

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state         <= COLLECT;
      wr_ptr        <= 0;
      plen          <= 0;
      rd_ptr        <= 0;
      emit_rem      <= 0;
      msgs_left     <= '0;
      expected_seq  <= 64'd1;
      m_tvalid      <= 1'b0;
      m_tlast       <= 1'b0;
      m_tkeep       <= '0;
      m_tdata       <= '0;
      ev_gap        <= 1'b0;
      ev_hb         <= 1'b0;
      ev_eos        <= 1'b0;
      ev_seq        <= '0;
      ev_expected   <= '0;
      gap_total     <= '0;
      dup_cnt       <= '0;
      frame_err_cnt <= '0;
    end else begin
      m_tvalid <= 1'b0;
      m_tlast  <= 1'b0;
      ev_gap   <= 1'b0;
      ev_hb    <= 1'b0;
      ev_eos   <= 1'b0;

      case (state)
        COLLECT: begin
          if (s_tvalid) begin
            for (int i = 0; i < KEEP_W; i++)
              if (s_tkeep[i] && (wr_ptr + i) < BUFB)
                pbuf[wr_ptr + i] <= s_tdata[8*i +: 8];
            if (s_tlast) begin
              plen   <= wr_ptr + count_keep(s_tkeep);
              wr_ptr <= 0;
              state  <= HDR;
            end else begin
              wr_ptr <= wr_ptr + KEEP_W;
            end
          end
        end

        HDR: begin
          automatic logic [63:0] seq   = p_be64(10);
          automatic logic [15:0] count = p_be16(18);
          ev_seq <= seq;
          if (plen < HDR_B) begin
            frame_err_cnt <= frame_err_cnt + 1;
            state         <= COLLECT;
          end else if (count == EOS_COUNT) begin
            ev_eos <= 1'b1;
            state  <= COLLECT;
          end else begin
            if (seq > expected_seq) begin
              ev_gap      <= 1'b1;
              ev_expected <= expected_seq;
              gap_total   <= gap_total + 32'((seq - expected_seq));
            end
            if (count == 0) begin
              ev_hb <= 1'b1;
              if (seq > expected_seq) expected_seq <= seq;
              state <= COLLECT;
            end else if (seq < expected_seq) begin
              dup_cnt <= dup_cnt + 1;
              state   <= COLLECT;
            end else begin
              msgs_left    <= count;
              rd_ptr       <= HDR_B;
              expected_seq <= seq + 64'(count);
              state        <= MLEN;
            end
          end
        end

        MLEN: begin
          automatic int mlen = int'(p_be16(rd_ptr));
          if (mlen == 0 || rd_ptr + 2 + mlen > plen) begin
            frame_err_cnt <= frame_err_cnt + 1;
            state         <= COLLECT;
          end else begin
            emit_rem <= mlen;
            rd_ptr   <= rd_ptr + 2;
            state    <= EMIT;
          end
        end

        EMIT: begin
          automatic int k = (emit_rem > KEEP_W) ? KEEP_W : emit_rem;
          for (int i = 0; i < KEEP_W; i++) begin
            m_tdata[8*i +: 8] <= (i < k) ? pbuf[rd_ptr + i] : 8'h00;
            m_tkeep[i]        <= (i < k);
          end
          m_tvalid <= 1'b1;
          m_tlast  <= (emit_rem <= KEEP_W);
          rd_ptr   <= rd_ptr + k;
          emit_rem <= emit_rem - k;
          if (emit_rem <= KEEP_W) begin
            if (msgs_left == 1) begin
              if (rd_ptr + k != plen) frame_err_cnt <= frame_err_cnt + 1;
              state <= COLLECT;
            end else begin
              msgs_left <= msgs_left - 1;
              state     <= MLEN;
            end
          end
        end

        default: state <= COLLECT;
      endcase
    end
  end

endmodule
