// Self-checking TB for the sweep detector:
//   file(.itch) -> itch_decoder -> [msg FIFO] -> order_table -> sweep_detect.
// Logs the sweep sequence to sweep_rtl.log; the Makefile diffs it against
// scripts/dump_sweep.py (the detection half; the forward-return validation is
// Python-only analysis, not something hardware produces).
//
// The order table is the real 2^13 x 16 URAM instance, so the executions the
// detector sees are the ones the book actually resolves -- a book bug cannot
// masquerade as a detector bug.
//
// +itch=<path> stimulus, +loc=<n> tracked locate, +min=<n> +gap=<ns> params.
`timescale 1ns/1ps
module tb_sweep;
  import itch5_pkg::*;

  localparam int DATA_W = 64;
  localparam int KEEP_W = DATA_W / 8;

  logic clk = 1'b0, rst_n = 1'b0;
  always #1.552 clk = ~clk;

  logic [DATA_W-1:0] tdata;
  logic [KEEP_W-1:0] tkeep;
  logic tvalid, tlast, tready;
  itch_msg_t msg;
  logic mvalid, len_err;

  logic [15:0] track_locate = 16'd13;
  logic [31:0] cfg_min_levels = 32'd2;
  logic [47:0] cfg_gap        = 48'd1000000;

  // order_table outputs
  logic        ot_ready, ot_valid;
  logic [7:0]  ot_type, ot_side;
  logic [47:0] ot_ts;
  logic [15:0] ot_locate;
  logic        ot_has_rem, ot_has_add;
  logic [31:0] ot_rem_price, ot_rem_qty, ot_add_price, ot_add_qty;
  logic [31:0] overflow_cnt, miss_cnt;
  logic        ot_init_done;

  // sweep_detect outputs
  logic        sw_sweep, sw_is_buy;
  logic [31:0] sw_levels, sw_shares, sweep_cnt;
  logic [47:0] sw_ts_end;
  logic        flush = 1'b0;

  itch_decoder #(.DATA_W(DATA_W)) dec (
    .clk(clk), .rst_n(rst_n),
    .s_tdata(tdata), .s_tkeep(tkeep), .s_tvalid(tvalid), .s_tlast(tlast), .s_tready(tready),
    .m_msg(msg), .m_valid(mvalid), .m_len_err(len_err)
  );

  localparam int MSGW = $bits(itch_msg_t);
  logic            mf_valid, mf_ready;
  logic [MSGW-1:0] mf_data;
  logic [31:0]     mf_drop;

  logic [6:0] mf_level;
  drop_fifo #(.WIDTH(MSGW), .DEPTH(64)) u_msg_fifo (
    .clk(clk), .rst_n(rst_n),
    .push_valid(mvalid), .push_data(msg),
    .pop_valid(mf_valid), .pop_data(mf_data), .pop_ready(mf_ready),
    .drop_cnt(mf_drop), .level(mf_level), .level_max()
  );

  order_table #(.SETS_BITS(13), .WAYS(16)) ot (
    .clk(clk), .rst_n(rst_n), .track_locate(track_locate),
    .s_msg(itch_msg_t'(mf_data)), .s_valid(mf_valid), .s_ready(mf_ready),
    .o_valid(ot_valid), .o_type(ot_type), .o_ts(ot_ts), .o_locate(ot_locate), .o_side(ot_side),
    .o_has_rem(ot_has_rem), .o_rem_price(ot_rem_price), .o_rem_qty(ot_rem_qty),
    .o_has_add(ot_has_add), .o_add_price(ot_add_price), .o_add_qty(ot_add_qty),
    .init_done(ot_init_done), .overflow_cnt(overflow_cnt), .miss_cnt(miss_cnt)
  );

  sweep_detect u_sweep (
    .clk(clk), .rst_n(rst_n),
    .cfg_min_levels(cfg_min_levels), .cfg_gap(cfg_gap),
    .i_valid(ot_valid), .i_type(ot_type), .i_side(ot_side),
    .i_has_rem(ot_has_rem), .i_price(ot_rem_price), .i_qty(ot_rem_qty), .i_ts(ot_ts),
    .i_flush(flush),
    .o_sweep(sw_sweep), .o_is_buy(sw_is_buy),
    .o_levels(sw_levels), .o_shares(sw_shares), .o_ts_end(sw_ts_end),
    .sweep_cnt(sweep_cnt)
  );

  // ---------- monitor ----------
  int fd_log;
  initial fd_log = $fopen("sweep_rtl.log", "w");
  always @(posedge clk) if (rst_n && sw_sweep) begin
    if (sw_is_buy) $fdisplay(fd_log, "%0d BUY levels=%0d shares=%0d",
                             sw_ts_end, sw_levels, sw_shares);
    else           $fdisplay(fd_log, "%0d SELL levels=%0d shares=%0d",
                             sw_ts_end, sw_levels, sw_shares);
  end

  // ---------- driver ----------
  byte unsigned payload[];

  // The decoder feeds the msg FIFO with no backpressure and the order table
  // drains it at ~6 cy/msg (URAM read latency), so at full injection the
  // depth-64 FIFO overflows and drops (830 k on the first attempt), diverging
  // from the golden. This TB over-drives like `stress`; to keep every execution
  // reaching the detector, pace injection on the FIFO level -- wait at the
  // message boundary while it is more than half full. The decoder's s_tready
  // does not help: it reflects the decoder accepting input, not the FIFO being
  // full downstream of it.
  task automatic send_msg(input int n);
    int i, k;
    i = 0;
    while (mf_level > 7'd40) @(negedge clk);   // let the table drain the FIFO
    while (i < n) begin
      k = (n - i > KEEP_W) ? KEEP_W : (n - i);
      @(negedge clk);
      tdata = '0; tkeep = '0;
      for (int j = 0; j < k; j++) begin
        tdata[8*j +: 8] = payload[i+j];
        tkeep[j] = 1'b1;
      end
      tvalid = 1'b1;
      tlast  = (i + k == n);
      i += k;
    end
    @(negedge clk);
    tvalid = 1'b0; tlast = 1'b0; tkeep = '0;
  endtask

  initial begin
    string fname;
    int fd, c1, c2, len, loc, mn, gp;

    fname = "../step5-board/real.itch";
    void'($value$plusargs("itch=%s", fname));
    if ($value$plusargs("loc=%d", loc)) track_locate = loc[15:0];
    if ($value$plusargs("min=%d", mn))  cfg_min_levels = mn;
    if ($value$plusargs("gap=%d", gp))  cfg_gap = gp;

    fd = $fopen(fname, "rb");
    if (fd == 0) begin $display("FATAL: cannot open %s", fname); $finish; end

    tvalid = 1'b0; tlast = 1'b0; tkeep = '0; tdata = '0;
    repeat (5) @(negedge clk);
    rst_n = 1'b1;
    wait (ot_init_done);              // URAM clear sweep; see order_table
    repeat (2) @(negedge clk);

    forever begin
      c1 = $fgetc(fd);
      if (c1 == -1) break;
      c2 = $fgetc(fd);
      len = (c1 << 8) | c2;
      if (len == 0 || len > 64) begin $display("FATAL: bad frame length %0d", len); break; end
      payload = new[len];
      for (int x = 0; x < len; x++) payload[x] = byte'($fgetc(fd));
      send_msg(len);
    end
    $fclose(fd);

    // let the last executions drain through the table, then flush the open run
    repeat (30) @(posedge clk);
    @(negedge clk); flush = 1'b1;
    @(negedge clk); flush = 1'b0;
    repeat (5) @(posedge clk);
    $fclose(fd_log);

    $display("TB done: %0d sweeps (min=%0d gap=%0d) overflow=%0d msg_drop=%0d",
             sweep_cnt, cfg_min_levels, cfg_gap, overflow_cnt, mf_drop);
    if (overflow_cnt != 0) $display("FAIL: table overflow %0d", overflow_cnt);
    if (mf_drop != 0)      $display("FAIL: %0d messages dropped before the table", mf_drop);
    $finish;
  end

endmodule
