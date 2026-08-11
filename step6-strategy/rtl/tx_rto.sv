// Retransmission timeout — the card notices its own unacknowledged order and
// asks tx_replay_buf to send it again.
//
// WHAT WAS MISSING. tx_replay_buf has held the last sixteen assembled frames
// since it was wired in, and tcp_rx now tracks the acknowledgement number the
// venue sends back. Between them the card has everything needed to detect a lost
// order -- and nothing did. The resend was host-initiated, which sounded like a
// deliberate division of labour until the inbound path was finished and it became
// clear what it meant in practice: the venue's replies reach software through a
// capture buffer the host reads in batches, so "software decides when to resend"
// is "software decides some milliseconds later", by which time the order it would
// re-send is answering a market that has moved. The only place with timely
// knowledge of an unacknowledged order is the fabric.
//
// WHY A TIMEOUT AND NOT FAST RETRANSMIT. TCP's three-duplicate-ack rule needs the
// receiver to keep getting data past the hole, which is what makes the duplicates.
// This traffic is a handful of small frames with long gaps between them and at
// most cfg_max_inflight outstanding, so the venue usually has nothing to send a
// duplicate ack ABOUT. The signal fast retransmit relies on mostly does not exist
// here; a timeout is the detector this traffic pattern actually admits.
//
// WHY THIS IS SAFE TO DO IN HARDWARE, which is the part that matters. A resend is
// idempotent twice over: the replayed bytes carry the original TCP sequence
// number, so the venue's stack discards them if it already has that range, and
// they carry the original OUCH order token, which OUCH 4.2 says the venue ignores
// if it has seen it ("If you send an Enter Order Message with a previously used
// Order Token, the new order will be ignored"). A spurious retransmission
// therefore cannot double-fill and cannot open a hole in the stream. That is what
// makes this a detector rather than a protocol.
//
// AND WHY IT STAYS OFF THE HOT PATH. This module drives one pulse. It does not
// touch the live stream, and tx_replay_buf only ever emits a replay when the live
// path is idle, so a retransmission cannot delay a new order. It also does not go
// through the strategy, so a resend does not consume an in-flight slot -- the
// order it re-sends already did.
//
// ARMING, and the trap it avoids. peer_ack resets to zero and only updates when
// an inbound segment with the ACK flag arrives. Comparing a zero peer_ack against
// a sequence number that started at cfg_init_seq would make every frame look
// unacknowledged from the first cycle, and a design with no venue at all -- every
// simulation in this repository, and the card on a bench -- would sit there
// retransmitting into the void. So the timer only arms once peer_ack has MOVED at
// least once, which is the hardware's evidence that something is listening.
`timescale 1ns/1ps
module tx_rto #(
  parameter int SLOTS   = 16,        // tx_replay_buf's ring depth
  parameter int PAYLD_B = 52         // payload bytes per order frame (tcp_tx)
)(
  input  logic        clk,
  input  logic        rst_n,

  // configuration. cfg_en defaults to 0 everywhere: the datapath behaves exactly
  // as it did before this module existed until a host turns it on.
  input  logic        cfg_en,
  input  logic [31:0] cfg_rto_cycles,   // idle core cycles before a resend
  input  logic [3:0]  cfg_max_retries,  // attempts per unacknowledged frame

  // the two facts a loss detector needs, both already exported
  input  logic [31:0] seq_num,          // tcp_tx: next sequence number to send
  input  logic [31:0] peer_ack,         // tcp_rx: last ack the venue sent

  // to tx_replay_buf
  output logic        o_resend_req,
  output logic [$clog2(SLOTS)-1:0] o_resend_age,

  output logic [31:0] st_fired,         // resends this module asked for
  output logic [31:0] st_gaveup         // frames abandoned at cfg_max_retries
);
  localparam int AW = $clog2(SLOTS);

  // Unacknowledged bytes, compared as SIGNED so the sequence space wraps the way
  // TCP's does: a peer_ack just past the wrap is still ahead of a seq_num just
  // before it, and an unsigned compare would read that as 4 GB outstanding.
  wire signed [31:0] unacked = $signed(seq_num) - $signed(peer_ack);
  wire               outstanding = (unacked > 0);

  // How many frames that is, clamped to the ring. A divide would be exact and
  // pointless: every order frame carries exactly PAYLD_B payload bytes (the
  // SoupBinTCP + OUCH enter order is fixed length) and the risk gate caps orders
  // in flight at SLOTS, so counting how many constant multiples fit answers it
  // without a divider.
  logic [AW:0] nframes;
  always_comb begin
    nframes = '0;
    for (int k = 0; k < SLOTS; k++)
      if (unacked > $signed(32'(k * PAYLD_B))) nframes = (AW+1)'(k + 1);
  end
  // age 0 is the most recent frame stored, so the OLDEST unacknowledged one --
  // the one a TCP sender retransmits first -- is nframes-1 back.
  wire [AW-1:0] oldest_age = (nframes == 0) ? '0 : AW'(nframes - 1);

  logic [31:0] prev_ack;
  logic        armed, gave_up;
  logic [31:0] timer;
  logic [3:0]  retries;

  // "the acknowledgement moved" is computed INSIDE the clocked block, from the
  // same read of peer_ack that updates prev_ack. As a continuous assign it was a
  // scheduling hazard rather than a description of the hardware: prev_ack <=
  // peer_ack takes the value at the edge, while a wire feeding the same block may
  // still carry the pre-edge comparison, so the flop advanced and the edge that
  // advanced it was never seen. Harmless when the source is a flop in the same
  // domain -- which it is, in the design -- and a silent no-arm the moment
  // anything drives it otherwise, which is exactly what its own testbench did.
  always_ff @(posedge clk) begin
    automatic logic ack_moved = (peer_ack != prev_ack);
    if (!rst_n) begin
      prev_ack     <= '0;
      armed        <= 1'b0;
      gave_up      <= 1'b0;
      timer        <= '0;
      retries      <= '0;
      o_resend_req <= 1'b0;
      o_resend_age <= '0;
      st_fired     <= '0;
      st_gaveup    <= '0;
    end else begin
      o_resend_req <= 1'b0;
      prev_ack     <= peer_ack;

      if (ack_moved) begin
        // Progress. Whatever it acknowledged is no longer our problem, and the
        // next frame gets a full timeout of its own rather than inheriting the
        // remains of this one's.
        armed   <= 1'b1;
        timer   <= '0;
        retries <= '0;
        gave_up <= 1'b0;
      end else if (!cfg_en || !armed || !outstanding) begin
        timer   <= '0;
        retries <= '0;
        gave_up <= 1'b0;
      end else if (timer < cfg_rto_cycles) begin
        timer   <= timer + 1'b1;
      end else begin
        // Timed out with data outstanding.
        timer <= '0;
        if (retries < cfg_max_retries) begin
          o_resend_req <= 1'b1;
          o_resend_age <= oldest_age;
          retries      <= retries + 1'b1;
          st_fired     <= st_fired + 1'b1;
        end else if (!gave_up) begin
          // Stop rather than hammer. A venue that has not acknowledged after
          // cfg_max_retries is not dropping packets, it is gone, and the useful
          // behaviour is a counter a host can see rather than a frame every
          // timeout forever. A latch rather than a retry comparison, so a
          // cfg_max_retries of 15 cannot wrap the counter back into firing.
          gave_up   <= 1'b1;
          st_gaveup <= st_gaveup + 1'b1;
        end
      end
    end
  end

endmodule
