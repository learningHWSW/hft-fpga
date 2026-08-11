// Self-checking TB for order_table, fed through the step-2 decoder.
//
// file(.itch) -> itch_decoder(64b) -> order_table. Drives each ITCH message
// as one AXI-Stream packet; the decoder's itch_msg_t/valid feeds the table.
// Logs one book-delta record per table output to book_rtl.log, diffed by the
// Makefile against scripts/dump_book.py (golden).
//
// +itch=<path> stimulus, +loc=<n> tracked stock locate (default 1, synthetic
// AAPL). Asserts no decoded message is dropped (table always ready in time)
// and overflow_cnt==0 (table sized for the symbol, FINDINGS §4.2).
//
// Runs unmodified under xsim and Verilator --binary --timing.
`timescale 1ns/1ps

module tb_order_table;
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

  // TB_NSYM symbols share the table. The default of 1 keeps every existing run
  // exactly as it was; the multi-symbol run compiles with -d TB_NSYM=2 and
  // passes a second locate, which is what proves a delta finds its way back to
  // the right book from an entry that stores an index and not a locate.
`ifndef TB_NSYM
  `define TB_NSYM 1
`endif
  localparam int NSYM = `TB_NSYM;
  localparam int SYMW = (NSYM > 1) ? $clog2(NSYM) : 1;
  logic [NSYM*16-1:0] track_locate = {NSYM{16'd1}};
  logic [SYMW-1:0]    o_sym;
  logic        s_ready;
  logic        o_valid;
  logic [7:0]  o_type, o_side;
  logic [15:0] o_locate;
  logic        o_has_rem, o_has_add;
  logic [31:0] o_rem_price, o_rem_qty, o_add_price, o_add_qty;
  logic [31:0] overflow_cnt, miss_cnt;
  logic        init_done;

  itch_decoder #(.DATA_W(DATA_W)) dec (
    .clk(clk), .rst_n(rst_n),
    .s_tdata(tdata), .s_tkeep(tkeep), .s_tvalid(tvalid), .s_tlast(tlast), .s_tready(tready),
    .m_msg(msg), .m_valid(mvalid), .m_len_err(len_err)
  );

  order_table #(.SETS_BITS(16), .WAYS(8), .NSYM(NSYM)) dut (
    .clk(clk), .rst_n(rst_n),
    .track_locate(track_locate),
    .s_msg(msg), .s_valid(mvalid), .s_ready(s_ready),
    .o_valid(o_valid), .o_type(o_type), .o_ts(), .o_locate(o_locate),
    .o_sym(o_sym), .o_side(o_side),
    .o_has_rem(o_has_rem), .o_rem_price(o_rem_price), .o_rem_qty(o_rem_qty),
    .o_has_add(o_has_add), .o_add_price(o_add_price), .o_add_qty(o_add_qty),
    .init_done(init_done),
    .overflow_cnt(overflow_cnt), .miss_cnt(miss_cnt)
  );

  // ---------- monitor ----------
  int fd_log;
  int n_out = 0, n_dropped = 0;
  initial fd_log = $fopen("book_rtl.log", "w");

  always @(posedge clk) begin
    if (rst_n) begin
      if (mvalid && !s_ready) n_dropped++;   // table busy when a msg arrived
      if (o_valid) begin
        n_out++;
        $fdisplay(fd_log, "%c locate=%0d side=%c rem=%0d:%0d add=%0d:%0d",
                  o_type, o_locate, o_side,
                  o_rem_price, o_rem_qty, o_add_price, o_add_qty);
      end
    end
  end

  // ---------- driver (file -> decoder) ----------
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
    if ($value$plusargs("loc=%d", loc))
      for (int k = 0; k < NSYM; k++) track_locate[16*k +: 16] = loc[15:0];
    // +loc2 fills the second slot. Every slot is written first, so an unused
    // one holds a duplicate of the first rather than zero -- locate 0 is a real
    // locate, and a table that tracked it by accident would admit stray orders.
    if ($value$plusargs("loc2=%d", loc) && NSYM > 1) track_locate[16*1 +: 16] = loc[15:0];

    fd = $fopen(fname, "rb");
    if (fd == 0) begin $display("FATAL: cannot open %s", fname); $finish; end

    tvalid = 1'b0; tlast = 1'b0; tkeep = '0; tdata = '0;
    repeat (5) @(negedge clk);
    rst_n = 1'b1;
    repeat (2) @(negedge clk);

    // Wait out the clear sweep before feeding anything. The table holds s_ready
    // low for SETS cycles after reset while it zeroes every way, and this
    // testbench used to drive straight through that window: the inserts still
    // emitted their add-deltas (an A needs no lookup), every write was
    // overwritten by the sweep's zeros, and so every later E/X/U/D/C missed. The
    // log came out with the five inserts and none of the five lookups, which
    // reads like a broken order table and is really a testbench that started too
    // early. The full chain never had the bug because fh_core exports init_done
    // and the kernel gates the feed on it.
    @(posedge init_done);
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
      // Space the messages far enough apart that the table is always idle when
      // the decoder presents the next one. The table is a correctness-first FSM
      // (2 cycles per message, 3 for U) and applies real backpressure on
      // s_ready; the full chain absorbs that with the message FIFO in fh_core,
      // but this testbench feeds the decoder directly and has no such buffer. A
      // 0-2 cycle gap let the decoder finish a short message while the table was
      // still busy with the previous one, and those messages were silently
      // dropped -- three of them, which is why the F insert and its matching D
      // were missing from the log. Four cycles clears the worst case (U); the
      // random part on top keeps the phase relationship from being fixed.
      repeat (4 + $urandom_range(0, 2)) @(negedge clk);
    end
    $fclose(fd);

    repeat (20) @(posedge clk);
    $fclose(fd_log);
    $display("TB done: %0d book records, dropped=%0d overflow=%0d miss=%0d",
             n_out, n_dropped, overflow_cnt, miss_cnt);
    if (n_dropped != 0 || overflow_cnt != 0)
      $display("FAIL: dropped=%0d overflow=%0d", n_dropped, overflow_cnt);
    $finish;
  end

endmodule
