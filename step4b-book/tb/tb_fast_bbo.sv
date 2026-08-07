// Self-checking testbench for fast_bbo.
//
// The module's value is a claim about SAFETY, not about speed, so that is what
// is checked: whenever it says `o_certain`, its BBO must equal what a full book
// model computes. Speed is reported as a count, because a fast path that is
// certain 5 % of the time would be pointless -- but a fast path that is certain
// and WRONG would silently break the project's headline property, that there is
// no regime in which it emits a wrong order.
//
// The reference is a complete level map (an associative array per side), not
// another copy of the DUT's rules -- otherwise a mistake in the rules would be
// reproduced on both sides and agree with itself, which is the failure mode the
// rest of this project's goldens are built to avoid.
`timescale 1ns/1ps
module tb_fast_bbo;
  logic clk = 0, rst_n = 0;
  always #2.3 clk = ~clk;                       // ~215 MHz

  logic        i_valid = 0;
  logic [47:0] i_ts = 0;
  logic [7:0]  i_side = "B";
  logic        i_has_rem = 0, i_has_add = 0;
  logic [31:0] i_rem_price = 0, i_rem_qty = 0, i_add_price = 0, i_add_qty = 0;

  logic        i_lad_valid = 0, i_lad_has_bid = 0, i_lad_has_ask = 0;
  logic [31:0] i_lad_bid_price = 0, i_lad_bid_qty = 0;
  logic [31:0] i_lad_ask_price = 0, i_lad_ask_qty = 0;

  logic        o_valid, o_certain, o_has_bid, o_has_ask;
  logic [47:0] o_ts;
  logic [31:0] o_bid_price, o_bid_qty, o_ask_price, o_ask_qty;
  logic [31:0] certain_cnt, defer_cnt;

  fast_bbo dut (.*);

  // ---- reference: a full book, the thing price_ladder actually is ----
  int bid_lv [int];      // price -> aggregate qty
  int ask_lv [int];

  int errors = 0, records = 0;

  function automatic void ref_apply(input bit is_bid, input bit has_rem,
                                    input int rem_px, input int rem_q,
                                    input bit has_add, input int add_px,
                                    input int add_q);
    if (is_bid) begin
      if (has_rem && bid_lv.exists(rem_px)) begin
        bid_lv[rem_px] -= rem_q;
        if (bid_lv[rem_px] <= 0) bid_lv.delete(rem_px);
      end
      if (has_add) bid_lv[add_px] = (bid_lv.exists(add_px) ? bid_lv[add_px] : 0) + add_q;
    end else begin
      if (has_rem && ask_lv.exists(rem_px)) begin
        ask_lv[rem_px] -= rem_q;
        if (ask_lv[rem_px] <= 0) ask_lv.delete(rem_px);
      end
      if (has_add) ask_lv[add_px] = (ask_lv.exists(add_px) ? ask_lv[add_px] : 0) + add_q;
    end
  endfunction

  function automatic void ref_best(output bit hb, output int bp, output int bq,
                                   output bit ha, output int ap, output int aq);
    hb = 0; bp = 0; bq = 0; ha = 0; ap = 0; aq = 0;
    foreach (bid_lv[p]) if (!hb || p > bp) begin hb = 1; bp = p; bq = bid_lv[p]; end
    foreach (ask_lv[p]) if (!ha || p < ap) begin ha = 1; ap = p; aq = ask_lv[p]; end
  endfunction

  // ---- drive one delta, then check the DUT against the reference ----
  task automatic delta(input bit is_bid, input bit has_rem, input int rem_px,
                       input int rem_q, input bit has_add, input int add_px,
                       input int add_q);
    bit hb, ha; int bp, bq, ap, aq;
    @(negedge clk);
    i_valid = 1; i_side = is_bid ? "B" : "S"; i_ts = i_ts + 1000;
    i_has_rem = has_rem; i_rem_price = rem_px; i_rem_qty = rem_q;
    i_has_add = has_add; i_add_price = add_px; i_add_qty = add_q;
    @(negedge clk);
    i_valid = 0; i_has_rem = 0; i_has_add = 0;

    ref_apply(is_bid, has_rem, rem_px, rem_q, has_add, add_px, add_q);
    ref_best(hb, bp, bq, ha, ap, aq);

    @(posedge clk);                     // o_valid is registered
    records++;

    if (!o_valid) begin
      $display("FAIL: no record emitted for delta %0d", records); errors++;
      return;
    end

    if (o_certain) begin
      // THE SAFETY PROPERTY.
      if (o_has_bid !== hb || o_has_ask !== ha ||
          (hb && (o_bid_price != bp || o_bid_qty != bq)) ||
          (ha && (o_ask_price != ap || o_ask_qty != aq))) begin
        $display("FAIL: certain but WRONG at record %0d", records);
        $display("      dut  bid %0d@%0d (%0b)  ask %0d@%0d (%0b)",
                 o_bid_qty, o_bid_price, o_has_bid, o_ask_qty, o_ask_price, o_has_ask);
        $display("      ref  bid %0d@%0d (%0b)  ask %0d@%0d (%0b)",
                 bq, bp, hb, aq, ap, ha);
        errors++;
      end
    end else begin
      // A deferral is always allowed. Resync it from the reference, which is what
      // price_ladder would supply.
      @(negedge clk);
      i_lad_valid = 1;
      i_lad_has_bid = hb; i_lad_bid_price = bp; i_lad_bid_qty = bq;
      i_lad_has_ask = ha; i_lad_ask_price = ap; i_lad_ask_qty = aq;
      @(negedge clk);
      i_lad_valid = 0;
    end
  endtask

  initial begin
    repeat (4) @(negedge clk);
    rst_n = 1;
    repeat (2) @(negedge clk);

    // seed the shadow, as the ladder would after reset
    @(negedge clk);
    i_lad_valid = 1; i_lad_has_bid = 0; i_lad_has_ask = 0;
    @(negedge clk); i_lad_valid = 0;

    // ---- the six cases from the module header, explicitly ----
    delta(1, 0,0,0, 1, 1500000, 100);   // first bid           -> certain
    delta(1, 0,0,0, 1, 1500500, 200);   // better bid          -> certain
    delta(1, 0,0,0, 1, 1500500, 50);    // add at best         -> certain
    delta(1, 0,0,0, 1, 1499000, 400);   // add at worse price  -> certain
    delta(1, 1,1499000,400, 0,0,0);     // remove worse level  -> certain
    delta(1, 1,1500500,100, 0,0,0);     // partial at best     -> certain
    check_certain(6, "the five non-emptying shapes");

    delta(1, 1,1500500,150, 0,0,0);     // EMPTIES the best    -> must defer
    check_deferred("removal that empties the best level");

    // asks, where "better" is the other direction
    delta(0, 0,0,0, 1, 1502000, 100);
    delta(0, 0,0,0, 1, 1501000, 300);   // lower ask is better -> certain
    delta(0, 1,1501000,300, 0,0,0);     // empties best ask    -> must defer
    check_deferred("removal that empties the best ask");

    // ---- randomised, against the full book model ----
    begin
      automatic int px, q;
      for (int i = 0; i < 4000; i++) begin
        automatic bit bid = $urandom_range(0,1);
        px = 1500000 + 100 * $urandom_range(0, 20);
        q  = 100 * $urandom_range(1, 5);
        if ($urandom_range(0,2) == 0) begin
          // a removal from a level that exists, so it is a realistic delta
          automatic int keys [$];
          if (bid) begin foreach (bid_lv[k]) keys.push_back(k); end
          else     begin foreach (ask_lv[k]) keys.push_back(k); end
          if (keys.size() == 0) begin delta(bid, 0,0,0, 1, px, q); continue; end
          px = keys[$urandom_range(0, keys.size()-1)];
          q  = bid ? bid_lv[px] : ask_lv[px];
          if ($urandom_range(0,1)) q = (q > 100) ? q - 100 : q;   // partial or full
          delta(bid, 1, px, q, 0, 0, 0);
        end else begin
          delta(bid, 0,0,0, 1, px, q);
        end
      end
    end

    $display("TB: %0d records, certain=%0d defer=%0d (%0d%% answered early)",
             records, certain_cnt, defer_cnt,
             (certain_cnt * 100) / (certain_cnt + defer_cnt));
    if (errors == 0)
      $display("PASS: fast_bbo -- never certain and wrong, over %0d records", records);
    else
      $display("FAIL: %0d error(s)", errors);
    $finish;
  end

  int last_certain;
  task automatic check_certain(input int n, input string what);
    if (certain_cnt < n) begin
      $display("FAIL: expected >=%0d certain for %s (got %0d)", n, what, certain_cnt);
      errors++;
    end
  endtask
  task automatic check_deferred(input string what);
    if (o_certain) begin
      $display("FAIL: %s should have deferred", what); errors++;
    end
  endtask

  initial begin #500000; $display("FAIL: timeout"); $finish; end
endmodule
