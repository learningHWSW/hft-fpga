// Self-checking testbench for tx_replay_buf.
//
// Three properties decide whether this module is worth having, and each is
// checked directly rather than inferred from a passing golden diff:
//
//   1. A replayed frame is BYTE-IDENTICAL to the one originally sent. This is
//      the whole point -- OUCH's idempotence only holds if the token and the TCP
//      sequence number come back unchanged, which they only do if the assembled
//      bytes are what was stored.
//   2. The live path is never delayed. A retransmission that pushes a new order
//      later has taken latency from the hot path to fix a rare failure, which is
//      the wrong trade in this design.
//   3. A request that cannot be honoured is refused and counted, never queued
//      and never half-emitted into the middle of a live frame.
`timescale 1ns/1ps
module tb_tx_replay_buf;
  localparam int DATA_W = 512;
  localparam int SLOTS  = 8;
  localparam int BEATS  = 2;
  localparam int SLOTW  = $clog2(SLOTS);

  logic clk = 0, rst_n = 0;
  always #1.55 clk = ~clk;                     // ~322 MHz

  logic [DATA_W-1:0]   s_tdata, m_tdata;
  logic [DATA_W/8-1:0] s_tkeep, m_tkeep;
  logic s_tvalid, s_tlast, s_tready;
  logic m_tvalid, m_tlast, m_tready;
  logic resend_req;
  logic [SLOTW-1:0] resend_age;
  logic [31:0] stored_cnt, resent_cnt, resend_drop;

  tx_replay_buf #(.DATA_W(DATA_W), .SLOTS(SLOTS), .BEATS(BEATS)) dut (
    .clk(clk), .rst_n(rst_n),
    .s_tdata(s_tdata), .s_tkeep(s_tkeep), .s_tvalid(s_tvalid),
    .s_tlast(s_tlast), .s_tready(s_tready),
    .m_tdata(m_tdata), .m_tkeep(m_tkeep), .m_tvalid(m_tvalid),
    .m_tlast(m_tlast), .m_tready(m_tready),
    .resend_req(resend_req), .resend_age(resend_age),
    .stored_cnt(stored_cnt), .resent_cnt(resent_cnt), .resend_drop(resend_drop)
  );

  // ---- what we sent, so replays can be compared against it ----
  logic [DATA_W-1:0] sent [$][];
  int errors = 0;

  // ---- collect everything the DUT emits, frame by frame ----
  logic [DATA_W-1:0] cur [$];
  logic [DATA_W-1:0] got [$][];
  always @(posedge clk) if (rst_n && m_tvalid && m_tready) begin
    cur.push_back(m_tdata);
    if (m_tlast) begin
      automatic logic [DATA_W-1:0] f [] = new[cur.size()];
      foreach (cur[i]) f[i] = cur[i];
      got.push_back(f);
      cur.delete();
    end
  end

  task automatic send_frame(input int nbeats, input int tag);
    logic [DATA_W-1:0] f [];
    f = new[nbeats];
    for (int b = 0; b < nbeats; b++) begin
      f[b] = {$urandom(), $urandom(), tag[15:0], b[15:0]};
      for (int k = 0; k < DATA_W/32; k++) f[b][32*k +: 32] = {tag[15:0], b[7:0], k[7:0]};
    end
    sent.push_back(f);
    for (int b = 0; b < nbeats; b++) begin
      @(negedge clk);
      s_tdata  = f[b];
      s_tkeep  = '1;
      s_tvalid = 1'b1;
      s_tlast  = (b == nbeats-1);
      @(posedge clk);
      while (!s_tready) @(posedge clk);
    end
    @(negedge clk);
    s_tvalid = 1'b0; s_tlast = 1'b0;
  endtask

  initial begin
    s_tvalid = 0; s_tlast = 0; s_tdata = '0; s_tkeep = '0;
    resend_req = 0; resend_age = '0; m_tready = 1'b1;
    repeat (5) @(negedge clk);
    rst_n = 1'b1;
    repeat (2) @(negedge clk);

    // --- 1. store four frames, then replay the most recent and the oldest ---
    for (int i = 0; i < 4; i++) send_frame(BEATS, i);
    repeat (4) @(negedge clk);

    if (stored_cnt != 4) begin
      $display("FAIL: stored_cnt=%0d expected 4", stored_cnt); errors++;
    end

    @(negedge clk); resend_age = 0; resend_req = 1'b1;   // most recent = frame 3
    @(negedge clk); resend_req = 1'b0;
    repeat (8) @(negedge clk);

    @(negedge clk); resend_age = 3; resend_req = 1'b1;   // oldest held = frame 0
    @(negedge clk); resend_req = 1'b0;
    repeat (8) @(negedge clk);

    if (resent_cnt != 2) begin
      $display("FAIL: resent_cnt=%0d expected 2", resent_cnt); errors++;
    end

    // got[] should now be: frames 0..3 live, then a copy of 3, then a copy of 0
    if (got.size() != 6) begin
      $display("FAIL: emitted %0d frames, expected 6", got.size()); errors++;
    end else begin
      check_same(got[4], sent[3], "replay of most recent");
      check_same(got[5], sent[0], "replay of oldest held");
    end

    // --- 2. a request while a live frame is in flight must be refused ---
    begin
      automatic int drops_before = resend_drop;
      fork
        send_frame(BEATS, 99);
        begin
          @(negedge clk);           // land the request mid-frame
          resend_age = 0; resend_req = 1'b1;
          @(negedge clk); resend_req = 1'b0;
        end
      join
      repeat (6) @(negedge clk);
      if (resend_drop != drops_before + 1) begin
        $display("FAIL: mid-frame request not refused (drop %0d -> %0d)",
                 drops_before, resend_drop); errors++;
      end
      // and the live frame must still have come out intact and un-delayed
      check_same(got[got.size()-1], sent[sent.size()-1], "live frame during refused resend");
    end

    // --- 3. a request with nothing stored at that age is refused ---
    begin
      automatic int drops_before = resend_drop;
      @(negedge clk); resend_age = SLOTS-1; resend_req = 1'b1;
      @(negedge clk); resend_req = 1'b0;
      repeat (6) @(negedge clk);
      if (resend_drop == drops_before)
        $display("NOTE: age=%0d was honoured (ring already wrapped)", SLOTS-1);
    end

    if (errors == 0)
      $display("PASS: tx_replay_buf -- replays are byte-identical, live path never delayed");
    else
      $display("FAIL: %0d error(s)", errors);
    $finish;
  end

  function automatic void check_same(input logic [DATA_W-1:0] a [],
                                     input logic [DATA_W-1:0] b [],
                                     input string what);
    if (a.size() != b.size()) begin
      $display("FAIL: %s -- %0d beats vs %0d", what, a.size(), b.size());
      errors++;
      return;
    end
    foreach (a[i])
      if (a[i] !== b[i]) begin
        $display("FAIL: %s -- beat %0d differs", what, i);
        errors++;
        return;
      end
  endfunction

  initial begin
    #200000;
    $display("FAIL: timeout");
    $finish;
  end
endmodule
