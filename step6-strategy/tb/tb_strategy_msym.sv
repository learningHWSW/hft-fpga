// Multi-symbol TB for the strategy and the OUCH builder.
//
// THE STIMULUS IS DELIBERATELY THE WORST CASE FOR SHARED STATE: the SAME BBO
// record is presented to both symbols, back to back, for the whole log. If any
// per-book state were actually shared, the two streams would interfere
// maximally and the failure would be impossible to miss:
//
//   prev_buy/prev_sell shared -> symbol 0's record raises the edge, symbol 1's
//     identical record then finds the condition already true and fires nothing.
//     Symbol 1's order log would be nearly empty.
//   position shared           -> the position moves twice per record, so
//     cfg_pos_limit binds at half the record count and BOTH streams truncate.
//   the latched BBO shared    -> harmless here (the records are equal), which
//     is why tb_fh_core_msym drives two genuinely different books as well.
//
// So the expected result for EACH symbol is the ordinary single-symbol golden,
// unchanged, and the check is the existing dump_orders.py output diffed twice.
// No new golden is written for this, on purpose: a golden authored beside the
// multi-symbol RTL could share a mistake with it, and this one has been diffed
// against the single-symbol RTL since step 6.
//
// WHAT IS CONFIGURED AWAY, and why that is honest rather than convenient.
// cfg_max_inflight is SHARED between symbols by design -- it counts orders on
// one TCP session with one replay buffer, and the resource it limits is the
// wire, not the book. Two symbols firing into a shared budget therefore cannot
// reproduce a single-symbol golden, and should not. So this test runs with the
// limit set high enough that it never binds, and the in-flight limiter keeps
// being covered by tb_strategy.sv where it is the thing under test. What this
// run does exercise is cfg_pos_limit, which IS per symbol and does bind.
//
// THE OUCH SIDE. cfg_stock is per symbol and nothing else in an Enter Order is,
// so the check is exactly that: every packet from symbol 0 carries "AAPL    "
// in the Stock field and every packet from symbol 1 carries "MSFT    ", at the
// byte offset OUCH 4.2 puts it. Token numbers differ between the two streams
// (token_seq is one counter for one session), so the packets are NOT otherwise
// comparable, and pretending they were would be a weaker test than this.
//
// +bbo=<path> stimulus, +out0/+out1=<path> per-symbol order logs.
`timescale 1ns/1ps
module tb_strategy_msym;
  localparam int NSYM = 2;
  localparam int SYMW = $clog2(NSYM);

  // Matches the golden's parameters (see the Makefile's dump_orders.py call).
  // MAX_INFLIGHT is the one that differs from tb_strategy: see the header.
  localparam logic [31:0] CFG_MAX_SPREAD   = 32'd2000;
  localparam logic [3:0]  CFG_RATIO_SHIFT  = 4'd1;
  localparam logic [31:0] CFG_MIN_QTY      = 32'd100;
  localparam logic [31:0] CFG_ORDER_QTY    = 32'd100;
  localparam logic [31:0] CFG_POS_LIMIT    = 32'd1000;
  localparam logic [15:0] CFG_MAX_INFLIGHT = 16'hFFFF;

  logic clk = 0, rst_n = 0;
  always #2.309 clk = ~clk;

  logic            i_valid = 0;
  logic [SYMW-1:0] i_sym   = 0;
  logic [47:0]     i_ts;
  logic            i_has_bid, i_has_ask;
  logic [31:0]     i_bid_price, i_bid_qty, i_ask_price, i_ask_qty;

  logic            o_valid, o_is_buy, o_ready;
  logic [SYMW-1:0] o_sym;
  logic [47:0]     o_ts;
  logic [31:0]     o_qty, o_price;

  logic [511:0] p_tdata;
  logic [63:0]  p_tkeep;
  logic         p_tvalid, p_tlast;
  logic [31:0]  pkt_cnt, token_seq;

  logic [31:0] sent_cnt, blk_pos_cnt, blk_inflight_cnt, blk_txfull_cnt, blk_qty_cnt;
  logic [NSYM*32-1:0] position;
  logic [15:0] inflight;

  strategy #(.NSYM(NSYM)) dut (
    .clk(clk), .rst_n(rst_n),
    .cfg_enable(1'b1),
    .cfg_max_spread(CFG_MAX_SPREAD), .cfg_ratio_shift(CFG_RATIO_SHIFT),
    .cfg_min_qty(CFG_MIN_QTY), .cfg_order_qty(CFG_ORDER_QTY),
    .cfg_pos_limit(CFG_POS_LIMIT), .cfg_max_inflight(CFG_MAX_INFLIGHT),
    .i_valid(i_valid), .i_sym(i_sym), .i_ts(i_ts),
    .i_has_bid(i_has_bid), .i_bid_price(i_bid_price), .i_bid_qty(i_bid_qty),
    .i_has_ask(i_has_ask), .i_ask_price(i_ask_price), .i_ask_qty(i_ask_qty),
    .cfg_sweep_en(1'b0), .i_sweep(1'b0), .i_sweep_sym('0), .i_sweep_is_buy(1'b0),
    .i_ack(1'b0),
    .o_valid(o_valid), .o_sym(o_sym), .o_ts(o_ts), .o_is_buy(o_is_buy),
    .o_qty(o_qty), .o_price(o_price), .o_ready(o_ready),
    .sent_cnt(sent_cnt), .blk_pos_cnt(blk_pos_cnt),
    .blk_inflight_cnt(blk_inflight_cnt), .blk_txfull_cnt(blk_txfull_cnt),
    .blk_qty_cnt(blk_qty_cnt),
    .position(position), .inflight(inflight)
  );

  // "AAPL    " for symbol 0, "MSFT    " for symbol 1, byte 0 in the low byte
  ouch_builder #(.DATA_W(512), .NSYM(NSYM)) bld (
    .clk(clk), .rst_n(rst_n),
    .cfg_token_prefix({"1", "0", "A", "G", "P", "F"}),
    .cfg_stock({{" ", " ", " ", " ", "T", "F", "S", "M"},
                {" ", " ", " ", " ", "L", "P", "A", "A"}}),
    .cfg_firm({"1", "T", "F", "H"}),
    .cfg_tif(32'd0), .cfg_min_qty(32'd0),
    .cfg_display("A"), .cfg_capacity("P"), .cfg_sweep("N"),
    .cfg_cross("N"), .cfg_cust("N"),
    .i_valid(o_valid), .i_sym(o_sym), .i_is_buy(o_is_buy),
    .i_qty(o_qty), .i_price(o_price),
    .i_ready(o_ready),
    .m_tdata(p_tdata), .m_tkeep(p_tkeep), .m_tvalid(p_tvalid), .m_tlast(p_tlast),
    .m_tready(1'b1),
    .pkt_cnt(pkt_cnt), .token_seq(token_seq)
  );

  // ---------------- monitors ----------------
  int fout [NSYM];
  int n_ord [NSYM];
  int n_pkt [NSYM];
  int stock_bad = 0;

  always @(posedge clk) if (rst_n && o_valid) begin
    if (o_is_buy) $fdisplay(fout[o_sym], "%0d BUY qty=%0d px=%0d",  o_ts, o_qty, o_price);
    else          $fdisplay(fout[o_sym], "%0d SELL qty=%0d px=%0d", o_ts, o_qty, o_price);
    n_ord[o_sym]++;
  end

  // The Stock field: OUCH 4.2 Enter Order puts it at byte 23 of the message,
  // and the message starts at byte 3 of the SoupBinTCP frame the builder emits
  // -- so byte 23 of the packet, which is what the builder indexes. Checked on
  // the packet rather than trusted from the config, because the whole point of
  // the change is that the builder picks the right slice of cfg_stock.
  // bld.i_sym is sampled here rather than latched: the packet is registered on
  // the cycle the intent is accepted, so the tag that built it is the one
  // presented on that cycle.
  logic [SYMW-1:0] pkt_sym;
  always @(posedge clk) if (rst_n && o_valid && o_ready) pkt_sym <= o_sym;

  always @(posedge clk) if (rst_n && p_tvalid) begin
    automatic logic [63:0] stock = p_tdata[8*23 +: 64];
    automatic logic [63:0] want  = (pkt_sym == 1)
                                 ? {" ", " ", " ", " ", "T", "F", "S", "M"}
                                 : {" ", " ", " ", " ", "L", "P", "A", "A"};
    n_pkt[pkt_sym]++;
    if (stock !== want) begin
      stock_bad++;
      if (stock_bad <= 3)
        $display("FAIL: packet for symbol %0d carries stock %s, expected %s",
                 pkt_sym, stock, want);
    end
  end

  // ---------------- stimulus ----------------
  string bbo_path, out_path [NSYM], line;
  int    fin, rec = 0;
  longint unsigned bbo_ts;
  int unsigned     bp, bq, ap, aq;
  bit              have_bbo = 0;

  task automatic read_bbo;
    string l;
    have_bbo = 0;
    while ($fgets(l, fin) > 0)
      if ($sscanf(l, "%d bid=%d:%d ask=%d:%d", bbo_ts, bp, bq, ap, aq) == 5) begin
        have_bbo = 1; return;
      end
  endtask

  // Present one record to one symbol. Driven on the negedge, as everywhere in
  // this repo -- driving on the posedge the DUT samples is a race that xsim and
  // Verilator resolve differently (see tb_strategy.sv's note).
  task automatic drive(input int unsigned sym);
    @(negedge clk);
    i_valid = 1'b1; i_sym = SYMW'(sym); i_ts = bbo_ts[47:0];
    i_has_bid = (bp != 0); i_bid_price = bp; i_bid_qty = bq;
    i_has_ask = (ap != 0); i_ask_price = ap; i_ask_qty = aq;
    @(negedge clk);
    i_valid = 1'b0;
    repeat (4) @(posedge clk);
  endtask

  initial begin
    if (!$value$plusargs("bbo=%s", bbo_path)) bbo_path = "bbo_in.log";
    if (!$value$plusargs("out0=%s", out_path[0])) out_path[0] = "orders_rtl_s0.log";
    if (!$value$plusargs("out1=%s", out_path[1])) out_path[1] = "orders_rtl_s1.log";

    for (int k = 0; k < NSYM; k++) begin
      fout[k]  = $fopen(out_path[k], "w");
      n_ord[k] = 0;
      n_pkt[k] = 0;
    end

    fin = $fopen(bbo_path, "r");
    if (fin == 0) begin $display("FATAL: cannot open %s", bbo_path); $finish; end

    repeat (5) @(negedge clk);
    rst_n = 1'b1;
    repeat (2) @(negedge clk);

    read_bbo();
    while (have_bbo) begin
      rec++;
      // the same record to both books, back to back
      for (int k = 0; k < NSYM; k++) drive(k);
      read_bbo();
    end

    repeat (50) @(posedge clk);
    for (int k = 0; k < NSYM; k++) $fclose(fout[k]);
    $fclose(fin);

    $display("TB done: %0d records to each of %0d symbols", rec, NSYM);
    for (int k = 0; k < NSYM; k++)
      $display("  symbol %0d: %0d orders, %0d OUCH packets, position %0d",
               k, n_ord[k], n_pkt[k], $signed(position[32*k +: 32]));
    $display("  blocked: pos=%0d inflight=%0d txfull=%0d qty=%0d",
             blk_pos_cnt, blk_inflight_cnt, blk_txfull_cnt, blk_qty_cnt);

    if (stock_bad != 0)
      $display("FAIL: %0d OUCH packet(s) carried the wrong stock symbol", stock_bad);
    // The in-flight limiter is configured not to bind here (see the header). If
    // it fired anyway the two order streams are not comparable with a
    // single-symbol golden and the diff below would be meaningless.
    if (blk_inflight_cnt != 0)
      $display("FAIL: the shared in-flight limiter blocked %0d order(s), and this run is configured so it cannot",
               blk_inflight_cnt);
    for (int k = 0; k < NSYM; k++) begin
      if (n_ord[k] == 0) $display("FAIL: symbol %0d sent no orders", k);
      if (n_ord[k] != n_pkt[k])
        $display("FAIL: symbol %0d sent %0d orders and built %0d packets",
                 k, n_ord[k], n_pkt[k]);
    end
    $finish;
  end
endmodule
