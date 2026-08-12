// How long the venue takes to acknowledge an order, measured in hardware.
//
// WHY THIS EXISTS. tx_rto's two constants -- cfg_rto_cycles and
// cfg_rto_retries -- are guesses, and they are the only numbers in this design
// chosen without evidence. They cannot be chosen with evidence either, because
// the input they need is the distribution of venue acknowledgement latency and
// nothing has ever answered these orders except a Python generator. A timeout
// below the RTT resends orders the venue already has; one far above it gives
// back the reason for doing any of this in hardware.
//
// So this is the instrument, built before the thing it measures exists. The
// day a session faces a real counterparty, the number is already being taken.
//
// IT NEEDS NO NEW TAPS. It watches the same two signals tx_rto does, both
// already exported: tcp_tx's seq_num and tcp_rx's peer_ack. A send is seq_num
// advancing; an acknowledgement is peer_ack passing the value seq_num took.
// Nothing is threaded through the datapath and nothing is added to it.
//
// WHAT THE NUMBER IS, precisely, because a latency figure without its endpoints
// is decoration:
//
//   start  the cycle after tcp_tx commits the frame's sequence number (its
//          CALC state -- the frame has not reached the MAC yet)
//   stop   the cycle peer_ack, as tcp_rx presents it, covers that frame
//
// It is therefore KERNEL TO KERNEL, not wire to wire. It excludes the MAC,
// SerDes and framing in both directions -- about 300 ns the round trip,
// measured in step 8 -- and includes everything else: our transmit tail, the
// venue's whole round trip, and our receive path up to peer_ack moving. Add the
// MAC's share if you want a wire figure. The few cycles between CALC and the
// last beat leaving are inside the measurement and are ~10 ns against an RTT
// that will be microseconds; they are not worth a tap of their own.
//
// ONE MEASUREMENT AT A TIME, and that is a decision rather than a shortcut.
// Acknowledgements are CUMULATIVE: an ack covering the third frame also covers
// the first two, and says nothing about when the venue saw either. So the probe
// arms on a send only when idle and lets frames sent during a measurement pass
// unmeasured. With orders capped at four in flight, most sends are still
// measured; how many were not is st_samples against st_frame_cnt, which the
// host already reads.
//
// A RESEND POISONS THE SAMPLE. If the frame under measurement was retransmitted
// -- by tx_rto or by the host's button -- the ack that finally arrives may be
// answering either copy, and the difference is exactly the timeout being
// measured. Those are counted in st_lost rather than averaged in.
//
// NO VENUE, NO SAMPLES. On a bench with GT loopback there is nothing to
// acknowledge anything, peer_ack never moves, and this module reports
// st_samples = 0 forever. That is the correct output. It abandons a stuck
// measurement after CAP_BITS cycles so the counter cannot wrap and report a
// small number for an infinite wait.
`timescale 1ns/1ps
module ack_latency #(
  parameter int PAYLD_B  = 52,   // payload bytes per order frame (tcp_tx)
  // 2^28 core cycles is ~1.2 s at 220 MHz: longer than any acknowledgement
  // worth waiting for, short enough that the counter never approaches a wrap.
  parameter int CAP_BITS = 28
)(
  input  logic        clk,
  input  logic        rst_n,

  input  logic [31:0] seq_num,     // tcp_tx: next sequence number to send
  input  logic [31:0] peer_ack,    // tcp_rx: last ack the venue sent
  input  logic        cfg_load,    // session (re)load: seq_num JUMPS, not a send
  input  logic        i_resend,    // a retransmission was requested

  output logic [31:0] st_last,     // cycles, most recent completed measurement
  output logic [31:0] st_min,
  output logic [31:0] st_max,
  output logic [31:0] st_samples,  // completed measurements, for a mean with sum
  output logic [63:0] st_sum,      // total cycles over st_samples measurements
  output logic [31:0] st_lost      // abandoned: poisoned by a resend, or timed out
);
  localparam logic [31:0] CAP = (32'd1 << CAP_BITS) - 32'd1;

  // ---- a send is seq_num moving, except when software moved it ----
  // cfg_load writes cfg_init_seq into seq_num, which looks exactly like a send
  // one cycle later. The load is registered so the resulting change can be told
  // apart from the real thing.
  logic [31:0] seq_q;
  logic        load_q;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      seq_q  <= '0;
      load_q <= 1'b0;
    end else begin
      seq_q  <= seq_num;
      load_q <= cfg_load;
    end
  end
  wire sent = (seq_num != seq_q) && !load_q;

  // ---- has anything ever acknowledged anything ----
  // The same guard tx_rto documents, for the same reason. peer_ack comes out of
  // reset at zero, which is not a point in this session's sequence space, and a
  // signed compare against it would read as "already acknowledged" for half of
  // all initial sequence numbers. Until peer_ack MOVES there is no evidence a
  // counterparty exists, and nothing is measured.
  logic [31:0] ack_q;
  logic        ack_seen;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      ack_q    <= '0;
      ack_seen <= 1'b0;
    end else begin
      ack_q <= peer_ack;
      if (cfg_load)                ack_seen <= 1'b0;   // new session, new evidence
      else if (peer_ack != ack_q)  ack_seen <= 1'b1;
    end
  end

  // ---- the measurement ----
  logic        armed, tainted;
  logic [31:0] target, cnt;

  // Signed, so the comparison follows TCP's sequence space around the wrap: an
  // ack just past zero is still ahead of a target just below it, and an
  // unsigned compare would call that 4 GB short.
  wire signed [31:0] past_target = $signed(peer_ack) - $signed(target);
  wire               covered     = ack_seen && armed && (past_target >= 0);
  wire               timed_out   = armed && (cnt == CAP);

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      armed      <= 1'b0;
      tainted    <= 1'b0;
      target     <= '0;
      cnt        <= '0;
      st_last    <= '0;
      st_min     <= '0;
      st_max     <= '0;
      st_samples <= '0;
      st_sum     <= '0;
      st_lost    <= '0;
    end else if (cfg_load) begin
      // A reloaded session is a different sequence space; a measurement in
      // flight across it means nothing. The statistics are left alone -- they
      // are what the previous session measured, and zeroing them would lose it.
      armed   <= 1'b0;
      tainted <= 1'b0;
    end else begin
      if (armed) cnt <= cnt + 32'd1;
      if (armed && i_resend) tainted <= 1'b1;

      if (covered) begin
        armed <= 1'b0;
        if (tainted) begin
          st_lost <= st_lost + 32'd1;
        end else begin
          st_last    <= cnt;
          st_samples <= st_samples + 32'd1;
          st_sum     <= st_sum + 64'(cnt);
          if (st_samples == 0 || cnt < st_min) st_min <= cnt;
          if (cnt > st_max)                    st_max <= cnt;
        end
      end else if (timed_out) begin
        armed   <= 1'b0;
        st_lost <= st_lost + 32'd1;
      end

      // Arming happens after the above so a frame sent in the same cycle a
      // measurement completes starts the next one rather than being skipped.
      if (sent && (!armed || covered || timed_out)) begin
        armed   <= 1'b1;
        tainted <= i_resend;
        target  <= seq_num;      // seq_num already includes this frame's payload
        cnt     <= '0;
      end
    end
  end

`ifndef SYNTHESIS
  // The target must be exactly one frame ahead of where the session was, or the
  // assumption that a send is "seq_num moved by PAYLD_B" has stopped holding --
  // which would mean tcp_tx changed shape and this probe is measuring something
  // else. Simulation-only, like order_table's one-hot check.
  always @(posedge clk)
    if (rst_n && sent && !cfg_load && (seq_num - seq_q) != 32'(PAYLD_B))
      $fatal(1, "ack_latency: seq_num advanced by %0d, expected %0d -- a send is no longer one frame",
             seq_num - seq_q, PAYLD_B);
`endif

endmodule
