// Transmit replay buffer — keep the last N order frames so the host can ask for
// one to be re-sent.
//
// WHY THIS IS SMALL, which is not obvious until you read the OUCH spec. The
// transmit path is fire-and-forget, and the instinct is that adding retransmission
// means a dedup protocol, an acknowledgement state machine and a negotiation with
// the venue. OUCH 4.2 removes all of it:
//
//   "all host-bound messages are designed so that they can be benignly resent for
//    robust recovery from connection and application failures"
//
//   "If you send an Enter Order Message with a previously used Order Token, the
//    new order will be ignored."
//
// So a resend cannot double-fill: the venue discards a duplicate token. There is
// nothing to negotiate and no acknowledgement to track. What is left is a ring of
// the frames already sent, and a way to push one back out.
//
// THE ONE THING THAT WOULD BREAK IT, and the reason this stores bytes rather than
// intent: ouch_builder mints the Order Token from cfg_token_prefix plus an
// incrementing counter, and tcp_tx assigns a TCP sequence number per frame.
// Re-deriving a frame from the original order would therefore produce a NEW token
// and a NEW sequence number — a genuinely different order, which is exactly the
// double-fill the idempotence above was supposed to prevent, and a TCP stream with
// a hole in it. Replaying the ASSEMBLED BYTES is what makes the resend a resend.
//
// LATENCY: none added. The live frame passes straight through; the write into the
// ring happens in parallel on the same beats. The replay path only ever drives the
// output when the live path is idle, so a retransmission can never delay a new
// order — the hot path keeps its fire-and-forget timing exactly.
//
// DEPTH: the risk gate already refuses to have more than cfg_max_inflight orders
// outstanding, so that is the most that can ever need re-sending. SLOTS defaults
// to 16 to match, and a frame is 2 beats at 512 bits, so the whole buffer is 2 KB.
`timescale 1ns/1ps
module tx_replay_buf #(
  parameter int DATA_W = 512,
  parameter int SLOTS  = 16,       // >= cfg_max_inflight
  parameter int BEATS  = 2         // max beats per order frame
)(
  input  logic clk,
  input  logic rst_n,

  // live frame in (from tcp_tx)
  input  logic [DATA_W-1:0]   s_tdata,
  input  logic [DATA_W/8-1:0] s_tkeep,
  input  logic                s_tvalid,
  input  logic                s_tlast,
  output logic                s_tready,

  // frame out (to the TX clock crossing)
  output logic [DATA_W-1:0]   m_tdata,
  output logic [DATA_W/8-1:0] m_tkeep,
  output logic                m_tvalid,
  output logic                m_tlast,
  input  logic                m_tready,

  // host control: pulse req with a slot age (0 = most recent frame stored)
  input  logic                resend_req,
  input  logic [$clog2(SLOTS)-1:0] resend_age,

  output logic [31:0]         stored_cnt,    // frames written to the ring
  output logic [31:0]         resent_cnt,    // frames pushed back out
  output logic [31:0]         resend_drop    // requests refused (busy or empty)
);
  localparam int SLOTW = $clog2(SLOTS);
  localparam int BEATW = (BEATS > 1) ? $clog2(BEATS) : 1;

  typedef struct packed {
    logic [DATA_W-1:0]   data;
    logic [DATA_W/8-1:0] keep;
    logic                last;
  } beat_t;

  beat_t ring [SLOTS*BEATS];
  logic [BEATW:0] len [SLOTS];        // beats actually stored, per slot

  logic [SLOTW-1:0] wr_slot;
  logic [BEATW:0]   wr_beat;
  logic             wrapped;          // ring has been filled at least once

  // ---- live path: straight through, and captured on the way ----
  // s_tready is the downstream's, unmodified while idle, so the live frame sees
  // no backpressure this module invented. During a replay the live path is held
  // off for at most BEATS cycles.
  logic             rp_busy;
  assign s_tready = m_tready && !rp_busy;

  wire live_beat = s_tvalid && s_tready;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      wr_slot <= '0; wr_beat <= '0; wrapped <= 1'b0;
      stored_cnt <= '0;
    end else if (live_beat) begin
      // Compared as integers on purpose. BEATW'(BEATS) truncates -- BEATW is
      // $clog2(BEATS), so casting BEATS itself to that width gives 0 and the
      // write never happens. Cost an hour of "the replay comes back wrong".
      if (wr_beat < BEATS)
        ring[wr_slot*BEATS + wr_beat] <= '{data:s_tdata, keep:s_tkeep, last:s_tlast};
      if (s_tlast) begin
        len[wr_slot] <= wr_beat + 1'b1;
        wr_beat      <= '0;
        wr_slot      <= wr_slot + 1'b1;
        if (wr_slot == SLOTW'(SLOTS-1)) wrapped <= 1'b1;
        stored_cnt   <= stored_cnt + 1'b1;
      end else begin
        wr_beat <= wr_beat + 1'b1;
      end
    end
  end

  // ---- replay path ----
  // A request is accepted only when the live path is idle and the addressed slot
  // actually holds a frame. Refusals are counted rather than queued: a dropped
  // retransmission request is recoverable (ask again), a retransmission that
  // collides with a live order is not.
  logic [SLOTW-1:0] rp_slot;
  logic [BEATW:0]   rp_beat;
  logic [BEATW:0]   rp_len;

  wire [SLOTW-1:0] req_slot = wr_slot - 1'b1 - resend_age;
  wire             req_ok   = (stored_cnt != 0) &&
                              (wrapped || (SLOTW'(resend_age) < wr_slot)) &&
                              (len[req_slot] != 0);

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      rp_busy <= 1'b0; rp_slot <= '0; rp_beat <= '0; rp_len <= '0;
      resent_cnt <= '0; resend_drop <= '0;
    end else begin
      if (resend_req) begin
        if (!rp_busy && !s_tvalid && req_ok) begin
          rp_busy <= 1'b1;
          rp_slot <= req_slot;
          rp_len  <= len[req_slot];
          rp_beat <= '0;
        end else begin
          resend_drop <= resend_drop + 1'b1;
        end
      end
      if (rp_busy && m_tready) begin
        if (rp_beat + 1'b1 >= rp_len) begin
          rp_busy    <= 1'b0;
          resent_cnt <= resent_cnt + 1'b1;
        end
        rp_beat <= rp_beat + 1'b1;
      end
    end
  end

  // ---- output mux: live always wins ----
  wire beat_t rp_q = ring[rp_slot*BEATS + rp_beat];

  always_comb begin
    if (rp_busy) begin
      m_tdata  = rp_q.data;
      m_tkeep  = rp_q.keep;
      m_tlast  = (rp_beat + 1'b1 >= rp_len);
      m_tvalid = 1'b1;
    end else begin
      m_tdata  = s_tdata;
      m_tkeep  = s_tkeep;
      m_tlast  = s_tlast;
      m_tvalid = s_tvalid;
    end
  end
endmodule
