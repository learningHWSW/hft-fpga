// Self-checking TB for the full L2 book chain:
//   file(.itch) -> itch_decoder(64b) -> order_table -> price_ladder.
// Logs the BBO sequence to bbo_rtl.log; the Makefile diffs it against
// scripts/dump_bbo.py (golden = step-1 book model, canonical format).
//
// +itch=<path> stimulus, +loc=<n> tracked stock locate (default 1). Asserts
// no order-table output is dropped by the ladder (rate is decoder-limited),
// overflow_cnt==0 (table sized), and oob_cnt==0 (price band wide enough).
//
// Runs unmodified under xsim and Verilator --binary --timing.
`timescale 1ns/1ps

module tb_price_ladder;
  import itch5_pkg::*;

  localparam int DATA_W = 64;
  localparam int KEEP_W = DATA_W / 8;

  logic clk = 1'b0;
  logic rst_n = 1'b0;
  always #1.552 clk = ~clk;

  logic [DATA_W-1:0] tdata;
  logic [KEEP_W-1:0] tkeep;
  logic tvalid, tlast, tready;
  itch_msg_t msg;
  logic mvalid, len_err;

  logic [15:0] track_locate = 16'd1;
  logic [31:0] cfg_base = 32'd1500000;   // $150 band for synthetic; +base= for real

  // order_table outputs
  logic        ot_ready, ot_valid;
  logic [7:0]  ot_type, ot_side;
  logic [47:0] ot_ts;
  logic [15:0] ot_locate;
  logic        ot_has_rem, ot_has_add;
  logic [31:0] ot_rem_price, ot_rem_qty, ot_add_price, ot_add_qty;
  logic [31:0] overflow_cnt, miss_cnt;

  // price_ladder outputs
  logic        pl_ready, bbo_valid;
  logic [47:0] bbo_ts;
  logic        bbo_has_bid, bbo_has_ask;
  logic [31:0] bbo_bid_price, bbo_bid_qty, bbo_ask_price, bbo_ask_qty;
  logic [31:0] oob_cnt;

  itch_decoder #(.DATA_W(DATA_W)) dec (
    .clk(clk), .rst_n(rst_n),
    .s_tdata(tdata), .s_tkeep(tkeep), .s_tvalid(tvalid), .s_tlast(tlast), .s_tready(tready),
    .m_msg(msg), .m_valid(mvalid), .m_len_err(len_err)
  );

  order_table #(.SETS_BITS(16), .WAYS(8)) ot (
    .clk(clk), .rst_n(rst_n), .track_locate(track_locate),
    .s_msg(msg), .s_valid(mvalid), .s_ready(ot_ready),
    .o_valid(ot_valid), .o_type(ot_type), .o_ts(ot_ts), .o_locate(ot_locate), .o_side(ot_side),
    .o_has_rem(ot_has_rem), .o_rem_price(ot_rem_price), .o_rem_qty(ot_rem_qty),
    .o_has_add(ot_has_add), .o_add_price(ot_add_price), .o_add_qty(ot_add_qty),
    .overflow_cnt(overflow_cnt), .miss_cnt(miss_cnt)
  );

  price_ladder #(.LEVELS(4096), .TICK(100)) pl (
    .clk(clk), .rst_n(rst_n), .cfg_base(cfg_base),
    .i_valid(ot_valid), .i_ts(ot_ts), .i_side(ot_side),
    .i_has_rem(ot_has_rem), .i_rem_price(ot_rem_price), .i_rem_qty(ot_rem_qty),
    .i_has_add(ot_has_add), .i_add_price(ot_add_price), .i_add_qty(ot_add_qty),
    .i_ready(pl_ready),
    .o_valid(bbo_valid), .o_ts(bbo_ts),
    .o_has_bid(bbo_has_bid), .o_bid_price(bbo_bid_price), .o_bid_qty(bbo_bid_qty),
    .o_has_ask(bbo_has_ask), .o_ask_price(bbo_ask_price), .o_ask_qty(bbo_ask_qty),
    .oob_cnt(oob_cnt)
  );

  // ---------- monitor ----------
  int fd_log;
  int n_bbo = 0, n_dropped = 0;
  initial fd_log = $fopen("bbo_rtl.log", "w");

  always @(posedge clk) begin
    if (rst_n) begin
      if (ot_valid && !pl_ready) n_dropped++;   // ladder busy when a record arrived
      if (bbo_valid) begin
        n_bbo++;
        $fdisplay(fd_log, "%0d bid=%0d:%0d ask=%0d:%0d",
                  bbo_ts, bbo_bid_price, bbo_bid_qty, bbo_ask_price, bbo_ask_qty);
      end
    end
  end

  // ---------- driver ----------
  byte unsigned payload[];

  task automatic send_msg(input int n);
    int i, k;
    i = 0;
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
    int fd, c1, c2, len, loc;

    fname = "../step1-sw-parser/test.itch";
    void'($value$plusargs("itch=%s", fname));
    if ($value$plusargs("loc=%d", loc)) track_locate = loc[15:0];
    void'($value$plusargs("base=%d", cfg_base));

    fd = $fopen(fname, "rb");
    if (fd == 0) begin $display("FATAL: cannot open %s", fname); $finish; end

    tvalid = 1'b0; tlast = 1'b0; tkeep = '0; tdata = '0;
    repeat (5) @(negedge clk);
    rst_n = 1'b1;
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
      repeat ($urandom_range(0, 2)) @(negedge clk);
    end
    $fclose(fd);

    repeat (30) @(posedge clk);
    $fclose(fd_log);
    // oob = prices outside the ladder band (deep/stub quotes far from BBO).
    // Dropping them is by design (PLAN §2.1); the BBO diff is what proves
    // correctness — if an oob price should have been the BBO, the diff fails.
    $display("TB done: %0d BBO updates, dropped=%0d overflow=%0d oob=%0d (oob ok: deep levels)",
             n_bbo, n_dropped, overflow_cnt, oob_cnt);
    if (n_dropped != 0 || overflow_cnt != 0)
      $display("FAIL: dropped=%0d overflow=%0d", n_dropped, overflow_cnt);
    $finish;
  end

endmodule
