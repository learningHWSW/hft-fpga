// The post-reset clear sweep, tested for its EFFECT rather than its existence.
//
// UltraRAM has no INIT. On the device the table comes up holding whatever the
// silicon felt like, `valid` bits included, so order_table walks every set after
// reset writing an all-zero entry. Nothing in the golden-diff suite exercises
// that: the goldens start from an empty book either way, and a build with the
// sweep deleted would pass every one of them.
//
// It used to be caught by accident. `otable_mem` carried a behavioural array
// that deliberately did not initialise, so a missing sweep showed up as X
// propagating out of the first lookup. That array is gone (FINDINGS 4.5 -- all
// three flows now build the XPM macro), and XPM's simulation model ZEROES
// itself regardless of USE_MEM_INIT: memory that comes up indeterminate on the
// device comes up empty in the simulator, which is precisely the lie the sweep
// exists to defend against. Measured, not assumed -- an unwritten location
// reads 0, not X.
//
// So the accident is replaced by a test. Garbage is written directly into the
// memory model before reset is released, and the table must not see it.
//
// THE SECOND HALF IS THE CONTROL, and the test is worthless without it. A miss
// proves nothing on its own -- a poke that landed somewhere the FSM never reads
// would produce exactly the same miss, and the test would pass while checking
// nothing. So after the sweep has finished the same garbage is poked in again,
// and the same delete must now HIT it. One poke, two outcomes, and the only
// difference between them is whether the sweep has run.
`timescale 1ns/1ps
module tb_otable_clear;
  import itch5_pkg::*;

  // Small enough that the sweep is 64 cycles rather than 8,192. The sweep's
  // length is not what is under test; that it happens at all is.
  localparam int SETS_BITS = 6;
  localparam int SETS      = 1 << SETS_BITS;
  localparam int WAYS      = 2;
  localparam int RD_LAT    = 2;
  localparam int EW        = 1 + 64 + 1 + 32 + 32 + 1;   // {valid,oref,is_buy,price,qty,sym}

  // The ref hashes to its own low bits, so poisoning every set covers it
  // whatever SETS_BITS is.
  localparam logic [63:0] REF   = 64'h0000_0000_0000_1234;
  localparam logic [31:0] PRICE = 32'hDEAD_BEEF;
  localparam logic [31:0] QTY   = 32'd777;
  localparam logic [EW-1:0] POISON = {1'b1, REF, 1'b1, PRICE, QTY, 1'b0};
  // The other way gets a DIFFERENT ref. Writing the same one into both ways is
  // garbage the design is entitled to rule out -- order_ref is unique, which is
  // why the entry select is a one-hot OR and not a priority mux -- and
  // order_table's own assertion says so ($fatal, "2 ways matched"). Garbage
  // that violates the design's stated premise tests the assertion, not the
  // sweep.
  localparam logic [EW-1:0] POISON2 = {1'b1, REF ^ 64'h1, 1'b1, PRICE, QTY, 1'b0};

  logic clk = 0, rst_n = 0;
  always #2.5 clk = ~clk;

  itch_msg_t   msg;
  logic        s_valid = 0, s_ready;
  logic        o_valid, o_has_rem, o_has_add, init_done;
  logic [7:0]  o_type, o_side;
  logic [15:0] o_locate;
  logic [31:0] o_rem_price, o_rem_qty, o_add_price, o_add_qty;
  logic [31:0] overflow_cnt, miss_cnt;

  order_table #(.SETS_BITS(SETS_BITS), .WAYS(WAYS), .RD_LAT(RD_LAT), .NSYM(1)) dut (
    .clk(clk), .rst_n(rst_n),
    .track_locate(16'd1),
    .s_msg(msg), .s_valid(s_valid), .s_ready(s_ready),
    .o_valid(o_valid), .o_type(o_type), .o_ts(), .o_locate(o_locate),
    .o_sym(), .o_side(o_side),
    .o_has_rem(o_has_rem), .o_rem_price(o_rem_price), .o_rem_qty(o_rem_qty),
    .o_has_add(o_has_add), .o_add_price(o_add_price), .o_add_qty(o_add_qty),
    .init_done(init_done),
    .overflow_cnt(overflow_cnt), .miss_cnt(miss_cnt)
  );

  // Reaching into the XPM model. There is no other way to put garbage in a
  // memory whose whole point is that its contents cannot be controlled, and the
  // hierarchical name is checked by the control below: if this path stopped
  // resolving to the array the FSM reads, the control would stop hitting.
  // WAYS is 2 and the two pokes are written out, because a hierarchical name
  // cannot be indexed by a run-time variable.
  task automatic poison();
    for (int s = 0; s < SETS; s++) begin
      dut.g_way[0].u_mem.u_xpm.xpm_memory_base_inst.mem[s] = POISON2;
      dut.g_way[1].u_mem.u_xpm.xpm_memory_base_inst.mem[s] = POISON;
    end
  endtask

  int fails = 0;
  task automatic check(input bit ok, input string what);
    if (ok) $display("  ok: %s", what);
    else begin $display("FAIL: %s", what); fails++; end
  endtask

  // Send one message and report what came back within a few cycles.
  logic saw_valid, saw_rem;
  logic [31:0] saw_price;
  task automatic send_delete();
    msg = '0;
    msg.msg_type  = "D";
    msg.locate    = 16'd1;
    msg.order_ref = REF;
    @(negedge clk);
    while (!s_ready) @(negedge clk);
    s_valid = 1;
    @(negedge clk);
    s_valid = 0;
    saw_valid = 0; saw_rem = 0; saw_price = '0;
    repeat (4 + RD_LAT + 4) begin
      @(posedge clk);
      if (o_valid) begin
        saw_valid = 1;
        saw_rem   = o_has_rem;
        saw_price = o_rem_price;
      end
    end
  endtask

  int t_release, t_done;
  initial begin
    poison();                       // before reset is released, as the device is
    repeat (4) @(negedge clk);
    rst_n = 1;
    t_release = $time;

    check(!init_done, "init_done is low out of reset");
    while (!init_done) @(posedge clk);
    t_done = $time;
    check((t_done - t_release) >= SETS * 5,
          $sformatf("init_done rises after the sweep, not before (%0d ns for %0d sets)",
                    (t_done - t_release), SETS));

    // 1. the table must not see what was in the memory before the sweep
    send_delete();
    check(!(saw_valid && saw_rem),
          "a delete for a poisoned ref does not remove a phantom level");
    check(miss_cnt == 32'd1, $sformatf("it counts as a miss (miss_cnt=%0d)", miss_cnt));

    // 2. THE CONTROL: the same garbage, poked after the sweep, must be found.
    //    Without this, part 1 passes even if the poke never reached the memory.
    poison();
    repeat (2) @(negedge clk);
    send_delete();
    check(saw_valid && saw_rem,
          "the same poke AFTER the sweep is found -- so part 1 was the sweep, not a poke that missed");
    check(saw_price == PRICE,
          $sformatf("and it is the poked entry (price=%08h)", saw_price));

    if (fails == 0) $display("PASS: the post-reset clear sweep removes what URAM comes up with");
    else            $display("FAIL: %0d check(s) failed", fails);
    $finish;
  end

  // A sweep that never ends would otherwise hang the run.
  initial begin
    #1_000_000;
    $display("FAIL: timeout -- init_done never rose, or a message was never answered");
    $finish;
  end
endmodule
