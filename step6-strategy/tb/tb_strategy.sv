// Self-checking TB for step 6: BBO log -> strategy -> order log.
//
// Stimulus is the BBO log step 4b already produces, so this tests exactly what
// step 6 adds — the rule and the risk gate — against scripts/dump_orders.py.
// The Makefile diffs the two logs.
//
// Records are presented one at a time rather than back to back. BBO updates
// are inherently sparse (1779 across a 5 M-message slice, i.e. one per ~2800
// messages), so this is the realistic arrival pattern; sustained back-to-back
// BBO updates are not a case the book engine can produce. The pipeline is
// written to handle them anyway, but this TB does not prove that.
//
// Acks are scheduled by BBO RECORD INDEX, not by cycle count — the same clock
// the golden uses, which is the only way the two can agree exactly on when the
// in-flight limiter releases.
//
// +bbo=<path> stimulus, +out=<path> order log.
`timescale 1ns/1ps
module tb_strategy;
  localparam int MAXREC   = 200000;
  localparam int ACK_GAP  = 50;      // must match dump_orders.py

  // configuration — measured against the replay, see dump_orders.py
  localparam logic [31:0] CFG_MAX_SPREAD   = 32'd2000;
  localparam logic [3:0]  CFG_RATIO_SHIFT  = 4'd1;
  localparam logic [31:0] CFG_MIN_QTY      = 32'd100;
  localparam logic [31:0] CFG_ORDER_QTY    = 32'd100;
  localparam logic [31:0] CFG_POS_LIMIT    = 32'd1000;
  localparam logic [15:0] CFG_MAX_INFLIGHT = 16'd4;

  logic clk = 0, rst_n = 0;
  always #2.309 clk = ~clk;          // 216.5 MHz, the measured core Fmax

  logic        i_valid = 0, i_ack = 0;
  logic [47:0] i_ts;
  logic        i_has_bid, i_has_ask;
  logic [31:0] i_bid_price, i_bid_qty, i_ask_price, i_ask_qty;

  logic        o_valid, o_is_buy;
  logic [47:0] o_ts;
  logic [31:0] o_qty, o_price;
  logic        o_ready = 1;          // golden models no TX backpressure

  logic [31:0] sent_cnt, blk_pos_cnt, blk_inflight_cnt, blk_txfull_cnt;
  logic signed [31:0] position;
  logic [15:0] inflight;

  strategy dut (
    .clk(clk), .rst_n(rst_n),
    .cfg_enable(1'b1),
    .cfg_max_spread(CFG_MAX_SPREAD), .cfg_ratio_shift(CFG_RATIO_SHIFT),
    .cfg_min_qty(CFG_MIN_QTY), .cfg_order_qty(CFG_ORDER_QTY),
    .cfg_pos_limit(CFG_POS_LIMIT), .cfg_max_inflight(CFG_MAX_INFLIGHT),
    .i_valid(i_valid), .i_ts(i_ts),
    .i_has_bid(i_has_bid), .i_bid_price(i_bid_price), .i_bid_qty(i_bid_qty),
    .i_has_ask(i_has_ask), .i_ask_price(i_ask_price), .i_ask_qty(i_ask_qty),
    .i_ack(i_ack),
    .o_valid(o_valid), .o_ts(o_ts), .o_is_buy(o_is_buy),
    .o_qty(o_qty), .o_price(o_price), .o_ready(o_ready),
    .sent_cnt(sent_cnt), .blk_pos_cnt(blk_pos_cnt),
    .blk_inflight_cnt(blk_inflight_cnt), .blk_txfull_cnt(blk_txfull_cnt),
    .position(position), .inflight(inflight)
  );

  int          fout;
  int          acks_due [MAXREC];
  int          fired_this_rec = 0;

  // monitor: log every order and note that one fired, for ack scheduling
  always @(posedge clk) begin
    if (rst_n && o_valid) begin
      // separate calls, not %s with a ternary: string literals in a ternary are
      // padded to the wider operand, so "BUY" comes out as " BUY"
      if (o_is_buy) $fdisplay(fout, "%0d BUY qty=%0d px=%0d",  o_ts, o_qty, o_price);
      else          $fdisplay(fout, "%0d SELL qty=%0d px=%0d", o_ts, o_qty, o_price);
      fired_this_rec++;
    end
  end

  string bbo_path, out_path, line;
  int    fin, rec = 0, code;

  initial begin
    if (!$value$plusargs("bbo=%s", bbo_path)) bbo_path = "bbo_gold.log";
    if (!$value$plusargs("out=%s", out_path)) out_path = "orders_rtl.log";
    fin  = $fopen(bbo_path, "r");
    fout = $fopen(out_path, "w");
    if (fin == 0)  begin $display("FAIL: cannot open %s", bbo_path); $finish; end

    repeat (5) @(posedge clk);
    rst_n = 1;
    repeat (5) @(posedge clk);

    while ($fgets(line, fin) > 0) begin
      automatic longint unsigned ts;
      automatic int unsigned bp, bq, ap, aq;
      code = $sscanf(line, "%d bid=%d:%d ask=%d:%d", ts, bp, bq, ap, aq);
      if (code != 5) continue;
      rec++;

      // acks due at this record land before the record is judged
      while (acks_due[rec] > 0) begin
        @(posedge clk);
        i_ack = 1'b1;
        @(posedge clk);
        i_ack = 1'b0;
        acks_due[rec]--;
      end

      fired_this_rec = 0;
      @(posedge clk);
      i_valid     = 1'b1;
      i_ts        = ts[47:0];
      i_has_bid   = (bp != 0);
      i_bid_price = bp;
      i_bid_qty   = bq;
      i_has_ask   = (ap != 0);
      i_ask_price = ap;
      i_ask_qty   = aq;
      @(posedge clk);
      i_valid = 1'b0;

      repeat (4) @(posedge clk);       // let stage 2 resolve and the monitor run
      if (fired_this_rec > 0 && (rec + ACK_GAP) < MAXREC)
        acks_due[rec + ACK_GAP] += fired_this_rec;
    end

    repeat (20) @(posedge clk);
    $fclose(fout);
    $display("TB done: %0d records, %0d orders (pos=%0d inflight=%0d)",
             rec, sent_cnt, position, inflight);
    $display("  blocked: position=%0d inflight=%0d tx-full=%0d",
             blk_pos_cnt, blk_inflight_cnt, blk_txfull_cnt);
    // the golden has no TX backpressure model, so any tx-full block would mean
    // the two are being asked different questions
    if (blk_txfull_cnt != 0) $display("FAIL: tx-full blocks with o_ready tied high");
    $finish;
  end

endmodule
