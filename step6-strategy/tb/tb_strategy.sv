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
  logic        i_sweep = 0, i_sweep_is_buy = 0;

  logic        o_valid, o_is_buy;
  logic [47:0] o_ts;
  logic [31:0] o_qty, o_price;
  logic        o_ready;              // driven by the OUCH builder's readiness

  // OUCH builder outputs
  logic [511:0] p_tdata;
  logic [63:0]  p_tkeep;
  logic         p_tvalid, p_tlast;
  logic         p_tready;            // driven by the TCP engine's readiness
  logic [31:0]  pkt_cnt, token_seq;

  // TCP engine outputs
  logic [511:0] f_tdata;
  logic [63:0]  f_tkeep;
  logic         f_tvalid, f_tlast;
  logic         f_tready = 1;        // golden models no MAC backpressure
  logic [31:0]  seq_num, frame_cnt;
  logic         cfg_load = 0;

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
    .cfg_sweep_en(1'b1), .i_sweep(i_sweep), .i_sweep_is_buy(i_sweep_is_buy),
    .i_ack(i_ack),
    .o_valid(o_valid), .o_ts(o_ts), .o_is_buy(o_is_buy),
    .o_qty(o_qty), .o_price(o_price), .o_ready(o_ready),
    .sent_cnt(sent_cnt), .blk_pos_cnt(blk_pos_cnt),
    .blk_inflight_cnt(blk_inflight_cnt), .blk_txfull_cnt(blk_txfull_cnt),
    .position(position), .inflight(inflight)
  );

  // chained, so this run checks the strategy AND the packet it produces
  ouch_builder #(.DATA_W(512)) bld (
    .clk(clk), .rst_n(rst_n),
    .cfg_token_prefix({"1", "0", "A", "G", "P", "F"}),   // "FPGA01", byte 0 first
    .cfg_stock({" ", " ", " ", " ", "L", "P", "A", "A"}), // "AAPL    "
    .cfg_firm({"1", "T", "F", "H"}),                      // "HFT1"
    .cfg_tif(32'd0),                                      // IOC
    .cfg_min_qty(32'd0),
    .cfg_display("Y"), .cfg_capacity("P"), .cfg_sweep("N"),
    .cfg_cross("N"), .cfg_cust("N"),
    .i_valid(o_valid), .i_is_buy(o_is_buy), .i_qty(o_qty), .i_price(o_price),
    .i_ready(o_ready),
    .m_tdata(p_tdata), .m_tkeep(p_tkeep), .m_tvalid(p_tvalid), .m_tlast(p_tlast),
    .m_tready(p_tready),
    .pkt_cnt(pkt_cnt), .token_seq(token_seq)
  );

  tcp_tx #(.DATA_W(512), .PAYLD_B(52)) tx (
    .clk(clk), .rst_n(rst_n),
    .cfg_dst_mac(48'hAABBCCDDEEFF), .cfg_src_mac(48'h001122334455),
    .cfg_src_ip(32'h0A000002),  .cfg_dst_ip(32'h0A000009),
    .cfg_src_port(16'd40001),   .cfg_dst_port(16'd4001),
    .cfg_init_seq(32'h10000000), .cfg_ack_num(32'h20000000),
    .cfg_window(16'd65535), .cfg_init_id(16'h1000), .cfg_load(cfg_load),
    .s_tdata(p_tdata), .s_tvalid(p_tvalid), .s_tready(p_tready),
    .m_tdata(f_tdata), .m_tkeep(f_tkeep), .m_tvalid(f_tvalid), .m_tlast(f_tlast),
    .m_tready(f_tready),
    .seq_num(seq_num), .frame_cnt(frame_cnt)
  );

  int          fout, fpkt, ffrm;
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

  // packet monitor: dump the framed bytes as hex, byte 0 first, so the line
  // matches what dump_ouch.py prints via bytes.hex()
  always @(posedge clk) begin
    if (rst_n && p_tvalid && p_tready) begin
      automatic int nb = 0;
      for (int i = 0; i < 64; i++) if (p_tkeep[i]) nb++;
      for (int i = 0; i < nb; i++) $fwrite(fpkt, "%02x", p_tdata[8*i +: 8]);
      $fwrite(fpkt, "\n");
    end
  end

  // frame monitor: a frame spans two beats, so accumulate then print one line
  logic [8*106-1:0] frm_acc;
  int               frm_bytes = 0;
  always @(posedge clk) begin
    if (rst_n && f_tvalid && f_tready) begin
      automatic int nb = 0;
      for (int i = 0; i < 64; i++) if (f_tkeep[i]) nb++;
      for (int i = 0; i < nb; i++) frm_acc[8*(frm_bytes + i) +: 8] = f_tdata[8*i +: 8];
      frm_bytes += nb;
      if (f_tlast) begin
        for (int i = 0; i < frm_bytes; i++) $fwrite(ffrm, "%02x", frm_acc[8*i +: 8]);
        $fwrite(ffrm, "\n");
        frm_bytes = 0;
      end
    end
  end

  string bbo_path, out_path, pkt_path, frm_path, sw_path, line;
  int    fin, fsw = 0, rec = 0, code;

  // two-way merge lookahead: the BBO log and the sweep log are each already in
  // timestamp order, so a stable merge (BBO before sweep at equal ts) reproduces
  // exactly the event order the combined golden processes.
  bit              have_bbo = 0, have_sw = 0, sw_is_buy = 0;
  longint unsigned bbo_ts, sw_ts;
  int unsigned     bp, bq, ap, aq;
  int unsigned     sent_before;

  task automatic read_bbo;
    string l;
    have_bbo = 0;
    while ($fgets(l, fin) > 0)
      if ($sscanf(l, "%d bid=%d:%d ask=%d:%d", bbo_ts, bp, bq, ap, aq) == 5) begin
        have_bbo = 1; return;
      end
  endtask

  task automatic read_sw;
    string l, dir;
    have_sw = 0;
    if (fsw == 0) return;
    while ($fgets(l, fsw) > 0)
      if ($sscanf(l, "%d %s", sw_ts, dir) == 2) begin
        sw_is_buy = (dir == "BUY"); have_sw = 1; return;
      end
  endtask

  // drive one BBO event: process its acks, pulse i_valid, schedule this event's
  // ack if it fired an order (sent_cnt is the DUT's own count)
  // Stimulus is driven on the NEGEDGE, like every other testbench in this repo
  // (tb_t2t.sv, tb_t2t_axil_full.sv). Driving it with blocking assignments just
  // after @(posedge clk) -- the same edge the DUT samples on -- is a race, and
  // not a harmless one: xsim resolved it the other way from Verilator, so the
  // DUT saw each BBO one record late. The log then showed every order shifted to
  // the following record's timestamp and price, and the last order vanished
  // because there was no further record to shift onto. Verilator passed, xsim
  // failed, and neither was reporting a design bug.
  task automatic drive_bbo;
    rec++;
    while (acks_due[rec] > 0) begin
      @(negedge clk); i_ack = 1'b1;
      @(negedge clk); i_ack = 1'b0;
      acks_due[rec]--;
    end
    sent_before = sent_cnt;
    @(negedge clk);
    i_valid = 1'b1; i_ts = bbo_ts[47:0];
    i_has_bid = (bp != 0); i_bid_price = bp; i_bid_qty = bq;
    i_has_ask = (ap != 0); i_ask_price = ap; i_ask_qty = aq;
    @(negedge clk);
    i_valid = 1'b0;
    repeat (4) @(posedge clk);
    if (sent_cnt != sent_before && (rec + ACK_GAP) < MAXREC)
      acks_due[rec + ACK_GAP] += (sent_cnt - sent_before);
  endtask

  // drive one sweep event: no rec increment (acks are consumed on BBO records),
  // but schedule this order's ack at the current record like any other
  task automatic drive_sweep;
    sent_before = sent_cnt;
    @(negedge clk);
    i_sweep = 1'b1; i_sweep_is_buy = sw_is_buy;
    @(negedge clk);
    i_sweep = 1'b0;
    repeat (4) @(posedge clk);
    if (sent_cnt != sent_before && (rec + ACK_GAP) < MAXREC)
      acks_due[rec + ACK_GAP] += (sent_cnt - sent_before);
  endtask

  initial begin
    if (!$value$plusargs("bbo=%s", bbo_path)) bbo_path = "bbo_gold.log";
    if (!$value$plusargs("out=%s", out_path)) out_path = "orders_rtl.log";
    if (!$value$plusargs("pkt=%s", pkt_path)) pkt_path = "ouch_rtl.log";
    if (!$value$plusargs("frm=%s", frm_path)) frm_path = "frames_rtl.log";
    if ($value$plusargs("sweep=%s", sw_path)) fsw = $fopen(sw_path, "r");
    fin  = $fopen(bbo_path, "r");
    fout = $fopen(out_path, "w");
    fpkt = $fopen(pkt_path, "w");
    ffrm = $fopen(frm_path, "w");
    if (fin == 0)  begin $display("FAIL: cannot open %s", bbo_path); $finish; end

    repeat (5) @(negedge clk);
    rst_n = 1;
    @(negedge clk);
    cfg_load = 1;                    // software hands over the established connection
    @(negedge clk);
    cfg_load = 0;
    repeat (5) @(negedge clk);

    // stable two-way merge: BBO before sweep at an equal timestamp
    read_bbo();
    read_sw();
    while (have_bbo || have_sw) begin
      if (have_bbo && (!have_sw || bbo_ts <= sw_ts)) begin
        drive_bbo();
        read_bbo();
      end else begin
        drive_sweep();
        read_sw();
      end
    end

    repeat (20) @(posedge clk);
    $fclose(fout);
    $fclose(fpkt);
    $fclose(ffrm);
    $display("TB done: %0d records, %0d orders (pos=%0d inflight=%0d)",
             rec, sent_cnt, position, inflight);
    $display("  blocked: position=%0d inflight=%0d tx-full=%0d",
             blk_pos_cnt, blk_inflight_cnt, blk_txfull_cnt);
    // the golden has no TX backpressure model, so any tx-full block would mean
    // the two are being asked different questions
    if (blk_txfull_cnt != 0) $display("FAIL: tx-full blocked -- the builder stalled the strategy");
    if (pkt_cnt != sent_cnt) $display("FAIL: %0d orders but %0d packets", sent_cnt, pkt_cnt);
    if (frame_cnt != pkt_cnt) $display("FAIL: %0d packets but %0d frames", pkt_cnt, frame_cnt);
    $display("  next seq=%08x (expect %08x)", seq_num, 32'h10000000 + 52*frame_cnt);
    $finish;
  end

endmodule
