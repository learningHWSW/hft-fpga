// Sweep / momentum-ignition detector — step 6.
//
// A sweep is an aggressive marketable order walking one side of the book across
// several price levels. In ITCH that is an EXECUTION (E, Order Executed; C,
// Executed with Price) consuming a resting order — NOT a Delete/Cancel, which
// is the order's own owner pulling it. The resting order's side gives the
// aggressor's direction, exactly as the Python golden (scripts/dump_sweep.py)
// computes it:
//   execution against a resting ASK ('S') -> offer lifted -> BUY  sweep (up)
//   execution against a resting BID ('B') -> bid hit      -> SELL sweep (down)
//
// It runs on the order table's delta stream (o_type / o_side / o_rem_price /
// o_rem_qty / o_ts), so it sees exactly the resolved executions the book does.
//
// A run is a maximal group of same-direction executions with <= cfg_gap between
// consecutive ones. It FIRES as a sweep when it has walked >= cfg_min_levels
// price levels. "Levels walked" is a FRONTIER count, not a set of prices: the
// hardware keeps one register, the furthest price reached in the sweep
// direction, and counts a level each time an execution pushes past it. For a
// marketable order walking the book the execution prices are monotonic, so the
// frontier count equals the distinct-price count the golden's set would give
// (measured: they agree on every qualifying sweep — data/FINDINGS.md §5). A
// price at or behind the frontier extends the run without adding a level, which
// is the correct "walking" semantics and costs one comparator.
//
// The measured signal (FINDINGS §5): >= 3-level sweeps continue in their
// direction ~75% of the time over the next millisecond, median one tick. The
// forward-return validation stays in Python; this block only detects.
`timescale 1ns/1ps
module sweep_detect (
  input  logic         clk,
  input  logic         rst_n,

  // configuration
  input  logic [31:0]  cfg_min_levels,
  input  logic [47:0]  cfg_gap,          // max ts gap within a run (ITCH ns)

  // order-table delta stream
  input  logic         i_valid,
  input  logic [7:0]   i_type,           // ITCH message type
  input  logic [7:0]   i_side,           // resting order side, 'B' or 'S'
  input  logic         i_has_rem,
  input  logic [31:0]  i_price,          // consumed level
  input  logic [31:0]  i_qty,            // shares consumed
  input  logic [47:0]  i_ts,

  // end-of-stream flush (a testbench pulses it; on the wire a run instead
  // closes when the next execution breaks it — see the note in the FSM)
  input  logic         i_flush,

  // sweep fired
  output logic         o_sweep,
  output logic         o_is_buy,
  output logic [31:0]  o_levels,
  output logic [31:0]  o_shares,
  output logic [47:0]  o_ts_end,

  output logic [31:0]  sweep_cnt
);
  typedef enum logic [1:0] { IDLE, BUY, SELL } dir_t;
  dir_t        run_dir;
  logic [31:0] run_frontier;
  logic [31:0] run_levels;
  logic [31:0] run_shares;
  logic [47:0] run_last_ts;

  // a qualifying execution: E or C (not X, not D), with a removal delta
  wire is_exec = i_valid && i_has_rem && ((i_type == "E") || (i_type == "C"));
  wire dir_t exec_dir = (i_side == "S") ? BUY : SELL;   // ask consumed -> buy

  // does this execution break the current run (opposite dir, or gap too big)?
  wire brk = (run_dir != IDLE) &&
             ((exec_dir != run_dir) || ((i_ts - run_last_ts) > cfg_gap));

  // does the current run qualify to fire?
  wire fire_run = (run_dir != IDLE) && (run_levels >= cfg_min_levels);

  // frontier push: this execution walks a level further out
  wire push = (run_dir == BUY  && i_price > run_frontier) ||
              (run_dir == SELL && i_price < run_frontier);

  task automatic emit_run;
    o_sweep  <= 1'b1;
    o_is_buy <= (run_dir == BUY);
    o_levels <= run_levels;
    o_shares <= run_shares;
    o_ts_end <= run_last_ts;
    sweep_cnt <= sweep_cnt + 1;
  endtask

  task automatic start_run(input dir_t d);
    run_dir      <= d;
    run_frontier <= i_price;
    run_levels   <= 32'd1;
    run_shares   <= i_qty;
    run_last_ts  <= i_ts;
  endtask

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      o_sweep      <= 1'b0;
      run_dir      <= IDLE;
      run_frontier <= '0;
      run_levels   <= '0;
      run_shares   <= '0;
      run_last_ts  <= '0;
      sweep_cnt    <= '0;
    end else begin
      o_sweep <= 1'b0;

      // flush: close an open run (a TB uses this at end of stream; on the wire
      // the run closes when a later execution breaks it, which carries the same
      // run_last_ts, so the fired record is identical)
      if (i_flush) begin
        if (fire_run) emit_run();
        run_dir <= IDLE;
      end else if (is_exec) begin
        if (brk) begin
          if (fire_run) emit_run();     // close the old run
          start_run(exec_dir);          // and open a new one on this execution
        end else if (run_dir == IDLE) begin
          start_run(exec_dir);
        end else begin
          if (push) begin
            run_levels   <= run_levels + 1;
            run_frontier <= i_price;
          end
          run_shares  <= run_shares + i_qty;
          run_last_ts <= i_ts;
        end
      end
    end
  end

endmodule
