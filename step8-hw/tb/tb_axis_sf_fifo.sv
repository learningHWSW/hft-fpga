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
`timescale 1ns/1ps
module tb_axis_sf_fifo;
  localparam int DATA_W = 512;
  localparam int KEEP_W = DATA_W / 8;
  localparam int DEPTH  = 64;          // small on purpose: make it fill
  localparam int NFRAME = 300;
  localparam int MAXLEN = 24;          // a 1518-byte Ethernet frame is 24 beats

  real wper = 1.6665;                  // ap_clk, 300 MHz
  real rper = 1.5515;                  // gt_txusrclk2, 322.265625 MHz

  logic w_clk = 0, r_clk = 0;
  logic w_rst_n = 0, r_rst_n = 0;

  initial forever #(wper) w_clk = ~w_clk;
  initial forever #(rper) r_clk = ~r_clk;

  logic [DATA_W-1:0] s_tdata = '0;
  logic [KEEP_W-1:0] s_tkeep = '0;
  logic              s_tvalid = 0, s_tlast = 0, s_tready;
  logic [31:0]       pkts_in, hwm;

  logic [DATA_W-1:0] m_tdata;
  logic [KEEP_W-1:0] m_tkeep;
  logic              m_tvalid, m_tlast, m_tready = 0;

  axis_sf_fifo #(.DATA_W(DATA_W), .DEPTH(DEPTH)) dut (
    .w_clk(w_clk), .w_rst_n(w_rst_n),
    .s_tdata(s_tdata), .s_tkeep(s_tkeep), .s_tvalid(s_tvalid),
    .s_tlast(s_tlast), .s_tready(s_tready),
    .pkts_in(pkts_in), .hwm(hwm),
    .r_clk(r_clk), .r_rst_n(r_rst_n),
    .m_tdata(m_tdata), .m_tkeep(m_tkeep), .m_tvalid(m_tvalid),
    .m_tlast(m_tlast), .m_tready(m_tready)
  );

  // ---------------- scoreboard ----------------
  // One entry per beat, in order, plus the simulation time at which the frame
  // that beat belongs to became COMPLETE. The reader checks against the head.
  typedef struct {
    logic [DATA_W-1:0] d;
    logic [KEEP_W-1:0] k;
    logic              l;
    bit                first;       // first beat of its frame
    realtime           committed;   // when this frame's tlast was written
  } exp_t;
  exp_t expq [$];

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
    exp_t pend [$];
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
      pend.push_back(e);

      // stall the writer sometimes, including mid-frame
      while ((rnd() % 5) == 0) @(negedge w_clk);

      @(negedge w_clk);
      s_tdata  = e.d;
      s_tkeep  = e.k;
      s_tlast  = e.l;
      s_tvalid = 1'b1;
      // hold until accepted: this is the tready contract under test
      do @(posedge w_clk); while (!s_tready);
      @(negedge w_clk);
      s_tvalid = 1'b0;
      s_tlast  = 1'b0;
    end
    // the frame is complete NOW; stamp every one of its beats with that time
    foreach (pend[j]) begin
      pend[j].committed = $realtime;
      expq.push_back(pend[j]);
    end
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
        // THE store-and-forward check: a frame's first beat must not leave
        // before its last beat was written.
        if (e.first && ($realtime < e.committed)) begin
          $display("FAIL: frame released early -- first beat out at %t, frame \
completed at %t", $realtime, e.committed);
          early++;
          errors++;
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

    $display("TB: %0d frames / %0d beats through, hwm=%0d of %0d, early releases=%0d",
             n_frames_out, n_beats_out, hwm, DEPTH, early);
    if (errors == 0)
      $display("PASS: axis_sf_fifo -- order, tkeep, tlast, store-and-forward, no underrun");
    else
      $display("FAIL: %0d checks failed", errors);
    $finish;
  end

endmodule
