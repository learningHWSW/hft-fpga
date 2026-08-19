// Unit test for axis_sf_fifo -- the store-and-forward property itself, not the
// datapath that happens to use it.
//
// WHY SEPARATELY. tb_t2t_kernel.sv exercises this FIFO, but only with the traffic
// the synthetic feed happens to produce: eight frames, arriving slowly, with a
// reader that is almost never busy. Every interesting failure mode of a
// dual-clock store-and-forward FIFO lives outside that: a nearly-full array, a
// reader faster than the writer, a writer faster than the reader, backpressure
// arriving mid-frame, and frames whose length is 1 beat or the full maximum. A
// bug in any of those would show up in the kernel testbench as a corrupted order
// frame with no indication of where it came from -- and two of them were in the
// first version of this module.
//
// THE PROPERTY THAT MATTERS. A CMAC transmit port that is starved mid-frame does
// not bubble, it underruns, and the frame goes onto the wire corrupted. The whole
// point of this FIFO is that a frame becomes readable only once it is entirely
// resident. So the central check here is not "the bytes came out right" -- it is
// that the FIRST beat of a frame never leaves before the LAST beat of that frame
// was written. That is checked in simulation time, per frame, for every frame.
//
// The two failures this test was written after, both of which it catches:
//   * a commit POINTER crossed as Gray code. Gray is only safe for a value that
//     changes by one; a commit pointer jumps by a whole frame, and a synchroniser
//     can then latch an address that was never written.
//   * a frame count that advanced when the last beat reached the output PORT
//     rather than when it was FETCHED. The payload memory is synchronous and the
//     port adds a second slot, so the reader ran two beats past the committed
//     region and emitted whatever the array held.
//
// +wper=<ps> +rper=<ps> set the two clock half-periods, so the same test runs
// with the reader faster than the writer and the other way round -- which is the
// difference between the feed path (ap_clk -> 322 MHz, reader faster) and a
// hypothetical slower sink.
//
// FOUR CONFIGURATIONS, set with xelab -generic_top, because the module now has
// two switches and the interesting question is what each one gives up:
//
//   SAME_CLOCK  bypasses the synchronisers when both ends are one clock. It must
//               change nothing a check here can see EXCEPT latency -- the
//               store-and-forward guarantee is untouched, so "no frame released
//               early" is still a failure.
//   CUT_THROUGH releases a frame before its last beat is written. Early release
//               is then the POINT, so it stops being a failure and becomes a
//               requirement: a run with zero early releases means the generic
//               did not apply, or CT_MIN came out at the frame length, and the
//               test would otherwise pass while proving nothing.
//
// What never stops being a failure, in any configuration, is tvalid dropping
// mid-frame while the sink is asking. That is the CMAC underrun, and it is the
// only thing store-and-forward was ever buying.
//
// The writer's behaviour has to match the W_GAP_MAX it claims. In cut-through
// runs it therefore does not stall inside a frame, and it paces itself one frame
// at a time so s_tready cannot stall it either -- a writer that backpressures
// mid-frame is not a W_GAP_MAX=1 writer, and testing cut-through against a
// source that breaks its own contract would only prove the contract matters.
`timescale 1ns/1ps
module tb_axis_sf_fifo #(
  parameter bit SAME_CLOCK  = 0,
  parameter bit CUT_THROUGH = 0,
  parameter int W_GAP_MAX   = 1
);
  localparam int DATA_W = 512;
  localparam int KEEP_W = DATA_W / 8;
  localparam int DEPTH  = 64;          // small on purpose: make it fill
  localparam int NFRAME = 300;
  localparam int MAXLEN = 24;          // a 1518-byte Ethernet frame is 24 beats

  real wper = 1.6665;                  // ap_clk, 300 MHz
  real rper = 1.5515;                  // gt_txusrclk2, 322.265625 MHz

  logic w_clk = 0, r_clk_gen = 0;
  logic w_rst_n = 0, r_rst_n = 0;

  initial forever #(wper) w_clk = ~w_clk;
  initial forever #(rper) r_clk_gen = ~r_clk_gen;

  // one net, not two nets that happen to agree: SAME_CLOCK is a claim about the
  // clock, and the DUT deletes real synchronisers on the strength of it
  wire r_clk = SAME_CLOCK ? w_clk : r_clk_gen;

  // no mid-frame stalls when the DUT has been told the source cannot stall
  localparam bit WSTALL = !CUT_THROUGH;
  localparam bit PACE   = CUT_THROUGH;

  logic [DATA_W-1:0] s_tdata = '0;
  logic [KEEP_W-1:0] s_tkeep = '0;
  logic              s_tvalid = 0, s_tlast = 0, s_tready;
  logic [31:0]       pkts_in, hwm, starves;

  logic [DATA_W-1:0] m_tdata;
  logic [KEEP_W-1:0] m_tkeep;
  logic              m_tvalid, m_tlast, m_tready = 0;

  axis_sf_fifo #(
    .DATA_W(DATA_W), .DEPTH(DEPTH),
    .SAME_CLOCK(SAME_CLOCK), .CUT_THROUGH(CUT_THROUGH),
    .MAX_FRAME_BEATS(MAXLEN), .W_GAP_MAX(W_GAP_MAX)
  ) dut (
    .w_clk(w_clk), .w_rst_n(w_rst_n),
    .s_tdata(s_tdata), .s_tkeep(s_tkeep), .s_tvalid(s_tvalid),
    .s_tlast(s_tlast), .s_tready(s_tready),
    .pkts_in(pkts_in), .hwm(hwm),
    .r_clk(r_clk), .r_rst_n(r_rst_n),
    .m_tdata(m_tdata), .m_tkeep(m_tkeep), .m_tvalid(m_tvalid),
    .m_tlast(m_tlast), .m_tready(m_tready), .starves(starves)
  );

  // ---------------- scoreboard ----------------
  // One entry per beat, in order. A beat is queued as soon as the FIFO accepts
  // it, not when its frame ends: under cut-through the reader can be emitting
  // beat 0 while the writer is still on beat 5, and a scoreboard that only
  // learns about the frame at tlast would report the FIFO inventing data.
  typedef struct {
    logic [DATA_W-1:0] d;
    logic [KEEP_W-1:0] k;
    logic              l;
    bit                first;       // first beat of its frame
    int                id;          // which frame
  } exp_t;
  exp_t expq [$];

  // When each frame became complete, and when its first beat left. Kept per
  // frame rather than per beat because the two events are no longer ordered:
  // that IS the property under test, and comparing them at the end works
  // whichever way round they happened.
  realtime commit_time [NFRAME];
  realtime first_out   [NFRAME];
  bit      seen_out    [NFRAME];

  int errors   = 0;
  int n_beats_out = 0, n_frames_out = 0;
  int early    = 0;                 // frames released before they were complete

  // ---------------- writer ----------------
  int unsigned lfsr = 32'h1234_5678;
  function automatic int unsigned rnd();
    lfsr = (lfsr >> 1) ^ (-(lfsr & 32'd1) & 32'hD000_0000);
    return lfsr;
  endfunction

  task automatic send_frame(input int len, input int id);
    for (int i = 0; i < len; i++) begin
      exp_t e;
      // a payload that identifies its frame and its position within it, so a
      // reordering or a duplicated beat is visible rather than merely "wrong"
      e.d = '0;
      e.d[31:0]   = id;
      e.d[63:32]  = i;
      e.d[127:64] = {id[15:0], i[15:0], 32'hA5A5_5A5A};
      e.k = (i == len-1) ? ({KEEP_W{1'b1}} >> (rnd() % 8)) : {KEEP_W{1'b1}};
      e.l = (i == len-1);
      e.first = (i == 0);
      e.id = id;

      // Stall the writer sometimes, including mid-frame -- but only where the
      // DUT has not been promised otherwise. Without a stall the beats go out
      // back to back, one per w_clk, which is what W_GAP_MAX=1 means and what
      // the old driver did NOT do: it dropped tvalid between beats and so
      // delivered one beat every two cycles.
      if (WSTALL) while ((rnd() % 5) == 0) begin
        @(negedge w_clk);
        s_tvalid = 1'b0;
        s_tlast  = 1'b0;
      end

      @(negedge w_clk);
      s_tdata  = e.d;
      s_tkeep  = e.k;
      s_tlast  = e.l;
      s_tvalid = 1'b1;
      // hold until accepted: this is the tready contract under test
      do @(posedge w_clk); while (!s_tready);
      // queued the instant the FIFO took it, which is the instant it could
      // legally come back out under cut-through
      expq.push_back(e);
      // the frame is complete the moment its last beat is ACCEPTED
      if (e.l) commit_time[id] = $realtime;
    end
    @(negedge w_clk);
    s_tvalid = 1'b0;
    s_tlast  = 1'b0;
  endtask

  // ---------------- reader ----------------
  always @(posedge r_clk) begin
    if (r_rst_n) m_tready <= ((rnd() % 4) != 0);   // busy a quarter of the time
  end

  bit in_frame_out = 0;

  always @(posedge r_clk) begin
    if (r_rst_n && m_tvalid && m_tready) begin
      if (expq.size() == 0) begin
        $display("FAIL: beat emitted with nothing expected (t=%t)", $realtime);
        errors++;
      end else begin
        automatic exp_t e = expq.pop_front();
        if (m_tdata !== e.d) begin
          $display("FAIL: data mismatch at out-beat %0d: got %h expected %h",
                   n_beats_out, m_tdata[127:0], e.d[127:0]);
          errors++;
        end
        if (m_tkeep !== e.k) begin
          $display("FAIL: tkeep mismatch at out-beat %0d: got %h expected %h",
                   n_beats_out, m_tkeep, e.k);
          errors++;
        end
        if (m_tlast !== e.l) begin
          $display("FAIL: tlast mismatch at out-beat %0d: got %b expected %b",
                   n_beats_out, m_tlast, e.l);
          errors++;
        end
        // stamp when this frame's first beat left; the comparison against the
        // frame's completion time is made at the end, because under cut-through
        // the completion has not happened yet
        if (e.first) begin
          first_out[e.id] = $realtime;
          seen_out[e.id]  = 1'b1;
        end
        n_beats_out++;
        if (m_tlast) n_frames_out++;
        in_frame_out = !m_tlast;
      end
    end
  end

  // Once a frame starts leaving, it must not stall for want of data. The FIFO
  // cannot control m_tready, but it CAN be required never to drop m_tvalid
  // mid-frame while the reader is asking -- which is exactly the underrun the
  // MAC would see.
  always @(posedge r_clk) begin
    if (r_rst_n && in_frame_out && m_tready && !m_tvalid) begin
      $display("FAIL: tvalid dropped mid-frame with the reader ready at %t -- \
this is a CMAC underrun", $realtime);
      errors++;
    end
  end

  // ---------------- sequence ----------------
  int total_beats = 0;
  initial begin
    void'($value$plusargs("wper=%f", wper));
    void'($value$plusargs("rper=%f", rper));

    repeat (8) @(negedge w_clk); w_rst_n = 1;
    repeat (8) @(negedge r_clk); r_rst_n = 1;
    repeat (4) @(negedge w_clk);

    for (int f = 0; f < NFRAME; f++) begin
      automatic int len;
      // cover the ends deliberately: single-beat frames and maximum-length ones
      case (f % 8)
        0:       len = 1;
        1:       len = MAXLEN;
        2:       len = 2;
        default: len = 1 + (rnd() % MAXLEN);
      endcase
      total_beats += len;
      // one frame in flight at a time, so s_tready can never stall the writer
      // mid-frame and break the W_GAP_MAX the DUT was given
      if (PACE) wait (n_frames_out == f);
      send_frame(len, f);
      // sometimes let the FIFO drain, sometimes hammer it towards full
      if ((rnd() % 3) == 0) repeat (rnd() % 40) @(negedge w_clk);
    end

    // drain
    fork
      begin
        wait (n_frames_out == NFRAME);
      end
      begin
        repeat (400000) @(posedge r_clk);
        $display("FAIL: timeout -- %0d of %0d frames came out (%0d of %0d beats)",
                 n_frames_out, NFRAME, n_beats_out, total_beats);
        errors++;
      end
    join_any
    disable fork;

    repeat (50) @(posedge r_clk);

    if (expq.size() != 0) begin
      $display("FAIL: %0d beats never emerged", expq.size());
      errors++;
    end
    if (pkts_in != NFRAME) begin
      $display("FAIL: pkts_in = %0d, expected %0d", pkts_in, NFRAME);
      errors++;
    end
    if (hwm == 0 || hwm > DEPTH) begin
      $display("FAIL: hwm = %0d, outside 1..%0d", hwm, DEPTH);
      errors++;
    end
    // the DUT's own underrun counter, which is what the register map would read
    if (starves != 0) begin
      $display("FAIL: starves = %0d -- the port went idle mid-frame", starves);
      errors++;
    end
    // The release-time comparison, per frame, now that both times exist.
    for (int f = 0; f < NFRAME; f++) begin
      if (!seen_out[f]) begin
        $display("FAIL: frame %0d never produced a first beat", f);
        errors++;
      end else if (first_out[f] < commit_time[f]) begin
        early++;
        if (!CUT_THROUGH) begin
          $display("FAIL: frame %0d released early -- first beat out at %t, \
complete at %t", f, first_out[f], commit_time[f]);
          errors++;
        end
      end
    end

    // A cut-through run that released nothing early did not cut through: either
    // the generic never applied, or CT_MIN came out at the whole frame. Both are
    // silent passes without this.
    if (CUT_THROUGH && early == 0) begin
      $display("FAIL: CUT_THROUGH=1 but no frame was released before it was \
complete -- CT_MIN=%0d for MAX_FRAME_BEATS=%0d, W_GAP_MAX=%0d",
               dut.CT_MIN, MAXLEN, W_GAP_MAX);
      errors++;
    end

    $display("TB: %0d frames / %0d beats through, hwm=%0d of %0d, early releases=%0d, starves=%0d",
             n_frames_out, n_beats_out, hwm, DEPTH, early, starves);
    $display("TB: SAME_CLOCK=%0d CUT_THROUGH=%0d W_GAP_MAX=%0d -> CT_MIN=%0d",
             SAME_CLOCK, CUT_THROUGH, W_GAP_MAX, dut.CT_MIN);
    if (errors == 0)
      $display("PASS: axis_sf_fifo -- order, tkeep, tlast, %s, no underrun",
               CUT_THROUGH ? "cut-through" : "store-and-forward");
    else
      $display("FAIL: %0d checks failed", errors);
    $finish;
  end

endmodule
