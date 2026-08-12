// ack_latency, driven by its two inputs directly.
//
// The probe's whole job is to turn "seq_num moved" and "peer_ack moved" into a
// number, so the testbench moves them and checks the number. Driving the real
// tcp_tx would test tcp_tx; what needs testing here is the arithmetic, the
// sequence-space wrap, and the four cases where a measurement must NOT be
// recorded -- which are the cases a real venue would produce and a bench never
// will.
`timescale 1ns/1ps
module tb_ack_latency;
  localparam int PAYLD_B  = 52;
  localparam int CAP_BITS = 10;      // 1023 cycles, so the timeout case is testable

  logic clk = 0, rst_n = 0;
  always #2.5 clk = ~clk;

  logic [31:0] seq_num = 0, peer_ack = 0;
  logic        cfg_load = 0, i_resend = 0;
  logic [31:0] st_last, st_min, st_max, st_samples, st_lost;
  logic [63:0] st_sum;

  ack_latency #(.PAYLD_B(PAYLD_B), .CAP_BITS(CAP_BITS)) dut (
    .clk(clk), .rst_n(rst_n),
    .seq_num(seq_num), .peer_ack(peer_ack),
    .cfg_load(cfg_load), .i_resend(i_resend),
    .st_last(st_last), .st_min(st_min), .st_max(st_max),
    .st_samples(st_samples), .st_sum(st_sum), .st_lost(st_lost)
  );

  int fails = 0;
  task automatic check(input bit ok, input string what);
    if (ok) $display("  ok: %s", what);
    else begin $display("FAIL: %s", what); fails++; end
  endtask

  // one order frame: seq_num advances by exactly one payload, as tcp_tx does
  task automatic send();
    @(negedge clk);
    seq_num = seq_num + PAYLD_B;
  endtask

  // the venue acknowledges everything sent so far
  task automatic ack_all();
    @(negedge clk);
    peer_ack = seq_num;
  endtask

  task automatic wait_cycles(input int n);
    repeat (n) @(negedge clk);
  endtask

  // Bring the session up the way software does, and get peer_ack moving so the
  // "is anything listening" guard is satisfied.
  //
  // The evidence is delivered WITHOUT sending an order -- the venue
  // acknowledging the handshake, which is a real thing that happens and which
  // arms no measurement. Doing it with an order instead would be realistic too,
  // and the probe would measure that order: once peer_ack has moved the compare
  // is sound, and the cycles from that send to that ack are a genuine round
  // trip. That is the design's behaviour and it is correct; it is just not a
  // useful fixture, because every count below would then be one ahead.
  task automatic open_session(input logic [31:0] isn);
    @(negedge clk);
    seq_num  = isn;
    cfg_load = 1;
    @(negedge clk);
    cfg_load = 0;
    wait_cycles(2);
    @(negedge clk);
    peer_ack = isn;                // the handshake's ack: evidence, not an order
    wait_cycles(3);
  endtask

  initial begin
    wait_cycles(4);
    rst_n = 1;
    wait_cycles(2);

    // ---- 1. a measurement is the cycles between the send and the ack ----
    open_session(32'h0001_0000);
    check(st_samples == 0, "the handshake's own ack records nothing");

    send();
    wait_cycles(20);
    ack_all();
    wait_cycles(3);
    check(st_samples == 1, $sformatf("one sample recorded (%0d)", st_samples));
    check(st_last == 20, $sformatf("20 cycles between send and ack, measured %0d", st_last));
    check(st_min == 20 && st_max == 20, "min and max are that one sample");
    check(st_sum == 20, $sformatf("sum = %0d", st_sum));

    // ---- 2. min, max and sum across several ----
    send(); wait_cycles(50); ack_all(); wait_cycles(3);
    send(); wait_cycles(8);  ack_all(); wait_cycles(3);
    check(st_samples == 3, $sformatf("three samples (%0d)", st_samples));
    check(st_min == 8,  $sformatf("min is the shortest (%0d)", st_min));
    check(st_max == 50, $sformatf("max is the longest (%0d)", st_max));
    check(st_sum == 78, $sformatf("sum is 20+50+8 (%0d)", st_sum));
    check(st_last == 8, "last is the most recent, not the largest");

    // ---- 3. cumulative acks: frames sent while measuring are not measured ----
    // Three frames go out back to back and one ack covers all three. Exactly one
    // measurement is recorded, because the ack says nothing about when the venue
    // saw the second and third.
    send(); wait_cycles(5); send(); wait_cycles(5); send();
    wait_cycles(10);
    ack_all();
    wait_cycles(3);
    check(st_samples == 4, $sformatf("one more sample for three frames (%0d)", st_samples));
    // 5 + 5 + 10 waited, plus one cycle for each of the two intervening sends:
    // send() advances the clock itself, which is easy to forget when reading the
    // expected number off the wait_cycles calls alone.
    check(st_last == 22, $sformatf("and it is the FIRST frame's latency (%0d)", st_last));

    // ---- 4. a resend poisons the sample ----
    send();
    wait_cycles(5);
    @(negedge clk); i_resend = 1;
    @(negedge clk); i_resend = 0;
    wait_cycles(10);
    ack_all();
    wait_cycles(3);
    check(st_samples == 4, "a retransmitted frame's ack is not a sample");
    check(st_lost == 1, $sformatf("it is counted as lost (%0d)", st_lost));
    check(st_last == 22, "and the previous sample is untouched");

    // ---- 5. no counterparty: peer_ack never moves, nothing is invented ----
    // The bench case. The measurement is abandoned after CAP cycles rather than
    // left to wrap the counter and report a small number for an infinite wait.
    send();
    wait_cycles((1 << CAP_BITS) + 20);
    check(st_samples == 4, "an unanswered frame produces no sample");
    check(st_lost == 2, $sformatf("it is abandoned, and counted (%0d)", st_lost));

    // ---- 6. the sequence space wraps, and the compare follows it ----
    // A session whose numbers run over 2^32 mid-measurement. An unsigned compare
    // reads the wrapped ack as 4 GB behind and never completes.
    open_session(32'hFFFF_FFE0);
    send();                         // target wraps to 0x0000_0014
    wait_cycles(12);
    ack_all();
    wait_cycles(3);
    check(st_samples == 5, $sformatf("the measurement completes across the wrap (%0d)", st_samples));
    check(st_last == 12, $sformatf("with the right number (%0d)", st_last));

    // ---- 7. a session reload is not a send ----
    // cfg_load writes a new initial sequence number, which moves seq_num by far
    // more than a payload. Counting that as a frame would arm a measurement that
    // no ack can ever satisfy.
    open_session(32'h4000_0000);
    check(st_samples == 5, "the reload itself recorded nothing");
    check(st_lost == 2, "and lost nothing");
    send();
    wait_cycles(7);
    ack_all();
    wait_cycles(3);
    check(st_samples == 6 && st_last == 7,
          $sformatf("the session measures normally afterwards (%0d samples, last %0d)",
                    st_samples, st_last));

    if (fails == 0) $display("PASS: ack_latency measures the round trip, and refuses to invent one");
    else            $display("FAIL: %0d check(s) failed", fails);
    $finish;
  end

  initial begin
    #500_000;
    $display("FAIL: timeout");
    $finish;
  end
endmodule
