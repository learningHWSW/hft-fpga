// Loaded-latency probe: tick-to-trade while the pipeline is BUSY.
//
// WHY A SECOND PROBE. lat_probe measures the unloaded path, and can only do so
// because it refuses any sample whose frame did not arrive into a provably empty
// pipeline. That guard is what makes its 220 ns trustworthy, and it is also
// exactly why it cannot answer data/FINDINGS.md 7.2: a burst has many frames in
// flight by definition, so every sample would be excluded. 7.2 predicts the
// queue, not the pipe, dominates there -- 10.04 us iterative, 0.95 us with the
// II=1 table -- and those numbers are model output, never measured.
//
// WHY NO TAG HAD TO BE THREADED. The obvious implementation is a timestamp
// carried alongside each message through splitter, decoder, order table, ladder,
// strategy, builder and framer -- eight verified modules, all of which would need
// their interfaces widened and their goldens re-confirmed. That work is
// unnecessary, because the datapath ALREADY threads a unique per-message field
// end to end: the ITCH timestamp. itch_msg_t.timestamp survives into
// order_table.o_ts, into price_ladder.o_ts, into strategy.o_ts, and t2t_top
// exposes it as ord_ts -- "the exchange timestamp of the message that caused this
// order". So the message's identity is already at both ends of the path; all that
// is missing is when it arrived.
//
// This block supplies that. It records, for each decoded message, the local cycle
// at which it appeared, keyed by its ITCH timestamp; when an order fires citing
// that timestamp, the difference is the time that message spent in the machine.
// No datapath change at all -- only two observation taps.
//
// WHAT IT MEASURES, precisely: decoder output to order emit. That interval
// contains the message FIFO, the order table, the delta FIFO, the ladder and the
// strategy -- i.e. every queue on the path, which is where 7.2's burst tail
// lives. It excludes the fixed front end (RX, CDC, splitter, decode), which does
// not queue and is already inside lat_probe's unloaded figure. Wire-to-order
// under load is therefore this number plus that fixed front end, and the two
// probes together bracket it.
//
// Measured in CORE clock cycles, because the core clock is the one the queues
// drain at.
`timescale 1ns/1ps
module lat_loaded #(
  parameter int TSW     = 48,       // ITCH timestamp width
  parameter int IDXW    = 10,       // 1024 correlation slots
  parameter int NBUCKET = 24        // log2 buckets: covers 1 .. 8M cycles
)(
  input  logic             clk,
  input  logic             rst_n,
  input  logic             clear,

  // ---- tap 1: a message leaves the decoder (queueing starts here) ----
  input  logic             msg_valid,
  input  logic [TSW-1:0]   msg_ts,

  // ---- tap 2: an order leaves the strategy, citing its causing message ----
  input  logic             ord_valid,
  input  logic [TSW-1:0]   ord_ts,

  // ---- results, in core clock cycles ----
  output logic [31:0]      lat_min,
  output logic [31:0]      lat_max,
  output logic [31:0]      lat_last,
  output logic [31:0]      lat_sum_lo,
  output logic [31:0]      lat_sum_hi,
  output logic [31:0]      samples,
  output logic [31:0]      misses,     // order cited a message we no longer hold
  output logic [31:0]      hist [NBUCKET]
);
  localparam int TAGW = TSW - IDXW;
  localparam int EW   = 1 + TAGW + 32;      // valid ++ tag ++ arrival

  // ---- local time ----
  logic [31:0] now;
  always_ff @(posedge clk) begin
    if (!rst_n) now <= '0;
    else        now <= now + 1'b1;
  end

  // ---- correlation slot index ----
  // A fold, not the raw low bits. ITCH timestamps are nanoseconds since
  // midnight and consecutive messages are hundreds to thousands of nanoseconds
  // apart, so raw ts[IDXW-1:0] clusters exactly the way FINDINGS 4 found raw
  // order_refs clustering in the order table ("the filter table needs a mixing
  // hash, not raw" -- 24142 overflows raw vs 132 mixed). The same lesson, the
  // same one-XOR fix.
  function automatic logic [IDXW-1:0] slot(input logic [TSW-1:0] t);
    return t[IDXW-1:0] ^ t[2*IDXW-1:IDXW] ^ t[3*IDXW-1:2*IDXW];
  endfunction

  (* ram_style = "block" *) logic [EW-1:0] tbl [1<<IDXW];

  // ---- write port: every decoded message claims its slot ----
  // An older message losing its slot to a newer one is fine and expected: the
  // order that would have cited it has either already fired or is never coming.
  // It shows up as a miss, counted, not as a wrong latency.
  always_ff @(posedge clk) begin
    if (msg_valid) tbl[slot(msg_ts)] <= {1'b1, msg_ts[TSW-1:IDXW], now};
  end

  // ---- read port: ONE address, one read expression, as eth_capture learned ----
  logic [IDXW-1:0] rd_idx;
  logic [EW-1:0]   rd_ent;
  always_ff @(posedge clk) rd_ent <= tbl[rd_idx];

  logic           q_valid;
  logic [TSW-1:0] q_ts;

  // accumulate pipeline (see the staging note below)
  logic        s1_valid, s2_valid;
  logic [31:0] s1_d, s2_d;
  int unsigned s2_b;

  always_comb rd_idx = slot(ord_ts);

  function automatic int unsigned bucket_of(input logic [31:0] d);
    int unsigned b;
    b = 0;
    for (int i = 31; i >= 1; i--) if (d[i]) begin b = i; break; end
    return (b >= NBUCKET) ? (NBUCKET - 1) : b;
  endfunction

  always_ff @(posedge clk) begin
    if (!rst_n || clear) begin
      q_valid <= 1'b0; q_ts <= '0;
      s1_valid <= 1'b0; s2_valid <= 1'b0; s1_d <= '0; s2_d <= '0; s2_b <= 0;
      lat_min <= 32'hFFFF_FFFF; lat_max <= '0; lat_last <= '0;
      lat_sum_lo <= '0; lat_sum_hi <= '0;
      samples <= '0; misses <= '0;
      for (int i = 0; i < NBUCKET; i++) hist[i] <= '0;
    end else begin
      // stage 1: an order fires -- the table read is already in flight
      q_valid <= ord_valid;
      q_ts    <= ord_ts;

      // stage 2: the slot has been read; does it still hold that message?
      // The accumulate is pipelined for the same measured reason lat_probe's is:
      // done in one cycle the path runs BRAM output -> compare -> subtract ->
      // 31-iteration leading-one search -> indexed counter increment, and it
      // showed up as
      //   Source: u_lat_loaded/tbl_reg_bram_0/CLKBWRCLK
      //   Destination: u_lat_loaded/hist_reg[18][17]/D    Slack -0.013 ns
      // A probe must not be what caps the frequency of the datapath it watches.
      s1_valid <= 1'b0;
      s2_valid <= 1'b0;

      if (q_valid) begin
        if (rd_ent[EW-1] && (rd_ent[EW-2 -: TAGW] == q_ts[TSW-1:IDXW])) begin
          s1_d     <= now - rd_ent[31:0];      // stage 1: subtract only
          s1_valid <= 1'b1;
        end else begin
          misses <= misses + 1'b1;
        end
      end

      if (s1_valid) begin                      // stage 2: classify
        s2_d     <= s1_d;
        s2_b     <= bucket_of(s1_d);
        s2_valid <= 1'b1;
      end

      if (s2_valid) begin                      // stage 3: accumulate
        lat_last <= s2_d;
        if (s2_d < lat_min) lat_min <= s2_d;
        if (s2_d > lat_max) lat_max <= s2_d;
        {lat_sum_hi, lat_sum_lo} <= {lat_sum_hi, lat_sum_lo} + 64'(s2_d);
        samples   <= samples + 1'b1;
        hist[s2_b] <= hist[s2_b] + 1'b1;
      end
    end
  end

endmodule
