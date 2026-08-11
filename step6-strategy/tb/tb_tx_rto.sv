// Self-checking testbench for tx_rto.
//
// The module decides WHEN to re-send, so the properties worth checking are the
// ones where a wrong decision is expensive or invisible:
//
//   1. it is silent until the venue has spoken. Before the first acknowledgement
//      peer_ack is zero and every frame looks unacknowledged, so an unarmed
//      module would retransmit into a connection that does not exist -- which is
//      every simulation in this repository and a card on a bench.
//   2. it is silent when disabled, whatever the sequence numbers say.
//   3. it asks for the OLDEST unacknowledged frame, because that is the one a
//      TCP sender retransmits first and the age is what tx_replay_buf indexes by.
//      Asking for the wrong age re-sends a frame that was never lost.
//   4. an acknowledgement cancels the pending timeout rather than merely
//      shortening it, and restores the full retry budget.
//   5. it stops at cfg_max_retries and says so once, rather than emitting a
//      frame per timeout forever at a venue that has gone away.
`timescale 1ns/1ps
module tb_tx_rto;
  localparam int SLOTS   = 16;
  localparam int PAYLD_B = 52;
  localparam int AW      = $clog2(SLOTS);

  logic clk = 0, rst_n = 0;
  always #2.3 clk = ~clk;                        // ~215 MHz

  logic        cfg_en = 0;
  logic [31:0] cfg_rto_cycles = 20;
  logic [3:0]  cfg_max_retries = 3;
  logic [31:0] seq_num = 32'h1000_0000;
  logic [31:0] peer_ack = 32'h0000_0000;

  logic          o_resend_req;
  logic [AW-1:0] o_resend_age;
  logic [31:0]   st_fired, st_gaveup;

  tx_rto #(.SLOTS(SLOTS), .PAYLD_B(PAYLD_B)) dut (.*);

  int errors = 0;
  int seen_req = 0;
  int unsigned fired_before = 0;
  logic [AW-1:0] last_age;

  always @(posedge clk) if (rst_n && o_resend_req) begin
    seen_req++;
    last_age <= o_resend_age;
  end

  task automatic tick(input int n = 1);
    repeat (n) @(posedge clk);
  endtask

  task automatic check(input bit ok, input string what);
    if (!ok) begin
      errors++;
      $display("FAIL: %s", what);
    end
  endtask

  // Wait long enough for a timeout to have fired if it were going to.
  task automatic settle();
    tick(cfg_rto_cycles + 10);
  endtask

  initial begin
    tick(4);
    rst_n = 1;
    tick(2);

    // ---- 1) unarmed: four frames outstanding, no acknowledgement ever ----
    cfg_en  <= 1;
    seq_num <= 32'h1000_0000 + 4 * PAYLD_B;
    settle(); settle();
    check(seen_req == 0, "resent before the venue ever acknowledged anything");
    check(st_fired == 0, "st_fired moved while unarmed");

    // ---- 2) arm: one acknowledgement, covering the first two frames ----
    // From here the module knows the connection is live.
    peer_ack <= 32'h1000_0000 + 2 * PAYLD_B;
    tick(2);
    check(seen_req == 0, "resent on the acknowledgement itself");

    // ---- 3) disabled: still armed, still outstanding, must stay silent ----
    cfg_en <= 0;
    settle(); settle();
    check(seen_req == 0, "resent while cfg_en was low");
    cfg_en <= 1;

    // ---- 4) timeout: two frames outstanding -> the older of the two, age 1 ----
    settle();
    check(seen_req == 1, $sformatf("expected one resend, saw %0d", seen_req));
    check(last_age == 1, $sformatf("expected age 1 (oldest of two), got %0d", last_age));
    check(st_fired == 1, "st_fired did not count the resend");

    // ---- 5) an acknowledgement cancels the next timeout ----
    // It clears everything outstanding, so nothing may fire however long we wait.
    peer_ack <= seq_num;
    settle(); settle();
    check(seen_req == 1, "resent after everything was acknowledged");
    check(st_gaveup == 0, "gave up while the venue was answering");

    // ---- 6) one frame outstanding -> age 0, the most recent ----
    seq_num <= seq_num + PAYLD_B;
    settle();
    check(seen_req == 2, $sformatf("expected a second resend, saw %0d", seen_req));
    check(last_age == 0, $sformatf("expected age 0 (single frame), got %0d", last_age));

    // ---- 7) retry cap: it stops, counts once, and stays stopped ----
    // The cap is per EPISODE -- per run of unacknowledged data -- while st_fired
    // is cumulative, so this starts a fresh episode and measures the increment.
    // Nothing acknowledges from here, so the budget is used up and the module
    // must then go quiet rather than emit a frame per timeout forever.
    peer_ack <= seq_num;                       // close the previous episode
    tick(2);
    fired_before = st_fired;
    seq_num <= seq_num + PAYLD_B;              // one frame, never acknowledged
    repeat (cfg_max_retries + 3) settle();
    check(st_fired - fired_before == cfg_max_retries,
          $sformatf("fired %0d times in one episode, cap is %0d",
                    st_fired - fired_before, cfg_max_retries));
    check(st_gaveup == 1, $sformatf("expected one give-up, got %0d", st_gaveup));

    // ---- 8) an acknowledgement restores the budget ----
    fired_before = st_fired;
    peer_ack <= seq_num;            // everything acknowledged
    tick(2);
    seq_num  <= seq_num + PAYLD_B;  // and a new frame goes out
    settle();
    check(st_fired == fired_before + 1,
          "an acknowledgement did not restore the retry budget");
    check(st_gaveup == 1, "gave up twice for one dead episode");

    if (errors == 0)
      $display("PASS: tx_rto -- armed by the venue, oldest frame, capped retries");
    else
      $display("FAIL: tx_rto -- %0d errors", errors);
    $finish;
  end

  initial begin
    repeat (200000) @(posedge clk);
    $display("FAIL: timeout");
    $finish;
  end
endmodule
