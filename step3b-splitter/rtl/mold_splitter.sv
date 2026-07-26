// MoldUDP64 realigning splitter — step 3b, 512-bit (100G CMAC width).
//
// Input : AXI-Stream, DATA_W-bit MoldUDP64 payload beats. One UDP packet per
//         group of beats; the last beat of a packet is partial (tkeep marks
//         valid bytes). Packet boundaries come from framing (header MsgCount
//         + per-message length prefixes), not from tlast, so tlast is not
//         used in the datapath.
// Output: AXI-Stream, one complete ITCH message per beat, left-aligned
//         (message byte 0 in m_tdata[7:0]), m_tkeep = message length,
//         m_tlast = 1 every beat. Feeds itch_decoder #(.DATA_W(DATA_W))
//         unchanged — every ITCH msg (<=50 B) fits in one 512-bit beat.
// Events: gap / heartbeat / EOS pulses, same contract as step 3a.
//
// Realignment core: a 2-beat (128-byte) byte window held as a flat vector.
// Each cycle does, concurrently:
//   * consume  = bytes removed from the front (a whole message 2+len, the
//                20-byte header, or 0 when the front isn't complete yet)
//   * accept   = one input beat appended at the tail, iff room remains after
//                this cycle's consume (s_tready reflects that room)
// Both happen the same cycle via barrel shifts, so the output sustains
// 1 msg/cycle even when a beat packs 2-3 messages — matching the input-FIFO
// sizing (76 msgs worst case, data/FINDINGS.md). The upstream elastic FIFO
// absorbs the cycles where the front isn't ready and no beat is accepted.
//
// Window invariant: an incomplete front implies vcnt <= 52 (< one beat), so
// there is always room to accept a beat and make progress; occupancy never
// exceeds 128 bytes.
`timescale 1ns/1ps
module mold_splitter #(
  parameter int DATA_W = 512
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

  output logic                ev_gap,
  output logic                ev_hb,
  output logic                ev_eos,
  output logic [63:0]         ev_seq,
  output logic [63:0]         ev_expected,

  output logic [31:0]         gap_total,
  output logic [31:0]         dup_cnt,
  output logic [31:0]         frame_err_cnt
);
  localparam int BEATB = DATA_W / 8;          // bytes per beat (64)
  localparam int WINB  = 2 * BEATB;           // window bytes (128)
  localparam int WINW  = WINB * 8;            // window bits (1024)
  localparam int HDR_B = 20;                  // session 10 + seq 8 + count 2
  localparam logic [15:0] EOS_COUNT = 16'hFFFF;

  typedef enum logic [1:0] { HDR, EMIT, DROP } state_t;
  state_t state;

  logic [WINW-1:0]      win;                  // byte 0 in bits [7:0]
  logic [$clog2(WINB):0] vcnt;                // valid bytes in window, 0..128
  logic [15:0]          msgs_left;
  logic [63:0]          expected_seq;

  // ---- big-endian field reads from the window ----
  function automatic logic [7:0]  wb(input int k);           return win[8*k +: 8]; endfunction
  function automatic logic [15:0] w_be16(input int off);     return {wb(off), wb(off+1)}; endfunction
  function automatic logic [63:0] w_be64(input int off);
    return {wb(off),   wb(off+1), wb(off+2), wb(off+3),
            wb(off+4), wb(off+5), wb(off+6), wb(off+7)};
  endfunction

  // valid bytes on the input beat (tkeep is contiguous from bit 0)
  function automatic int keep_len(input logic [BEATB-1:0] k);
    int c = 0;
    for (int i = 0; i < BEATB; i++) c += int'(k[i]);
    return c;
  endfunction

  // ---- combinational: front message length and readiness ----
  // NOTE: use a direct bit-select, not w_be16(0). A function that reads the
  // module signal `win` (not an argument) has no `win` in its sensitivity
  // when called from a continuous assign, so xsim never re-evaluates it and
  // msglen sticks at X. (Verilator inlines and happens to track it.) The
  // big-endian length prefix is win bytes 0..1: {byte0, byte1}.
  // msglen is REGISTERED, not read out of `win` combinationally. Reading it
  // from the window put win -> length -> readiness compare -> consume -> vcnt
  // arithmetic in one cycle, which became the critical path once the book was
  // pipelined. The next window value is computed anyway for the shift, so the
  // next front's length is registered from it and is always in step with `win`.
  logic [15:0] msglen;
  // mlen2 = msglen + 2 (message length including its 2-byte prefix), REGISTERED
  // in step with msglen. Retiming: consume and msg_ready both need msglen+2, and
  // that +2 adder used to sit at the head of the msglen -> consume -> vcnt chain
  // (the core-clock critical path once the book was pipelined, FINDINGS 6.1).
  // Precomputing it alongside msglen -- the +2 is computed from win_next, in
  // parallel with the msglen register, not in series with the vcnt arithmetic --
  // takes the adder out of that path. mlen2 is exactly msglen+2, so behaviour is
  // unchanged.
  logic [15:0] mlen2;
  logic        msg_ready;      // a full message sits at the window front
  logic        hdr_ready;      // a full MoldUDP64 header sits at the front
  assign msg_ready = (vcnt >= 2) && (32'(vcnt) >= 32'(mlen2));
  assign hdr_ready = (vcnt >= HDR_B);

  // consume: bytes removed from front this cycle
  logic [$clog2(WINB):0] consume;
  logic                  emit_now;            // drives m_tvalid
  always_comb begin
    consume  = '0;
    emit_now = 1'b0;
    unique case (state)
      HDR:  if (hdr_ready) consume = HDR_B[$clog2(WINB):0];
      EMIT: if (msg_ready) begin
              consume  = ($clog2(WINB)+1)'(mlen2);
              emit_now = 1'b1;
            end
      DROP: if (msg_ready) consume = ($clog2(WINB)+1)'(mlen2);
      default: ;
    endcase
  end

  // accept an input beat iff there is room once this cycle's consume happens
  logic [$clog2(WINB):0] beatlen;
  logic                  accept;
  assign beatlen  = ($clog2(WINB)+1)'(keep_len(s_tkeep));
  assign accept   = s_tvalid && ((32'(vcnt) - 32'(consume) + BEATB) <= WINB);
  assign s_tready = accept;

  // masked input beat, byte-extended to window width
  logic [WINW-1:0] beat_ext;
  always_comb begin
    beat_ext = '0;
    for (int i = 0; i < BEATB; i++)
      if (s_tkeep[i]) beat_ext[8*i +: 8] = s_tdata[8*i +: 8];
  end

  // ---- output (registered) ----
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      m_tvalid <= 1'b0;
      m_tlast  <= 1'b0;
      m_tkeep  <= '0;
      m_tdata  <= '0;
    end else begin
      m_tvalid <= emit_now;
      m_tlast  <= emit_now;
      if (emit_now) begin
        // drop the 2-byte length prefix, left-align the message body
        m_tdata <= win[16 +: DATA_W];
        m_tkeep <= (({{(BEATB-1){1'b0}}, 1'b1}) << msglen) - 1'b1;
      end else begin
        m_tkeep <= '0;
      end
    end
  end

  // ---- window update + control (registered) ----
  logic [WINW-1:0] win_shifted, win_next;
  assign win_shifted = win >> (8 * consume);
  assign win_next    = accept
                     ? (win_shifted | (beat_ext << (8 * (32'(vcnt) - 32'(consume)))))
                     : win_shifted;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state         <= HDR;
      win           <= '0;
      msglen        <= '0;
      mlen2         <= 16'd2;
      vcnt          <= '0;
      msgs_left     <= '0;
      expected_seq  <= 64'd1;
      ev_gap        <= 1'b0;
      ev_hb         <= 1'b0;
      ev_eos        <= 1'b0;
      ev_seq        <= '0;
      ev_expected   <= '0;
      gap_total     <= '0;
      dup_cnt       <= '0;
      frame_err_cnt <= '0;
    end else begin
      ev_gap <= 1'b0;
      ev_hb  <= 1'b0;
      ev_eos <= 1'b0;

      // window: shift out `consume` bytes, OR in an accepted beat at the tail
      win    <= win_next;
      msglen <= {win_next[7:0], win_next[15:8]};       // stays in step with `win`
      mlen2  <= {win_next[7:0], win_next[15:8]} + 16'd2;  // precomputed msglen+2
      vcnt   <= vcnt - consume + (accept ? beatlen : '0);

      // control FSM (mirrors dump_mold.py's receiver model)
      unique case (state)
        HDR: if (hdr_ready) begin
          automatic logic [63:0] seq   = w_be64(10);
          automatic logic [15:0] count = w_be16(18);
          ev_seq <= seq;
          if (count == EOS_COUNT) begin
            ev_eos <= 1'b1;
          end else begin
            if (seq > expected_seq) begin
              ev_gap      <= 1'b1;
              ev_expected <= expected_seq;
              gap_total   <= gap_total + 32'(seq - expected_seq);
            end
            if (count == 16'd0) begin
              ev_hb <= 1'b1;
              if (seq > expected_seq) expected_seq <= seq;
            end else if (seq < expected_seq) begin
              dup_cnt   <= dup_cnt + 1;
              msgs_left <= count;
              state     <= DROP;
            end else begin
              msgs_left    <= count;
              expected_seq <= seq + 64'(count);
              state        <= EMIT;
            end
          end
        end

        EMIT: if (msg_ready) begin
          if (msglen == 16'd0) begin
            frame_err_cnt <= frame_err_cnt + 1;
            state         <= HDR;              // give up on this packet
          end else if (msgs_left == 16'd1) begin
            state <= HDR;
          end else begin
            msgs_left <= msgs_left - 16'd1;
          end
        end

        DROP: if (msg_ready) begin
          if (msglen == 16'd0 || msgs_left == 16'd1) state <= HDR;
          else msgs_left <= msgs_left - 16'd1;
        end

        default: state <= HDR;
      endcase
    end
  end

endmodule
