// Self-checking TB for cfg_cdc: quasi-static config crossing between two
// asynchronous clocks (src = AXI-Lite, dst = core).
//
// Checks: (1) after a commit pulse, dst_data equals the value that was present
// at commit, and dst_load pulses exactly once; (2) dst_data does NOT change
// when src_data changes without a commit (the whole point of the snapshot);
// (3) it works repeatedly across the async boundary. Two unrelated clock
// periods so the crossing is exercised, not just aligned edges.
`timescale 1ns/1ps
module tb_cfg_cdc;
  localparam int W = 64;

  logic src_clk = 0, dst_clk = 0, src_rst_n = 0, dst_rst_n = 0;
  always #2.0 src_clk = ~src_clk;    // 250 MHz-ish
  always #2.3 dst_clk = ~dst_clk;    // ~217 MHz-ish, deliberately incommensurate

  logic [W-1:0] src_data = 0, dst_data;
  logic         src_load = 0, dst_load;

  cfg_cdc #(.W(W)) dut (
    .src_clk(src_clk), .src_rst_n(src_rst_n), .src_data(src_data), .src_load(src_load),
    .dst_clk(dst_clk), .dst_rst_n(dst_rst_n), .dst_data(dst_data), .dst_load(dst_load)
  );

  int errs = 0, load_pulses = 0;
  always @(posedge dst_clk) if (dst_rst_n && dst_load) load_pulses++;

  task automatic commit(input [W-1:0] v);
    @(negedge src_clk); src_data = v;
    repeat (2) @(negedge src_clk);       // let it settle (quasi-static)
    src_load = 1; @(negedge src_clk); src_load = 0;
  endtask

  task automatic expect_dst(input [W-1:0] v, input string nm);
    // wait for the crossing to land (bounded)
    int g = 0;
    while (dst_data !== v && g < 200) begin @(posedge dst_clk); g++; end
    if (dst_data !== v) begin
      $display("FAIL %s: dst_data=%h expected %h", nm, dst_data, v);
      errs++;
    end
  endtask

  initial begin
    repeat (4) @(negedge src_clk); src_rst_n = 1;
    repeat (4) @(negedge dst_clk); dst_rst_n = 1;
    repeat (4) @(negedge src_clk);

    commit(64'hDEAD_BEEF_0000_0001);
    expect_dst(64'hDEAD_BEEF_0000_0001, "commit 1");

    // change src_data WITHOUT a commit -> dst must hold the old value
    @(negedge src_clk); src_data = 64'hFFFF_FFFF_FFFF_FFFF;
    repeat (40) @(posedge dst_clk);
    if (dst_data !== 64'hDEAD_BEEF_0000_0001) begin
      $display("FAIL: dst_data changed without commit (%h)", dst_data);
      errs++;
    end

    commit(64'h0123_4567_89AB_CDEF);
    expect_dst(64'h0123_4567_89AB_CDEF, "commit 2");

    commit(64'h0000_0000_0000_0000);
    expect_dst(64'h0000_0000_0000_0000, "commit 3");

    repeat (5) @(posedge dst_clk);   // let commit 3's dst_load pulse be counted
    if (load_pulses != 3) begin
      $display("FAIL: dst_load pulsed %0d times, expected 3", load_pulses);
      errs++;
    end

    if (errs == 0) $display("PASS: cfg_cdc crossed 3 commits, held between them, %0d load pulses",
                            load_pulses);
    else           $display("FAIL: %0d error(s)", errs);
    $finish;
  end

  initial begin repeat (100000) @(posedge src_clk); $display("FAIL: timeout"); $finish; end
endmodule
