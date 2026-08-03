// Latency probe: measures tick-to-trade on the card, in hardware, per order.
//
// WHY THIS EXISTS. data/FINDINGS.md 7.1 gives the unloaded tick-to-trade as
// ~135 ns (imbalance) / ~90 ns (sweep), but that number is SUMMED from per-stage
// FSM state counts with a stated error bar of +/-1 cycle per stage. It is the one
// headline number in a project that otherwise measures everything against a
// golden. This block measures it instead.
//
// THE ATTRIBUTION PROBLEM, and why it is solvable here. tb_t2t.sv tried this and
// documented why it gave up on the front half: frames keep arriving while an
// order is in flight, so a "time of the last frame" stamp gets overwritten by a
// LATER frame than the one that caused the order, and the result is a
// meaningless lower bound (it reported min=1). Attributing an order to its
// causing frame in general needs a tag threaded through every stage of the
// datapath -- splitter, decoder, order table, ladder, strategy, builder, framer.
//
// This block does not need that, because on the card the feed comes from
// eth_replay and WE SET THE INTER-FRAME GAP. If the gap exceeds the pipeline's
// depth, only one frame is ever in flight, and "the most recent frame" IS the
// causing frame. No datapath change, no tag, no risk to verified RTL.
//
// That assumption is not asserted, it is CHECKED. A sample counts only if the
// stamped frame was preceded by at least cfg_quiet idle RX cycles -- a genuinely
// empty pipeline -- and samples that fail the test are excluded and counted in
// `excluded`, so a measurement taken under the wrong conditions is visible as a
// number rather than quietly wrong. If `excluded` is non-zero the gap was too
// small and the run should be repeated, not reinterpreted.
//
// WHAT IT DOES NOT MEASURE. Latency under load -- FINDINGS 7.2's burst tail,
// where the queue dominates and worst-case tick-to-trade is microseconds rather
// than nanoseconds. That genuinely does need the threaded tag, because during a
// burst there are many frames in flight by definition. This block measures the
// unloaded number, which is the one currently estimated.
//
// Time base is the RX clock, so a tick is one cycle of whatever drives the wire
// side: ap_clk in the Phase A harness, the CMAC's 322.265625 MHz in Phase B.
// The host converts to nanoseconds; the RTL deliberately does not, because a
// divider here would buy nothing and the host knows the frequency it asked for.
`timescale 1ns/1ps
module lat_probe #(
  parameter int DATA_W  = 512,
  parameter int NBUCKET = 16          // histogram buckets, powers of two
)(
  input  logic                clk,
  input  logic                rst_n,
  input  logic                clear,          // one-cycle pulse: zero everything

  // minimum idle RX cycles before a frame for its sample to count. Set from the
  // host to something comfortably above the pipeline depth.
  input  logic [15:0]         cfg_quiet,

  // ---- RX side: the frame going in ----
  input  logic [DATA_W-1:0]   rx_tdata,       // first beat carries the headers
  input  logic                rx_tvalid,
  input  logic                rx_tlast,

  // ---- TX side: the frame coming out ----
  input  logic [DATA_W-1:0]   tx_tdata,       // first beat carries the headers
  input  logic                tx_tvalid,
  input  logic                tx_tlast,
  input  logic                tx_tready,

  // ---- results ----
  output logic [31:0]         lat_min,
  output logic [31:0]         lat_max,
  output logic [31:0]         lat_last,
  output logic [31:0]         lat_sum_lo,     // sum and count give the mean
  output logic [31:0]         lat_sum_hi,
  output logic [31:0]         samples,
  output logic [31:0]         excluded,       // pipeline was not empty: not counted
  output logic [31:0]         orphans,        // order with no stamp at all
  output logic [31:0]         hist [NBUCKET]  // log2 buckets of the sample
);
  // ================= time base =================
  logic [31:0] ts;
  always_ff @(posedge clk) begin
    if (!rst_n) ts <= '0;
    else        ts <= ts + 1'b1;      // free-running; wraps, and deltas are small
  end

  // ================= RX framing =================
  // A frame's arrival is its FIRST beat, which is also where the MAC would put
  // the first bit on the wire. Tracking in_frame is what distinguishes the start
  // of a frame from every subsequent beat of it.
  logic        rx_in_frame;
  logic [15:0] idle_cnt;              // consecutive cycles with no RX activity
  wire         rx_sof = rx_tvalid && !rx_in_frame;

  // ONLY THE FEED STARTS A MEASUREMENT. In Phase A the RX stream carries nothing
  // but feed frames, so this test is always true and costs nothing. In Phase B
  // the GT is in near-end loopback, which means our own order frames come back
  // in on RX a few hundred nanoseconds after they left -- and an order frame
  // arriving on RX would re-stamp with stamp_ok low (it lands in a busy pipe),
  // so the SECOND order caused by a feed frame would be excluded rather than
  // measured. Restricting the stamp to IPv4/UDP keeps the returning TCP orders
  // from destroying the samples they are themselves evidence of.
  //
  // idle_cnt is deliberately NOT filtered the same way: a returning order frame
  // really does occupy the RX path, so it must break the quiet window. Only the
  // decision of WHAT to stamp is narrowed, never the check on whether the
  // pipeline was empty.
  wire         rx_is_feed = (rx_tdata[8*12 +: 8] == 8'h08) &&    // IPv4
                            (rx_tdata[8*13 +: 8] == 8'h00) &&
                            (rx_tdata[8*23 +: 8] == 8'd17);      // UDP

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      rx_in_frame <= 1'b0;
      idle_cnt    <= '0;
    end else begin
      if (rx_tvalid) begin
        rx_in_frame <= !rx_tlast;
        idle_cnt    <= '0;
      end else begin
        if (idle_cnt != 16'hFFFF) idle_cnt <= idle_cnt + 1'b1;
      end
    end
  end

  // ================= stamp =================
  // The stamp is NOT consumed by the first order it explains. One MoldUDP64
  // frame carries many ITCH messages, so a single frame legitimately produces
  // several orders, and each of them is a real wire-to-order event measured from
  // that frame's arrival. Clearing the stamp on first use counted the second and
  // later orders as orphans and threw away half the samples.
  logic [31:0] stamp;
  logic        have_stamp;            // a frame has been stamped at all
  logic        stamp_ok;              // ...and it arrived into a provably empty pipe

  // ================= TX side =================
  // The TX port carries order frames, IGMP reports and ARP replies (axis_tx_arb
  // merges them), and only the order frame is a tick-to-trade event. IPv4
  // protocol 6 at byte 23 selects it -- the same test tb_t2t_axil_full.sv and
  // scripts/pack_eth.py use, so all three agree on what an order frame is.
  logic        tx_in_frame;
  wire         tx_sof     = tx_tvalid && tx_tready && !tx_in_frame;
  wire         tx_is_ord  = (tx_tdata[8*23 +: 8] == 8'd6) &&
                            !((tx_tdata[8*12 +: 8] == 8'h08) &&
                              (tx_tdata[8*13 +: 8] == 8'h06));   // not ARP

  always_ff @(posedge clk) begin
    if (!rst_n) tx_in_frame <= 1'b0;
    else if (tx_tvalid && tx_tready) tx_in_frame <= !tx_tlast;
  end

  // bucket index: floor(log2(delta)), saturating at the top bucket
  function automatic int unsigned bucket_of(input logic [31:0] d);
    int unsigned b;
    b = 0;
    for (int i = 31; i >= 1; i--)
      if (d[i]) begin b = i; break; end
    return (b >= NBUCKET) ? (NBUCKET - 1) : b;
  endfunction

  // resolve pipeline registers (see the staging note in the always_ff below)
  logic        p1_valid, p2_valid;
  logic [31:0] p1_d, p2_d;
  int unsigned p2_b;

  always_ff @(posedge clk) begin
    if (!rst_n || clear) begin
      stamp    <= '0; have_stamp <= 1'b0; stamp_ok <= 1'b0;
      p1_valid <= 1'b0; p2_valid <= 1'b0; p1_d <= '0; p2_d <= '0; p2_b <= 0;
      lat_min  <= 32'hFFFF_FFFF;
      lat_max  <= '0; lat_last <= '0;
      lat_sum_lo <= '0; lat_sum_hi <= '0;
      samples  <= '0; excluded <= '0; orphans <= '0;
      for (int i = 0; i < NBUCKET; i++) hist[i] <= '0;
    end else begin
      // ---- a frame arrives: stamp it, and record whether the pipe was empty ----
      if (rx_sof && rx_is_feed) begin
        stamp      <= ts;
        have_stamp <= 1'b1;
        // The quiet window is the whole guarantee: with this many idle cycles
        // behind it, nothing from an earlier frame can still be in the pipe, so
        // an order appearing next must belong to THIS frame.
        stamp_ok <= (idle_cnt >= cfg_quiet);
      end

      // ---- an order leaves: resolve, over three pipeline stages ----
      // Splitting this was a timing fix, and a measured one. Done in a single
      // cycle -- subtract, then a 31-iteration leading-one search, then an
      // indexed increment of a 16-entry counter array -- it became the critical
      // path of the whole design at 300 MHz:
      //   Source: u_lat/stamp_reg[8]/C  Destination: u_lat/hist_reg[2][12]/D
      //   Slack (VIOLATED) -0.089 ns, and 9 more just like it
      // Every violated path in that build was in this block; the datapath itself
      // closed at 220 MHz with none. Instrumentation has no business setting the
      // Fmax of the thing it measures, and it costs nothing to pipeline: these
      // are statistics counters read over AXI-Lite long after the fact, so
      // arriving two cycles later is invisible. The measured VALUE is unchanged,
      // because the subtraction still happens at resolve time.
      p1_valid <= 1'b0;
      p2_valid <= 1'b0;

      if (tx_sof && tx_is_ord) begin
        if (!have_stamp) begin
          orphans <= orphans + 1'b1;         // an order before any frame arrived
        end else if (!stamp_ok) begin
          excluded <= excluded + 1'b1;       // gap too small: refuse to guess
        end else begin
          p1_d     <= ts - stamp;            // stage 1: the subtraction only
          p1_valid <= 1'b1;
          // stamp deliberately left standing: further orders from this same
          // frame are equally real wire-to-order events
        end
      end

      if (p1_valid) begin                    // stage 2: classify
        p2_d     <= p1_d;
        p2_b     <= bucket_of(p1_d);
        p2_valid <= 1'b1;
      end

      if (p2_valid) begin                    // stage 3: accumulate
        lat_last <= p2_d;
        if (p2_d < lat_min) lat_min <= p2_d;
        if (p2_d > lat_max) lat_max <= p2_d;
        {lat_sum_hi, lat_sum_lo} <= {lat_sum_hi, lat_sum_lo} + 64'(p2_d);
        samples   <= samples + 1'b1;
        hist[p2_b] <= hist[p2_b] + 1'b1;
      end
    end
  end

endmodule
